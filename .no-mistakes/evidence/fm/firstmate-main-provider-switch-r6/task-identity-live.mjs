import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { spawn } from "node:child_process";

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

const child = spawn("pi", [
  "--mode", "rpc",
  "--offline",
  "--approve",
  "--no-session",
  "--no-context-files",
  "--no-extensions",
  "-e", join(root, ".pi/extensions/fm-primary-turnend-guard.ts"),
  "--model", "openai/gpt-4o",
], {
  cwd: root,
  env: {
    ...Object.fromEntries(Object.entries(process.env).filter(([key]) => !/API_KEY|TOKEN|SECRET|CREDENTIAL/.test(key))),
    FM_HOME: home,
    FM_ROOT_OVERRIDE: root,
    FM_CONFIG_OVERRIDE: config,
    FM_STATE_OVERRIDE: state,
    FM_TASK_ID: "test-secondmate",
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
  assert.equal(initial.data.model.provider, "openai");
  assert.equal(initial.data.model.id, "gpt-4o");

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
    assert.equal(unchanged.data.model.provider, "openai");
    assert.equal(unchanged.data.model.id, "gpt-4o");
  }

  await expectRefusal("Provider switch unavailable: only the top-level Firstmate primary may switch");
  for (const e of events) if (e.type === "extension_ui_request" || e.command === "get_state") console.log(JSON.stringify(e));

} finally {
  child.kill("SIGTERM");
  await new Promise((resolve) => child.once("exit", resolve));
}