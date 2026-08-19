# MGS Application Plane - Current Canonical Status

Date: 2026-08-19
Owner lane: `CHATGPT=APPLICATION_MIGRATION`
Infrastructure lane: `CODEX=INFRASTRUCTURE_SECURITY`

## Controlling architecture

- `sentinel-pi` is the canonical always-on hub.
- `HOME-BASE-LAPTOP` and `MAIN-GRETNA-PC` are Windows execution edges.
- The application lane does not mutate Cloudflare, host firewall, controller watchdog/startup, system-wide security packages, or infrastructure systemd while Codex owns the infrastructure lane.
- One writer per subsystem.

## Current application status

### Proton Calendar

**HEALTHY at application layer.** Calendar enumeration succeeds through the current connector.

### Personal Proton Mail

**HEALTHY on latest successful application probe.** SMTP and IMAP authenticate through the Pi Bridge.

### Law-firm Proton Mail

**SERVICE-SPECIFIC FAILURE.** Connector is reachable, but the firm Bridge configuration returns invalid username/password. Do not misclassify this as WAN or Cloudflare failure.

### Proton Drive

**SERVICE-SPECIFIC AUTH STATE.** The official Pi CLI is installed but currently logged out. The official browser authentication flow can be initiated. One attempted background login disappeared when that connector instance recycled, so authentication is not yet restored.

### Proton Pass

**MIGRATION IN PROGRESS.** The signed Pi `pass-cli` / PAT backend was healed. Pi-native MCP source is staged at `/home/mgs/mcp-services/proton-pass-pi/server.mjs` and passes `node --check`. Source of record is `mgs/proton-pass-pi/server.mjs` in this repository. Public routing and persistent infrastructure exposure remain the infrastructure lane. Runtime MCP client handshake still requires a clean verification.

### ICS FACTS

**SOURCE RECOVERED / MIGRATION TARGET.** Proven v0.2.1 production source exists on the Pi under `/home/mgs/mcp-services/ICS FACTS MCP`. Historical release documentation confirms production authentication, Julie/Dominic scope lock, section sweeps, external health, protected tool enumeration, and ChatGPT invocation. The Pi migration needs browser-edge and credential-backend wiring under the new Pi-hub / Windows-edge architecture. Do not rebuild from memory.

### Dominican Class of 2031 GroupMe

**SOURCE RECOVERED / PORT REQUIRED.** Existing v1.0.1 source is preserved at `/home/mgs/mcp-services/dominican-groupme.stage`. It is strongly Windows-specific: `C:\ProgramData`, Windows DPAPI, Windows Proton Pass CLI paths, and a Windows/Tailnet setup origin are embedded. It also requires `faye`, which is not currently installed elsewhere on the Pi. Do not treat folder copy as migration. Port deliberately after package-mutation coordination.

### Dominican PlusPortals

**RUNTIME RECOVERY REQUIRED.** No Pi application source directory was found in `/home/mgs/mcp-services`. The laptop retains `C:\ProgramData\MGS-Laptop-MCP\app\plusportals-connector-tools.js`, including the secure ChatGPT token-entry helper, but the referenced `C:\ProgramData\DominicanPlusPortalsMCPBridge` runtime is absent. Recover the actual runtime/source from preserved Windows/Git/Proton artifacts before rebuilding from memory.

## Documentation and Proton Drive rule

Every new or updated MCP must have current documentation mirrored to the relevant Proton Drive `Code/mcp` project folder. The historical `C:\Users\MGS\Proton Drive` namespace is currently read-only. `ProtonDrive_CLEAN` is writable but does not currently contain the canonical MCP hierarchy, so do not create a contradictory second canonical tree. Queue source-controlled docs for official Proton Drive CLI mirroring once Drive authentication is restored.

## Active next actions

1. Verify Pi-native Proton Pass MCP runtime handshake and hand persistent exposure to infrastructure lane.
2. Restore official Proton Drive CLI authentication without blocking other work on human interaction.
3. Recover law-firm Proton Bridge credentials/session without disturbing personal Proton Mail.
4. Wire ICS FACTS to Pi with Windows browser edge and Pi credential backend.
5. Recover PlusPortals runtime/source.
6. Port GroupMe from Windows-specific storage/DPAPI to Pi-native storage and signed Pass integration; coordinate any package install through the mutation mutex.
