# Remote task sandboxes

This page covers how to configure and operate the provider that runs Firstmate task sandboxes: short-lived, disposable virtual machines that host one task's working home.
It is for operators who wire a sandbox provider into a firstmate home and for anyone checking the adapter's safety behavior.

The planned placement integration will run ordinary ships and scouts in one-task Firstmate homes on disposable VMs, with the primary as their only supervisor.
Today, operators manage sandbox lifecycles manually; task launch and automatic cleanup are not integrated.

## Find a topic

| Task | Start here |
| --- | --- |
| Check what is wired today | [Current status](#current-status) |
| Understand the safety rules | [Principles](#principles) and [network profiles](#network-profiles) |
| Configure a provider | [Configure a provider](#configure-a-provider) |
| Drive the lifecycle by hand | [Operate](#operate) |
| Understand task routes and readiness | [Task routes](#task-routes) and [task readiness](#task-readiness) |
| Handle capacity or failures | [Capacity and failures](#capacity-and-failures) |
| Run the tests | [Verification](#verification) |

## Current status

The sandbox placement plan ships in stages.
What is wired today:

- The provider adapter `bin/fm-sandbox.sh` and its configuration: an operator can configure a provider and drive every lifecycle verb by hand.
- [Task routes](#task-routes): the transport reaches a sandbox task's one-task home from that task's own record, and every command that branches on remote placement recognizes a sandbox task record.
- [Task readiness](#task-readiness): the readiness doctor checks a sandbox host against a task profile.

Spawn does not yet accept sandbox placement, so no task is placed in a sandbox automatically.
The placement flag, host-side task control, status mirroring, teardown, and supervision integration land in later stages of the plan.

## Principles

- Placement is an explicit, per-task choice.
  Nothing infers it, and a sandbox outage is a blocker; firstmate never falls back silently to local placement.
- The feature is default-off.
  With no `config/sandbox-provider`, every sandbox request refuses and nothing else changes.
- The contract is provider-neutral.
  It names verbs and labels, not Proxmox, so an LXC or microVM provider can implement it later.
  The reference provider `pve-sandbox` lives in the proxmox-lab project.
- Firstmate never holds the Proxmox token and never calls the Proxmox API.
  Every effect and every observation flows through `bin/fm-sandbox.sh`, which invokes the provider with argv only, never a shell string.
- Every sandbox carries two labels: `fm_task=<task-id>` and `fm_home=<home tag>`.
  `extend`, `hold`, `release`, `policy`, `exec`, `snapshot`, and `rollback` require an existing sandbox belonging to this home, enforced by the [adapter's shared status guard](../bin/fm-sandbox.sh).
  Destroying a sandbox refuses when the labels disagree, so one home can never destroy another home's sandbox, and an already-absent sandbox is success, so cleanup is idempotent.
- Preserve unlanded work before invoking `destroy` manually.
  The adapter checks no landing evidence; the landed-work gate ships with the teardown integration.

## Network profiles

- The `default` profile allows DNS and HTTPS egress, blocks LAN and RFC1918 destinations, and allows inbound SSH from the primary only.
- The `open` profile lifts those restrictions and requires explicit per-task `--profile open`; configuring `default_profile=open` is refused.
- `fm-sandbox.sh policy <name>` prints a sandbox's effective rules for visibility.

## Credentials

Sandbox credentials are Pi API-key providers plus per-repository GitHub tokens only.
Host keys are pinned by the provider, not trusted on first use, and the SSH configuration the sandbox aliases live in is provider-managed.

## Configure a provider

`config/sandbox-provider` is local and gitignored, selected by `FM_HOME` like every other config file; [the configuration reference](configuration.md#sandbox-provider-configsandbox-provider) owns its exact format.
The provider command must satisfy the invocation, record framing, ownership-label validation, and exit contracts that [the `fm-sandbox.sh` header](../bin/fm-sandbox.sh) owns.

## Operate

`bin/fm-sandbox.sh` is the single entry point, and its `--help` prints the verb list.

- `create <task-id>` asks the provider for a sandbox and prints its `name`, `vmid`, `node`, `ssh_alias`, `user`, `profile`, `ttl_expires`, and `hostkey`.
- `status <name>` prints the sandbox's `state` (`running`, `stopped`, or `absent`); running and stopped records require both `fm_task` and `fm_home`, while absent records may omit labels.
- `list` prints this home's sandboxes only, one record line per sandbox, requiring both ownership labels for running and stopped records it retains.
  Records without this home's `fm_home` label are dropped.
- `extend <name> --ttl <duration>` renews the TTL; `hold <name>` and `release <name>` manage the reap-blocking hold label.
- `policy <name>` prints the effective firewall rules.
- `exec <name> -- <argv>` runs one bootstrap command inside the sandbox; its argv is never a shell string.
- `snapshot <name> <label>` and `rollback <name> <label>` are an optional safety net the provider may implement.
- `destroy <name> --expect-task <task-id>` removes the sandbox, refusing when the labels disagree and treating an absent sandbox as success.

## Task routes

A sandbox task's record in this home's `state/<id>.meta` declares its placement: `placement=sandbox` and `remote_kind=task` on a ship or scout, the SSH alias in `remote_host`, the VM's Firstmate code root in `remote_root`, and its one-task home in `remote_home`.
Placement is never inferred: a record without `placement=sandbox` is never treated as a sandbox task, and a record whose placement fields contradict each other is refused rather than guessed at.
[`bin/fm-remote-route-lib.sh`](../bin/fm-remote-route-lib.sh) is the one owner of that record contract and of remote dispatch for every command.

- `bin/fm-on.sh <task-id> <fm-command>` resolves the route from the task's record, selected by its exact task id.
  It applies the same transport checks as a second-mate registry route, refuses a code root and home that overlap, and refuses a task id that also names a registry route.
  Second-mate registry routes are unchanged.
- Until host-side task control exists, peek, steering, lifecycle control, and teardown refuse a sandbox task record by name, and teardown refuses it even with `--force`.
  The current-state read reports it as unknown, never as dead, and second-mate liveness and the watcher's queue checks skip it.
  None of them treats a sandbox task as a local task or as a remote second mate.

## Task readiness

`bin/fm-on.sh <task-id> fm-remote-doctor.sh --profile task` checks a sandbox host against the task profile, and `--fix` repairs it the same way it repairs a second-mate host.
The [doctor's header](../bin/fm-remote-doctor.sh) owns the line protocol and every check.

| Requirement | Tools |
| --- | --- |
| Always required | `git`, `jq`, `tmux`, and `treehouse` |
| At least one of | `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, or `kimi` |
| Optional | `tasks-axi`, because a task home's backlog is manual, plus `no-mistakes` and `gh` |

The task profile runs no Herdr session: it reports every Herdr check as skipped and never inspects, starts, or writes a Herdr server or launch agent.
It still requires the remote job worker and the entrypoint symlink, because every command other than the doctor runs through that worker.

## Capacity and failures

Provider capacity refusals during lifecycle calls and ownership status checks surface as blockers; [the adapter header](../bin/fm-sandbox.sh) owns the exact exit statuses, including the raw relay behavior once `exec` begins.
Treat it like any other infrastructure blocker: surface it, free sandboxes, or wait; never fall back to local placement.

Refusals name the concrete configuration, provider, or output problem, and provider failures include its stderr.
Invalid output is withheld, but refusal does not roll back effects the provider already performed.
Usage errors are rejected before invoking the provider.
After the ownership status check, `exec` relays raw provider output and exit status unchanged, including nonzero statuses; it does not apply lifecycle record validation or capacity translation.

## Verification

```sh
bin/fm-test-run.sh tests/fm-sandbox.test.sh
bin/fm-test-run.sh tests/fm-remote-route-lib.test.sh
```

The adapter suite drives every verb against a fake provider, including the refusal paths, the home-tag filtering, the capacity distinction, and argv-only invocation.
The route suite pins the task record contract and runs each command that branches on remote placement against a sandbox task record, proving each refuses without reaching the transport or a local backend.
Task route resolution and the task readiness profile are covered by `tests/fm-on.test.sh` and `tests/fm-remote-doctor.test.sh`, part of the [remote second-mate suite](remote-secondmates.md#portable-tests).
A real-cluster smoke run lands with the final stage of the plan.
