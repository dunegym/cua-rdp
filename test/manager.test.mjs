import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { HyperVDesktopManager as DesktopManager } from '../src/manager.mjs';

function fixture(overrides = {}) {
  const log = [];
  let keeperState = 'connected';
  let id;
  let unlocked = false;
  const machineGuid = '22222222-2222-2222-2222-222222222222';
  const session = { sessionId: 3, userSid: 'S-1-5-21-1000', machineGuid };
  const config = { vmId: '11111111-1111-1111-1111-111111111111', guestMachineGuid: machineGuid,
    guestRoot: 'C:\\ProgramData\\CuaRdp', rdp: { address: 'guest.test' } };
  const deps = {
    platform: 'win32', file: 'not-read', root: path.join(os.tmpdir(), 'cua-rdp-test-unused'),
    loadConfig: async () => config,
    acquireLock: async () => async () => { unlocked = true; log.push('unlock'); },
    verifyAddress: async () => { log.push('verifyAddress'); }, heartbeatMs: 1_000_000,
    createKeeper: () => ({
      start: async () => { log.push('rdp.start'); }, status: async () => ({ state: keeperState }),
      bootstrap: async () => { log.push('bootstrap'); }, stop: async () => { log.push('rdp.stop'); },
    }),
    createBroker: () => ({
      request: async (method, params) => {
        log.push(method === 'request' ? params.operation : method);
        if (method === 'prepare') return { hostMachineGuid: '33333333-3333-3333-3333-333333333333', guestMachineGuid: machineGuid, addresses: ['192.168.1.20'] };
        if (method === 'stage') { id = params.runId; return session; }
        if (method === 'attach') return { ...session, runId: id };
        if (method === 'request') {
          if (params.operation === 'health') return { json: JSON.stringify({ result: { ...session, runId: id, protocol: 2, state: 0, inputDesktop: 'Default' } }) };
          assert.equal(typeof params.payloadJson, 'string');
          JSON.parse(params.payloadJson);
          return { json: JSON.stringify({ result: { content: [{ type: 'text', text: 'done' }] } }) };
        }
        return { stopped: true };
      }, close: async () => { log.push('broker.close'); },
    }), ...overrides,
  };
  return { manager: new DesktopManager(deps), deps, log, setKeeper: value => { keeperState = value; }, get unlocked() { return unlocked; } };
}

test('lifecycle waits for identity and health before ready; concurrent starts serialize', async () => {
  const f = fixture();
  assert.equal((await f.manager.status()).state, 'stopped');
  const [a, b] = await Promise.all([f.manager.start(), f.manager.start()]);
  assert.equal(a.state, 'ready'); assert.equal(a.runId, b.runId);
  assert.equal(f.log.filter(item => item === 'stage').length, 1);
  assert.deepEqual(f.log.slice(0, 7), ['prepare', 'verifyAddress', 'rdp.start', 'stage', 'bootstrap', 'attach', 'health']);
  await f.manager.request('callTool', { name: 'click', arguments: {} });
  assert.equal((await f.manager.stop()).state, 'stopped');
  assert(f.unlocked);
  assert(f.log.indexOf('rdp.stop') < f.log.indexOf('stop'));
});

test('RDP disconnect fails closed without invoking driver or silently reconnecting', async () => {
  const f = fixture();
  await f.manager.start();
  f.setKeeper('failed');
  await assert.rejects(f.manager.request('callTool', {}), /RDP disconnected/);
  assert.equal(f.manager.summary().state, 'failed');
  assert(!f.log.includes('callTool'));
  await assert.rejects(f.manager.start(), /desktop_stop/);
  await f.manager.stop();
});

test('mismatched guest identity fails before RDP and releases unused lock', async () => {
  const f = fixture({ createBroker: () => ({ request: async () => ({ hostMachineGuid: 'x', guestMachineGuid: 'wrong' }), close: async () => {} }) });
  await assert.rejects(f.manager.start(), /identity mismatch/);
  assert(!f.log.includes('rdp.start')); assert(f.unlocked);
});

test('unconfirmed guest cleanup retains the exclusive lock', async () => {
  const f = fixture();
  const create = f.deps.createBroker;
  const g = fixture({ createBroker: () => {
    const broker = create();
    return { ...broker, request: (method, params) => method === 'stop' ? Promise.reject(new Error('cleanup unreachable')) : broker.request(method, params) };
  } });
  await g.manager.start();
  await assert.rejects(g.manager.stop(), /cleanup unreachable/);
  assert.equal(g.unlocked, false);
  assert.match(g.manager.summary().recovery, /Lock retained/);
  await assert.rejects(g.manager.start(), /desktop_stop/);
});

test('unsupported host and not-started calls have no side effects', async () => {
  const f = fixture({ platform: 'linux' });
  await assert.rejects(f.manager.start(), /Windows/);
  await assert.rejects(f.manager.request('callTool', {}), /not ready/);
  assert.deepEqual(f.log, []);
});

test('negative cleanup acknowledgment retains the VM lock', async () => {
  const base = fixture();
  const f = fixture({ createBroker: () => {
    const broker = base.deps.createBroker();
    return { ...broker, request: (method, params) => method === 'stop' ? Promise.resolve({ stopped: false, retained: true }) : broker.request(method, params) };
  } });
  await f.manager.start();
  await assert.rejects(f.manager.stop(), /cleanup is not confirmed/);
  assert.equal(f.unlocked, false);
});

test('unsupported driver resources do not invalidate a healthy isolated session', async () => {
  const base = fixture();
  const f = fixture({ createBroker: () => {
    const broker = base.deps.createBroker();
    return { ...broker, request: (method, params) => params?.operation === 'listResources'
      ? Promise.resolve({ error: { code: 'DRIVER_ERROR', message: 'Resources unsupported' } }) : broker.request(method, params) };
  } });
  await f.manager.start();
  await assert.rejects(f.manager.request('listResources'), /Resources unsupported/);
  assert.equal(f.manager.summary().state, 'ready');
  await f.manager.request('callTool', { name: 'click', arguments: {} });
  await f.manager.stop();
});
