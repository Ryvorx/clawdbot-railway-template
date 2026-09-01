# OpenClaw Railway Template

This repository packages **OpenClaw** for Railway with a small wrapper and a browser-based `/setup` wizard.

## Architecture

```text
Internet / Railway custom domain
        |
        v
Railway $PORT (wrapper, commonly 8080)
        |
        v
127.0.0.1:18789 (OpenClaw Gateway)
```

The wrapper:

- serves `/setup`
- manages the OpenClaw Gateway process
- reverse-proxies HTTP and WebSocket traffic to the loopback Gateway
- keeps OpenClaw state and workspace on the Railway volume
- provides backup/import and a small allowlisted debug console

Optional **Tailscale Serve** can expose the loopback Gateway directly to the tailnet over HTTPS/WSS:

```text
Tailscale client
      |
      v
https://<node>.<tailnet>.ts.net
      |
      v
Tailscale Serve
      |
      v
127.0.0.1:18789
```

## Port model — important

There are **two different ports**. Do not mix them up.

- `PORT` — injected by Railway; the public wrapper listens here. Railway commonly assigns `8080`.
- `OPENCLAW_GATEWAY_PORT` — the actual OpenClaw Gateway port. Default and recommended value: **`18789`**.
- `INTERNAL_GATEWAY_PORT` — compatibility alias used by older wrapper configurations. The startup script synchronizes it with `OPENCLAW_GATEWAY_PORT`.

For a normal Railway deployment:

```text
PORT=<Railway injected value>
OPENCLAW_GATEWAY_PORT=18789
```

Do **not** set `OPENCLAW_GATEWAY_PORT=8080`. That can make generated mobile pairing / QR configuration point at the wrapper port instead of the actual Gateway.

## Railway deployment

### Volume

Mount a persistent Railway volume at:

```text
/data
```

The included `railway.toml` expects this mount.

### Variables

Required for the wrapper setup UI:

```text
SETUP_PASSWORD=<strong password>
```

Recommended:

```text
OPENCLAW_STATE_DIR=/data/.openclaw
OPENCLAW_WORKSPACE_DIR=/data/workspace
OPENCLAW_GATEWAY_PORT=18789
```

Optional:

```text
OPENCLAW_GATEWAY_TOKEN=<stable generated secret>
```

If `OPENCLAW_GATEWAY_TOKEN` is omitted, the wrapper generates and persists one in the OpenClaw state directory.

Railway injects `PORT` automatically. Do not hard-code it in `railway.toml`.

### Public networking

Enable Railway Public Networking and route the Railway domain/custom domain to the wrapper port selected by Railway (`$PORT`, commonly `8080`).

The OpenClaw Gateway itself remains bound to loopback on `18789`.

### Health check

Railway checks:

```text
/healthz
```

This endpoint is intentionally available without setup authentication so Railway can probe the service.

## Setup

After deployment, open:

```text
https://<railway-domain>/setup
```

HTTP Basic auth is used for the wrapper UI. The username can be arbitrary; the password is `SETUP_PASSWORD`.

After onboarding, the wrapper automatically starts the Gateway even when nobody has opened the browser. This is required for Discord, Telegram and other polling/event integrations.

## Tailscale Serve (optional)

Tailscale is installed in the runtime image and runs in **userspace networking mode**, so Railway does not need `/dev/net/tun`.

### Tailnet prerequisites

Enable in the Tailscale admin console:

- MagicDNS
- HTTPS certificates

### Railway variable

For first enrollment, create a non-ephemeral Tailscale auth key and set:

```text
TAILSCALE_AUTH_KEY=tskey-auth-...
```

Recommended auth-key properties for a persistent Railway node:

- reusable: off
- ephemeral: off

The Tailscale node state is persisted under `/data/tailscale`, so the deployment does not create a new device on every restart.

### Tailscale variables

```text
TAILSCALE_ENABLED=auto
TAILSCALE_HOSTNAME=openclaw-railway
TAILSCALE_STATE_DIR=/data/tailscale
TAILSCALE_REQUIRED=false
```

Behavior:

- `TAILSCALE_ENABLED=auto` (default): start Tailscale when an auth key or persisted state exists; otherwise run normally without it.
- `TAILSCALE_ENABLED=true`: explicitly enable Tailscale.
- `TAILSCALE_ENABLED=false`: skip Tailscale completely.
- `TAILSCALE_REQUIRED=false` (default): if Tailscale fails, keep the normal Railway wrapper online.
- `TAILSCALE_REQUIRED=true`: fail the container when Tailscale cannot start or Serve cannot be configured.

After a successful first enrollment, `TAILSCALE_AUTH_KEY` is no longer needed while the persistent `/data/tailscale` state remains valid.

The startup script configures Tailscale Serve to proxy HTTPS/WSS directly to:

```text
http://127.0.0.1:18789
```

The resulting `.ts.net` URL is shown in the deployment logs by `tailscale serve status`.

### Tailscale authentication note

The `.ts.net` path goes directly to the OpenClaw Gateway and therefore does **not** pass through the wrapper's `SETUP_PASSWORD` Basic-auth layer. OpenClaw Gateway authentication/device pairing remains responsible for Gateway access.

Do not disable OpenClaw Gateway authentication merely because Tailscale is enabled unless you deliberately understand and accept that trust model.

## Persistence

Railway's container filesystem is ephemeral. Persist important data under `/data`.

Defaults:

```text
/data/.openclaw       OpenClaw state/config/credentials
/data/workspace       OpenClaw workspace
/data/tailscale       Tailscale node identity/state
/data/npm             npm global prefix
/data/npm-cache       npm cache
/data/pnpm            pnpm global binaries
/data/pnpm-store      pnpm store
```

### Optional bootstrap hook

If this file exists:

```text
/data/workspace/bootstrap.sh
```

the wrapper runs it at startup before the Gateway starts.

Use it for persistent user tooling, for example a Python virtual environment. Do not rely on `apt-get install` there because system packages live on the ephemeral container filesystem.

## Backups

Authenticated `/setup` provides:

- export to `.tar.gz`
- import into `/data`

The wrapper stops/restarts the Gateway around restore operations where required.

## Troubleshooting

### Mobile QR code contains the wrong port

Check:

```text
OPENCLAW_GATEWAY_PORT=18789
```

The Railway wrapper port (often `8080`) is **not** the OpenClaw Gateway port.

### `502 Bad Gateway` / Gateway unavailable

Check:

- Railway volume is mounted at `/data`
- `OPENCLAW_STATE_DIR=/data/.openclaw`
- `OPENCLAW_WORKSPACE_DIR=/data/workspace`
- `OPENCLAW_GATEWAY_PORT=18789`
- deployment logs for `[gateway]` failures
- `/healthz`
- authenticated `/setup/api/debug`

### Pairing required

From `/setup`, use the debug/device helper or the OpenClaw Control UI to approve the pending device request.

### Tailscale does not appear in the tailnet

Check deployment logs for `[tailscale]` and verify:

- `TAILSCALE_AUTH_KEY` is valid for first enrollment
- `/data` is mounted and writable
- MagicDNS is enabled
- HTTPS certificates are enabled

### Tailscale failure should not take OpenClaw down

Leave:

```text
TAILSCALE_REQUIRED=false
```

The startup wrapper will fall back to the normal Railway route if Tailscale setup fails.

## Development / CI

Local checks:

```bash
npm ci
npm run check
```

This validates JavaScript syntax, the Tailscale startup shell script, and the Node test suite.

Build locally:

```bash
docker build -t openclaw-railway-template .
```

Run without Tailscale:

```bash
docker run --rm -p 8080:8080 \
  -e PORT=8080 \
  -e SETUP_PASSWORD=test \
  -e OPENCLAW_STATE_DIR=/data/.openclaw \
  -e OPENCLAW_WORKSPACE_DIR=/data/workspace \
  -e OPENCLAW_GATEWAY_PORT=18789 \
  -e TAILSCALE_ENABLED=false \
  -v "$(pwd)/.tmpdata:/data" \
  openclaw-railway-template
```

Then open `http://localhost:8080/setup`.

GitHub Actions runs the source checks before attempting the Docker build.

## OpenClaw version updates

The Docker build pins OpenClaw using `OPENCLAW_GIT_REF` to a released tag. A scheduled GitHub workflow checks upstream releases and opens a pull request when a newer release is available.

This keeps upgrades reviewable instead of silently rebuilding from a moving `main` branch.

## Upstream

This repository is based on the Railway OpenClaw template originally maintained by Vignesh N (`vignesh07/clawdbot-railway-template`) and builds OpenClaw from the upstream `openclaw/openclaw` repository.
