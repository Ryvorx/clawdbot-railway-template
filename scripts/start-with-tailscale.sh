#!/usr/bin/env bash
set -euo pipefail

TAILSCALE_STATE_DIR="${TAILSCALE_STATE_DIR:-/data/tailscale}"
TAILSCALE_SOCKET="${TAILSCALE_SOCKET:-/var/run/tailscale/tailscaled.sock}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-openclaw-railway}"
TAILSCALE_ENABLED="${TAILSCALE_ENABLED:-auto}"
TAILSCALE_REQUIRED="${TAILSCALE_REQUIRED:-false}"

# Keep the port seen by the Railway wrapper and by OpenClaw itself identical.
# OPENCLAW_GATEWAY_PORT is the canonical public-facing setting for operators;
# INTERNAL_GATEWAY_PORT remains supported for compatibility with the wrapper.
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-${INTERNAL_GATEWAY_PORT:-18789}}"
if [ -n "${OPENCLAW_GATEWAY_PORT:-}" ] && [ -n "${INTERNAL_GATEWAY_PORT:-}" ] && [ "${OPENCLAW_GATEWAY_PORT}" != "${INTERNAL_GATEWAY_PORT}" ]; then
  echo "[startup] WARNING: OPENCLAW_GATEWAY_PORT (${OPENCLAW_GATEWAY_PORT}) and INTERNAL_GATEWAY_PORT (${INTERNAL_GATEWAY_PORT}) differ; using OPENCLAW_GATEWAY_PORT=${GATEWAY_PORT}." >&2
fi
export OPENCLAW_GATEWAY_PORT="${GATEWAY_PORT}"
export INTERNAL_GATEWAY_PORT="${GATEWAY_PORT}"

is_true() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

should_enable_tailscale() {
  case "${TAILSCALE_ENABLED,,}" in
    1|true|yes|on) return 0 ;;
    0|false|no|off) return 1 ;;
    auto)
      [ -n "${TAILSCALE_AUTH_KEY:-}" ] || [ -s "${TAILSCALE_STATE_DIR}/tailscaled.state" ]
      return
      ;;
    *)
      echo "[tailscale] Invalid TAILSCALE_ENABLED=${TAILSCALE_ENABLED}; use auto, true, or false." >&2
      exit 2
      ;;
  esac
}

start_wrapper_without_tailscale() {
  echo "[tailscale] Continuing without Tailscale; Railway/public wrapper remains available."
  exec node src/server.js
}

if ! should_enable_tailscale; then
  echo "[tailscale] Disabled (TAILSCALE_ENABLED=${TAILSCALE_ENABLED})."
  exec node src/server.js
fi

mkdir -p "${TAILSCALE_STATE_DIR}" "$(dirname "${TAILSCALE_SOCKET}")"
chmod 700 "${TAILSCALE_STATE_DIR}" 2>/dev/null || true
rm -f "${TAILSCALE_SOCKET}"

# Railway containers do not provide /dev/net/tun. Userspace networking is the
# supported Tailscale mode for this kind of container/serverless environment.
tailscaled \
  --tun=userspace-networking \
  --state="${TAILSCALE_STATE_DIR}/tailscaled.state" \
  --socket="${TAILSCALE_SOCKET}" \
  >/tmp/tailscaled.log 2>&1 &
TAILSCALED_PID=$!

stop_tailscaled() {
  kill "${TAILSCALED_PID}" 2>/dev/null || true
}

fail_tailscale() {
  local message="$1"
  echo "[tailscale] ${message}" >&2
  cat /tmp/tailscaled.log >&2 2>/dev/null || true
  if is_true "${TAILSCALE_REQUIRED}"; then
    stop_tailscaled
    exit 1
  fi
  stop_tailscaled
  start_wrapper_without_tailscale
}

# Wait for the daemon socket instead of requiring an authenticated status; a fresh
# node legitimately starts in NeedsLogin before `tailscale up` runs.
for _ in $(seq 1 80); do
  if [ -S "${TAILSCALE_SOCKET}" ]; then
    break
  fi
  if ! kill -0 "${TAILSCALED_PID}" 2>/dev/null; then
    fail_tailscale "tailscaled exited during startup."
  fi
  sleep 0.25
done

if [ ! -S "${TAILSCALE_SOCKET}" ]; then
  fail_tailscale "tailscaled socket did not become ready in time."
fi

BACKEND_STATE="$(tailscale --socket="${TAILSCALE_SOCKET}" status --json 2>/dev/null | node -e '
let s=""; process.stdin.on("data", d => s += d); process.stdin.on("end", () => {
  try { console.log(JSON.parse(s).BackendState || ""); } catch { console.log(""); }
});
' || true)"

if [ "${BACKEND_STATE}" != "Running" ]; then
  if [ -z "${TAILSCALE_AUTH_KEY:-}" ]; then
    fail_tailscale "Node is not logged in and TAILSCALE_AUTH_KEY is not set."
  fi

  if ! tailscale --socket="${TAILSCALE_SOCKET}" up \
    --auth-key="${TAILSCALE_AUTH_KEY}" \
    --hostname="${TAILSCALE_HOSTNAME}" \
    --accept-dns=false; then
    fail_tailscale "tailscale up failed."
  fi
fi

# Do not pass the one-time bootstrap auth key to OpenClaw or child processes.
unset TAILSCALE_AUTH_KEY

# Publish the loopback-only OpenClaw gateway to this tailnet over HTTPS/WSS.
# --yes prevents an interactive prompt in a headless Railway deployment.
if ! tailscale --socket="${TAILSCALE_SOCKET}" serve --bg --yes "http://127.0.0.1:${GATEWAY_PORT}"; then
  fail_tailscale "tailscale serve failed. Ensure MagicDNS and HTTPS are enabled for the tailnet."
fi

echo "[tailscale] status:"
tailscale --socket="${TAILSCALE_SOCKET}" status || true
echo "[tailscale] serve status:"
tailscale --socket="${TAILSCALE_SOCKET}" serve status || true

echo "[startup] OpenClaw gateway port: ${GATEWAY_PORT}"
exec node src/server.js
