# Remote task sandboxes

This page covers how to configure and operate the provider that runs Firstmate task sandboxes: short-lived, disposable virtual machines that host one task's working home.
It is for operators who wire a sandbox provider into a firstmate home and for anyone checking the adapter's safety behavior.

Sandbox placement runs an ordinary ship or scout in a one-task Firstmate home on a disposable VM, with the supervising home as its only supervisor.
Spawn places and launches such a task and mirrors its status today; lifecycle control, stale-pane supervision, and cleanup are later stages, as [current status](#current-status) lists.

## Find a topic

| Task | Start here |
| --- | --- |
| Check what is wired today | [Current status](#current-status) |
| Understand the safety rules | [Principles](#principles) and [network profiles](#network-profiles) |
| Configure a provider | [Configure a provider](#configure-a-provider) |
| Drive the lifecycle by hand | [Operate](#operate) |
| Place a task in a sandbox | [Placement](#placement) |
| Understand task routes and readiness | [Task routes](#task-routes) and [task readiness](#task-readiness) |
| Read, steer, or check a placed task | [Status mirror and routed verbs](#status-mirror-and-routed-verbs) |
| Understand what a sandbox host runs | [Host-side task control](#host-side-task-control) |
| Handle capacity or failures | [Capacity and failures](#capacity-and-failures) |
| Run the tests | [Verification](#verification) |

## Current status

The sandbox placement plan ships in stages.
What is wired today:

- The provider adapter `bin/fm-sandbox.sh` and its configuration: an operator can configure a provider and drive every lifecycle verb by hand.
- [Task routes](#task-routes): the transport reaches a sandbox task's one-task home from that task's own record, and every command that branches on remote placement recognizes a sandbox task record.
- [Task readiness](#task-readiness): the readiness doctor checks a sandbox host against a task profile.
- [Host-side task control](#host-side-task-control): everything a sandbox host runs for its one task, from provisioning its home to retiring it, and briefs rendered for that home.
- [Placement](#placement): `bin/fm-spawn.sh --placement sandbox` creates a sandbox, converges and gates it, provisions its home with the task's credentials, launches the task, and records its route.
- [Status mirror and routed verbs](#status-mirror-and-routed-verbs): the worker's status lines reach this home's status log and wake Firstmate, a scout's report arrives before its terminal line, and peek, steering, and current-state reads route to the task's host.

Sandbox placement is not for real use until the remaining stages land.
Lifecycle control arrives in PR6: interrupt, exit, and relaunch with the record republished.
Until PR6, `fm-control.sh` keeps its explicit named refusal of sandbox tasks.
Stale-pane and liveness supervision, teardown, and orphan and TTL handling of a placed task arrive in later stages of the plan.
Until then lifecycle control and teardown refuse a sandbox task, and cleaning one up is a manual operator step: preserve its unlanded work, destroy the sandbox, and close its record and backlog item.

## Principles

- [Placement](#placement) owns per-task selection, backlog recording, and the no-fallback rule.
- The feature is default-off.
  Provider operations require [provider configuration](configuration.md#sandbox-provider-configsandbox-provider); task transport requires an explicit [task route](#task-routes).
- The contract is provider-neutral.
  It names verbs and labels, not Proxmox, so an LXC or microVM provider can implement it later.
  The reference provider `pve-sandbox` lives in the proxmox-lab project.
- Firstmate never holds the Proxmox token and never calls the Proxmox API.
  Every provider effect and observation flows through `bin/fm-sandbox.sh`, which invokes the provider with argv only, never a shell string.
- Every sandbox carries two labels: `fm_task=<task-id>` and `fm_home=<home tag>`.
  `extend`, `hold`, `release`, `policy`, `exec`, `snapshot`, and `rollback` require an existing sandbox belonging to this home, enforced by the [adapter's shared status guard](../bin/fm-sandbox.sh).
  Destroying a sandbox refuses when the labels disagree, so one home can never destroy another home's sandbox, and an already-absent sandbox is success, so cleanup is idempotent.
- Preserve unlanded work before invoking `destroy` manually.
  The adapter checks no landing evidence; the host-side `retire` gate described below does not make provider destruction safe automatically.

## Network profiles

- The `default` profile allows DNS and HTTPS egress, blocks LAN and RFC1918 destinations, and allows inbound SSH from the primary only.
- The `open` profile lifts those restrictions and requires explicit per-task `--profile open`; configuring `default_profile=open` is refused.
- `fm-sandbox.sh policy <name>` prints a sandbox's effective rules for visibility.

## Credentials

Sandbox credentials are Pi API-key providers plus per-repository GitHub tokens only.
They reach a sandbox only in its provisioning manifest, are written only on the sandbox host with mode 0600, and never appear in output, logs, or task records; [host-side task control](#host-side-task-control) owns where they land.
Project origins containing embedded passwords are refused before sandbox creation.
The local, captain-owned `config/sandbox-credentials` selects which of them each task receives, by harness, model provider, delivery mode, and project; [the configuration reference](configuration.md#sandbox-credentials-configsandbox-credentials) owns its format.
Host keys are pinned by the provider, not trusted on first use, and the SSH configuration the sandbox aliases live in is provider-managed.

## Configure a provider

`config/sandbox-provider` is local and gitignored, selected by `FM_HOME` like every other config file; [the configuration reference](configuration.md#sandbox-provider-configsandbox-provider) owns its exact format.
The provider command must satisfy the invocation, record framing, ownership-label validation, and exit contracts that [the `fm-sandbox.sh` header](../bin/fm-sandbox.sh) owns.

## Operate

`bin/fm-sandbox.sh` is the single entry point, and its `--help` prints the verb list.

- `config` prints the validated settings - the provider's name, default profile, TTL, and the sandbox template's code root and home - without invoking the provider.
- `create <task-id>` asks the provider for a sandbox and prints its `name`, `vmid`, `node`, `ssh_alias`, `user`, `profile`, `ttl_expires`, and `hostkey`.
- `status <name>` prints the sandbox's `state` (`running`, `stopped`, or `absent`); running and stopped records require both `fm_task` and `fm_home`, while absent records may omit labels.
- `list` prints this home's sandboxes only, one record line per sandbox, requiring both ownership labels for running and stopped records it retains.
  Records without this home's `fm_home` label are dropped.
- `extend <name> --ttl <duration>` renews the TTL; `hold <name>` and `release <name>` manage the reap-blocking hold label.
- `policy <name>` prints the effective firewall rules.
- `exec <name> -- <argv>` runs one bootstrap command inside the sandbox; its argv is never a shell string.
- `snapshot <name> <label>` and `rollback <name> <label>` are an optional safety net the provider may implement.
- `destroy <name> --expect-task <task-id>` removes the sandbox, refusing when the labels disagree and treating an absent sandbox as success.

## Placement

`bin/fm-spawn.sh <task-id> <project> --mode <mode> --yolo <on|off> --placement sandbox` places a ship in a sandbox, and `--scout --placement sandbox` places a scout; [the spawn header](../bin/fm-spawn.sh) owns the exact refusals, sequence, and record fields.

- Placement is chosen per task, recorded with its reason in the task's backlog note, and passed explicitly; nothing infers it, and a refusal or an unavailable provider is a blocker, never a local fallback.
- Render the brief for the sandbox home with `bin/fm-brief.sh ... --for-home <remote_home> --for-root <remote_root>`, using the values `bin/fm-sandbox.sh config` prints; spawn refuses a brief that does not name that home's status file.
- `--sandbox-profile <name>` defaults to the provider's default profile.
  Any other profile, such as `open`, needs an explicit captain instruction for that exact task, recorded in its brief with `fm-brief.sh --sandbox-profile <name>`; spawn refuses it otherwise.
- Claude (pending the PR7 real-host smoke test), second mates, `local-only` ships, backends other than tmux, raw harness commands, and briefs carrying the `--herdr-lab` contract are refused.
- A sandboxed Pi worker needs `--model <provider>/<id>` and a [credential](#credentials) for that provider.
  This home's worker account pins do not apply, because a sandbox's credentials come only from `config/sandbox-credentials`.

Spawn checks the backlog item before anything exists, then creates the sandbox and publishes a provisional task record carrying its [route](#task-routes).
One provider `exec` fast-forwards the sandbox's Firstmate code root to this home's default-branch commit before any `bin/fm-on.sh` call.
Read-only provider exec calls then verify exact HEAD equality and clean tracked files before the [task readiness](#task-readiness) gate checks the host.
The template must use `/opt/firstmate` for its code root and `/home/agent/fm-home` for its task home.
A mismatched or dirty code root refuses the spawn without resetting, checking out, or discarding changes.
[Host-side task control](#host-side-task-control) then provisions the home and launches the task, and spawn checks the route block it returns field by field before it publishes the final record and moves the backlog item to In flight.
Last, spawn arms the task's [status mirror](#status-mirror-and-routed-verbs); an arm that fails keeps the launched task and its record and names the arm command to rerun.

A failure before launch destroys the sandbox, which holds no work yet, and removes the provisional record.
Once launch may have started, including an SSH exit 255 that leaves its completion unknown, the sandbox is held and its record kept so the route stays reachable for reconciliation; spawn never destroys a sandbox that may hold work.
Spawn returns an SSH exit 255 from the transport unchanged, so a caller can tell an unreachable host from a refusal.

## Task routes

A sandbox task's explicit placement and route come from this home's `state/<id>.meta`; [`bin/fm-remote-route-lib.sh`](../bin/fm-remote-route-lib.sh) owns the required fields, validation, and remote dispatch contract.

- `bin/fm-on.sh <task-id> <fm-command>` resolves the route from the task's record, selected by its exact task id.
  It applies the same transport checks as a second-mate registry route, refuses a code root and home that overlap, and refuses a task id that also names a registry route.
  Second-mate registry routes are unchanged.
- Peek, steering, and the current-state read route a sandbox task to [host-side task control](#host-side-task-control), as [status mirror and routed verbs](#status-mirror-and-routed-verbs) describes.
- Until the primary routes the remaining verbs there, lifecycle control and teardown refuse a sandbox task record by name, and teardown refuses it even with `--force`.
  Second-mate liveness and the watcher's queue checks skip it.
  None of them treats a sandbox task as a local task or as a remote second mate.

## Task readiness

`bin/fm-on.sh <task-id> fm-remote-doctor.sh --profile task` checks a sandbox host against the task profile; add `--fix` to repair its automatable gaps.
The [doctor's header and tool declarations](../bin/fm-remote-doctor.sh) own the profile's requirements, Herdr exclusions, repair boundaries, and line protocol.

## Status mirror and routed verbs

The worker appends status lines to its own home's `state/<id>.status` on the sandbox host.
[`bin/fm-procevent-remote-reply.sh`](../bin/fm-procevent-remote-reply.sh) mirrors them into this home's `state/<id>.status`, whose ordinary signal scan wakes Firstmate, and its header owns the route kinds and the mirror contract.

- The mirror is the [remote second-mate mirror](remote-secondmates.md#how-remote-lines-are-mirrored) with the task's status log as its source: the same cursor continuity, byte normalization, replay identity, one wake per mirrored line, and continuity-break escalation.
- This home's copy is the task's authoritative status log, because only it holds the `resolved` lines an answer writes here.
- A task's lines offer no documents and settle no correlated reply, so a `report=` pointer in them mirrors as written.
- For a scout, a mirrored `done` or `failed` line first fetches `data/<id>/report.md`, at most 1 MiB, through the path-confined reader into this home's `data/<id>/report.md`, so scout completion reads a local report before the line wakes anyone.
  The shared [document-fetch failure policy](remote-secondmates.md#when-an-offered-document-cannot-be-fetched) applies; a refused scout fetch also removes any older local report so it cannot stand in for the report the terminal line announces.

Peek, steering, and the current-state read route by task id to [host-side task control](#host-side-task-control):

- `bin/fm-peek.sh <task-id>` reads the worker's pane through `capture`; an unreachable host fails loudly and is never a death claim.
- `bin/fm-send.sh <task-id>` delivers through `send` into the worker's durable inbox, unmarked and keyed by a per-request id, so a retry lands on the same record while an identical later steer is a new instruction.
  [Its header](../bin/fm-send.sh) owns the unconfirmed-delivery resend; `--resolve-key` closes the decision in this home's status log, and `--key` crosses to the pane.
- `bin/fm-crew-state.sh <task-id>` combines this home's status fold with the run-step and busy readings `crew-state` reports from the host; [its header](../bin/fm-crew-state.sh) owns the composition.
- A sandbox task's recorded window, `remote:<task-id>`, names no endpoint here, so peek and steering refuse it.

Turn-ended notifications stay on the host, so mirrored status lines remain the supervision signal until stale-pane supervision lands.

## Host-side task control

A sandbox host runs [`bin/fm-remote-task-control.sh`](../bin/fm-remote-task-control.sh) for its one task, reached through `bin/fm-on.sh <task-id> fm-remote-task-control.sh <verb> <task-id>`; its header owns every verb, the provisioning manifest, and the output blocks.

- `provision` builds the one-task home from a manifest on stdin: it clones the project from its origin, writes the brief, launch configuration, and credentials, and marks the home with `.fm-task-home` last.
  The same manifest again changes nothing, another task's home or a different manifest is refused, and a failed attempt removes what it created.
- `launch`, `control`, `crew-state`, and `retire` run the host's own spawn, control plane, current-state read, and teardown, so the landed-work test that guards a local cleanup guards a sandbox's too.
  Host-side retirement supports ships only; scouts are refused because their completion gate belongs to the supervising home.
- `state`, `observe`, `capture`, `send`, `key`, `head`, and `brief-update` read the endpoint, steer it through its durable inbox keyed by the primary's request id, and replace its brief.
- The task home's backlog is manual, because the task's backlog item lives in the supervising home.

Credentials are written only on the host: Pi entries into the account's `~/.pi/agent/auth.json` and the GitHub token into the account's gh credential store for github.com, each mode 0600.
Provision requires gh when a GitHub token is supplied, passes the token to `gh auth login --insecure-storage --with-token` on stdin, and restores the previous gh configuration if provisioning fails.
Storing the repository token in gh deliberately replaces passing `GH_TOKEN`: gh and git authenticate with the stored token exactly as they would with `GH_TOKEN`.
Git uses the absolute `gh auth git-credential` helper scoped to HTTPS github.com for the clone and its worktrees; the token never enters command arguments or the launch environment.

Use the remote-rendered brief described under [placement](#placement); [the brief header](../bin/fm-brief.sh) owns its path substitution contract.
A sandbox brief must be self-contained, because the sandbox cannot read the supervising home's reports.

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
bin/fm-test-run.sh tests/fm-remote-task-control.test.sh
bin/fm-test-run.sh tests/fm-remote-task-spawn.test.sh
bin/fm-test-run.sh tests/fm-remote-task-lifecycle-e2e.test.sh
```

The adapter suite drives every verb against a fake provider, including the refusal paths, the home-tag filtering, the capacity distinction, and argv-only invocation.
The route suite pins the task record contract and the consumer behavior described under [task routes](#task-routes), checking that routed verbs cross only the transport to the task's own host and that unsupported operations never reach the transport or a local backend, all leaving the task record unchanged.
The task control suite drives every host-side verb against a fixture home with fake tmux, including provision idempotence and rollback, foreign-home refusal, credential file modes, and a search of every output and record for planted credential values.
The placement suite drives `bin/fm-spawn.sh --placement sandbox` against a fake provider and a fake SSH transport that runs the real host-side control plane with fake tmux, covering the refusal matrix, the record fields, destroy before launch, the hold once launch may have started, SSH exit 255, the mirror armed at publish, and a search of every output, record, log, and argument for planted credential values.
The lifecycle suite drives a placed ship and scout on the same harness through the real process-event runner: a mirrored decision, a steer that answers it with `--resolve-key`, peek, the composed current state, and a scout report that is local before its terminal line lands.
The status mirror's route kind, peek, steering, and the current-state composition are also covered by `tests/fm-remote-reply.test.sh`, `tests/fm-peek-remote.test.sh`, `tests/fm-send-remote-delivery.test.sh`, and `tests/fm-crew-state.test.sh`.
Brief rendering for a sandbox home and the spawn refusal are covered by `tests/fm-brief.test.sh` and `tests/fm-task-delivery.test.sh`.
Task route resolution and the task readiness profile are covered by `tests/fm-on.test.sh` and `tests/fm-remote-doctor.test.sh`, part of the [remote second-mate suite](remote-secondmates.md#portable-tests).
A real-cluster smoke run lands with the final stage of the plan.
