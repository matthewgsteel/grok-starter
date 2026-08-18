---
name: mgs-windows-host-operations
description: Operate, recover, restart, diagnose, and harden Matthew G. Steel's Windows hosts through the private MGS Browser Controller. Use for MAIN-GRETNA-PC or HOME-BASE-LAPTO/HOME-BASE-LAPTOP host lifecycle work, remote-control recovery, startup/login repair, SYSTEM-plane availability, Browser Controller/Brave/Tailscale/Cloudflare recovery, or any consequential Windows host action where execution host and target host must be distinguished. Coordinate with Sentinel42/sentinel-pi for cross-host continuity, but do not treat the Pi as a Windows host.
---

# MGS Windows Host Operations

Treat host identity as a first-class safety boundary. Never infer the target from a stale tool description.

## Host resolution contract

Canonical identities:

- `home-base-laptop`: aliases `HOME-BASE-LAPTO`, `HOME-BASE-LAPTOP`.
- `main-gretna-pc`: alias `MAIN-GRETNA-PC`.
- `sentinel-pi`: aliases `sentinel-pi`, `Sentinel42 (Pi)`. Its LAN address is dynamic; resolve it at execution time. Tailscale identity may be used when healthy.

Before a consequential Windows action, determine both:

1. **execution host** — where the tool call actually runs;
2. **target host** — the machine the user intends to affect.

For PowerShell, verify execution identity with `$env:COMPUTERNAME` or an equivalent low-cost probe when there is any ambiguity. Do not trust stale connector descriptions.

Current durable routing pattern:

- `run_powershell` may execute on `home-base-laptop` even when historical text says Gretna.
- Use the durable laptop bridge / `run_gretna_powershell` path when execution must occur on `MAIN-GRETNA-PC`.
- Do not call a semantic restart/shutdown tool merely because it says "host" until the resolved target is proven.

Read `references/main-gretna-pc.md` before Gretna restart/login work.

## Control model

Maintain separate recovery planes.

### Windows SYSTEM plane

Keep remote control reachable without an interactive login where practical: MGS MCP, watchdog, automation Brave/CDP, Tailscale/Cloudflare transport, boot tasks, and recovery interlocks.

### Windows interactive plane

Treat the user's normal desktop session separately. A healthy SYSTEM MCP does not prove Explorer, user-session workers, or the visible desktop recovered.

For Gretna, the intended interactive identity is `MAIN-GRETNA-PC\mgste`; never substitute the historical `sentinelcore` account unless the user explicitly redesigns the machine.

### Cross-host continuity plane

Use `sentinel-pi` as the preferred lightweight always-on worker after it is healthy and not owned by another active maintenance thread. Use the laptop primarily as Windows control/failover, not as the permanent bulk worker when the Pi can safely carry routine jobs.

If another conversation/process is actively modifying the Pi, do not concurrently edit Pi runtime files. Read status/receipts only, or wait until that maintenance wave ends.

## Consequential-action gate

Before reboot, shutdown, service replacement, task replacement, large installation, destructive file work, or registry mutation:

1. resolve execution host and target host;
2. prove they are the intended identities;
3. check active no-restart/user-away instructions and host-specific interlocks;
4. preserve rollback state when the action changes control-plane availability;
5. verify the result on the target, not merely the caller.

Never claim a remote reboot because a command returned success. Require changed boot time plus return of the expected control plane.

## Restart prohibition

If the user prohibits restart/reboot while away, treat it as a hard freeze for the named host. Do not schedule delayed power actions or create one-shot proof reboots. Inspect for stale queued actions if needed to honor the freeze.

Read-only inspection, evidence preservation, and non-disruptive staging remain allowed unless the user narrows them too.

## ARSO and interactive login

Do not use Windows Automatic Restart Sign-On as proof of an unattended usable desktop. On Gretna, ARSO has authenticated and still landed behind a lock barrier.

For a future no-touch Gretna console, Sysinternals Autologon for the actual `mgste` identity remains the preferred design when the credential can be provided through a protected path. Never move a password through chat-visible output, command history, logs, or documentation merely to configure it.

## Recovery and availability standard

Favor boot triggers, SYSTEM service accounts, `StartWhenAvailable`, restart-on-failure, battery-safe settings, and health checks for the Windows control plane.

When repairing a host after an incident:

- preserve evidence before broad repair;
- prefer smallest responsible layer;
- distinguish "registration exists" from "payload exists and is healthy";
- do not reinstall an application blindly when its current data/config tree is an unresolved recovery source.

## Documentation and checkpoints

For material host/control changes:

- preserve working state first;
- make reversible edits;
- validate syntax/config before restart;
- record execution host, target host, result, rollback point, and hashes/receipts where useful;
- update the current infrastructure/recovery Markdown and the relevant Proton Drive documentation folder when the write path is available.

Historical current-state documents remain historical. Do not let them override a newer controlling recovery/continuity record.

## Completion signals

For SYSTEM recovery, require the expected MCP/control transport and critical boot tasks on the target host.

For full Gretna desktop recovery, additionally require:

- `explorer.exe` running as the intended `mgste` user;
- required user-session workers;
- no `LogonUI.exe`/`LockApp.exe` barrier;
- changed boot timestamp for any claimed reboot test.

State precisely what is proven and what remains inferred.
