import { spawn } from 'node:child_process';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import {
  loadProjectDotEnv,
  ensurePassSession,
  runPassCli,
  passVaultList,
  passCliBin,
  passSessionDir
} from '/home/mgs/openclaw-sentinel42/scripts/proton-pass-bridge.mjs';

loadProjectDotEnv();
process.env.PROTON_PASS_KEY_PROVIDER ||= 'fs';
process.env.PROTON_PASS_SESSION_DIR ||= '/tmp/pass-agent-sentinel42';

const server = new McpServer({ name: 'proton-pass-verified', version: '3.0.0-pi' });

const result = (value) => ({
  content: [{ type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value, null, 2) }]
});

const parse = (text) => {
  try { return JSON.parse(String(text || '')); }
  catch { return String(text || '').trim(); }
};

const fail = (message) => { throw new Error(message); };

async function requireSession() {
  const status = await ensurePassSession();
  if (!status?.ok) fail(`Proton Pass session unavailable: ${status?.reason || 'unknown'}`);
  return status;
}

function selectorArgs(args = {}, { includeItem = true } = {}) {
  const out = [];
  if (args.shareId) out.push(`--share-id=${args.shareId}`);
  else if (args.vaultName) out.push('--vault-name', args.vaultName);

  if (includeItem) {
    if (args.itemId) out.push(`--item-id=${args.itemId}`);
    else if (args.itemTitle) out.push('--item-title', args.itemTitle);
  }
  return out;
}

async function run(args, reason = '') {
  await requireSession();
  const response = await runPassCli(args, { needsReason: Boolean(reason), reason });
  return parse(response.stdout);
}

async function vaultDocument() {
  await requireSession();
  const response = await passVaultList();
  const parsed = parse(response.stdout);
  return parsed && typeof parsed === 'object' ? parsed : { vaults: [], raw: parsed };
}

async function resolveVault({ shareId, vaultName } = {}) {
  const doc = await vaultDocument();
  const vaults = Array.isArray(doc.vaults) ? doc.vaults : [];
  if (shareId) return vaults.find((v) => v.share_id === shareId) || fail('Vault share ID not found');
  if (vaultName) return vaults.find((v) => v.name === vaultName) || fail(`Vault not found: ${vaultName}`);
  fail('vaultName or shareId is required');
}

async function spawnWithInput(args, input, reason) {
  await requireSession();
  loadProjectDotEnv();
  return await new Promise((resolve, reject) => {
    const env = {
      ...process.env,
      PROTON_PASS_SESSION_DIR: passSessionDir(),
      PROTON_PASS_KEY_PROVIDER: 'fs',
      PROTON_PASS_AGENT_REASON: reason
    };
    const child = spawn(passCliBin(), args, { env, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (data) => { stdout += data; });
    child.stderr.on('data', (data) => { stderr += data; });
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) resolve(parse(stdout));
      else reject(new Error((stderr || stdout || `pass-cli exit ${code}`).trim()));
    });
    child.stdin.end(input);
  });
}

const itemSelectorSchema = {
  shareId: z.string().min(1).max(512).optional(),
  vaultName: z.string().min(1).max(512).optional(),
  itemId: z.string().min(1).max(512).optional(),
  itemTitle: z.string().min(1).max(512).optional()
};

server.registerTool('get_connection_status', {
  description: 'Check the Proton Pass CLI session and return structured degraded status instead of throwing a raw MCP error.',
  annotations: { readOnlyHint: true }
}, async () => {
  try {
    const status = await ensurePassSession();
    return result({
      ok: Boolean(status?.ok),
      status: status?.ok ? 'connected' : 'degraded',
      reason: status?.reason || '',
      runtime: 'pi-native',
      host: 'sentinel-pi'
    });
  } catch (error) {
    return result({ ok: false, status: 'degraded', reason: String(error?.message || error) });
  }
});

server.registerTool('get_runtime_status', {
  description: 'Return MCP runtime configuration without reading any vault or item.',
  annotations: { readOnlyHint: true }
}, async () => {
  let version = '';
  try { version = String((await runPassCli(['--version'])).stdout || '').trim(); } catch {}
  return result({
    ok: true,
    runtime: 'pi-native',
    host: 'sentinel-pi',
    version,
    cli: passCliBin(),
    sessionDir: passSessionDir(),
    keyProvider: process.env.PROTON_PASS_KEY_PROVIDER || 'fs'
  });
});

server.registerTool('list_vaults', {
  description: 'List Proton Pass vault metadata. Does not read item contents.',
  annotations: { readOnlyHint: true }
}, async () => result(await vaultDocument()));

server.registerTool('list_items', {
  description: 'List item metadata in all vaults without secret fields. Use get_item only when the user explicitly asks for secret content.',
  annotations: { readOnlyHint: true }
}, async () => {
  const doc = await vaultDocument();
  const output = [];
  for (const vault of (doc.vaults || [])) {
    const response = await runPassCli([
      'item', 'list', `--share-id=${vault.share_id}`, '--filter-state', 'active', '--output', 'json'
    ]);
    output.push({ vault: { name: vault.name, share_id: vault.share_id }, items: parse(response.stdout) });
  }
  return result({ vaults: output });
});

server.registerTool('get_item', {
  description: 'Read one Proton Pass item or one selected field. Secret values may be returned, so use only when the user explicitly requests them. The reason is written to Proton agent audit history.',
  inputSchema: {
    ...itemSelectorSchema,
    field: z.string().min(1).max(512).optional(),
    reason: z.string().min(1).max(300)
  },
  annotations: { readOnlyHint: true }
}, async (args) => {
  if (!args.itemId && !args.itemTitle) fail('itemId or itemTitle is required');
  const cliArgs = ['item', 'view', ...selectorArgs(args), '--output', 'json'];
  if (args.field) cliArgs.push('--field', args.field);
  return result(await run(cliArgs, args.reason));
});

server.registerTool('create_login', {
  description: 'Create a Proton Pass login item. The password is sent to pass-cli over stdin, not placed in the shell command line.',
  inputSchema: {
    shareId: z.string().min(1).max(512).optional(),
    vaultName: z.string().min(1).max(512).optional(),
    title: z.string().min(1).max(512),
    username: z.string().max(4096).optional(),
    email: z.string().max(4096).optional(),
    password: z.string().max(16384),
    urls: z.array(z.string().max(4096)).max(50).optional(),
    totpUri: z.string().max(16384).optional(),
    reason: z.string().min(1).max(300)
  }
}, async (args) => {
  if (!args.shareId && !args.vaultName) fail('shareId or vaultName is required');
  const template = {
    title: args.title,
    username: args.username ?? null,
    email: args.email ?? null,
    password: args.password,
    totp_uri: args.totpUri ?? null,
    urls: args.urls || []
  };
  return result(await spawnWithInput(
    ['item', 'create', 'login', '--from-template', '-', ...selectorArgs(args, { includeItem: false })],
    JSON.stringify(template),
    args.reason
  ));
});

server.registerTool('update_item_fields', {
  description: 'Update one or more fields on an item. Supports standard fields and custom section-qualified fields.',
  inputSchema: {
    ...itemSelectorSchema,
    fields: z.array(z.object({
      name: z.string().min(1).max(512),
      value: z.string().max(16384)
    })).min(1).max(50),
    reason: z.string().min(1).max(300)
  }
}, async (args) => {
  if (!args.itemId && !args.itemTitle) fail('itemId or itemTitle is required');
  const cliArgs = ['item', 'update', ...selectorArgs(args)];
  for (const field of args.fields) cliArgs.push('--field', `${field.name}=${field.value}`);
  return result(await run(cliArgs, args.reason));
});

server.registerTool('move_item', {
  description: 'Move an item from one Proton Pass vault to another.',
  inputSchema: {
    fromShareId: z.string().min(1).max(512).optional(),
    fromVaultName: z.string().min(1).max(512).optional(),
    toShareId: z.string().min(1).max(512).optional(),
    toVaultName: z.string().min(1).max(512).optional(),
    itemId: z.string().min(1).max(512).optional(),
    itemTitle: z.string().min(1).max(512).optional(),
    reason: z.string().min(1).max(300)
  }
}, async (args) => {
  if ((!args.fromShareId && !args.fromVaultName) || (!args.toShareId && !args.toVaultName)) fail('source and destination vault are required');
  if (!args.itemId && !args.itemTitle) fail('itemId or itemTitle is required');
  const cliArgs = ['item', 'move'];
  if (args.fromShareId) cliArgs.push(`--from-share-id=${args.fromShareId}`);
  else cliArgs.push('--from-vault-name', args.fromVaultName);
  if (args.itemId) cliArgs.push(`--item-id=${args.itemId}`);
  else cliArgs.push('--item-title', args.itemTitle);
  if (args.toShareId) cliArgs.push(`--to-share-id=${args.toShareId}`);
  else cliArgs.push('--to-vault-name', args.toVaultName);
  return result(await run(cliArgs, args.reason));
});

server.registerTool('trash_item', {
  description: 'Move an item to Proton Pass trash. This is recoverable with restore_item.',
  inputSchema: { ...itemSelectorSchema, reason: z.string().min(1).max(300) }
}, async (args) => {
  if (!args.itemId && !args.itemTitle) fail('itemId or itemTitle is required');
  return result(await run(['item', 'trash', ...selectorArgs(args)], args.reason));
});

server.registerTool('restore_item', {
  description: 'Restore an item from Proton Pass trash.',
  inputSchema: { ...itemSelectorSchema, reason: z.string().min(1).max(300) }
}, async (args) => {
  if (!args.itemId && !args.itemTitle) fail('itemId or itemTitle is required');
  return result(await run(['item', 'untrash', ...selectorArgs(args)], args.reason));
});

server.registerTool('delete_item_permanently', {
  description: 'Permanently delete a trashed item. Requires the exact item ID repeated as confirmation and cannot be undone.',
  inputSchema: {
    shareId: z.string().min(1).max(512),
    itemId: z.string().min(1).max(512),
    confirmItemId: z.string().min(1).max(512),
    reason: z.string().min(1).max(300)
  },
  annotations: { destructiveHint: true }
}, async (args) => {
  if (args.itemId !== args.confirmItemId) fail('confirmItemId must exactly match itemId');
  const trashed = await run([
    'item', 'list', `--share-id=${args.shareId}`, '--filter-state', 'trashed', '--output', 'json'
  ], args.reason);
  if (!JSON.stringify(trashed).includes(args.itemId)) fail('Item is not present in Proton Pass trash; permanent delete refused');
  return result(await run([
    'item', 'delete', `--share-id=${args.shareId}`, `--item-id=${args.itemId}`
  ], args.reason));
});

server.registerTool('create_vault', {
  description: 'Create a new Proton Pass vault.',
  inputSchema: {
    name: z.string().min(1).max(512),
    reason: z.string().min(1).max(300)
  }
}, async (args) => result(await run(['vault', 'create', '--name', args.name], args.reason)));

server.registerTool('rename_vault', {
  description: 'Rename a Proton Pass vault.',
  inputSchema: {
    shareId: z.string().min(1).max(512).optional(),
    vaultName: z.string().min(1).max(512).optional(),
    newName: z.string().min(1).max(512),
    reason: z.string().min(1).max(300)
  }
}, async (args) => {
  if (!args.shareId && !args.vaultName) fail('shareId or vaultName is required');
  return result(await run([
    'vault', 'update', ...selectorArgs(args, { includeItem: false }), '--name', args.newName
  ], args.reason));
});

server.registerTool('delete_vault_permanently', {
  description: 'Permanently delete a Proton Pass vault. Requires the exact vault name repeated as confirmation and cannot be undone.',
  inputSchema: {
    vaultName: z.string().min(1).max(512),
    confirmVaultName: z.string().min(1).max(512),
    reason: z.string().min(1).max(300)
  },
  annotations: { destructiveHint: true }
}, async (args) => {
  if (args.vaultName !== args.confirmVaultName) fail('confirmVaultName must exactly match vaultName');
  const vault = await resolveVault({ vaultName: args.vaultName });
  return result(await run(['vault', 'delete', `--share-id=${vault.share_id}`], args.reason));
});

await server.connect(new StdioServerTransport());
