defmodule HotReleaseApp.Router do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/version" do
    send_resp(conn, 200, HotReleaseApp.version())
  end

  get "/state" do
    send_resp(conn, 200, inspect(HotReleaseApp.StateServer.snapshot()))
  end

  get "/pid" do
    send_resp(conn, 200, inspect(Process.whereis(HotReleaseApp.StateServer)))
  end

  get "/new-module" do
    module = HotReleaseApp.NewFeature

    body =
      if Code.ensure_loaded?(module) and function_exported?(module, :value, 0) do
        to_string(module.value())
      else
        "missing"
      end

    send_resp(conn, 200, body)
  end

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
