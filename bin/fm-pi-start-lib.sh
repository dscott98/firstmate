#!/usr/bin/env bash
# Pi/Pi-signed launch readiness, sourced by fm-spawn.sh after fm-backend.sh.
# fm_pi_start_extension <absolute-receipt> <encoded-brief-file> emits an explicit -e extension.
# The caller allocates a fresh, private, incarnation-specific receipt path
# outside the project and rejects a pre-existing receipt before launch.
# before_agent_start must match the frozen encoded brief, then agent_start
# writes the receipt synchronously; session_start, the initial
# fm-spawn busy seed, native backend activity, and rendered brief echoes cannot
# prove that Pi started processing its instructions. A short completed turn
# leaves the same receipt, so polling cannot miss it.
# fm_pi_wait_for_start <backend> <target> <label> <receipt> <harness-version>
# waits up to FM_PI_READY_POLLS (120) at FM_PI_POLL_INTERVAL (0.5 seconds).
# It selects Enter at most once, only for the complete live folder-trust
# selector with the exact per-folder Trust item selected. Parent/session-only
# choices, partial frames and history are never answered. No trust store is
# written here. Unsupported viewport capture, capture/key failure, and timeout
# refuse with a harness/version diagnostic. The receipt is the sole success
# condition and is checked before reading the screen or sending any key.
# The staged launch directory owns extension/receipt retention and teardown.

fm_pi_start_extension() { # <receipt> <encoded-brief-file>
  local paths_json
  paths_json=$(jq -cn --arg receipt "$1" --arg prompt "$2" '{receipt:$receipt,prompt:$prompt}') || return 1
  cat <<EOF
import { readFileSync, writeFileSync } from "node:fs";
const paths = $paths_json;
const expected = readFileSync(paths.prompt, "utf8").replace(/\n+$/, "");
export default function (pi) {
  let started = false;
  let briefPending = false;
  pi.on("before_agent_start", (event) => { briefPending = event.prompt === expected; });
  pi.on("agent_start", () => {
    if (started || !briefPending) return;
    writeFileSync(paths.receipt, "agent-start\n", { flag: "wx", mode: 0o600 });
    started = true;
  });
}
EOF
}

fm_pi_trust_selected() { # <visible-plain-capture>
  local pane=$1
  case "$pane" in *'Trust project folder?'*) ;; *) return 1 ;; esac
  case "$pane" in *'Do not trust'*) ;; *) return 1 ;; esac
  case "$pane" in *'↑↓ navigate'*) ;; *) return 1 ;; esac
  case "$pane" in *'enter select'*) ;; *) return 1 ;; esac
  printf '%s\n' "$pane" | grep -Eq '^[[:space:]]*→ Trust[[:space:]]*$'
}

fm_pi_wait_for_start() { # <backend> <target> <label> <receipt> <harness-version>
  local backend=$1 target=$2 label=$3 receipt=$4 identity=$5
  local pane i=0 answered=0 max=${FM_PI_READY_POLLS:-120}
  local interval=${FM_PI_POLL_INTERVAL:-0.5}
  fm_backend_visible_capture_supported "$backend" || {
    echo "error: $identity startup needs a verified viewport capture on backend '$backend'" >&2
    return 1
  }
  while [ "$i" -lt "$max" ]; do
    if [ -f "$receipt" ] && [ ! -L "$receipt" ] &&
      [ "$(cat "$receipt")" = agent-start ]; then
      return 0
    fi
    pane=$(fm_backend_visible_capture "$backend" "$target" "$label") || {
      echo "error: $identity startup could not read the live viewport on '$backend'" >&2
      return 1
    }
    if [ "$answered" -eq 0 ] && fm_pi_trust_selected "$pane"; then
      fm_backend_send_key "$backend" "$target" Enter "$label" || {
        echo "error: $identity could not select per-folder Trust" >&2
        return 1
      }
      answered=1
    fi
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  echo "error: $identity did not confirm agent_start; per-folder Trust selections=$answered; inspect $target" >&2
  return 1
}
