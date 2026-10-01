# Remote task sandboxes

This page covers how to configure and operate the provider that runs Firstmate task sandboxes: short-lived, disposable virtual machines that host one task's working home.
It is for operators who wire a sandbox provider into a firstmate home and for anyone checking the adapter's safety behavior.

A sandbox task is an ordinary ship or scout whose endpoint and files live in a one-task Firstmate home on a disposable VM, driven by the primary through the same remote transport that drives remote second mates.
The primary stays the only supervisor; the VM provides an isolated worker environment on provider infrastructure, and the sandbox is destroyed when the task is done.

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
  Destroying a sandbox refuses when the labels disagree, so one home can never destroy another home's sandbox, and an already-absent sandbox is success, so cleanup is idempotent.
- Nothing destroys unlanded work.
  Destroying a sandbox is cleanup, and the landed-work gate that stands in front of it ships with the teardown integration.

## Network profiles

- The `default` profile allows DNS and HTTPS egress, blocks LAN and RFC1918 destinations, and allows inbound SSH from the primary only.
- The `open` profile lifts those restrictions and is used only by explicit per-task instruction, never by analogy or as a default.
- `fm-sandbox.sh policy <name>` prints a sandbox's effective rules for visibility.

## Credentials

Sandbox credentials are Pi API-key providers plus per-repository GitHub tokens only.
Host keys are pinned by the provider, not trusted on first use, and the SSH configuration the sandbox aliases live in is provider-managed.

## Configure a provider

`config/sandbox-provider` is local and gitignored, selected by `FM_HOME` like every other config file; [the configuration reference](configuration.md#sandbox-provider-configsandbox-provider) owns its exact format.
The reference layout:

```sh
/usr/local/bin/pve-sandbox
default_profile=default
ttl=4h
ssh_include=/home/operator/.ssh/config.d/firstmate-sandboxes
```

The first line is the provider command's absolute path; the three keys are all required.
The provider command must satisfy the invocation, output, and exit contracts that [the `fm-sandbox.sh` header](../bin/fm-sandbox.sh) owns.
In short:

- It receives argv only, one verb per call, and its `exec` argv is relayed verbatim.
- Its stdout is `key=value` lines from a closed key set, one pair per line, with per-verb required keys; anything else is refused and nothing from that call is trusted.
- It labels every sandbox `fm_task=<task-id>` and `fm_home=<home tag>`, filters `list` by the home tag, and refuses `destroy` when the labels disagree.
- It exits `75` only to report capacity, which surfaces as a blocker.

## Operate

`bin/fm-sandbox.sh` is the single entry point, and its `--help` prints the verb list.

- `create <task-id>` asks the provider for a sandbox and prints its `name`, `vmid`, `node`, `ssh_alias`, `user`, `profile`, `ttl_expires`, and `hostkey`.
- `status <name>` prints the sandbox's `state` (`running`, `stopped`, or `absent`) and its labels.
- `list` prints this home's sandboxes only, each record starting with its `name=`.
- `extend <name> --ttl <duration>` renews the TTL; `hold <name>` and `release <name>` manage the reap-blocking hold label.
- `policy <name>` prints the effective firewall rules.
- `exec <name> -- <argv>` runs one bootstrap command inside the sandbox; its argv is never a shell string.
- `snapshot <name> <label>` and `rollback <name> <label>` are an optional safety net the provider may implement.
- `destroy <name> --expect-task <task-id>` removes the sandbox, refusing when the labels disagree and treating an absent sandbox as success.

## Capacity and failures

A provider that cannot take another sandbox exits `75`, and the adapter surfaces that as a capacity blocker (exit 4).
Treat it like any other infrastructure blocker: surface it, free sandboxes, or wait; never fall back to local placement.

Every other refusal exits 3 and names the concrete problem: no configuration, a malformed configuration, a missing or non-executable provider, a provider failure with its stderr included, or provider output that violates the contract.
Usage errors, such as a malformed duration or a name containing whitespace, exit 2 and change nothing.

## Verification

```sh
bin/fm-test-run.sh tests/fm-sandbox.test.sh
```

The suite drives every verb against a fake provider, including the refusal paths, the home-tag filtering, the capacity distinction, and argv-only invocation.
A real-cluster smoke run lands with the final stage of the plan.
