#!/usr/bin/env bash
set -eu
LAB=$(mktemp -d "$PWD/.fm-mkdir-probe.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
for round in 1 2 3 4 5; do
  pids=()
  for i in $(seq 1 20); do
    (if /usr/bin/mkdir "$LAB/claim-$round" 2>/dev/null; then printf 'won\n'; fi) > "$LAB/result-$i" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  printf 'round %s successful mkdir calls: ' "$round"
  cat "$LAB"/result-* | wc -l
done
