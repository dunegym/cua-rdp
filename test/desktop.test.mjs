import test from 'node:test';
import assert from 'node:assert/strict';
import { DesktopManager } from '../src/desktop.mjs';

function fixture() {
  const f = { backend: 'child-session', loads: 0, starts: 0, state: 'stopped', cleanup: true, selected: [] };
  f.manager = new DesktopManager({
    loadConfig: async () => { f.loads++; return { backend: f.backend }; },
    createBackend: backend => {
      f.selected.push(backend);
      return {
        start: async () => { f.starts++; f.state = 'ready'; },
        summary: () => ({ state: f.state }), status: async () => {},
        request: async (operation, payload) => ({ operation, payload }),
        stop: async () => { if (!f.cleanup) { f.state = 'failed'; throw new Error('Cleanup unconfirmed'); } f.state = 'stopped'; return { state: 'stopped' }; },
        dispose: async () => { f.state = 'stopped'; },
      };
    },
  });
  return f;
}

test('public dispatcher does not read config or create a desktop for status and stop', async () => {
  const f = fixture();
  assert.deepEqual(await f.manager.status(), { state: 'stopped' });
  await f.manager.stop();
  await assert.rejects(f.manager.request('callTool', {}), /not ready/);
  assert.equal(f.loads, 0); assert.equal(f.selected.length, 0);
});

test('dispatcher pins one backend until stop and reloads config on the next start', async () => {
  const f = fixture();
  const result = await f.manager.start();
  assert.equal(result.backend, 'child-session');
  f.backend = 'hyperv';
  await f.manager.start();
  assert.equal(f.loads, 1);
  assert.deepEqual(await f.manager.request('listTools', { cursor: 'page' }), { operation: 'listTools', payload: { cursor: 'page' } });
  await f.manager.stop();
  assert.equal((await f.manager.start()).backend, 'hyperv');
  assert.deepEqual(f.selected, ['child-session', 'hyperv']);
  await f.manager.dispose();
});

test('failed cleanup retains the original adapter despite a changed backend setting', async () => {
  const f = fixture(); await f.manager.start(); f.cleanup = false;
  await assert.rejects(f.manager.stop(), /Cleanup unconfirmed/);
  f.backend = 'hyperv';
  assert.equal((await f.manager.status()).backend, 'child-session');
  assert.deepEqual(f.selected, ['child-session']);
  f.cleanup = true; await f.manager.stop();
});

test('dispatcher rejects unsupported authentication modes and interactive Hyper-V startup', async () => {
  const f = fixture();
  await assert.rejects(f.manager.start({ authentication: 'automatic' }), /authentication/);
  assert.equal(f.starts, 0);
  f.backend = 'hyperv';
  await assert.rejects(f.manager.start({ authentication: 'interactive' }), /Child Session/);
  assert.equal(f.starts, 0);
});
