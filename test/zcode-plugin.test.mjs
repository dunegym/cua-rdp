import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { ROOT } from '../src/location.mjs';
import { createMcpServer, PANEL_URI, panelDirectory } from '../src/mcp.mjs';

const json = async relative => JSON.parse(await readFile(path.join(ROOT, relative), 'utf8'));

test('the ZCode manifest declares the server and the child desktop surface', async () => {
  const manifest = await json('.zcode-plugin/plugin.json');
  assert.equal(manifest.name, 'cua-rdp');
  const server = manifest.mcpServers['cua-rdp'];
  assert.equal(server.type, 'stdio');
  assert.match(server.command, /^node(\.exe)?$/u);
  assert.deepEqual(server.args, ['${ZCODE_PLUGIN_ROOT}/dist/desktop-server.mjs']);
  assert.equal(server.env.CUA_RDP_PANEL_DIR, '${ZCODE_PLUGIN_ROOT}/ui');
  // Interactive authentication waits up to 330 s and a guest call may take 360 s, so the
  // host must not cut a legitimate panel call short.
  assert.ok(server.timeoutMs >= 360_000, 'the server timeout must exceed the guest deadlines');
  assert.ok((await stat(path.join(ROOT, 'dist', 'desktop-server.mjs'))).isFile(), 'the packaged server bundle must exist');

  const [surface] = manifest.ui.surfaces;
  assert.equal(surface.id, 'child-desktop');
  assert.equal(surface.server, 'cua-rdp');
  assert.equal(surface.resourceUri, PANEL_URI);
  assert.equal(surface.availability, 'session');
  assert.ok(surface.title['zh-CN'], 'the panel needs its Chinese title');

  // The shared desktop skill is what teaches the session agent to take the desktop over.
  assert.ok((await stat(path.join(ROOT, manifest.skills, 'desktop', 'SKILL.md'))).isFile(), 'the desktop skill must exist');
});

test('the committed panel page is self-contained', async () => {
  const page = await readFile(path.join(ROOT, 'ui', 'panel.html'), 'utf8');
  assert.match(page, /<!doctype html>/iu);
  // esbuild escapes non-ASCII literals, so assert on the load-bearing marker instead:
  // the bundled page must carry the desktop_start call the panel is built around.
  assert.match(page, /desktop_start/u);
  // The host loads the page from the resource text with no network access.
  const external = page.match(/(?:src|href)\s*=\s*["']https?:\/\/[^"']*["']/giu) ?? [];
  assert.deepEqual(external, [], 'the panel must not reference external resources');
  assert.doesNotMatch(page, /<link/u, 'the panel must not reference stylesheets');
});

test('panel mode is gated on a non-empty CUA_RDP_PANEL_DIR', () => {
  assert.equal(panelDirectory({}), null);
  assert.equal(panelDirectory({ CUA_RDP_PANEL_DIR: '' }), null, 'an empty user_config default must behave as unset');
  assert.equal(panelDirectory({ CUA_RDP_PANEL_DIR: '  ' }), null);
  assert.equal(panelDirectory({ CUA_RDP_PANEL_DIR: 'C:/x/ui' }), 'C:/x/ui');
});

test('panel mode registers the panel resource and UI tool hints without changing the tool set', async () => {
  const manager = { start: async () => ({}), status: async () => ({ state: 'stopped' }), stop: async () => ({ state: 'stopped' }), request: async () => { throw new Error('unused'); } };
  const pair = server => {
    const client = new Client({ name: 'cua-rdp-test', version: '0' }, { capabilities: {} });
    const [clientSide, serverSide] = InMemoryTransport.createLinkedPair();
    // Both ends must connect concurrently: the client's initialize handshake only
    // completes once the server end is attached to the other side of the pair.
    return async () => { await Promise.all([client.connect(clientSide), server.connect(serverSide)]); return client; };
  };

  const bare = createMcpServer(manager, { panelDir: null });
  const bareClient = await pair(bare)();
  const bareTools = (await bareClient.listTools()).tools;
  assert.equal(bareTools.length, 7, 'tools must always be advertised');
  assert.ok(!Object.hasOwn(bareTools.find(tool => tool.name === 'desktop_start') ?? {}, '_meta'), 'no panel hints outside ZCode');
  assert.ok(!bareClient.getServerCapabilities().resources, 'resources must stay hidden outside ZCode');
  await bareClient.close();
  await bare.close();

  const paneled = createMcpServer(manager, { panelDir: path.join(ROOT, 'ui') });
  const client = await pair(paneled)();
  assert.ok(client.getServerCapabilities().resources, 'panel mode must advertise resources');
  const listed = await client.listTools();
  assert.equal(listed.tools.length, 7);
  for (const name of ['desktop_start', 'desktop_status', 'desktop_stop']) {
    const tool = listed.tools.find(entry => entry.name === name);
    assert.deepEqual(tool._meta?.ui, { resourceUri: PANEL_URI, surface: 'child-desktop', visibility: ['model', 'app'] }, `${name} must carry the panel hint`);
  }
  assert.ok(!listed.tools.find(entry => entry.name === 'desktop_call')._meta, 'driver tools stay panel-agnostic');
  const resources = await client.listResources();
  assert.deepEqual(resources.resources.map(resource => resource.uri), [PANEL_URI]);
  const read = await client.readResource({ uri: PANEL_URI });
  assert.match(read.contents[0].text, /<!doctype html>/iu);
  await client.close();
  await paneled.close();
});

test('the packaged server serves the panel over stdio in panel mode', async t => {
  const client = new Client({ name: 'cua-rdp-zcode-test', version: '0.4.6' }, { capabilities: {} });
  const transport = new StdioClientTransport({
    command: process.execPath, args: [path.join(ROOT, 'dist', 'desktop-server.mjs')], cwd: ROOT, stderr: 'pipe',
    env: { ...process.env, CUA_RDP_PANEL_DIR: path.join(ROOT, 'ui') },
  });
  transport.stderr?.on('data', () => {});
  await client.connect(transport);
  t.after(async () => { await client.close(); });

  const tools = await client.listTools();
  assert.equal(tools.tools.length, 7);
  assert.deepEqual(tools.tools.find(tool => tool.name === 'desktop_start')._meta?.ui?.surface, 'child-desktop');

  const resources = await client.listResources();
  assert.deepEqual(resources.resources.map(resource => resource.uri), [PANEL_URI]);
  const page = await client.readResource({ uri: PANEL_URI });
  assert.equal(page.contents[0].mimeType, 'text/html');
  assert.match(page.contents[0].text, /<!doctype html>/iu);
});
