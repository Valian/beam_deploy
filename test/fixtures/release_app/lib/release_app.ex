defmodule ReleaseApp do
  @moduledoc false
  @version System.get_env("FIXTURE_RESPONSE_VERSION", "v0")

  def version, do: @version
end
