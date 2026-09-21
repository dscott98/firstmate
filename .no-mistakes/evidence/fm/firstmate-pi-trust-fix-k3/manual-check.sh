#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=/home/dscott/.no-mistakes/evidence/01M317WX753M91Z0H7F37QTEZ7
SOCKET=$(cat .pi-gate-manual/socket-path)
tmux() { command tmux -S "$SOCKET" "$@"; }
. bin/fm-backend.sh
. bin/fm-pi-start-lib.sh
export FM_PI_READY_POLLS=3 FM_PI_POLL_INTERVAL=0.1
tmux capture-pane -p -t validation > "$EVIDENCE/pi-fresh-trust.txt"
for choice in parent session; do
 tmux send-keys -t validation Down
 sleep 0.2
 rc=0
 fm_pi_wait_for_start tmux validation validation "$ROOT/.pi-gate-manual/absent-receipt" 'pi 0.85.1' > "$EVIDENCE/pi-$choice-refusal.txt" 2>&1 || rc=$?
 test "$rc" = 1
 test ! -e .pi-gate-manual/agent/trust.json
 tmux capture-pane -p -t validation > "$EVIDENCE/pi-$choice-menu.txt"
 grep 'Trust project folder?' "$EVIDENCE/pi-$choice-menu.txt"
 cat "$EVIDENCE/pi-$choice-refusal.txt"
done
tmux send-keys -t validation Up Up
sleep 0.2
rc=0
fm_pi_wait_for_start tmux validation validation "$ROOT/.pi-gate-manual/absent-receipt" 'pi 0.85.1' > "$EVIDENCE/pi-no-brief-refusal.txt" 2>&1 || rc=$?
test "$rc" = 1
sleep 1
jq -e --arg project "$ROOT/.pi-gate-manual/project" 'keys == [$project] and .[$project] == true' .pi-gate-manual/agent/trust.json
cp .pi-gate-manual/agent/trust.json "$EVIDENCE/pi-manual-trust.json"
tmux capture-pane -p -t validation > "$EVIDENCE/pi-after-trust-no-brief.txt"
cat "$EVIDENCE/pi-no-brief-refusal.txt"
