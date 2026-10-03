#!/usr/bin/env bash
set -eu
scratch=$(mktemp -d "$PWD/.engine-check.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
export FM_HOME="$scratch" FM_ROOT="$PWD"
unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE
mkdir -p "$scratch/state" "$scratch/config"
. bin/fm-wake-lib.sh
. bin/fm-timeout-lib.sh
. bin/fm-supervision-engine-lib.sh
cat > "$scratch/engine" <<'STUB'
#!/bin/bash
/bin/sleep 1.3
printf 'engine completed\n'
STUB
chmod +x "$scratch/engine"
export FM_SUPERVISION_ENGINE_CLAUDE_BIN="$scratch/engine"
: > "$scratch/prompt"
: > "$scratch/message"
sleep() { printf '%s\n' "$1" >> "$scratch/sleeps"; /bin/sleep "$@"; }
for pair in '0 0.05 0.1' '1 0.05 0.05' '1 0.01 0.1' '1 0.2 0.1' '1 bogus 0.1'; do
  read -r FM_TEST_SEAM FM_ENGINE_POLL_STEP expected <<< "$pair"
  export FM_TEST_SEAM FM_ENGINE_POLL_STEP
  : > "$scratch/sleeps"
  fm_supervision_engine_turn claude sonnet "$scratch/prompt" "$scratch/message" test new 10 "$scratch/result" "$scratch/errors"
  actual=$(sort -u "$scratch/sleeps")
  [ "$actual" = "$expected" ]
  printf 'marker=%s requested=%s observed_sleep=%s result=%s\n' "$FM_TEST_SEAM" "$FM_ENGINE_POLL_STEP" "$actual" "$(cat "$scratch/result")"
done
