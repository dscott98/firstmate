#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
export FM_HOME="$ROOT/.test-local/hold-home"
export FM_DATA_OVERRIDE="$FM_HOME/data" FM_STATE_OVERRIDE="$FM_HOME/state" FM_CONFIG_OVERRIDE="$FM_HOME/config" FM_PROJECTS_OVERRIDE="$FM_HOME/projects" FM_ROOT_OVERRIDE="$ROOT"
unset TASKS_AXI_FILE TASKS_AXI_BACKEND
mkdir -p "$FM_HOME"/{data,state,config,projects}
cp .tasks.toml "$FM_HOME/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
for id in proof-origin wrong-origin legacy-origin; do
  printf "kind=scout\nmode=scout\n" > "$FM_HOME/state/$id.meta"
  bin/fm-tasks-axi.sh add "$id" --title "$id" --repo sample >/dev/null 2>&1 || true
done
reason=$'Choose rollout (safe or fast).\nPreserve café and "quotes".'
run() { printf '\n$'; printf ' %q' "$@"; printf '\n'; "$@"; }
run bin/fm-captain-hold.sh hold proof-call --title 'Rollout choice' --reason "$reason" --origin proof-origin --repo sample
run bin/fm-tasks-axi.sh show proof-call
run bin/fm-tasks-axi.sh list
bin/fm-fleet-snapshot.sh --json > "$ROOT/.test-local/snapshot-output"
cat "$ROOT/.test-local/snapshot-output"
cat "$ROOT/.test-local/snapshot-output" | jq -e --arg reason "$reason" '.backlog.records[] | select(.id=="proof-call") | .hold_reason == $reason'
run bin/fm-captain-hold.sh complete proof-origin proof-call
run bin/fm-captain-hold.sh verify proof-origin
reject() { if run "$@"; then echo 'ERROR: accepted invalid inventory'; exit 1; else echo 'Expected refusal'; fi; }
reject bin/fm-captain-hold.sh complete proof-call proof-call
reject bin/fm-captain-hold.sh complete wrong-origin proof-call
run bin/fm-captain-hold.sh hold legacy-call --title 'Legacy call' --reason 'Original reason' --repo sample
run bin/fm-captain-hold.sh complete legacy-origin legacy-call
run bin/fm-captain-hold.sh verify legacy-origin
printf '\nAll live CLI assertions passed.\n'
