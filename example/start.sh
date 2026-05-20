#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

export MIX_ENV="${MIX_ENV:-prod}"
export DEMO_BUTTON_LABEL="${DEMO_BUTTON_LABEL:-Deploy the blue release}"
export PHX_SERVER="${PHX_SERVER:-true}"
export BEAM_DEPLOY="${BEAM_DEPLOY:-true}"
export PORT="${PORT:-4000}"
export DEMO_SOURCE_DIR="${DEMO_SOURCE_DIR:-$(pwd)}"

release_bin="_build/prod/rel/example/bin/example"

echo "==> Installing dependencies"
mix deps.get --only prod

echo "==> Building release with label: ${DEMO_BUTTON_LABEL}"
mix compile --force
mix release --overwrite

if [[ -x "$release_bin" ]]; then
  echo "==> Stopping existing release if running"
  "$release_bin" stop >/dev/null 2>&1 || true
fi

pkill -f "$(pwd)/_build/prod/rel/example" >/dev/null 2>&1 || true
sleep 1

echo "==> Starting release on http://localhost:${PORT}"
"$release_bin" daemon

echo "==> Started PID: $("$release_bin" pid)"
echo "==> Open http://localhost:${PORT}"
