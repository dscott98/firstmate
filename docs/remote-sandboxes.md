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
| Handle capacity or failures | [Capacity and failures](#capacity-and-failures) |
| Run the tests | [Verification](#verification) |

## Current status

The sandbox placement plan ships in stages.
What is wired today is the provider adapter `bin/fm-sandbox.sh` and its configuration: an operator can configure a provider and drive every lifecycle verb by hand.
Spawn does not yet accept sandbox placement, so no task is placed in a sandbox automatically.
The placement flag, task control, status mirroring, teardown, and supervision integration land in later stages of the plan.

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
```

The suite drives every verb against a fake provider, including the refusal paths, the home-tag filtering, the capacity distinction, and argv-only invocation.
A real-cluster smoke run lands with the final stage of the plan.
