# MGS Proton Pass MCP — Pi-Native Migration

**Date:** 2026-08-19
**Target host:** `sentinel-pi`
**Public hostname preserved:** `protonpass.matthewgsteel.com`

## Objective

Move the production Proton Pass MCP off the historical Windows/Gretna scheduled-task gateway and onto the Raspberry Pi control plane, without changing the ChatGPT-facing tool names or weakening the Proton Pass audit/deletion safeguards.

## Existing state discovered

- The signed Proton Pass CLI is installed at `/home/mgs/.local/bin/pass-cli`.
- The Pi already contains a tested Pass integration helper at `/home/mgs/openclaw-sentinel42/scripts/proton-pass-bridge.mjs`.
- `scripts/pass-heal.sh` successfully creates a fresh PAT-backed session and returns `HEAL_OK`.
- The helper loads the private PAT from the existing project environment, uses the filesystem key provider, and maintains `/tmp/pass-agent-sentinel42`.
- Both `Personal` and `Sentinel42's ProtonPass Vault` are visible through the signed CLI.
- The legacy production gateway was a Windows scheduled task named `Proton MCP Pass Gateway` with source under `C:\Users\mgste\AppData\Local\Programs\ProtonPassMCPBridge\server.mjs`.
- `protonpass.matthewgsteel.com` still resolves through Cloudflare, but the legacy backend is no longer reachable and the public endpoint returns a Cloudflare origin/tunnel error.

## Pi runtime design

### MCP service

`mgs-proton-pass-mcp.service`

- User: `mgs`
- MCP process: Node + MCP SDK 1.30.0
- HTTP transport: existing `supergateway`
- Listener: `127.0.0.1:8012`
- Streamable HTTP path: `/mcp`
- Restart: always

### Compatibility proxy

`mgs-proton-pass-proxy.service`

- Listener: `127.0.0.1:8013`
- Accepts any historical connector path.
- Rewrites the request to `127.0.0.1:8012/mcp`.
- This allows the existing ChatGPT connector URL/path to remain unchanged even if its old randomized path is no longer recoverable from the Windows gateway.

## ChatGPT tool contract preserved

1. `get_connection_status`
2. `get_runtime_status`
3. `list_vaults`
4. `list_items`
5. `get_item`
6. `create_login`
7. `update_item_fields`
8. `move_item`
9. `trash_item`
10. `restore_item`
11. `delete_item_permanently`
12. `create_vault`
13. `rename_vault`
14. `delete_vault_permanently`

## Safeguards preserved

- `get_item` requires an audit reason when secret content is read.
- Mutating operations pass the requested reason to `PROTON_PASS_AGENT_REASON`.
- New login passwords are supplied to `pass-cli` through a JSON template on stdin rather than the process argument list.
- `delete_item_permanently` requires `confirmItemId` to exactly equal `itemId` and verifies that the target item is already in Proton Pass trash.
- `delete_vault_permanently` requires an exact repeated vault name.
- Leading-hyphen identifiers are passed using equals-form options where necessary (`--share-id=<id>`, `--item-id=<id>`), preserving the August 12 fix.

## Dependency policy

No new package installation is required. The service reuses:

- MCP SDK from `/home/mgs/mcp-services/proton-drive/node_modules`
- `supergateway` from the same dependency tree
- existing signed `pass-cli`
- existing PAT/session-healing helper

## Source files

- `server.mjs`
- `proxy.mjs`
- `mgs-proton-pass-mcp.service`
- `mgs-proton-pass-proxy.service`
- `deploy.sh`
- `README.md`

All source is stored under `mgs/proton-pass-pi/` in `matthewgsteel/grok-starter`.

## Verification required before production cutover

1. Both systemd services active and enabled.
2. Ports 8012 and 8013 bound only to loopback.
3. Real MCP `initialize` succeeds directly on 8012.
4. Real MCP `initialize` succeeds through an arbitrary path on 8013.
5. `get_connection_status` reports connected after automatic session healing.
6. Cloudflare public hostname routes to the Pi proxy.
7. ChatGPT `Proton_Pass_(Verified)` successfully calls `get_runtime_status`, `get_connection_status`, and `list_vaults`.
8. Existing destructive-action confirmation semantics remain intact.

## Rollback

Preserve the previous Cloudflare DNS/tunnel configuration before cutover. If the Pi gateway fails verification, restore the previous route and stop/disable the two Pi services. Do not restart the legacy Windows Proton Pass gateway merely as an experiment unless its exact known-good configuration is positively identified.

## Documentation mirror requirement

After production verification, mirror this record and the final deployment receipt into the relevant Proton Drive MCP project folder. The Proton Drive copy is the human-readable durable project record; source-control copies remain the implementation record.
