import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { createMcpServer } from '../src/mcp.mjs';
import { ROOT } from '../src/location.mjs';

test('MCP exposes lifecycle and schema discovery, preserves image tool results', async t => {
  const image = { content: [{ type: 'image', data: 'aW1hZ2U=', mimeType: 'image/png' }] };
  const calls = [];
  const manager = {
    start: async options => { calls.push({ operation: 'start', payload: options }); return { state: 'ready' }; }, status: async () => ({ state: 'ready' }), stop: async () => ({ state: 'stopped' }),
    request: async (operation, payload) => {
      calls.push({ operation, payload });
      if (operation === 'listTools') return { tools: [{ name: 'click', inputSchema: { type: 'object' } }, { name: 'get_window_state', inputSchema: { type: 'object' } }], nextCursor: 'next' };
      if (operation === 'readResource') return { contents: [{ uri: payload.uri, text: 'Instructions' }] };
      return image;
    },
  };
  const server = createMcpServer(manager);
  const client = new Client({ name: 'test', version: '1' }, { capabilities: {} });
  const [ct, st] = InMemoryTransport.createLinkedPair();
  await server.connect(st); await client.connect(ct);
  t.after(async () => { await client.close(); await server.close(); });
  const listed = await client.listTools();
  assert.equal(listed.tools.length, 7);
  assert.deepEqual(listed.tools.find(tool => tool.name === 'desktop_start').inputSchema.properties.authentication.enum, ['background', 'interactive']);
  assert.deepEqual(listed.tools.find(tool => tool.name === 'desktop_start').inputSchema.properties.window.enum, ['visible', 'hidden']);
  await client.callTool({ name: 'desktop_start', arguments: { authentication: 'interactive', window: 'hidden' } });
  assert.deepEqual(calls.find(call => call.operation === 'start').payload, { authentication: 'interactive', window: 'hidden' });
  assert.equal((await client.callTool({ name: 'desktop_start', arguments: { authentication: 'auto' } })).isError, true);
  assert.equal((await client.callTool({ name: 'desktop_start', arguments: { window: 'floaty' } })).isError, true);
  const discovery = await client.callTool({ name: 'desktop_tools', arguments: { filter: 'click' } });
  assert.equal(JSON.parse(discovery.content[0].text).tools.length, 1);
  assert.equal(JSON.parse(discovery.content[0].text).nextCursor, 'next');
  assert.deepEqual(await client.callTool({ name: 'desktop_call', arguments: { tool: 'get_window_state', arguments: { pid: 99 } } }), image);
  const resource = await client.callTool({ name: 'desktop_read_resource', arguments: { uri: 'skill://cua-driver/SKILL.md' } });
  assert.equal(resource.content[0].type, 'resource');
  assert.equal(resource.content[0].resource.text, 'Instructions');
  assert.equal(calls.filter(call => call.operation === 'callTool').length, 1);
  assert.equal((await client.callTool({ name: 'desktop_call', arguments: { tool: 'click', arguments: [] } })).isError, true);
  assert.equal((await client.callTool({ name: 'desktop_start', arguments: { command: 'cmd' } })).isError, true);
});

test('real stdio plugin handshake works without a VM or configuration', async t => {
  const client = new Client({ name: 'smoke', version: '1' }, { capabilities: {} });
  const transport = new StdioClientTransport({ command: process.execPath, args: [path.join(ROOT, 'src', 'server.mjs')], stderr: 'pipe',
    env: { CUA_RDP_CONFIG: path.join(ROOT, 'test', 'not-a-real-config.json') } });
  transport.stderr?.resume();
  await client.connect(transport);
  t.after(() => client.close());
  assert.equal((await client.listTools()).tools.length, 7);
  const status = await client.callTool({ name: 'desktop_status', arguments: {} });
  assert.equal(JSON.parse(status.content[0].text).state, 'stopped');
  const start = await client.callTool({ name: 'desktop_start', arguments: {} });
  assert.equal(start.isError, true);
  assert.match(start.content[0].text, /Configuration missing|requires Windows/);
  await client.callTool({ name: 'desktop_stop', arguments: {} });
});
