defmodule ReleaseApp.Router do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/version" do
    send_resp(conn, 200, ReleaseApp.version())
  end

  get "/handoff" do
    case ReleaseApp.State.get_handoff() do
      nil -> send_resp(conn, 200, "none")
      data -> send_resp(conn, 200, inspect(data))
    end
  end

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
