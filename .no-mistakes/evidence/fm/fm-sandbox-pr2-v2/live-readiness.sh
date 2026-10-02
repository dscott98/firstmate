#!/usr/bin/env bash
set -eu
LAB=$(mktemp -d "$PWD/.fm-readiness-lab.XXXXXX")
cleanup() {
  if [ -f "$LAB/remote-job/worker.pid" ]; then
    worker_pid=$(cat "$LAB/remote-job/worker.pid")
    . bin/fm-remote-job-lib.sh
    fm_remote_job_stop_worker_tree "$worker_pid" || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/.local/bin"
ln -s "$(command -v treehouse)" "$LAB/.local/bin/treehouse"
export FM_HOME="$LAB" HOME="$LAB" FM_REMOTE_JOB_STATE_ROOT="$LAB/remote-job"
export PATH="$LAB/.local/bin:/usr/bin:/bin"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
printf '%s\n' '$ bin/fm-remote-doctor.sh --profile task --fix'
bin/fm-remote-doctor.sh --profile task --fix
printf '%s\n' '$ bin/fm-remote-doctor.sh --profile task'
bin/fm-remote-doctor.sh --profile task
