# MAIN-GRETNA-PC recovery reference

## Authority and identities

Host: `MAIN-GRETNA-PC`

Primary host-control MCP: `MGS Browser Controller`

MCP listener: TCP `8765`

Automation Brave CDP: TCP `9222`

Automation Brave profile: `C:\ProgramData\MGS-MCP\Brave-Automation-Profile`

Primary MCP task: `MGS MCP Server`

Watchdog task: `MGS MCP Watchdog`

Automation browser task: `MGS Browser Controller Brave Launcher`

Startup supervisor: `MGS Proton Startup Supervisor`

Reboot guard: `MGS Unattended Reboot Guard`

Normal reboot authorization marker: `C:\ProgramData\MGS-MCP\proton-startup-supervisor\ALLOW-SYSTEM-REBOOT.once`

Temporary user-away hard block: `C:\ProgramData\MGS-MCP\proton-startup-supervisor\NO-REBOOT-WHILE-USER-AWAY.lock`

Primary interactive user: `MAIN-GRETNA-PC\mgste`

Microsoft account attached to that profile: `mgsteel@live.com`

`mgste` SID: `S-1-5-21-3715195755-1537707504-3649533163-1001`

Separate local account: `MAIN-GRETNA-PC\sentinelcore`

`sentinelcore` SID: `S-1-5-21-3715195755-1537707504-3649533163-1006`

Do not confuse these accounts. Their profiles and intended roles are different.

## What is actually proven

The SYSTEM control plane survives Windows reboot independently of an interactive login. MGS MCP, automation Brave/CDP, Tailscale, and SYSTEM boot/recovery tasks have returned after real reboots.

ARSO is enabled on this standalone PC, but ARSO is not sufficient proof of an unattended usable desktop. During the 2026-08-11 `/g` test, Winlogon recorded successful authentication at about 11:35:49 and the physical display then showed the Windows lock screen. Treat that as ARSO functioning for automatic authentication while leaving a lock barrier, not as full interactive recovery.

## 2026-08-11 failed proof-test diagnosis

A later unexpected reboot occurred at 11:49:50 after the user had already prohibited further restarts. The user did not newly authorize that reboot. Windows System Event 1074 showed:

- initiating process: `C:\Windows\system32\shutdown.exe`
- actor: `NT AUTHORITY\SYSTEM`
- comment: `MGS sentinelcore AutoAdminLogon proof test`

The subsequent boot time was 11:50:15.

At 11:50:30, Winlogon attempted interactive authentication and returned result `1326`. Security Event 4625 identified the failed account as:

- account: `sentinelcore`
- domain: `MAIN-GRETNA-PC`
- logon type: `2` (interactive)
- status: `0xC000006D`
- substatus: `0xC000006A` (bad password)

This proves the stale proof test targeted the wrong account for the user's intended desktop and supplied a credential Windows rejected.

The one-shot proof action self-cleaned or otherwise disappeared after firing. Later inspection found no live delayed restart process, no Run/RunOnce restart action, and no registered task action containing the proof/restart command.

## Current AutoAdminLogon state after diagnosis

The nonsecret Winlogon values were blank after the failed proof:

- `AutoAdminLogon`
- `DefaultUserName`
- `DefaultDomainName`
- `AutoLogonCount`
- `ForceAutoLogon`

Therefore permanent AutoAdminLogon for `mgste` has not yet been established.

There is no applied computer GPO, no legal logon banner, no device-lock policy, and the machine is not domain-, Entra-, or workplace-joined. These are not the current blockers.

Microsoft Sysinternals Autologon remains the preferred mechanism because it stores the password as an LSA secret. Validate the `mgste` credential before calling Autologon because the Sysinternals utility itself does not validate submitted credentials.

## Credential/control-plane boundary

The Microsoft account password is stored in Proton Pass under the dedicated login item `MAIN-GRETNA-PC Microsoft Account`.

The Proton Pass bridge and several other user-bound gateways depend on a live `mgste` interactive session. When Windows is sitting at `LogonUI`, those user-bound services may be unavailable even though the SYSTEM Browser Controller still works.

ChatGPT's current tool boundary has blocked combining Proton Pass secret retrieval with a PowerShell/Autologon process call. Do not bypass or obfuscate that boundary. Use an exposed protected-secret path when available or stage the correct local operation for a future valid `mgste` login.

## User-away restart freeze

When the user explicitly prohibits restarts while away:

- do not reboot or restart the PC
- do not restart services, MCP connectors, tasks, or tunnels
- do not create delayed proof-reboot actions
- clear stale one-time reboot authorization markers if present
- keep `NO-REBOOT-WHILE-USER-AWAY.lock` active
- inspect for queued power actions before any later restart test

A temporary hard-block branch was added to the event-triggered reboot guard so a stale SYSTEM `shutdown.exe` attempt can be aborted while the user-away lock exists.

## Availability hardening

Sleep and hibernation timeouts are disabled on AC and battery while this host serves as an always-available remote node. Lid-close action is configured to do nothing.

Critical host-lifecycle tasks should remain battery-safe, including:

- `MGS MCP Server`
- `MGS MCP Watchdog`
- `MGS Browser Controller Brave Launcher`
- `MGS Proton Startup Supervisor`
- `MGS MCP Restart Helper`
- `MGS Browser Controller Restart Helper 0.3.2`
- `MGS Unattended Reboot Guard`

Keep `DisallowStartIfOnBatteries=false` and `StopIfGoingOnBatteries=false` for these tasks.

## Diagnostic logs

The following logs were enabled during the 2026-08-11 investigation and should remain enabled for future proof:

- `Microsoft-Windows-LSA/Operational`
- `Microsoft-Windows-TaskScheduler/Operational`
- `Microsoft-Windows-Winlogon/Operational` was already available

Use Security Events 4624/4625 and Winlogon authentication events to distinguish successful authentication, bad credentials, lock barriers, and the wrong target account.

## Future completion test

Do not perform another reboot until the user explicitly permits it.

Before a future test:

1. confirm the user-away hard block has been intentionally removed
2. confirm no stale delayed restart actions exist
3. configure Sysinternals AutoAdminLogon for validated `mgste` credentials, not `sentinelcore`
4. verify the nonsecret AutoAdminLogon identity state
5. verify SYSTEM recovery plane health

After a permitted reboot, require all of the following before calling success:

- changed `LastBootUpTime`
- Browser Controller/MCP returned
- Tailscale/Cloudflare and critical SYSTEM tasks healthy
- `explorer.exe` running as `MAIN-GRETNA-PC\mgste`
- required `mgste` user workers running
- no `LogonUI.exe` or `LockApp.exe` barrier

ARSO authentication alone is not a passing result.
