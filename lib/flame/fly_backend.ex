defmodule FLAME.FlyBackend do
  @moduledoc """
  A `FLAME.Backend` using [Fly.io](https://fly.io) machines.

  The only required configuration is telling FLAME to use the
  `FLAME.FlyBackend` by default and the `:token` which is your Fly.io API
  token. These can be set via application configuration in your `config/runtime.exs`
  withing a `:prod` block:

      if config_env() == :prod do
        config :flame, :backend, FLAME.FlyBackend
        config :flame, FLAME.FlyBackend, token: System.fetch_env!("FLY_API_TOKEN")
        ...
      end

  To set your `FLY_API_TOKEN` secret, you can run the following commands locally:

  ```bash
  $ fly secrets set FLY_API_TOKEN="$(fly auth token)"
  ```

  The following backend options are supported, and mirror the
  [Fly.io machines create API](https://fly.io/docs/machines/api/machines-resource/#machine-config-object-properties):

  * `:cpu_kind` - The size of the runner CPU. Defaults to `"performance"`.

  * `:cpus` - The number of runner CPUs. Defaults to `System.schedulers_online()`
    for the number of cores of the running parent app.

  * `:memory_mb` - The memory of the runner. Must be a 1024 multiple. Defaults to `4096`.

  * `:gpu_kind` - The type of GPU reservation to make.

  * `:gpus` - The number of runner GPUs. Defaults to `1` if `:gpu_kind` is set.

  * `:mounts` - List volumes to mount. Refer to FlyBackend.Mount for opt details

  * `:boot_timeout` - The boot timeout. Defaults to `30_000`.

  * `:app` – The name of the otp app. Defaults to `System.get_env("FLY_APP_NAME")`,

  * `:image` – The URL of the docker image to pass to the machines create endpoint.
    Defaults to `System.get_env("FLY_IMAGE_REF")` which is the image of your running app.

  * `:token` – The Fly API token. Defaults to `System.get_env("FLY_API_TOKEN")`.

  * `:host` – The host of the Fly API. Defaults to `"https://api.machines.dev"`.

  * `:init` – The init object to pass to the machines create endpoint. Defaults to `%{}`.
    Possible values include:

      * `:cmd` – list of strings for the command
      * `:entrypoint` – list strings for the entrypoint command
      * `:exec` – list of strings for the exec command
      * `:kernel_args` - list of strings
      * `:swap_size_mb` – integer value in megabytes for the swap size
      * `:tty` – boolean

  * `:services` - The optional services to run on the machine. Defaults to `[]`.

  * `:metadata` - The optional map of metadata to set for the machine. Defaults to `%{}`.

  ## Environment Variables

  The FLAME Fly machines *do not* inherit the environment variables of the parent.
  You must explicit provide the environment that you would like to forward to the
  machine. For example, if your FLAME's are starting your Ecto repos, you can copy
  the env from the parent:

  ```elixir
  config :flame, FLAME.FlyBackend,
    token: System.fetch_env!("FLY_API_TOKEN"),
    env: %{
      "DATABASE_URL" => System.fetch_env!("DATABASE_URL"),
      "POOL_SIZE" => "1"
    }
  ```

  Or pass the env to each pool:

  ```elixir
  {FLAME.Pool,
    name: MyRunner,
    backend: {FLAME.FlyBackend, env: %{"DATABASE_URL" => System.fetch_env!("DATABASE_URL")}}
  }
  ```
  """
  @behaviour FLAME.Backend

  alias FLAME.FlyBackend
  alias FLAME.Parser.JSON

  alias FLAME.FlyBackend.Mount

  require Logger

  @derive {Inspect,
           only: [
             :host,
             :init,
             :cpu_kind,
             :cpus,
             :memory_mb,
             :gpu_kind,
             :gpus,
             :mounts,
             :image,
             :app,
             :runner_id,
             :local_ip,
             :remote_terminator_pid,
             :runner_instance_id,
             :runner_private_ip,
             :runner_node_base,
             :runner_node_name,
             :boot_timeout
           ]}
  defstruct host: nil,
            init: %{},
            local_ip: nil,
            env: %{},
            region: nil,
            cpu_kind: nil,
            cpus: nil,
            memory_mb: nil,
            gpu_kind: nil,
            gpus: nil,
            mounts: [],
            image: nil,
            services: [],
            metadata: %{},
            app: nil,
            token: nil,
            boot_timeout: nil,
            runner_id: nil,
            remote_terminator_pid: nil,
            parent_ref: nil,
            runner_instance_id: nil,
            runner_private_ip: nil,
            runner_node_base: nil,
            runner_node_name: nil,
            log: nil

  @retry 10

  @valid_opts [
    :app,
    :region,
    :image,
    :token,
    :host,
    :init,
    :cpu_kind,
    :cpus,
    :memory_mb,
    :gpu_kind,
    :gpus,
    :mounts,
    :boot_timeout,
    :env,
    :terminator_sup,
    :log,
    :services,
    :metadata
  ]

  @impl true
  def init(opts) do
    conf = Application.get_env(:flame, __MODULE__) || []
    [_node_base, ip] = node() |> to_string() |> String.split("@")

    default = %FlyBackend{
      app: System.get_env("FLY_APP_NAME"),
      region: System.get_env("FLY_REGION"),
      image: System.get_env("FLY_IMAGE_REF"),
      token: System.get_env("FLY_API_TOKEN"),
      host: "https://api.machines.dev",
      cpu_kind: "performance",
      cpus: System.schedulers_online(),
      memory_mb: 4096,
      boot_timeout: 30_000,
      services: [],
      mounts: [],
      metadata: %{},
      init: %{},
      log: Keyword.get(conf, :log, false)
    }

    provided_opts =
      conf
      |> Keyword.merge(opts)
      |> Keyword.validate!(@valid_opts)

    %FlyBackend{} = state = Map.merge(default, Map.new(provided_opts))

    for key <- [:token, :image, :host, :app] do
      unless Map.get(state, key) do
        raise ArgumentError, "missing :#{key} config for #{inspect(__MODULE__)}"
      end
    end

    mounts = state.mounts |> List.wrap() |> Enum.map(&Mount.parse_opts/1)

    state =
      Map.merge(state, %{mounts: mounts, runner_node_base: "#{state.app}-flame-#{rand_id(20)}"})

    parent_ref = make_ref()

    encoded_parent =
      parent_ref
      |> FLAME.Parent.new(self(), __MODULE__, state.runner_node_base, "FLY_PRIVATE_IP")
      |> FLAME.Parent.encode()

    new_env =
      %{"PHX_SERVER" => "false", "FLAME_PARENT" => encoded_parent}
      |> Map.merge(state.env)
      |> then(fn env ->
        if flags = System.get_env("ERL_AFLAGS") do
          Map.put_new(env, "ERL_AFLAGS", flags)
        else
          env
        end
      end)
      |> then(fn env ->
        if flags = System.get_env("ERL_ZFLAGS") do
          Map.put_new(env, "ERL_ZFLAGS", flags)
        else
          env
        end
      end)

    new_state = %{state | env: new_env, parent_ref: parent_ref, local_ip: ip}

    {:ok, new_state}
  end

  @impl true
  # TODO explore spawn_request
  def remote_spawn_monitor(%FlyBackend{} = state, term) do
    case term do
      func when is_function(func, 0) ->
        {pid, ref} = Node.spawn_monitor(state.runner_node_name, func)
        {:ok, {pid, ref}}

      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        {pid, ref} = Node.spawn_monitor(state.runner_node_name, mod, fun, args)
        {:ok, {pid, ref}}

      other ->
        raise ArgumentError,
              "expected a null arity function or {mod, func, args}. Got: #{inspect(other)}"
    end
  end

  @impl true
  def system_shutdown do
    System.stop()
  end

  def with_elapsed_ms(func) when is_function(func, 0) do
    {micro, result} = :timer.tc(func)
    {result, div(micro, 1000)}
  end

  defp allocate_volume_ids(%FlyBackend{mounts: []}), do: []

  defp allocate_volume_ids(%FlyBackend{mounts: mounts} = state) when is_list(mounts) do
    case get_volumes(state) do
      [] ->
        {:error, "no Fly volumes found"}

      all_volumes ->
        volume_ids_by_name =
          all_volumes
          |> Enum.filter(fn vol ->
            vol["attached_machine_id"] == nil && vol["state"] == "created" &&
              vol["host_status"] == "ok" &&
              Map.get(state, :region, vol["region"]) == vol["region"]
          end)
          |> Enum.shuffle()
          |> Enum.group_by(& &1["name"], & &1["id"])

        {new_mounts, _unused_vols} =
          Enum.map_reduce(
            mounts,
            volume_ids_by_name,
            fn
              %{volume: nil} = mount, leftover_vols ->
                case leftover_vols[mount.name] do
                  [volume_id | rest] ->
                    {%{mount | volume: volume_id}, %{leftover_vols | mount.name => rest}}

                  _ ->
                    raise ArgumentError,
                          "no available Fly volumes with the name \"#{mount.name}\" in region \"#{Map.get(state, :region)}\" found"
                end

              mount, leftover_vols ->
                {mount, leftover_vols}
            end
          )

        Enum.map(new_mounts, &Map.from_struct/1)
    end
  end

  defp allocate_volume_ids(_) do
    raise ArgumentError, "expected a list of mounts"
  end

  defp get_volumes(%FlyBackend{} = state) do
    http_request!(:get, "#{state.host}/v1/apps/#{state.app}/volumes", @retry,
      headers: [
        {"Accept", "application/json"},
        {"Authorization", "Bearer #{state.token}"}
      ],
      connect_timeout: state.boot_timeout
    )
  end

  @impl true
  def remote_boot(%FlyBackend{parent_ref: parent_ref} = state) do
    {resp, req_connect_time} =
      with_elapsed_ms(fn ->
        http_request!(:post, "#{state.host}/v1/apps/#{state.app}/machines", @retry,
          content_type: "application/json",
          headers: [
            {"Content-Type", "application/json"},
            {"Authorization", "Bearer #{state.token}"}
          ],
          connect_timeout: state.boot_timeout,
          body: fn ->
            JSON.encode!(%{
              name: state.runner_node_base,
              region: state.region,
              config: %{
                image: state.image,
                mounts: allocate_volume_ids(state),
                init: state.init,
                guest: %{
                  cpu_kind: state.cpu_kind,
                  cpus: state.cpus,
                  memory_mb: state.memory_mb,
                  gpu_kind: state.gpu_kind,
                  gpus: if(state.gpu_kind, do: state.gpus || 1)
                },
                auto_destroy: true,
                restart: %{policy: "no"},
                env: state.env,
                services: state.services,
                metadata: Map.put(state.metadata, :flame_parent_ip, state.local_ip)
              }
            })
          end
        )
      end)

    if state.log do
      Logger.log(
        state.log,
        "#{inspect(__MODULE__)} #{inspect(node())} machine create #{req_connect_time}ms"
      )
    end

    remaining_connect_window = state.boot_timeout - req_connect_time

    case resp do
      %{"id" => id, "instance_id" => instance_id, "private_ip" => ip} ->
        new_state =
          %{
            state
            | runner_id: id,
              runner_instance_id: instance_id,
              runner_private_ip: ip
          }

        remote_terminator_pid =
          receive do
            {^parent_ref, {:remote_up, remote_terminator_pid}} ->
              remote_terminator_pid
          after
            remaining_connect_window ->
              Logger.error("failed to connect to fly machine within #{state.boot_timeout}ms")
              exit(:timeout)
          end

        new_state = %{
          new_state
          | remote_terminator_pid: remote_terminator_pid,
            runner_node_name: node(remote_terminator_pid)
        }

        {:ok, remote_terminator_pid, new_state}

      other ->
        {:error, other}
    end
  end

  defp rand_id(len) do
    len
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
    |> binary_part(0, len)
  end

  defp http_request!(method, url, remaining_tries, opts) when method in [:get, :post] do
    validation_request_opts!(method, opts)

    headers =
      for {field, val} <- Keyword.fetch!(opts, :headers),
          do: {String.to_charlist(field), val}

    request = make_request(method, url, headers, opts)
    http_opts = make_http_opts(opts)

    case :httpc.request(method, request, http_opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _, response_body}} ->
        JSON.decode!(response_body)

      # 429 Too Many Requests (rate limited)
      # 412 Precondition Failed (can't find capacity)
      # 409 Conflict (the flyd tried ending up not having capacity)
      # 422 Unprocessable Entity (could not find capcity for volume workloads)
      {:ok, {{_, status, _}, _, _response_body}}
      when status in [429, 412, 409, 422] and remaining_tries > 0 ->
        Process.sleep(1000)
        http_request!(method, url, remaining_tries - 1, opts)

      {:ok, {{_, status, reason}, _, resp_body}} ->
        raise "failed #{method} #{url} with #{inspect(status)} (#{inspect(reason)}): #{inspect(resp_body)} #{inspect(headers)}"

      {:error, reason} ->
        raise "failed #{method} #{url} with #{inspect(reason)} #{inspect(headers)}"
    end
  end

  defp validation_request_opts!(:get, opts) do
    Keyword.validate!(opts, [:headers, :connect_timeout])
  end

  defp validation_request_opts!(:post, opts) do
    Keyword.validate!(opts, [:headers, :body, :connect_timeout, :content_type])
  end

  defp make_request(:get, url, headers, _opts) do
    {url, headers}
  end

  defp make_request(:post, url, headers, opts) do
    content_type = Keyword.fetch!(opts, :content_type)

    body =
      case Keyword.fetch!(opts, :body) do
        body_func when is_function(body_func) -> body_func.()
        body -> body
      end

    {url, headers, ~c"#{content_type}", body}
  end

  defp make_http_opts(opts) do
    connect_timeout = Keyword.fetch!(opts, :connect_timeout)

    [
      ssl:
        [
          verify: :verify_peer,
          depth: 2,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ] ++ cacerts_options(),
      connect_timeout: connect_timeout
    ]
  end

  defp cacerts_options do
    cond do
      certs = otp_cacerts() ->
        [cacerts: certs]

      Application.spec(:castore, :vsn) ->
        [cacertfile: Application.app_dir(:castore, "priv/cacerts.pem")]

      true ->
        IO.warn("""
        No certificate trust store was found.

        A certificate trust store is required in
        order to download locales for your configuration.
        Since elixir_make could not detect a system
        installed certificate trust store one of the
        following actions may be taken:

        1. Use OTP 25+ on an OS that has built-in certificate
           trust store.

        2. Install the hex package `castore`. It will
           be automatically detected after recompilation.

        """)

        []
    end
  end

  if System.otp_release() >= "25" do
    defp otp_cacerts do
      :public_key.cacerts_get()
    rescue
      _ -> nil
    end
  else
    defp otp_cacerts, do: nil
  end
end
