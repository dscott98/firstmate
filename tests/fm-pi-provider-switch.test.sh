#!/usr/bin/env bash
# Credential-free real Pi RPC regression for the primary-only provider switch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_PI_PROVIDER_SWITCH_LIVE pi node

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot fm-pi-provider-switch)
export FM_PI_PROVIDER_SWITCH_ROOT="$ROOT"
export FM_PI_PROVIDER_SWITCH_TMP="$TMP_ROOT"

node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { spawn } from "node:child_process";

const root = process.env.FM_PI_PROVIDER_SWITCH_ROOT;
const fixture = process.env.FM_PI_PROVIDER_SWITCH_TMP;
assert.ok(root && fixture, "provider-switch fixture paths are set");

const home = join(fixture, "home");
const state = join(home, "state");
const piConfig = join(fixture, "pi-config");
mkdirSync(state, { recursive: true });
mkdirSync(piConfig, { recursive: true });
writeFileSync(
  join(piConfig, "models.json"),
  JSON.stringify({
    providers: {
      fixture: {
        baseUrl: "https://example.invalid/v1",
        apiKey: "fixture-key",
        api: "openai-completions",
        models: [{
          id: "starting",
          name: "Fixture Starting",
          reasoning: false,
          input: ["text"],
          contextWindow: 4096,
          maxTokens: 256,
        }],
      },
      openrouter: {
        baseUrl: "https://openrouter.ai/api/v1",
        apiKey: "fixture-key",
        api: "openai-completions",
        models: [{
          id: "openai/gpt-5.6-sol",
          name: "OpenRouter GPT-5.6 Sol",
          reasoning: true,
          input: ["text"],
          contextWindow: 1050000,
          maxTokens: 128000,
          compat: { thinkingFormat: "openrouter" },
        }],
      },
    },
  }),
);

const child = spawn("pi", [
  "--mode", "rpc",
  "--offline",
  "--approve",
  "--no-session",
  "--no-context-files",
  "--no-extensions",
  "-e", join(root, ".pi/extensions/fm-primary-turnend-guard.ts"),
  "--model", "fixture/starting",
], {
  cwd: root,
  env: {
    ...process.env,
    FM_HOME: home,
    FM_ROOT_OVERRIDE: root,
    PI_CODING_AGENT_DIR: piConfig,
    PI_TELEMETRY: "false",
  },
  stdio: ["pipe", "pipe", "pipe"],
});

writeFileSync(join(state, ".lock"), `${child.pid}\n`);

const events = [];
let buffer = "";
child.stdout.setEncoding("utf8");
child.stdout.on("data", (chunk) => {
  buffer += chunk;
  for (;;) {
    const newline = buffer.indexOf("\n");
    if (newline < 0) break;
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    if (!line.trim()) continue;
    try {
      events.push(JSON.parse(line));
    } catch {
      throw new Error(`Pi emitted non-JSON RPC output: ${line}`);
    }
  }
});

let stderr = "";
child.stderr.setEncoding("utf8");
child.stderr.on("data", (chunk) => { stderr += chunk; });

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
async function waitFor(predicate, description) {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const match = events.find(predicate);
    if (match) return match;
    if (child.exitCode !== null) throw new Error(`Pi exited while ${description}: ${stderr}`);
    await delay(25);
  }
  throw new Error(`Timed out while ${description}: ${stderr}`);
}

let requestId = 0;
async function send(type, fields = {}) {
  const id = `provider-switch-${++requestId}`;
  child.stdin.write(`${JSON.stringify({ id, type, ...fields })}\n`);
  const response = await waitFor((event) => event.id === id, `${type} response`);
  assert.equal(response.success, true, JSON.stringify(response));
  return response;
}

try {
  const initial = await send("get_state");
  assert.equal(initial.data.model.provider, "fixture");
  assert.equal(initial.data.model.id, "starting");

  await send("prompt", { message: "/fm-openrouter-sol" });
  const successNotice = await waitFor(
    (event) => event.type === "extension_ui_request" &&
      event.method === "notify" &&
      event.message === "Primary session switched to openrouter/openai/gpt-5.6-sol",
    "successful provider-switch notification",
  );
  assert.equal(successNotice.notifyType, "info");

  const switched = await send("get_state");
  assert.equal(switched.data.model.provider, "openrouter");
  assert.equal(switched.data.model.id, "openai/gpt-5.6-sol");

  await send("prompt", { message: "/fm-openrouter-sol unexpected" });
  const usageNotice = await waitFor(
    (event) => event.type === "extension_ui_request" &&
      event.method === "notify" &&
      event.message === "Usage: /fm-openrouter-sol (no arguments)",
    "invalid-argument notification",
  );
  assert.equal(usageNotice.notifyType, "error");

  const afterInvalid = await send("get_state");
  assert.equal(afterInvalid.data.model.provider, "openrouter");
  assert.equal(afterInvalid.data.model.id, "openai/gpt-5.6-sol");

  writeFileSync(join(state, ".lock"), "999999\n");
  await send("prompt", { message: "/fm-openrouter-sol" });
  const ownershipNotice = await waitFor(
    (event) => event.type === "extension_ui_request" &&
      event.method === "notify" &&
      event.message === "Provider switch unavailable: this session does not own the Firstmate primary lock",
    "primary-lock ownership notification",
  );
  assert.equal(ownershipNotice.notifyType, "error");

  const afterOwnershipFailure = await send("get_state");
  assert.equal(afterOwnershipFailure.data.model.provider, "openrouter");
  assert.equal(afterOwnershipFailure.data.model.id, "openai/gpt-5.6-sol");
  assert.equal(existsSync(join(piConfig, "settings.json")), false);
  console.log("ok - real Pi provider-switch command changes only the locked primary session and fails closed on invalid input or lock loss");
} finally {
  child.kill("SIGTERM");
  await new Promise((resolve) => child.once("exit", resolve));
}
NODE
