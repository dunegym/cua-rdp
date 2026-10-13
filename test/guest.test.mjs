import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createGuestService, assertInteractive } from '../guest/service.mjs';

const token = 'a'.repeat(64);
const config = { expectedMachineGuid: 'guest-guid', expectedSessionId: 2, expectedUserSid: 'S-1-test', runId: 'b'.repeat(32), token, leaseMs: 180000 };
const interactive = { machineGuid: 'guest-guid', sessionId: 2, userSid: 'S-1-test', protocol: 2, state: 0, inputDesktop: 'Default' };
const image = { content: [{ type: 'image', data: 'aW1hZ2U=', mimeType: 'image/png' }], structuredContent: { ok: true } };

async function fixture() {
  let current = { ...interactive };
  let calls = 0;
  let closed = false;
  const driver = {
    listTools: async () => ({ tools: [{ name: 'screenshot', inputSchema: { type: 'object' } }] }),
    listResources: async () => ({ resources: [] }),
    callTool: async () => { calls++; return image; }, readResource: async ({ uri }) => ({ contents: [{ uri, text: 'skill' }] }),
    close: async () => { closed = true; },
  };
  const service = await createGuestService({ config, identity: async () => current, driver });
  const request = (operation, payload = {}, headers = {}) => fetch(`http://127.0.0.1:${service.port}/${operation}`, {
    method: 'POST', headers: { Authorization: `Bearer ${token}`, ...headers }, body: JSON.stringify(payload),
  });
  return { service, request, setState: state => { current = { ...interactive, ...state }; }, get calls() { return calls; }, get closed() { return closed; } };
}

test('guest rejects Session 0, console, wrong identity, disconnected and locked states', () => {
  assert.doesNotThrow(() => assertInteractive(interactive, config));
  for (const change of [{ sessionId: 0 }, { sessionId: 3 }, { protocol: 0 }, { state: 4 }, { inputDesktop: 'Winlogon' }, { machineGuid: 'host' }, { userSid: 'other' }]) {
    assert.throws(() => assertInteractive({ ...interactive, ...change }, config), /pinned, active, unlocked/);
  }
});

test('guest rejects reused Child Session IDs by exact FILETIME generation while keeping legacy configs', () => {
  const expected = { ...config, expectedSessionLogonTime: '134200000000000007' };
  assert.doesNotThrow(() => assertInteractive({ ...interactive, logonTime: expected.expectedSessionLogonTime }, expected));
  for (const logonTime of [undefined, null, '134200000000000008', 134200000000000000]) {
    assert.throws(() => assertInteractive({ ...interactive, logonTime }, expected), { code: 'ISOLATION_LOST' });
  }
  assert.doesNotThrow(() => assertInteractive(interactive, config));
});

test('loopback bridge rejects unauthenticated and browser-origin requests', async t => {
  const f = await fixture(); t.after(() => f.service.close());
  assert.equal((await f.request('health', {}, { Authorization: 'Bearer wrong' })).status, 403);
  assert.equal((await f.request('health', {}, { Origin: 'https://attacker.invalid' })).status, 403);
  const wrongHostStatus = await new Promise((resolve, reject) => {
    const request = http.request({ host: '127.0.0.1', port: f.service.port, path: '/health', method: 'POST',
      headers: { Host: 'attacker.invalid', Authorization: `Bearer ${token}` } }, response => { response.resume(); resolve(response.statusCode); });
    request.on('error', reject); request.end('{}');
  });
  assert.equal(wrongHostStatus, 400);
  assert.equal((await f.request('unknown')).status, 404);
  assert.equal(f.calls, 0);
});

test('bridge preserves images and resources, but rechecks session before each call', async t => {
  const f = await fixture(); t.after(() => f.service.close());
  const health = await (await f.request('health')).json();
  assert.equal(health.result.runId, config.runId);
  assert.deepEqual((await (await f.request('callTool', { name: 'screenshot', arguments: {} })).json()).result, image);
  assert.equal(f.calls, 1);
  const resource = await (await f.request('readResource', { uri: 'skill://cua-driver/SKILL.md' })).json();
  assert.equal(resource.result.contents[0].text, 'skill');
  f.setState({ state: 4 });
  assert.match((await (await f.request('callTool', { name: 'screenshot', arguments: {} })).json()).error.message, /RDP session/);
  assert.equal(f.calls, 1);
});

test('authenticated stop succeeds even when guest desktop is locked', async t => {
  const f = await fixture(); t.after(() => f.service.close());
  f.setState({ inputDesktop: 'Winlogon' });
  const response = await f.request('shutdown');
  assert.equal((await response.json()).result.stopped, true);
});

test('lease expiry closes an orphaned driver without new requests', async () => {
  let now = 0;
  let closed;
  const finished = new Promise(resolve => { closed = resolve; });
  const service = await createGuestService({ config: { ...config, leaseMs: 10 }, identity: async () => interactive,
    driver: { close: async () => { closed(); } }, now: () => now });
  now = 11;
  await finished;
  await service.close();
});

test('guest stop marker closes the driver before its lease expires', async () => {
  let requested = false;
  let resolveClosed;
  const closed = new Promise(resolve => { resolveClosed = resolve; });
  const service = await createGuestService({ config: { ...config, leaseMs: 10 }, now: () => 0,
    shouldStop: async () => requested, identity: async () => interactive, driver: { close: async () => resolveClosed() } });
  requested = true;
  await closed;
  await service.close();
});

test('driver errors remain semantic; isolation errors are distinguishable', async t => {
  const service = await createGuestService({ config, identity: async () => interactive,
    driver: { listResources: async () => { throw new Error('Unsupported resources'); }, close: async () => {} } });
  t.after(() => service.close());
  const response = await fetch(`http://127.0.0.1:${service.port}/listResources`, {
    method: 'POST', headers: { Authorization: `Bearer ${token}` }, body: '{}',
  });
  assert.equal((await response.json()).error.code, 'DRIVER_ERROR');
});
