#!/usr/bin/env bash
set -eu
ROOT=$PWD
export FM_HERDR_LAB_STATE_DIR="$ROOT/.test-herdr-lab"
H="$ROOT/bin/fm-herdr-lab.sh"
S=fm-lab-meta-final
LAB="$ROOT/.test-live-home"
export FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID
trap '"$H" teardown "$S"' EXIT
mkdir -p "$LAB/proj" "$LAB/data/proof"
git -C "$LAB/proj" init -q
true
true
cat > "$LAB/data/proof/brief.md" <<'EOF'
# Validation worker
## Captain's intent
Reply READY and wait. Do not run tools, change any files, or start any task.
## Firstmate spec
This is an isolated launch validation. Reply READY only.
EOF
"$H" provision "$S"
"$H" run "$S" workspace create --cwd "$LAB/wt" --label proof --env FM_HOME="$LAB" --no-focus
"$H" viewer start "$S"
"$H" run "$S" agent start proof --kind codex --pane w1:p1 --timeout 15000 -- --dangerously-bypass-approvals-and-sandbox -c 'features.hooks=false' -c 'check_for_update_on_startup=false'
cat > "$LAB/state/proof.meta" <<EOF
window=$S:w1:p1
endpoint_task_id=proof
worktree=$LAB/wt
project=$LAB/proj
harness=codex
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
backend=herdr
herdr_session=$S
herdr_workspace_id=w1
herdr_tab_id=w1:t1
herdr_pane_id=w1:p1
pr=https://github.com/example/repo/pull/78
pr_head=0123456789abcdef0123456789abcdef01234567
x_request=meta-proof
EOF
. "$ROOT/bin/fm-pr-lib.sh"
fm_pr_poll_prepare "$LAB/state" proof github https://github.com/example/repo/pull/78 github.com example/repo 78 "$ROOT/bin/fm-pr-poll.sh"
fm_pr_poll_publish_prepared
fm_pr_poll_artifacts_valid "$LAB/state" proof "$ROOT/bin/fm-pr-poll.sh"
echo BEFORE_AUTHENTICATES
printf '%s\n' "$$" > "$LAB/state/.lock"
printf '%s on\n' "$$" > "$LAB/state/.trace-context-effective"
"$H" run "$S" agent read proof
FM_CONTROL_EXIT_WAIT=15 FM_CONTROL_LAUNCH_WAIT=15 "$ROOT/bin/fm-control.sh" proof relaunch --note 'Reply READY only; do not use tools or change files.'
cat "$LAB/state/proof.meta"
fm_pr_poll_artifacts_valid "$LAB/state" proof "$ROOT/bin/fm-pr-poll.sh"
echo AFTER_AUTHENTICATES
"$H" run "$S" agent read proof
printf 'foreign_key=invalid\n' >> "$LAB/state/proof.meta"
if fm_pr_poll_artifacts_valid "$LAB/state" proof "$ROOT/bin/fm-pr-poll.sh"; then exit 8; else echo FOREIGN_TAIL_REJECTED; fi
