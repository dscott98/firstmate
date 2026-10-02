#!/usr/bin/env bash
set -eu
LAB=$(mktemp -d "$PWD/.fm-sequence-probe.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
for revision in 4aedf7c8a0886c179365edbe34e3bf2b38d63dcc 9666b869e9ea28bbf7542d53ff3f84fc42e9ce9f; do
  git show "$revision:bin/fm-remote-job-lib.sh" > "$LAB/lib.sh"
  (
    . "$LAB/lib.sh"
    export FM_REMOTE_JOB_STATE_ROOT="$LAB/$revision"
    mkdir -p "$LAB/account"
    fm_remote_job_prepare_state "$LAB/account"
    mkdir "$LAB/results-$revision"
    pids=()
    for i in $(seq 1 20); do
      fm_remote_job_next_seq > "$LAB/results-$revision/$i" &
      pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
    printf 'revision=%s\n' "$revision"
    cat "$LAB/results-$revision/"* | sort -n
    printf 'durable claim count: '
    find "$FM_REMOTE_JOB_SEQ_CLAIMS" -mindepth 1 -maxdepth 1 -type d | wc -l
  )
done
