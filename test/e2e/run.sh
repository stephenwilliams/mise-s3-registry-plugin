#!/usr/bin/env bash
# End-to-end test: a real `mise use s3reg:<tool>@<range>` round-trip through the
# Lua plugin against a real `s3reg serve` backed by a real object store (MinIO in
# Docker). Exercises version resolution, the sha256 install gate, exec_env, and
# bearer auth. Linux-first, but runs on macOS Docker Desktop too.
#
# Requires: Docker, Go (to build s3reg unless S3REG_BIN is set), and mise.
# Overrides: S3REG_SRC (path to s3-registry checkout), S3REG_BIN (prebuilt binary).
set -euo pipefail

# free_port asks the OS for an unused TCP port so the harness never silently
# binds to (or, worse, talks to) an unrelated service already on a fixed port.
free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
S3REG_SRC=${S3REG_SRC:-$(cd "$PLUGIN_DIR/.." && pwd)/s3-registry}

MINIO_IMAGE=${MINIO_IMAGE:-minio/minio:RELEASE.2025-04-22T22-12-26Z}
MC_IMAGE=${MC_IMAGE:-minio/mc:RELEASE.2025-04-16T18-13-26Z}
MINIO_NAME="s3reg-e2e-minio-$$"
MINIO_PORT=${MINIO_PORT:-$(free_port)}
BUCKET=${BUCKET:-s3reg-e2e}
TOOL=${S3REG_TEST_TOOL:-mytool}

SERVE_PORT=${SERVE_PORT:-$(free_port)}
SERVE_AUTH_PORT=${SERVE_AUTH_PORT:-$(free_port)}
AUTH_TOKEN="e2e-secret-token"

export AWS_ACCESS_KEY_ID=minioadmin
export AWS_SECRET_ACCESS_KEY=minioadmin
export AWS_REGION=us-east-1
export AWS_ENDPOINT_URL="http://localhost:${MINIO_PORT}"

WORK=$(mktemp -d)
SERVE_PID=""
SERVE_AUTH_PID=""

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

cleanup() {
  [ -n "$SERVE_PID" ] && kill "$SERVE_PID" 2>/dev/null || true
  [ -n "$SERVE_AUTH_PID" ] && kill "$SERVE_AUTH_PID" 2>/dev/null || true
  docker rm -f "$MINIO_NAME" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

MC() { docker run --rm -i --network "container:${MINIO_NAME}" \
  -e "MC_HOST_local=http://minioadmin:minioadmin@127.0.0.1:9000" "$MC_IMAGE" "$@"; }

# --- host os/arch, mapped to the GOOS/GOARCH the registry keys on ----------
case "$(uname -s)" in
  Linux)  GOOS=linux ;;
  Darwin) GOOS=darwin ;;
  *) fail "unsupported OS $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64)   GOARCH=amd64 ;;
  arm64|aarch64)  GOARCH=arm64 ;;
  *) fail "unsupported arch $(uname -m)" ;;
esac
OSARCH="${GOOS}-${GOARCH}"
log "host target ${OSARCH}"

# --- build s3reg -----------------------------------------------------------
if [ -n "${S3REG_BIN:-}" ]; then
  [ -x "$S3REG_BIN" ] || fail "S3REG_BIN=$S3REG_BIN is not an executable file"
  S3REG="$S3REG_BIN"
else
  [ -d "$S3REG_SRC" ] || fail "s3-registry source not found at $S3REG_SRC (set S3REG_SRC or S3REG_BIN)"
  log "building s3reg from $S3REG_SRC"
  S3REG="$WORK/s3reg"
  (cd "$S3REG_SRC" && go build -o "$S3REG" ./cmd/s3reg)
fi

# --- start MinIO -----------------------------------------------------------
log "starting MinIO ($MINIO_IMAGE)"
docker run -d --name "$MINIO_NAME" -p "${MINIO_PORT}:9000" \
  -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
  "$MINIO_IMAGE" server /data >/dev/null

for _ in $(seq 1 60); do
  if curl -fsS "http://localhost:${MINIO_PORT}/minio/health/live" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "http://localhost:${MINIO_PORT}/minio/health/live" >/dev/null 2>&1 || fail "MinIO did not become healthy"
MC mb --ignore-existing "local/${BUCKET}" >/dev/null || fail "could not create bucket"

# --- publish a toy tool at several versions --------------------------------
# Each version's archive carries a bin/<tool> that prints its own version, so
# `mise exec` proves the right build was selected, installed, and PATH-wired.
publish_version() {
  local version="$1" bucket_flag="$2"
  local stage="$WORK/stage-$version"
  mkdir -p "$stage/bin"
  cat >"$stage/bin/$TOOL" <<EOF
#!/bin/sh
echo "$TOOL $version"
EOF
  chmod +x "$stage/bin/$TOOL"
  local archive="$WORK/${TOOL}_${version}_${GOOS}_${GOARCH}.tar.gz"
  tar -czf "$archive" -C "$stage" bin
  "$S3REG" publish --bucket "$bucket_flag" --endpoint "$AWS_ENDPOINT_URL" --s3-path-style \
    --tool "$TOOL" --version "$version" --os "$GOOS" --arch "$GOARCH" --file "$archive" >/dev/null
}

log "publishing $TOOL versions"
for v in 1.0.0 1.2.0 1.2.3 2.0.0; do publish_version "$v" "$BUCKET"; done

# --- boot the real server --------------------------------------------------
start_server() {
  local port="$1" token="$2" logfile="$3"
  # A short index cache TTL lets a version published after boot show up quickly.
  S3REG_API_TOKEN="$token" READINESS_STARTUP_GRACE=0 S3REG_CACHE_TTL=1s \
    "$S3REG" serve --addr ":${port}" --bucket "$BUCKET" \
    --endpoint "$AWS_ENDPOINT_URL" --s3-path-style >"$logfile" 2>&1 &
  echo $!
}
# wait_ready blocks until OUR s3reg serve answers ready. It fails fast if the
# process died (e.g. the port was taken) and rejects a 200 from any responder
# that is not s3reg (its ready body carries a "required" block).
wait_ready() {
  local port="$1" pid="$2" logfile="$3" body
  for _ in $(seq 1 30); do
    if ! kill -0 "$pid" 2>/dev/null; then
      fail "s3reg serve on :$port exited early: $(cat "$logfile")"
    fi
    body=$(curl -s "http://localhost:${port}/-/health/ready" || true)
    if printf '%s' "$body" | grep -q '"status":"ready"'; then
      return 0 # s3reg, ready
    fi
    if [ -n "$body" ] && ! printf '%s' "$body" | grep -q '"required"'; then
      # Something answered but it is not s3reg (no readiness "required" block).
      fail "port $port is held by another service, not s3reg (got: $body)"
    fi
    sleep 0.5
  done
  fail "server on :$port did not become ready"
}

log "starting s3reg serve on :$SERVE_PORT"
SERVE_PID=$(start_server "$SERVE_PORT" "" "$WORK/serve.log")
wait_ready "$SERVE_PORT" "$SERVE_PID" "$WORK/serve.log"

# --- isolate mise so the E2E never touches the developer's real install ----
export MISE_DATA_DIR="$WORK/mise-data"
export MISE_CACHE_DIR="$WORK/mise-cache"
export MISE_STATE_DIR="$WORK/mise-state"
export MISE_CONFIG_DIR="$WORK/mise-config"
export MISE_YES=1
# mise's default minimum_release_age would hide the versions published seconds ago.
export MISE_MINIMUM_RELEASE_AGE=0
mkdir -p "$MISE_DATA_DIR" "$MISE_CACHE_DIR" "$MISE_STATE_DIR" "$MISE_CONFIG_DIR"

export S3REG_URL="http://localhost:${SERVE_PORT}"
unset S3REG_TOKEN || true

# Drive mise from a neutral directory so it does not pick up the plugin repo's
# own mise.toml (whose postinstall hook shells out to hk, absent in this env).
cd "$WORK"

log "linking plugin"
mise plugin link --force s3reg "$PLUGIN_DIR"
mise cache clear >/dev/null 2>&1 || true

# --- ls-remote -------------------------------------------------------------
log "mise ls-remote s3reg:$TOOL"
REMOTE=$(mise ls-remote "s3reg:${TOOL}")
echo "$REMOTE"
for v in 1.0.0 1.2.0 1.2.3 2.0.0; do
  echo "$REMOTE" | grep -qx "$v" || fail "ls-remote missing $v"
done

# --- release dates ---------------------------------------------------------
# Every version was just published, so each has a created_at and a 1-day
# minimum_release_age hides them all without an undated-version warning.
log "release dates reach mise"
mise ls-remote --json "s3reg:${TOOL}" >"$WORK/remote.json"
python3 - "$WORK/remote.json" <<'EOF' || fail "ls-remote --json is missing created_at: $(cat "$WORK/remote.json")"
import json, sys
entries = json.load(open(sys.argv[1]))
sys.exit(0 if entries and all(e.get("created_at") for e in entries) else 1)
EOF
AGED=$(mise ls-remote --minimum-release-age 1d "s3reg:${TOOL}" 2>"$WORK/age.err") || true
grep -q "releases hidden by minimum_release_age" "$WORK/age.err" || fail "expected mise to hide fresh versions: $(cat "$WORK/age.err")"
[ -z "$AGED" ] || fail "a 1d minimum_release_age should hide fresh versions; got: $AGED"
if grep -q "has no release date" "$WORK/age.err"; then
  fail "mise reported an undated version: $(cat "$WORK/age.err")"
fi

# --- version resolution: range, latest, exact ------------------------------
assert_resolves() {
  local spec="$1" want="$2"
  if ! mise install "s3reg:${TOOL}@${spec}" >"$WORK/install.log" 2>&1; then
    cat "$WORK/install.log" >&2
    fail "install $spec failed"
  fi
  local got
  got=$(mise exec "s3reg:${TOOL}@${spec}" -- "$TOOL" 2>"$WORK/exec.log") || { cat "$WORK/exec.log" >&2; fail "exec $spec failed"; }
  [ "$got" = "$TOOL $want" ] || fail "spec $spec resolved to '$got', want '$TOOL $want'"
  log "resolved @$spec -> $want (exec ok)"
}
# mise applies the version selector itself (the plugin returns the raw list):
# a "1" prefix picks the highest 1.x, "latest" the newest, an exact version pins.
# (mise rejects caret/tilde ranges as a backend install argument.)
assert_resolves "1" "1.2.3"
assert_resolves "latest" "2.0.0"
assert_resolves "1.2.0" "1.2.0"

# --- sha256 install gate ---------------------------------------------------
# Publish 9.9.9 cleanly, then tamper the stored object bytes while leaving the
# index sha256 untouched. BackendInstall must abort before extracting.
log "sha256 gate: tampering a published artifact"
publish_version "9.9.9" "$BUCKET"
sleep 2 # let the server's index cache (1s TTL) pick up 9.9.9
TKEY="${TOOL}/9.9.9/${OSARCH}/${TOOL}_9.9.9_${GOOS}_${GOARCH}.tar.gz"
printf 'tampered-not-the-real-archive' | MC pipe "local/${BUCKET}/${TKEY}" >/dev/null || fail "tamper failed"
mise cache clear >/dev/null 2>&1 || true
if mise install "s3reg:${TOOL}@9.9.9" >"$WORK/tamper.log" 2>&1; then
  fail "install of tampered artifact succeeded; the sha256 gate did not fire"
fi
grep -qi "sha256 mismatch" "$WORK/tamper.log" || fail "expected a sha256 mismatch error; got: $(cat "$WORK/tamper.log")"
log "sha256 gate fired (install aborted before extract)"

# --- exec_env: the tool runs from install_path/bin ------------------------
log "exec_env PATH wiring"
mise install "s3reg:${TOOL}@2.0.0" >/dev/null 2>&1
BIN_OUT=$(mise exec "s3reg:${TOOL}@2.0.0" -- "$TOOL")
[ "$BIN_OUT" = "$TOOL 2.0.0" ] || fail "exec_env: got '$BIN_OUT'"

# --- bearer auth variant ---------------------------------------------------
log "auth variant: server + client with a bearer token"
SERVE_AUTH_PID=$(start_server "$SERVE_AUTH_PORT" "$AUTH_TOKEN" "$WORK/serve-auth.log")
wait_ready "$SERVE_AUTH_PORT" "$SERVE_AUTH_PID" "$WORK/serve-auth.log"
export S3REG_URL="http://localhost:${SERVE_AUTH_PORT}"
export S3REG_TOKEN="$AUTH_TOKEN"
mise cache clear >/dev/null 2>&1 || true
mise ls-remote "s3reg:${TOOL}" >/dev/null || fail "auth ls-remote failed (bearer on /versions)"
mise install "s3reg:${TOOL}@1.2.3" >/dev/null 2>&1 || fail "auth install failed (bearer on artifact fetch)"
AUTH_OUT=$(mise exec "s3reg:${TOOL}@1.2.3" -- "$TOOL")
[ "$AUTH_OUT" = "$TOOL 1.2.3" ] || fail "auth exec: got '$AUTH_OUT'"
log "auth variant ok (bearer sent on both /versions and the presigned fetch)"

log "E2E PASSED"
