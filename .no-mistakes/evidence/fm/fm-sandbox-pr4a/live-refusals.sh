#!/usr/bin/env bash
set -eu
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_SPAWN_NO_GUARD FM_BACKEND TASKS_AXI_FILE TASKS_AXI_BACKEND
LAB=$(mktemp -d "$PWD/.fm-validation-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB"
export FM_HOME="$LAB"
mkdir -p "$LAB/projects/alpha"
git -C "$LAB/projects/alpha" init -q -b main
printf '%s\n' '- alpha [direct-PR] - isolated validation project' > "$LAB/data/projects.md"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$LAB/.tasks.toml"
tasks-axi add lab-refusal 'Exercise sandbox refusal guards' --kind ship --file "$LAB/data/backlog.md" >/dev/null
run() {
  label=$1 expected=$2; shift 2
  printf '\nSCENARIO: %s\nCOMMAND: bin/fm-spawn.sh' "$label"
  printf ' %q' "$@"; printf '\n'
  set +e
  output=$(bin/fm-spawn.sh "$@" 2>&1)
  rc=$?
  set -e
  printf '%s\nexit=%s\n' "$output" "$rc"
  [ "$rc" -ne 0 ]
  case "$output" in *"$expected"*) ;; *) exit 90 ;; esac
  [ ! -f "$LAB/state/lab-refusal.meta" ]
  printf 'Verified: named refusal and no task record.\n'
}
run 'No configured provider' 'no sandbox provider configured' lab-refusal "$LAB/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
run 'Claude remains disabled' 'Claude in sandboxes waits for the PR7 real-host smoke test' lab-refusal "$LAB/projects/alpha" --mode direct-PR --yolo off --harness claude --placement sandbox
run 'Local-only task cannot be placed remotely' 'refuses --mode local-only' lab-refusal "$LAB/projects/alpha" --mode local-only --yolo off --placement sandbox
run 'Persistent home cannot be disposable' 'refuses --secondmate' lab-refusal --secondmate --placement sandbox
run 'Non-tmux backend refuses sandbox placement' 'only on the tmux backend' lab-refusal "$LAB/projects/alpha" --mode direct-PR --yolo off --backend herdr --placement sandbox
printf '\nBACKLOG AFTER REFUSALS\n'
tasks-axi show lab-refusal --file "$LAB/data/backlog.md"
printf '\nSTATE AFTER REFUSALS\n'
find "$LAB/state" -type f -printf '%P\n'
