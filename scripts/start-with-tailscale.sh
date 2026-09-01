#!/usr/bin/env bash
set -euo pipefail

TAILSCALE_STATE_DIR="${TAILSCALE_STATE_DIR:-/data/tailscale}"
TAILSCALE_SOCKET="${TAILSCALE_SOCKET:-/tmp/tailscaled.sock}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-openclaw-railway}"
GATEWAY_PORT="${INTERNAL_GATEWAY_PORT:-18789}"

mkdir -p "${TAILSCALE_STATE_DIR}"
rm -f "${TAILSCALE_SOCKET}"

# Railway containers do not provide /dev/net/tun, so run Tailscale in userspace mode.
tailscaled \
  --tun=userspace-networking \
  --state="${TAILSCALE_STATE_DIR}/tailscaled.state" \
  --socket="${TAILSCALE_SOCKET}" \
  >/tmp/tailscaled.log 2>&1 &
TAILSCALED_PID=$!

cleanup() {
  kill "${TAILSCALED_PID}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Wait until the local tailscaled socket is ready.
for _ in $(seq 1 60); do
  if tailscale --socket="${TAILSCALE_SOCKET}" status >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "${TAILSCALED_PID}" 2>/dev/null; then
    echo "tailscaled exited during startup" >&2
    cat /tmp/tailscaled.log >&2 || true
    exit 1
  fi
  sleep 0.25
done

BACKEND_STATE="$(tailscale --socket="${TAILSCALE_SOCKET}" status --json 2>/dev/null | node -e '
let s=""; process.stdin.on("data", d => s += d); process.stdin.on("end", () => {
  try { console.log(JSON.parse(s).BackendState || ""); } catch { console.log(""); }
});
' || true)"

if [ "${BACKEND_STATE}" != "Running" ]; then
  if [ -z "${TAILSCALE_AUTH_KEY:-}" ]; then
    echo "Tailscale is not logged in and TAILSCALE_AUTH_KEY is not set." >&2
    exit 1
  fi

  tailscale --socket="${TAILSCALE_SOCKET}" up \
    --auth-key="${TAILSCALE_AUTH_KEY}" \
    --hostname="${TAILSCALE_HOSTNAME}" \
    --accept-dns=false
fi

# Do not pass the bootstrap auth key to the OpenClaw process.
unset TAILSCALE_AUTH_KEY

# Publish the loopback-only OpenClaw gateway to this tailnet over HTTPS/WSS.
tailscale --socket="${TAILSCALE_SOCKET}" serve --bg "http://127.0.0.1:${GATEWAY_PORT}"

echo "Tailscale status:"
tailscale --socket="${TAILSCALE_SOCKET}" status || true
echo "Tailscale Serve:"
tailscale --socket="${TAILSCALE_SOCKET}" serve status || true

exec node src/server.js
