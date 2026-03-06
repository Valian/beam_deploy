# BeamDeploy Integration Tests

## Goal

Add end-to-end integration tests that exercise a real `mix release` built with
`beam_deploy`, start that release as the long-lived parent node, perform an
upgrade with a second release tarball, and verify the cutover behavior from the
outside.

These tests should cover the part that unit tests do not currently prove:

- a release boots with `BeamDeploy.start_link/1`
- the parent starts a serving peer successfully
- `BeamDeploy.upgrade/1` accepts a real release tarball
- the new peer becomes active
- the old peer shuts down cleanly
- handoff and cutover callbacks work across the swap
- the HTTP listener stays usable during the transition

## Recommended Scope

Start with one strong happy-path integration test. Do not try to build the full
 matrix immediately.

First target:

1. Build release `v1`
2. Start release `v1`
3. Confirm HTTP returns `v1`
4. Build release `v2`
5. Call `BeamDeploy.upgrade(path_to_v2_tarball)`
6. Assert HTTP eventually returns `v2`
7. Assert no request failures during a burst of upgrade-time requests
8. Assert `before_cutover` -> `after_cutover` handoff data arrived
9. Assert `BeamDeploy.status()` settles with `upgrading: false`

Once that works reliably, add failure-mode tests later.

## Fixture App

Create a standalone fixture project under `test/fixtures/release_app`.

Recommended shape:

- `test/fixtures/release_app/mix.exs`
- `test/fixtures/release_app/lib/release_app/application.ex`
- `test/fixtures/release_app/lib/release_app/router.ex`
- `test/fixtures/release_app/config/config.exs`
- `test/fixtures/release_app/config/runtime.exs`
- `test/fixtures/release_app/rel/`

The fixture should depend on the local package via a path dependency:

```elixir
{:beam_deploy, path: "../../.."}
```

Keep the app intentionally small:

- one `Agent` or `GenServer` holding state
- one HTTP server
- one module exposing a compile-time version string
- one handoff callback module

## HTTP Layer

Use `Bandit` plus `Plug.Router` as test-only deps in the main repo and the
fixture app.

Why:

- the current `BeamDeploy.PeerManager` injects `SO_REUSEPORT` into
  ThousandIsland/Bandit options
- this lets the integration test verify the real listener overlap behavior
  without bringing Phoenix into the fixture

Suggested HTTP endpoints:

- `GET /version`
  Returns the release marker, for example `v1` or `v2`
- `GET /handoff`
  Returns the last handoff payload observed by the new peer
- `GET /health`
  Returns `200 OK`

## Versioning Strategy

Do not keep two separate fixture apps unless the single-template approach turns
out to be unreliable.

Recommended approach:

- make the fixture app read `FIXTURE_APP_VERSION` from the environment in
  `mix.exs`
- make the HTTP version response come from a compile-time env, for example
  `FIXTURE_RESPONSE_VERSION`
- build the same fixture twice with different env values

That gives you:

- a real release version change
- a real code change visible at runtime
- less fixture duplication

Example build inputs:

- build 1: `FIXTURE_APP_VERSION=0.1.0`, `FIXTURE_RESPONSE_VERSION=v1`
- build 2: `FIXTURE_APP_VERSION=0.2.0`, `FIXTURE_RESPONSE_VERSION=v2`

## Fixture App Behavior

The fixture application's `Application.start/2` should delegate through
`BeamDeploy.start_link/1`, not start the user supervisor directly.

Recommended runtime options:

- `otp_app: :release_app`
- `start: {__MODULE__, :start_app, [type, args]}`
- `before_cutover: {ReleaseApp.Handoff, :before_cutover, []}`
- `after_cutover: {ReleaseApp.Handoff, :after_cutover, []}`
- `endpoint: nil`

`start_app/2` should start:

- the state holder process
- the Bandit HTTP server

The handoff module should:

- in `before_cutover/1`, return a payload that includes the outgoing version
  and maybe a monotonic timestamp
- in `after_cutover/1`, write that payload into the state holder so `/handoff`
  can expose it

## Release Build Helper

Create a test helper module, not an ad hoc shell script.

Suggested module:

- `test/support/integration/release_builder.ex`

Responsibilities:

1. Copy the fixture project to a temp working directory
2. Run `mix deps.get`
3. Run `mix release`
4. Return:
   - release root
   - path to `bin/release_app`
   - path to the generated tarball

Important:

- give each build its own temp directory
- isolate build artifacts with env vars like `MIX_BUILD_ROOT`, `MIX_DEPS_PATH`,
  and `MIX_HOME` where needed
- pass the version env vars explicitly to each build

## Running the Release in Tests

Create another helper module:

- `test/support/integration/release_runner.ex`

Responsibilities:

1. Start the built release with `Port.open/2`
2. Set a unique port, cookie, and node name
3. Set `BEAM_DEPLOY=true`
4. Set `BEAM_DEPLOY_PEER_HOST=127.0.0.1`
5. Wait until the release is reachable over HTTP
6. Provide helpers for:
   - `rpc(expr)` using `bin/release_app rpc`
   - `stop()`
   - log capture on failures

Recommended runtime env:

- `PORT=<unique_port>`
- `RELEASE_NODE=release_app_<id>@127.0.0.1`
- `RELEASE_COOKIE=<unique_cookie>`
- `RELEASE_DISTRIBUTION=name`
- `BEAM_DEPLOY=true`
- `BEAM_DEPLOY_PEER_HOST=127.0.0.1`

## The First Integration Test

Create a dedicated integration test file, for example:

- `test/beam_deploy/integration/release_swap_test.exs`

Mark it with a tag:

```elixir
@tag :integration
```

Recommended flow:

1. Build fixture release `v1`
2. Start `v1`
3. Poll `GET /version` until it returns `v1`
4. Build fixture release `v2`
5. Start a task that repeatedly requests `GET /version` during the upgrade
6. Call `runner.rpc(~s|BeamDeploy.upgrade("#{tarball_v2}")|)`
7. Assert the RPC result is `:ok`
8. Poll `GET /version` until it returns `v2`
9. Assert the request burst saw:
   - no connection errors
   - at least one successful response before upgrade settles
10. Poll `GET /handoff` until it shows the payload produced by `v1`
11. Assert `runner.rpc("BeamDeploy.status()")` shows `upgrading: false`

The burst requester should tolerate seeing both `v1` and `v2` during overlap.
That is expected. The failure signal is socket errors or a long gap in
successful responses.

## Assertion Strategy

Prefer eventual assertions with bounded retries over fixed sleeps.

Use helpers like:

- `wait_until(fun, timeout: 10_000, interval: 100)`
- `eventually_http(url, expected_body)`

What to assert:

- the service becomes reachable after boot
- the service remains reachable during upgrade
- the visible version changes from `v1` to `v2`
- handoff data appears on the new peer
- `BeamDeploy.peer_node()` changes after the upgrade

## Cleanup

The helpers must aggressively clean up on success and failure.

Required cleanup:

- stop the release OS process
- collect stdout/stderr when the test fails
- remove temp build directories
- kill stuck child processes if the release does not shut down

Do not rely on the test VM exiting to clean this up.

## Mix Test Integration

Do not run these tests by default in the normal fast suite.

Recommended setup:

- keep the existing unit tests in `mix test`
- run the release tests with `mix test --only integration`

If needed, skip them in CI until the fixture is stable.

## Follow-Up Tests After the Happy Path

Add these only after the first test is stable:

1. invalid tarball returns an error and leaves the old peer serving
2. `before_cutover` failure still completes the swap and records `nil`
3. `after_cutover` failure does not kill the parent or new peer
4. repeated upgrades `v1 -> v2 -> v3`
5. shutdown timeout forces peer termination when the old peer hangs

## Acceptance Criteria

This task is complete when:

- `mix test --only integration` builds two real releases and swaps between them
- the test proves the active HTTP responder changes from `v1` to `v2`
- the test proves handoff data crossed the cutover
- the test proves the listener stayed available during the upgrade
- cleanup is reliable enough for repeated local runs
