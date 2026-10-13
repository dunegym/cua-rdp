import test from 'node:test';
import assert from 'node:assert/strict';
import { LocalAgentClient } from '../src/local-agent.mjs';
import { createGuestService } from '../guest/service.mjs';

const token = 'a'.repeat(64);

test('local client authenticates, preserves images and propagates semantic errors through the real bridge', async t => {
  const config = { expectedMachineGuid: 'local-machine', expectedSessionId: 4, expectedUserSid: 'S-1-test', expectedSessionLogonTime: '134200000000000001', token, runId: 'b'.repeat(32), leaseMs: 180000 };
  let logonTime = config.expectedSessionLogonTime;
  let calls = 0;
  const image = { content: [{ type: 'image', mimeType: 'image/png', data: 'cGl4ZWxz' }], structuredContent: { ok: true } };
  const service = await createGuestService({ config,
    identity: async () => ({ machineGuid: 'local-machine', sessionId: 4, userSid: 'S-1-test', protocol: 2, state: 0, inputDesktop: 'Default', logonTime }),
    driver: { connected: true, callTool: async () => { calls++; return image; }, listResources: async () => { throw new Error('Unsupported resource'); }, close: async () => {} },
  });
  t.after(() => service.close());
  const client = new LocalAgentClient(service.port, token);
  const health = await client.request('health');
  assert.equal(health.pid, process.pid); assert.equal(health.logonTime, logonTime);
  assert.deepEqual(await client.request('callTool', { name: 'screenshot', arguments: {} }), image);
  await assert.rejects(client.request('listResources'), { code: 'DRIVER_ERROR' });
  await assert.rejects(new LocalAgentClient(service.port, 'c'.repeat(64)).request('health'), /HTTP 403/);
  logonTime = '134200000000000002';
  await assert.rejects(client.request('callTool', { name: 'click', arguments: {} }), { code: 'ISOLATION_LOST' });
  assert.equal(calls, 1);
});

test('local client bounds input and never sends an invalid operation', async () => {
  let calls = 0;
  const client = new LocalAgentClient(55555, token, async () => { calls++; });
  await assert.rejects(client.request('callTool', { text: 'a'.repeat(2 * 1024 * 1024) }), /not sent/);
  await assert.rejects(client.request('connect'), /Unsupported/);
  assert.equal(calls, 0);
  assert.throws(() => new LocalAgentClient(80, token));
  assert.throws(() => new LocalAgentClient(55555, 'wrong'));
});

test('local timeout aborts once without replaying input', async () => {
  let calls = 0;
  const client = new LocalAgentClient(55555, token, async (_url, options) => {
    calls++;
    assert.equal(options.redirect, 'error');
    return new Promise((_resolve, reject) => options.signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true }));
  });
  await assert.rejects(client.request('callTool', { name: 'click', arguments: {} }, 10), /outcome may be unknown.*not replayed/);
  assert.equal(calls, 1);
});

test('local client stops reading oversized output rather than following a new endpoint', async () => {
  const client = new LocalAgentClient(55555, token, async () => new Response(new ReadableStream({
    start(controller) { controller.enqueue(new Uint8Array(64 * 1024 * 1024 + 1)); controller.close(); },
  })));
  await assert.rejects(client.request('listTools'), /exceeded its limit/);
});
