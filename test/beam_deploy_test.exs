defmodule BeamDeployTest do
  use ExUnit.Case
  doctest BeamDeploy

  test "greets the world" do
    assert BeamDeploy.hello() == :world
  end
end
