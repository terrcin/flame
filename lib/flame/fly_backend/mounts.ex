defmodule FLAME.FlyBackend.Mounts do
  @derive {Inspect,
           only: [
             :name,
             :path,
             :volume,
             :extend_threshold_percent,
             :add_size_gb,
             :size_gb_limit
           ]}
  defstruct name: nil,
            path: nil,
            volume: nil,
            extend_threshold_percent: 0,
            add_size_gb: 0,
            size_gb_limit: 0
end
