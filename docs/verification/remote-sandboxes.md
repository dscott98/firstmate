# Remote task sandbox verification

This record contains the real-cluster evidence for the sandbox placement guarantees in [the operator guide](../remote-sandboxes.md).
The guide owns current setup, safety boundaries, and limits.
Task chronology, the disposable repository, and the full delivery transcript stay in the private task evidence.

## Real-cluster placement lifecycle

Verified on 2026-10-07 against a three-node Proxmox VE cluster (pve01-03) with the reference provider `pve-sandbox` from proxmox-lab, Firstmate `2f3aa92a` driving from a scratch lab home whose code root sat at that default-branch commit, and a `pi` worker on `minimax/minimax-m3`.
The task was a no-mistakes ship on a disposable private GitHub repository cloned from its origin inside the sandbox, with a `pi:minimax` key and a GitHub token selected by `config/sandbox-credentials`.

Placement command shape, run with the lab home's `FM_HOME`:

```sh
bin/fm-spawn.sh sbx-pr7b-smoke projects/fm-sbx-smoke-pr7b \
  --mode no-mistakes --yolo on --placement sandbox \
  --harness pi --model minimax/minimax-m3
```

Observed: the provider created a cold sandbox to SSH readiness in 13.5 s (provider timings: clone 0.50 s, start 1.25 s, address 10.39 s, host key 10.79 s, firewall enforce 0.57 s), and the whole placement - create, code-root convergence to the driving home's default-branch commit, the task readiness gate, provisioning the one-task home, and launching the worker - completed in 41 s.
The worker's first status line mirrored back 17 s after the spawn began, and a mid-task steer that amended the worker's commit completed its round trip (steer sent to mirrored fresh status line) in about 40 s.

Steering, decisions, and the no-mistakes pipeline all crossed the transport: `bin/fm-send.sh` delivered through the durable inbox, an ask-user finding at the review gate and one at the test gate each escalated as a keyed `needs-decision` line whose findings file the driving home read through the path-confined `fm-remote-file.sh get`, and each keyed decision returned through `fm-send.sh --resolve-key <key>` and closed its record, with roughly 47 s from escalation to the answer's `resolved` line.

The green merge and the guarded cleanup ran from the driving home:

```sh
bin/fm-pr-merge.sh sbx-pr7b-smoke https://github.com/dscott98/fm-sbx-smoke-pr7b/pull/1
bin/fm-teardown.sh sbx-pr7b-smoke
```

Observed: the merge verified the PR open, mergeable, and green at head, then verified `state=MERGED`, in 8 s; teardown ran the host-side landed-work test, closed the task's records and backlog item, and destroyed the sandbox in 12 s; `bin/fm-sandbox.sh list` and the provider's own list then showed no sandboxes.

## Unreachable host is unknown, never dead

With the task live and its worker parked, the provider paused the sandbox (`pve-sandbox pause <name>`, freezing the VM).
During the outage `bin/fm-peek.sh <id>` failed loudly with `host unreachable or endpoint unreadable; the task is not thereby dead`, and `bin/fm-crew-state.sh <id>` reported `state: unknown` with `not proof of death`.
The watcher's observations failed three consecutive times over 147 s and produced exactly one keyed wake per failure streak:

```text
check: sandbox sbx-pr7b-smoke unreachable: 3 consecutive observations of its host
sbx-sbx-pr7b-smoke-ccc304 failed over 147s (SSH exit 255: the host could not be
reached); its worker's state is unknown, not dead - check the sandbox and its
provider before any recovery
```

After `pve-sandbox resume <name>`, observations recovered on the next cadence tick with the same boot identity, and no death or wedge was ever recorded.

## Reboot recovery from the brief on disk

A guest reboot (`pve-sandbox reboot <name>`, SSH-ready again in 13 s) killed the sandbox's tmux server while the task's disk survived.
The next observation positively reported the endpoint gone:

```text
boot=1791399259
agent=missing
busy=dead
busy_source=endpoint-gone
```

The watcher emitted its once-per-incarnation dead-record report, naming the boot-time absence proof and the recovery command:

```text
stale: remote:sbx-pr7b-smoke (agent missing on sandbox host
sbx-sbx-pr7b-smoke-ccc304 - its recorded endpoint is gone there, so this is not a
wedge; reported once and not re-escalated while it stays that way - the sandbox
booted after this worker launched, so no tmux server survived; relaunch it from
its brief with bin/fm-control.sh sbx-pr7b-smoke relaunch; check for unlanded
work before any cleanup)
```

`bin/fm-control.sh <id> relaunch --note <text>` re-created the endpoint on the host in the same worktree, sent the brief because it had changed since launch, republished the task record from the host-confirmed route block, and the replacement worker verified its branch, PR, and landed state intact and parked without redoing shipped work.

## Claude remains refused

After the Pi path passed end to end, the same spawn with `--harness claude` refused before creating anything:

```text
error: Claude in sandboxes waits for the PR7 real-host smoke test
```

The output above is from the verified revision; the current spawn refusal points to the unsupported credential destination instead.
The [placement limits](../remote-sandboxes.md#placement) own Claude's continued exclusion after the Pi smoke run.

## Findings the run produced

Provisioning originally wired the absolute `gh auth git-credential` helper into the project clone but not into the no-mistakes gate repository, so a no-mistakes ship of a private repository failed its first pipeline run at the trusted-default-branch fetch; `bin/fm-remote-task-control.sh` now configures the gate repository with the same helper, and `tests/fm-remote-task-control.test.sh` covers the gate-repository helper configuration and its absence without a GitHub token.
Provisioning without a GitHub token and rollback of a failed initialization were exercised only by the colocated portable suite (`tests/fm-remote-task-control.test.sh`), while the live run covered the private-repository gate-repo fetch, the full create-launch-steer-PR-merge-teardown-destroy lifecycle, the paused-host case, and the reboot case.

Two environment observations are operational facts rather than firstmate defects: a no-mistakes run against a repository with no CI waits at the ci step until the trusted default branch declares `no_ci: true` (the disposable repository's owner seeded that declaration on `main`), and a scratch home whose state directory carries group or other write bits fails the status-mirror arm after launch with the arm named for rerun, because the process-event state root must be private.
