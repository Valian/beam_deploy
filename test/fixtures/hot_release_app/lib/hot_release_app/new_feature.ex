if System.get_env("FIXTURE_ENABLE_NEW_MODULE") in ["1", "true"] do
  defmodule HotReleaseApp.NewFeature do
    @moduledoc false

    def value, do: "new-module-loaded"
  end
end
