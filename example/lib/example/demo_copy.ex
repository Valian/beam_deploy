defmodule Example.DemoCopy do
  @label System.get_env("DEMO_BUTTON_LABEL", "Deploy the blue release")

  def button_label, do: @label
end
