import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

test("Railway health check points at the wrapper health endpoint", () => {
  const railway = fs.readFileSync(new URL("../railway.toml", import.meta.url), "utf8");
  const server = fs.readFileSync(new URL("../src/server.js", import.meta.url), "utf8");

  assert.match(railway, /healthCheckPath\s*=\s*"\/healthz"/);
  assert.match(server, /app\.get\("\/healthz"/);
});

test("Railway declares the canonical OpenClaw gateway port", () => {
  const railway = fs.readFileSync(new URL("../railway.toml", import.meta.url), "utf8");
  assert.match(railway, /OPENCLAW_GATEWAY_PORT\s*=\s*"18789"/);
});
