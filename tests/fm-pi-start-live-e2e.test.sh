#!/usr/bin/env bash
# Real Pi/Pi-signed startup guard under the scoped one-run --approve contract.
# A local provider consumes the brief; no credentials or model requests leave
# the machine. Only the worktree allocator is replaced, using a real isolated
# Git worktree and private tmux. Managed launches never answer a folder-trust
# dialog into the store: approval is one-run, so the store must stay empty.
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
    models: [{id: 'echo-' + 'x'.repeat(1200), name: 'Echo', reasoning: false, input: ['text'],
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
    for dir in /tmp/fm-"$id"+*; do
      if [ -e "$dir" ] || [ -L "$dir" ]; then rm -rf "$dir"; fi
    done
  done
  fm_test_cleanup
}
ids=()
trap cleanup EXIT
model=$(node -e 'process.stdout.write("echo-" + "x".repeat(1200))')
request_count() { if [ -f "$LAB/agent/requests" ]; then wc -l < "$LAB/agent/requests"; else echo 0; fi; }
assert_brief_received() {
  local expected=$1 before=$2
  for _ in $(seq 1 100); do
    if jq -e -s --rawfile expected "$expected" --argjson before "$before" '
      length > $before and
      (.[-1] | map(select(.role == "user")) | last | .content |
        if type == "string" then . else map(select(.type == "text") | .text) | join("") end)
        == ($expected | sub("\n+$"; ""))
    ' "$LAB/agent/requests" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
  done
  fail "$harness $version did not deliver the complete brief to its provider"
}
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
  for mode in fresh remembered ship; do
    id="pi-start-live-$$-$harness-$mode"
    ids+=("$id")
    kind_args=(--scout)
    if [ "$mode" = ship ]; then
      kind_args=(--mode no-mistakes --yolo off)
      rm -f "$LAB/agent/trust.json"
    fi
    brief="Reply PI_START_SENTINEL_$id; use no tools. $(node -e 'process.stdout.write("payload ".repeat(600))') END_$id"
    fm_test_spawn_brief "$LAB/home" "$id" "$brief"
    before=$(request_count)
    if ! PATH="$LAB/bin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$LAB/home" FM_SPAWN_NO_GUARD=1 \
      "$ROOT/bin/fm-spawn.sh" "$id" "$LAB/project" "${kind_args[@]}" --harness "$harness" \
      --backend tmux --model "fm-local/$model" > "$LAB/spawn.out" 2>&1; then
      cat "$LAB/spawn.out" >&2
      target=$(sed -n 's/^window=//p' "$LAB/home/state/$id.meta")
      "$REAL_TMUX" -S "$LAB/socket" capture-pane -p -t "$target" -S -0 >&2 || true
      fail "$harness $version $mode spawn did not prove brief processing"
    fi
    target=$(sed -n 's/^window=//p' "$LAB/home/state/$id.meta")
    "$ROOT/bin/fm-operational-input.sh" encode launch-brief < "$LAB/home/data/$id/launch-brief.md" > "$LAB/expected"
    assert_brief_received "$LAB/expected" "$before"
    gen=$(sed -n 's/^spawn_gen=//p' "$LAB/home/state/$id.meta")
    for launch_dir in /tmp/fm-"$id"+*; do [ -d "$launch_dir" ] && break; done
    [ "$(wc -c < "$launch_dir/launch.$gen.sh")" -gt 1024 ] || fail 'staged launch fixture is not long enough'
    pass "$harness $version staged launch over 1024 bytes delivered the complete long brief"
    # Managed launches carry Pi's scoped one-run --approve (bin/fm-spawn.sh),
    # so no folder-trust dialog is ever answered into the store: nothing may
    # persist, in any mode, even though the worktree carries .pi resources.
    [ ! -f "$LAB/agent/trust.json" ] || jq -e 'keys == []' "$LAB/agent/trust.json" >/dev/null \
      || fail "$harness $version $mode persisted a trust decision under one-run approval"
    "$REAL_TMUX" -S "$LAB/socket" send-keys -t "$target" -l /quit
    "$REAL_TMUX" -S "$LAB/socket" send-keys -t "$target" Enter
    # Relaunch from the recorded, stopped endpoint, with no persisted trust.
    sleep 1
    before=$(request_count)
    if ! PATH="$LAB/bin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$LAB/home" FM_SPAWN_NO_GUARD=1 \
      "$ROOT/bin/fm-spawn.sh" "$id" --relaunch > "$LAB/relaunch.out" 2>&1; then
      cat "$LAB/relaunch.out" >&2
      fail "$harness $version relaunch failed"
    fi
    assert_brief_received "$LAB/expected" "$before"
    "$REAL_TMUX" -S "$LAB/socket" kill-window -t "$target"
    [ ! -f "$LAB/agent/trust.json" ] || jq -e 'keys == []' "$LAB/agent/trust.json" >/dev/null \
      || fail "$harness $version $mode relaunch persisted a trust decision under one-run approval"
    pass "$harness $version $mode spawn and relaunch proved brief processing with one-run approval"
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
    --backend tmux --model "fm-local/$model" > "$LAB/secondmate.out" 2>&1; then
    cat "$LAB/secondmate.out" >&2
    fail "$harness $version secondmate failed startup proof"
  fi
  for _ in $(seq 1 100); do
    grep -Fq "PI_START_SECOND_SENTINEL_$id" "$LAB/agent/requests" && break
    sleep 0.1
  done
  grep -Fq "PI_START_SECOND_SENTINEL_$id" "$LAB/agent/requests" || fail "$harness $version secondmate charter not processed"
  [ ! -f "$LAB/agent/trust.json" ] || jq -e 'keys == []' "$LAB/agent/trust.json" >/dev/null \
    || fail "$harness $version secondmate persisted a trust decision under one-run approval"
  pass "$harness $version secondmate proved charter processing with one-run approval"

  # Exercise the real spawn's staging guards in this private live backend.
  # Every protected path and byte below belongs to this fixture alone.
  home_token=$(node -e 'process.stdout.write(require("node:crypto").createHash("sha256").update(process.argv[1]).digest("hex"))' "$LAB/home")
  for unsafe in writable symlink file; do
    id="pi-start-live-$$-$harness-$unsafe"
    ids+=("$id")
    fm_test_spawn_brief "$LAB/home" "$id" 'This unsafe launch must not run.'
    launch_dir="/tmp/fm-$id+$home_token"
    protected="$LAB/protected-$harness-$unsafe"
    mkdir "$protected"
    printf 'existing launch must survive\n' > "$protected/launch.sh"
    cp "$protected/launch.sh" "$LAB/unchanged"
    case "$unsafe" in
      writable) mkdir -m 0770 "$launch_dir"; cp "$protected/launch.sh" "$launch_dir/launch.sh" ;;
      symlink) ln -s "$protected" "$launch_dir" ;;
      file) cp "$protected/launch.sh" "$launch_dir" ;;
    esac
    before=$(request_count)
    rc=0
    PATH="$LAB/bin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$LAB/home" FM_SPAWN_NO_GUARD=1 \
      "$ROOT/bin/fm-spawn.sh" "$id" "$LAB/project" --scout --harness "$harness" \
      --backend tmux --model "fm-local/$model" > "$LAB/unsafe.out" 2>&1 || rc=$?
    expect_code 1 "$rc" "$harness $version unsafe $unsafe path must refuse"
    assert_contains "$(cat "$LAB/unsafe.out")" "task launch directory $launch_dir already exists" 'wrong refusal boundary'
    [ "$(request_count)" -eq "$before" ] || fail 'unsafe launch reached the provider'
    cmp "$protected/launch.sh" "$LAB/unchanged" || fail 'protected target was changed'
    case "$unsafe" in
      writable) cmp "$launch_dir/launch.sh" "$LAB/unchanged" || fail 'existing launch was overwritten' ;;
      symlink) [ -L "$launch_dir" ] || fail 'launch symlink was replaced' ;;
      file) cmp "$launch_dir" "$LAB/unchanged" || fail 'existing namespace file was overwritten' ;;
    esac
    rm -rf "$launch_dir"
    pass "$harness $version refused unsafe $unsafe launch path and preserved existing files"
  done

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
