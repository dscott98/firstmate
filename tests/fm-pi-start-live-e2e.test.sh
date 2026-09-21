#!/usr/bin/env bash
# Real Pi/Pi-signed trust/startup guard. A local provider consumes the brief;
# no credentials or model requests leave the machine. Only the worktree
# allocator is replaced, using a real isolated Git worktree and private tmux.
# Set FM_PI_START_LIVE=1 to require the installed-harness guard, or 0 to skip.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
candidate=pi
command -v pi >/dev/null || { ! command -v pi-signed >/dev/null || candidate=pi-signed; }
fm_live_gate default-on FM_PI_START_LIVE tmux node "$candidate"
LAB=$(fm_test_tmproot fm-pi-start-live)
LAB=$(cd "$LAB" && pwd -P)
REAL_TMUX=$(command -v tmux)
export LAB REAL_TMUX
mkdir -p "$LAB/bin" "$LAB/agent/extensions"
cat > "$LAB/bin/tmux" <<'EOF'
#!/usr/bin/env bash
args=()
for arg in "$@"; do
  case "$arg" in 'treehouse get') arg="cd '$LAB/wt'" ;; esac
  args+=("$arg")
done
exec "$REAL_TMUX" -S "$LAB/socket" "${args[@]}"
EOF
# The local provider exercises real Pi event dispatch without provider access.
cat > "$LAB/agent/extensions/local-provider.ts" <<'JS'
import {appendFileSync} from 'node:fs';
export default function(pi) {
  pi.registerProvider('fm-local', {
    baseUrl: 'http://127.0.0.1:1', apiKey: 'fixture', api: 'fm-local',
    models: [{id: 'echo', name: 'Echo', reasoning: false, input: ['text'],
      cost: {input: 0, output: 0, cacheRead: 0, cacheWrite: 0},
      contextWindow: 200000, maxTokens: 1000}],
    streamSimple(model, context) {
      appendFileSync(process.env.PI_CODING_AGENT_DIR + '/requests', JSON.stringify(context.messages) + '\n');
      const message = {role: 'assistant', content: [{type: 'text', text: 'PI_START_OK'}],
        api: model.api, provider: model.provider, model: model.id,
        usage: {input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
          cost: {input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0}},
        stopReason: 'stop', timestamp: Date.now()};
      return {async *[Symbol.asyncIterator]() { yield {type: 'done', reason: 'stop', message}; },
        result: async () => message};
    }
  });
}
JS
chmod +x "$LAB/bin/tmux"
# Shells launched by tmux inherit only this fixture's Pi resources.
export PI_CODING_AGENT_DIR="$LAB/agent" PI_TELEMETRY=false
export FM_BACKEND=tmux
unset TMUX FM_TASK_ID FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
fm_test_spawn_home "$LAB/home" pi
fm_git_init_commit "$LAB/project"
mkdir -p "$LAB/project/.pi"
printf '{}\n' > "$LAB/project/.pi/settings.json"
git -C "$LAB/project" add .pi/settings.json
git -C "$LAB/project" -c user.name=Test -c user.email=test@example.invalid commit -qm 'Trust fixture'
git -C "$LAB/project" worktree add -q --detach "$LAB/wt"
cleanup() {
  "$REAL_TMUX" -S "$LAB/socket" kill-server 2>/dev/null || true
  # These are only ids allocated by this fixture, never fleet task ids.
  for id in "${ids[@]+${ids[@]}}"; do
    rm -rf "/tmp/fm-$id"
    for dir in /tmp/fm-"$id"+*; do [ ! -d "$dir" ] || rm -rf "$dir"; done
  done
  fm_test_cleanup
}
ids=()
trap cleanup EXIT
checked=0
for harness in pi pi-signed; do
  executable=$(command -v "$harness" || true)
  if [ -z "$executable" ]; then echo "skip: $harness not installed"; continue; fi
  version=$("$executable" --version) || fail "$harness version probe failed"
  checked=$((checked + 1))
  # Pin the installed executable; flags remove inherited context, never trust.
  printf '#!/usr/bin/env bash\nexec %q --offline --no-session --no-context-files --no-skills "$@"\n' "$executable" > "$LAB/bin/$harness"
  chmod +x "$LAB/bin/$harness"
  "$REAL_TMUX" -S "$LAB/socket" -f /dev/null new-session -d -s firstmate -x 160 -y 45 -c "$LAB/wt" '/bin/bash --noprofile --norc'
  "$REAL_TMUX" -S "$LAB/socket" set-option -g default-command '/bin/bash --noprofile --norc'
  # Only this isolated store is reset to prove a fresh trust decision per binary.
  rm -f "$LAB/agent/trust.json" "$LAB/agent/requests"
  for mode in fresh remembered; do
    id="pi-start-live-$$-$harness-$mode"
    ids+=("$id")
    fm_test_spawn_brief "$LAB/home" "$id" "Reply PI_START_SENTINEL_$id; use no tools."
    if ! PATH="$LAB/bin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$LAB/home" FM_SPAWN_NO_GUARD=1 \
      "$ROOT/bin/fm-spawn.sh" "$id" "$LAB/project" --scout --harness "$harness" \
      --backend tmux --model fm-local/echo > "$LAB/spawn.out" 2>&1; then
      cat "$LAB/spawn.out" >&2
      target=$(sed -n 's/^window=//p' "$LAB/home/state/$id.meta")
      "$REAL_TMUX" -S "$LAB/socket" capture-pane -p -t "$target" -S -0 >&2 || true
      fail "$harness $version $mode spawn did not prove brief processing"
    fi
    target=$(sed -n 's/^window=//p' "$LAB/home/state/$id.meta")
    for _ in $(seq 1 100); do
      grep -Fq "PI_START_SENTINEL_$id" "$LAB/agent/requests" 2>/dev/null && break
      sleep 0.1
    done
    grep -Fq "PI_START_SENTINEL_$id" "$LAB/agent/requests" || fail "$harness $version did not process the supplied brief"
    jq -e --arg wt "$LAB/wt" 'keys == [$wt] and .[$wt] == true' "$LAB/agent/trust.json" >/dev/null \
      || fail "$harness $version trusted more than the task folder"
    "$REAL_TMUX" -S "$LAB/socket" send-keys -t "$target" -l /quit
    "$REAL_TMUX" -S "$LAB/socket" send-keys -t "$target" Enter
    # Relaunch from the recorded, stopped endpoint, keeping its trusted folder.
    sleep 1
    if ! PATH="$LAB/bin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$LAB/home" FM_SPAWN_NO_GUARD=1 \
      "$ROOT/bin/fm-spawn.sh" "$id" --relaunch > "$LAB/relaunch.out" 2>&1; then
      cat "$LAB/relaunch.out" >&2
      fail "$harness $version relaunch failed"
    fi
    "$REAL_TMUX" -S "$LAB/socket" kill-window -t "$target"
    pass "$harness $version $mode spawn and relaunch proved brief processing with folder-only trust"
  done
  id="pi-start-live-$$-$harness-secondmate"
  ids+=("$id")
  sm="$LAB/secondmate-$harness"
  mkdir -p "$sm/bin" "$sm/data" "$sm/.pi/extensions"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf '# Test home\n' > "$sm/AGENTS.md"
  printf 'PI_START_SECOND_SENTINEL_%s\n' "$id" > "$sm/data/charter.md"
  printf 'export default function () {}\n' > "$sm/.pi/extensions/fm-primary-turnend-guard.ts"
  cp "$sm/.pi/extensions/fm-primary-turnend-guard.ts" "$sm/.pi/extensions/fm-primary-pi-watch.ts"
  if ! PATH="$LAB/bin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$LAB/home" FM_SPAWN_NO_GUARD=1 \
    FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$sm" --secondmate --harness "$harness" \
    --backend tmux --model fm-local/echo > "$LAB/secondmate.out" 2>&1; then
    cat "$LAB/secondmate.out" >&2
    fail "$harness $version secondmate failed startup proof"
  fi
  for _ in $(seq 1 100); do
    grep -Fq "PI_START_SECOND_SENTINEL_$id" "$LAB/agent/requests" && break
    sleep 0.1
  done
  grep -Fq "PI_START_SECOND_SENTINEL_$id" "$LAB/agent/requests" || fail "$harness $version secondmate charter not processed"
  jq -e --arg wt "$LAB/wt" --arg sm "$sm" 'keys == ([$wt,$sm] | sort) and .[$sm] == true' "$LAB/agent/trust.json" >/dev/null \
    || fail "$harness $version secondmate trust escaped its folder"
  pass "$harness $version secondmate proved charter processing with folder-only trust"

  id="pi-start-live-$$-$harness-refusal"
  ids+=("$id")
  fm_test_spawn_brief "$LAB/home" "$id" 'No provider should run.'
  rc=0
  PATH="$LAB/bin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$LAB/home" FM_SPAWN_NO_GUARD=1 \
    FM_PI_READY_POLLS=20 FM_PI_POLL_INTERVAL=0.1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$LAB/project" --scout --harness "$harness" \
    --backend tmux --model fm-missing/no-model > "$LAB/refusal.out" 2>&1 || rc=$?
  expect_code 1 "$rc" "$harness $version launch without processing must refuse"
  assert_not_contains "$(cat "$LAB/refusal.out")" "spawned $id" 'false spawn success'
  assert_contains "$(cat "$LAB/refusal.out")" "$harness $version did not confirm agent_start" 'version diagnostic'
  pass "$harness $version refuses launch without agent_start"
  "$REAL_TMUX" -S "$LAB/socket" kill-server
done
[ "$checked" -gt 0 ] || fail 'no installed Pi harness was checked'
