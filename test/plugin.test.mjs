import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, copyFile, readFile, rm, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { ROOT } from '../src/location.mjs';

const json = async file => JSON.parse(await readFile(path.join(ROOT, file), 'utf8'));

test('marketplace plugin runs from a clean cache without node_modules or a desktop connection', async t => {
  const manifest = await json('plugin.json');
  assert.equal(manifest.$schema, 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json');
  const marketplace = await json('.agents/plugins/marketplace.json');
  const entry = marketplace.plugins.find(plugin => plugin.name === manifest.name);
  assert.ok(entry, 'Codex marketplace must expose this plugin');
  assert.equal(entry.source.path, './');
  assert.equal(manifest.version, (await json('package.json')).version);
  assert.equal(manifest.version, (await json('.claude-plugin/plugin.json')).version);

  // Use a cache path containing spaces and Unicode, outside the repo's dependency tree.
  const directory = await mkdtemp(path.join(os.tmpdir(), 'cua-rdp plugin-\u684c\u9762-'));
  let client;
  t.after(async () => {
    try { await client?.close(); }
    finally { await rm(directory, { recursive: true, force: true }); }
  });
  const mcp = await json('mcp.json');
  const server = mcp.mcpServers.desktop;
  const args = server.args.map(arg => arg.replaceAll('${PLUGIN_ROOT}', directory));
  assert.equal(server.command, 'node');
  const bundle = path.resolve(args[0]);
  assert.equal(path.dirname(bundle), path.join(directory, 'dist'));
  await mkdir(path.dirname(bundle), { recursive: true });
  await copyFile(path.join(ROOT, 'dist', 'desktop-server.mjs'), bundle);
  await assert.rejects(stat(path.join(directory, 'node_modules')), { code: 'ENOENT' });

  client = new Client({ name: 'clean-plugin-cache', version: '1' }, { capabilities: {} });
  const transport = new StdioClientTransport({ command: process.execPath, args, cwd: directory, stderr: 'pipe',
    env: { CUA_RDP_CONFIG: path.join(directory, 'missing-config.json') } });
  let diagnostic = '';
  transport.stderr?.on('data', chunk => { diagnostic += chunk; });
  await client.connect(transport);
  assert.equal(client.getServerVersion().version, manifest.version);
  assert.deepEqual((await client.listTools()).tools.map(tool => tool.name).sort(), [
    'desktop_call', 'desktop_read_resource', 'desktop_resources', 'desktop_start', 'desktop_status', 'desktop_stop', 'desktop_tools',
  ]);
  const call = async name => client.callTool({ name, arguments: {} });
  assert.equal(JSON.parse((await call('desktop_status')).content[0].text).state, 'stopped');
  const start = await call('desktop_start');
  assert.equal(start.isError, true);
  assert.match(start.content[0].text, /Configuration missing/);
  assert.equal(JSON.parse((await call('desktop_stop')).content[0].text).state, 'stopped');
  assert.doesNotMatch(diagnostic, /ERR_MODULE_NOT_FOUND|Dynamic require|import\.meta/);
});
