# BeamDeploy

`BeamDeploy` is a small Elixir library for blue-green release swaps and
in-process hot upgrades on a single host.

For blue-green swaps, it keeps a long-lived parent BEAM process running locally
and serves your application from a child peer node started with OTP's `:peer`
module. When you hand it a new `mix release` tarball, it:

1. extracts the release to a temp directory
2. boots a new peer with the new code and release config
3. overlaps old and new listeners via `SO_REUSEPORT`
4. gracefully shuts down the old peer

There is no storage backend, polling loop, Docker integration, or platform
coupling in this package. You bring the release and decide when to call the
upgrade command.

## Integration

```elixir
defmodule MyApp.Application do
  use Application

  def start(type, args) do
    BeamDeploy.start_link(
      otp_app: :my_app,
      start: {__MODULE__, :start_app, [type, args]},
      endpoint: MyAppWeb.Endpoint
    )
  end

  def start_app(_type, _args) do
    children = [
      MyApp.Repo,
      MyAppWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end
```

Enable BeamDeploy only where you want the parent/peer model:

```elixir
config :beam_deploy, enabled: true
```

or:

```bash
export BEAM_DEPLOY=true
```

Outside that environment, `BeamDeploy.start_link/1` just calls your `start_app`
callback directly.

## Blue-Green Upgrading

Copy a standard `mix release` tarball onto the target host, then call:

```elixir
BeamDeploy.upgrade("/tmp/my_app-0.2.0.tar.gz")
```

Typical release command:

```bash
bin/my_app rpc 'BeamDeploy.upgrade("/tmp/my_app-0.2.0.tar.gz")'
```

Useful status helpers:

```elixir
BeamDeploy.status()
BeamDeploy.peer_node()
BeamDeploy.upgrading?()
```

## Hot Upgrading

For compatible code changes, you can reload code inside the current node
without the parent/peer runtime:

```elixir
BeamDeploy.hot_upgrade("/tmp/my_app-0.2.0.tar.gz", otp_app: :my_app)
BeamDeploy.hot_upgrade("/tmp/my_app-0.2.0.tar.gz", otp_app: :my_app, suspend_timeout: 3_000)
```

The hot upgrade path:

1. extracts the tarball to a temp directory
2. copies changed `.beam` files into the currently loaded code paths
3. loads brand new modules explicitly for embedded-mode releases
4. reloads consolidated protocol beams
5. suspends affected processes, runs `code_change/3`, and resumes them

Use hot upgrade only when the supervision tree shape is unchanged and the
running release can safely migrate state through `code_change/3`.

## Requirements

- The runtime node must be distributed (`--name` or `--sname`).
- The new release must be built with the same OTP version as the running node.
- For Phoenix/Bandit cutovers, pass your endpoint or follow the `MyAppWeb.Endpoint`
  naming convention so BeamDeploy can inject `SO_REUSEPORT`.

## Hot Upgrade Limits

Hot upgrade is not supported for:

- supervision tree topology changes
- Erlang/OTP upgrades
- NIF upgrades
- major runtime config topology changes

Use a cold deploy or the blue-green path for those cases.
