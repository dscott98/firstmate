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
    FM_TASK_ID: "",
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

  const start = events.length;
  await send("prompt", { message: "/fm-openrouter-sol" });
  const authNotice = await waitFor(e => events.indexOf(e) >= start && e.type === "extension_ui_request" && e.method === "notify", "unconfigured provider refusal");
  assert.equal(authNotice.notifyType, "error");
  assert.match(authNotice.message, /not available|authentication is not configured/);
  const unchanged = await send("get_state");
  assert.equal(unchanged.data.model.provider, "openai");
  assert.equal(unchanged.data.model.id, "gpt-4o");
  await send("prompt", { message: "/fm-openrouter-sol unexpected" });
  await waitFor(e => e.message === "Usage: /fm-openrouter-sol (no arguments)", "usage refusal");
  writeFileSync(join(state, ".lock"), "999999\n");
  await expectRefusal("Provider switch unavailable: this session does not own the Firstmate primary lock");
  assert.equal(readFileSync(pinFile, "utf8"), quotaPin);
  assert.equal(existsSync(join(piConfig, "settings.json")), false);
  for (const event of events) {
    if (event.type === "extension_ui_request" || event.command === "get_state") console.log(JSON.stringify(event));
  }

} finally {
  child.kill("SIGTERM");
  await new Promise((resolve) => child.once("exit", resolve));
}