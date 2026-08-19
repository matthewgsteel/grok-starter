# Pi-native Proton Pass MCP

## Purpose

This deployment moves the Proton Pass MCP runtime from the legacy Windows/Gretna scheduled-task gateway to `sentinel-pi`, while preserving the existing ChatGPT tool contract and using Proton's signed `pass-cli` as the vault engine.

## Runtime

- Host: `sentinel-pi`
- Service user: `mgs`
- Pass CLI: `/home/mgs/.local/bin/pass-cli`
- Pass session helper: `/home/mgs/openclaw-sentinel42/scripts/proton-pass-bridge.mjs`
- MCP SDK / supergateway dependencies: reused from `/home/mgs/mcp-services/proton-drive/node_modules`
- MCP HTTP listener: `127.0.0.1:8012/mcp`
- Compatibility rewrite proxy: `127.0.0.1:8013/<any-existing-connector-path>` → `127.0.0.1:8012/mcp`
- Public hostname to preserve: `protonpass.matthewgsteel.com`

The compatibility proxy allows the existing ChatGPT connector URL/path to remain unchanged even if its historical path was randomized or is no longer present in surviving Windows configuration.

## Systemd

- `mgs-proton-pass-mcp.service`
- `mgs-proton-pass-proxy.service`

Both are enabled at boot and use `Restart=always`.

## Tool contract

The Pi server registers the existing Proton Pass operations:

- `get_connection_status`
- `get_runtime_status`
- `list_vaults`
- `list_items`
- `get_item`
- `create_login`
- `update_item_fields`
- `move_item`
- `trash_item`
- `restore_item`
- `delete_item_permanently`
- `create_vault`
- `rename_vault`
- `delete_vault_permanently`

Permanent deletion retains explicit confirmation checks. Item deletion also verifies that the target item is in Proton Pass trash before invoking the signed CLI delete operation.

## Credential behavior

The MCP never embeds Proton credentials in source code or systemd units. The existing Pi helper loads the Proton Pass PAT from the private OpenClaw project environment, maintains the filesystem-backed agent session under `/tmp/pass-agent-sentinel42`, and records operation reasons through `PROTON_PASS_AGENT_REASON`.

`create_login` sends the login JSON template, including the password, to `pass-cli` over stdin via `--from-template -`; the password is not placed in the process command line.

## Leading-hyphen identifiers

Pass share IDs and item IDs can begin with `-`. The gateway therefore uses equals-form arguments for identifiers where ambiguity matters, e.g.:

- `--share-id=<id>`
- `--item-id=<id>`

This preserves the August 12 permanent-delete fix.

## Deployment

Run on the Pi as `mgs`:

```bash
curl -fsSL https://raw.githubusercontent.com/matthewgsteel/grok-starter/main/mgs/proton-pass-pi/deploy.sh | bash
```

No package installation is required. The deployment reuses the MCP SDK and `supergateway` already installed for the Pi Proton Drive MCP.

## Verification

After deployment:

```bash
systemctl is-active mgs-proton-pass-mcp.service
systemctl is-active mgs-proton-pass-proxy.service
ss -lntp | grep -E ':(8012|8013)\b'
```

A real MCP `initialize` request should then be sent both to `127.0.0.1:8012/mcp` and through an arbitrary path on `127.0.0.1:8013` to prove the compatibility rewrite.

The final production verification is the ChatGPT `Proton_Pass_(Verified)` connector successfully returning `get_runtime_status`, `get_connection_status`, and `list_vaults` after `protonpass.matthewgsteel.com` is routed to the Pi proxy.

## Rollback

Before changing Cloudflare routing, preserve the current hostname/tunnel route. Rollback consists of restoring that route and stopping/disabling the two Pi services. The legacy Windows gateway should not be restarted merely as a rollback experiment unless its known-good task/configuration has been positively identified.
