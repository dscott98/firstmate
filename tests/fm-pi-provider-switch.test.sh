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
import { existsSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { createServer } from "node:http";

const root = process.env.FM_PI_PROVIDER_SWITCH_ROOT;
const fixture = process.env.FM_PI_PROVIDER_SWITCH_TMP;
assert.ok(root && fixture, "provider-switch fixture paths are set");

const home = join(fixture, "home");
const state = join(home, "state");
const config = join(home, "config");
mkdirSync(config, { recursive: true });
const piConfig = join(fixture, "pi-config");
mkdirSync(state, { recursive: true });
mkdirSync(piConfig, { recursive: true });
// Only loopback transport is reachable from these fixture models. The server
// records routing and rejects requests; it performs no inference.
const requests = [];
const server = createServer((request, response) => {
  let body = "";
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    requests.push({ url: request.url, body: JSON.parse(body) });
    response.writeHead(401, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ error: { message: "local routing probe complete" } }));
  });
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
server.unref();
const baseUrl = `http://127.0.0.1:${server.address().port}`;
const defaults = JSON.stringify({ defaultProvider: "openai-codex", defaultModel: "gpt-5.6-sol" });
writeFileSync(join(piConfig, "settings.json"), defaults);
const workerDefaults = "pi openai-codex/gpt-5.6-sol\n";
writeFileSync(join(config, "secondmate-harness"), workerDefaults);
writeFileSync(
  join(piConfig, "models.json"),
  JSON.stringify({
    providers: {
      "openai-codex": {
        baseUrl: `${baseUrl}/quota`,
        apiKey: "fixture-key",
        api: "openai-completions",
        models: [{
          id: "gpt-5.6-sol",
          name: "Fixture Starting",
          reasoning: false,
          input: ["text"],
          contextWindow: 4096,
          maxTokens: 256,
        }],
      },
      openrouter: {
        baseUrl: `${baseUrl}/openrouter`,
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

// Exercise the public extension bus used by the watcher, with both production
// extensions loaded by real Pi. No production handler or SDK is stubbed.
const probe = join(fixture, "probe.ts");
writeFileSync(probe, `export default function (pi) {
  pi.registerCommand("probe-supervision", { handler: async (_args, ctx) => {
    let settlement;
    pi.events.emit("fm-branch-supervision:dispatch", {
      eligible: true,
      message: "signal: provider routing probe",
      accept(promise) { settlement = promise; },
    });
    if (!settlement) throw new Error("supervision did not accept the wake");
    try { await settlement; ctx.ui.notify("probe settled: idle", "info"); }
    catch (error) { ctx.ui.notify("probe settled: " + error.message, "error"); }
  }});
}`);
const isolatedEnv = {
  PATH: process.env.PATH,
  HOME: home,
  TMPDIR: fixture,
  PI_CODING_AGENT_DIR: piConfig,
  PI_TELEMETRY: "false",
};
const child = spawn("pi", [
  "--mode", "rpc",
  "--offline",
  "--approve",
  "--no-session",
  "--no-context-files",
  "--no-extensions",
  "-e", join(root, ".pi/extensions/fm-primary-turnend-guard.ts"),
  "-e", join(root, ".pi/extensions/fm-branch-supervision.ts"),
  "-e", probe,
], {
  cwd: root,
  env: {
    ...isolatedEnv,
    FM_HOME: home,
    FM_ROOT_OVERRIDE: root,
    FM_CONFIG_OVERRIDE: config,
    FM_STATE_OVERRIDE: state,
    FM_TASK_ID: "",
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
  throw new Error(`Timed out while ${description}: ${stderr} ${JSON.stringify(events.slice(-5))}`);
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
  assert.equal(initial.data.model.provider, "openai-codex");
  assert.equal(initial.data.model.id, "gpt-5.6-sol");

  async function expectRefusal(message) {
    const start = events.length;
    await send("prompt", { message: "/fm-openrouter-sol" });
    const notice = await waitFor(
      (event) => events.indexOf(event) >= start && event.type === "extension_ui_request" &&
        event.method === "notify" && event.message === message,
      "provider-switch refusal",
    );
    assert.equal(notice.notifyType, "error");
    const unchanged = await send("get_state");
    assert.equal(unchanged.data.model.provider, "openai-codex");
    assert.equal(unchanged.data.model.id, "gpt-5.6-sol");
  }

  const pinFile = join(config, "supervision-branch-model");
  const pinError = "Provider switch unavailable: pin supervision to an independent openai-codex model with /supervision-model first";
  await expectRefusal(pinError);
  assert.equal(existsSync(pinFile), false);
  for (const pin of ["", "openai-codex/", "broken", "openrouter/openai/gpt-5.6-sol", "openai/gpt-5.6-sol"]) {
    writeFileSync(pinFile, pin);
    await expectRefusal(pinError);
    assert.equal(readFileSync(pinFile, "utf8"), pin);
  }
  const quotaPin = "openai-codex/gpt-5.6-sol\n";
  writeFileSync(pinFile, quotaPin);
  const marker = join(home, ".fm-secondmate-home");
  const identityError = "Provider switch unavailable: only the top-level Firstmate primary may switch";
  for (const identity of ["mate-local\n", "mate-remote\n", "", "invalid marker"]) {
    writeFileSync(marker, identity);
    await expectRefusal(identityError);
    rmSync(marker);
  }
  symlinkSync(join(home, "missing-marker"), marker);
  await expectRefusal(identityError);
  rmSync(marker);

  // Build the real supervision conversation before switching main. An empty
  // queue creates the branch without asking its provider for a completion.
  writeFileSync(join(state, ".wake-queue"), "");
  await send("prompt", { message: "/probe-supervision" });
  await waitFor((event) => event.type === "extension_ui_request" &&
    event.message === "probe settled: idle", "initial supervision conversation");
  assert.equal(requests.length, 0);
  const originalBranchFile = readFileSync(join(state, ".branch-session"), "utf8").trim();

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

  const project = join(home, "projects", "probe");
  mkdirSync(project, { recursive: true });
  writeFileSync(join(state, "probe.meta"), `project=${project}\nwindow=provider-probe\n`);
  writeFileSync(join(state, ".wake-queue"), "1\t1\tsignal\tprobe.status\tsignal: provider routing probe\n");
  const wakeStart = events.length;
  await send("prompt", { message: "/probe-supervision" });
  const settlement = await waitFor((event) => events.indexOf(event) >= wakeStart &&
    event.type === "extension_ui_request" && event.message?.startsWith("probe settled:"),
    "real supervision wake settlement");
  assert.equal(settlement.notifyType, "error", "local provider rejects without inference");
  assert.equal(requests.length, 1, "exactly one request, from supervision alone");
  assert.equal(requests[0].url, "/quota/chat/completions");
  assert.equal(requests[0].body.model, "gpt-5.6-sol");
  const branchFile = readFileSync(join(state, ".branch-session"), "utf8").trim();
  assert.equal(branchFile, originalBranchFile, "switch preserves the independent supervision conversation");
  const branchEntries = readFileSync(branchFile, "utf8").trim().split("\n").map(JSON.parse);
  const selections = branchEntries.filter((entry) => entry.type === "model_change");
  assert.ok(selections.length > 0, "real branch session records its provider selection");
  assert.ok(selections.every((entry) => entry.provider === "openai-codex" && entry.modelId === "gpt-5.6-sol"));
  assert.equal((await send("get_state")).data.model.provider, "openrouter");

  // A fresh worker process consumes the same defaults without main's session
  // selection. No prompt is sent, so neither process performs inference.
  const worker = spawn("pi", ["--mode", "rpc", "--offline", "--approve", "--no-session",
    "--no-context-files", "--no-extensions"], {
    cwd: fixture,
    env: { ...isolatedEnv, FM_TASK_ID: "probe-worker", FM_HOME: home },
    stdio: ["pipe", "pipe", "pipe"],
  });
  try {
    const workerState = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("fresh worker state timed out")), 15000);
      let output = "";
      worker.stdout.on("data", (chunk) => {
        output += chunk;
        for (const line of output.split("\n").slice(0, -1)) {
          const event = JSON.parse(line);
          if (event.id === "fresh-worker") { clearTimeout(timer); resolve(event); }
        }
      });
      worker.stdin.write(JSON.stringify({ id: "fresh-worker", type: "get_state" }) + "\n");
    });
    assert.equal(workerState.success, true);
    assert.equal(workerState.data.model.provider, "openai-codex");
    assert.equal(workerState.data.model.id, "gpt-5.6-sol");
  } finally {
    worker.kill("SIGTERM");
    await new Promise((resolve) => worker.once("exit", resolve));
  }
  assert.equal(readFileSync(join(config, "secondmate-harness"), "utf8"), workerDefaults);

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
  assert.equal(readFileSync(pinFile, "utf8"), quotaPin);
  assert.equal(readFileSync(join(piConfig, "settings.json"), "utf8"), defaults);
  console.log("ok - real Pi provider-switch command changes only the locked primary session, preserves supervision and fresh-worker quota models and defaults, and rejects unsafe switches");
} finally {
  server.close();
  child.kill("SIGTERM");
  await new Promise((resolve) => child.once("exit", resolve));
}
NODE
