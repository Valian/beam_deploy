defmodule ExampleWeb.DemoLive do
  use ExampleWeb, :live_view

  @choices [
    %{
      label: "Deploy the blue release",
      eyebrow: "Stable",
      description: "Return to the calm baseline build.",
      accent: "accent-blue"
    },
    %{
      label: "Ship the green build",
      eyebrow: "Fresh",
      description: "Cut over to a newly compiled green release.",
      accent: "accent-green"
    },
    %{
      label: "Promote the purple zip",
      eyebrow: "Bold",
      description: "Build a release archive and promote it live.",
      accent: "accent-purple"
    }
  ]

  @labels Enum.map(@choices, & &1.label)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(500, self(), :refresh_deployment)
    end

    {:ok, assign_demo(socket)}
  end

  @impl true
  def handle_event("deploy", %{"label" => label}, socket) when label in @labels do
    case Example.Deployer.deploy(label) do
      :ok ->
        {:noreply, assign_demo(socket)}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "A release is already building.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not start deployment: #{inspect(reason)}")}
    end
  end

  def handle_event("deploy", _params, socket) do
    {:noreply, put_flash(socket, :error, "Choose one of the demo labels.")}
  end

  @impl true
  def handle_info(:refresh_deployment, socket) do
    {:noreply, assign_demo(socket)}
  end

  defp assign_demo(socket) do
    deployment = Example.Deployer.status()

    assign(socket,
      choices: @choices,
      current_label: Example.DemoCopy.button_label(),
      deployment: deployment,
      busy?: deployment.state in [:running, :upgrading],
      status: status(deployment),
      log_lines: Enum.reverse(deployment.log)
    )
  end

  defp status(%{state: :idle}) do
    %{
      label: "Ready",
      detail: "Choose a release to build and swap in.",
      dot_class: "status-ready"
    }
  end

  defp status(%{state: :running, label: label}) do
    %{
      label: "Building",
      detail: "Compiling #{label} and packaging a release tarball.",
      dot_class: "status-running"
    }
  end

  defp status(%{state: :upgrading, label: label}) do
    %{
      label: "Swapping",
      detail: "BeamDeploy is starting the new peer for #{label}.",
      dot_class: "status-upgrading"
    }
  end

  defp status(%{state: :failed}) do
    %{
      label: "Failed",
      detail: "The build did not complete. The terminal output has the details.",
      dot_class: "status-failed"
    }
  end

  defp choice_id(label) do
    "deploy-" <> String.replace(String.downcase(label), ~r/[^a-z0-9]+/, "-")
  end
end
