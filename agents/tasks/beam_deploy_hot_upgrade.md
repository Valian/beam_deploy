# BeamDeploy Hot Upgrade Task

## Goal

Add an in-process hot upgrade path to `beam_deploy`, similar in spirit to
`fly_deploy` hot reloads, but without Fly-specific transport, storage, or
orchestration.

This is **not** the blue-green path already implemented in `beam_deploy`.
Instead of starting a new peer and cutting over, this work should support
reloading code inside the already running application process tree.

## What “done” means for v1

The first useful version should support:

1. a manual API like `BeamDeploy.hot_upgrade("/tmp/my_app-0.2.0.tar.gz", otp_app: :my_app)`
2. local tarball input only
3. copying release beam files into currently loaded code paths
4. loading new modules in embedded mode
5. reloading consolidated protocol beams
6. suspending affected processes
7. calling `code_change/3` on those processes
8. resuming processes even if part of the upgrade fails
9. explicit rejection or skipping of NIF module upgrades

This first pass does **not** need:

- polling
- S3 or any other storage layer
- orchestrator machines
- deployment metadata
- automatic replay after restart

## Reference Implementation in `fly_deploy`

Use the original package in `~/Projects/fly_deploy` as the source of truth for
the hot-upgrade mechanics.

Primary references:

- `~/Projects/fly_deploy/lib/fly_deploy/upgrader.ex`
  - download/extract/copy pipeline: lines `53-252`
  - startup replay path: lines `254-494`
  - safe live upgrade phases: lines `496-685`
  - NIF handling, consolidated protocols, static assets, LiveView reload hooks:
    the rest of the file
- `~/Projects/fly_deploy/lib/fly_deploy.ex`
  - hot upgrade limitations and semantics: lines `9-24`
  - hot upgrade process description: lines `116-150`
- `~/Projects/fly_deploy/lib/fly_deploy/poller.ex`
  - only relevant later if we decide to add startup replay or polling

What should be copied conceptually:

- the suspend -> reload -> `code_change/3` -> resume flow
- `:code.which/1` based beam replacement
- explicit loading of new modules
- consolidated protocol reloads
- NIF detection and exclusion

What should **not** come over into `beam_deploy` v1:

- `Req`
- AWS/Tigris signing
- S3 metadata reads/writes
- `FLY_*` environment logic
- poller-based orchestration

## Proposed API

Keep the hot-upgrade API separate from the blue-green API.

Recommended shape:

```elixir
BeamDeploy.hot_upgrade("/tmp/my_app-0.2.0.tar.gz", otp_app: :my_app)
BeamDeploy.hot_upgrade("/tmp/my_app-0.2.0.tar.gz", otp_app: :my_app, suspend_timeout: 3_000)
```

Optional later:

```elixir
BeamDeploy.replay_hot_upgrade_startup("/tmp/my_app-0.2.0.tar.gz", otp_app: :my_app)
```

Do **not** couple this API to `BeamDeploy.start_link/1`. Hot upgrade should be
usable by an app that does not use the blue-green parent/peer runtime at all.

## New Modules

Recommended file layout:

- `lib/beam_deploy/hot_upgrader.ex`
- optionally `lib/beam_deploy/hot_helpers.ex` if the port gets too large

`BeamDeploy` should only expose the public wrapper API and delegate into the new
module.

## Implementation Plan

### 1. Port the core upgrade engine

Start from `~/Projects/fly_deploy/lib/fly_deploy/upgrader.ex`, but replace the
download phase with a local file input.

The first implementation should:

1. validate the tarball exists
2. extract it into a unique temp dir
3. find `lib/**/ebin/*.beam`
4. copy changed beams into the paths reported by `:code.which/1`
5. copy brand new modules into the app’s ebin directory
6. explicitly `:code.load_binary/3` those new modules
7. copy `releases/*/consolidated/*.beam`
8. run the safe upgrade phases
9. clean up temp files

## 2. Port the safe upgrade phases

This is the critical part from
`~/Projects/fly_deploy/lib/fly_deploy/upgrader.ex:496-685`.

Keep the same basic algorithm:

1. call `:code.modified_modules/0`
2. split NIF modules away from normal modules
3. find processes to upgrade before loading new code
4. suspend those processes in parallel
5. purge and reload all changed modules
6. reload consolidated protocols explicitly
7. call `:sys.change_code(pid, module, :undefined, [])`
8. resume every process in an `after` block

The `after` block is non-negotiable. A partially suspended system is worse than
an upgrade failure.

## 3. Decide the minimum feature set

Some features from `fly_deploy` should probably be deferred:

- static asset copying
- Phoenix cache reset via `config_change/3`
- LiveView-specific reload hooks
- startup replay

Recommended v1 decision:

- keep consolidated protocol reloads
- skip LiveView reload hooks initially
- skip static asset copying initially unless the integration test proves we need it
- skip startup replay initially

Why:

- consolidated protocols affect ordinary code execution
- LiveView and static assets are framework niceties
- startup replay implies some notion of persisted “current hot patch”, which
  `beam_deploy` does not have yet

## 4. Document hard limits explicitly

The public docs must clearly state the same class of limits that
`fly_deploy` documents in `~/Projects/fly_deploy/lib/fly_deploy.ex:9-24`.

Hot upgrade should be treated as valid only for:

- code changes with compatible supervision shape
- processes that can survive `code_change/3`
- releases built with the same OTP version

It should be documented as unsafe or unsupported for:

- supervision tree changes
- VM / OTP upgrades
- NIF upgrades
- major config topology changes

## Test Plan

Reuse the fixture-app strategy from
`agents/tasks/beam_deploy_integration_tests.md`, but create a separate hot
upgrade integration path.

### Unit tests

Add focused tests for:

- missing tarball returns a clean error
- new module loading path
- NIF module detection
- process discovery logic
- always-resume semantics when reload or `code_change/3` fails

### Integration tests

Create a dedicated fixture app for hot upgrade validation.

The fixture app should include:

- one long-lived GenServer that implements `code_change/3`
- one HTTP endpoint returning:
  - current code version
  - current GenServer state
  - current process pid
- one new module introduced only in `v2`

Recommended integration flow:

1. build release `v1`
2. start release `v1` normally
3. confirm `/version` returns `v1`
4. record the pid of the stateful GenServer
5. build release `v2`
6. call `BeamDeploy.hot_upgrade(path, otp_app: :release_app)`
7. confirm:
   - `/version` now returns `v2`
   - the stateful process pid is unchanged
   - the process state was migrated by `code_change/3`
   - the new module from `v2` is callable

That “pid unchanged, state changed” assertion is the core proof that we are
really doing hot upgrade rather than blue-green replacement.

### Failure-mode integration tests

After the happy path is stable, add:

1. `code_change/3` failure still resumes the system
2. NIF-bearing module change is rejected or skipped deterministically
3. a tarball with a new module and a changed module works in one pass

## Suggested File Changes

Likely changes in this repo:

- `lib/beam_deploy.ex`
- `lib/beam_deploy/hot_upgrader.ex`
- `README.md`
- `test/beam_deploy_test.exs`
- new unit tests for hot upgrade internals
- new integration fixture and integration test files

## Rough Size / Effort

For planning purposes:

- runtime port: roughly `300-500` lines of real implementation
- tests and fixture app: roughly `300-600` lines
- docs and cleanup: another `100-200` lines

Practical effort estimate:

- MVP manual hot upgrade: `2-4 focused days`
- solid version with fixture tests and docs: `1-1.5 weeks`

## Acceptance Criteria

This task is complete when:

- `BeamDeploy.hot_upgrade/2` works from a local release tarball
- a fixture app proves the same process survives with migrated state
- new modules load correctly in embedded mode
- consolidated protocols reload correctly
- NIF changes are skipped or rejected explicitly
- the docs explain when to choose hot upgrade vs blue-green vs cold deploy
