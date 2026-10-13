import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { RdpKeeper, readStatusJson } from '../src/rdp.mjs';
import { readJson } from '../src/util.mjs';

for (const code of ['ENOENT', 'EBUSY', 'EPERM']) {
  test(`status reader tolerates a bounded ${code} replacement race without caching`, async () => {
    let calls = 0;
    const waits = [];
    const result = await readStatusJson('status', async () => {
      if (++calls < 3) throw Object.assign(new Error('replace race'), { code });
      return { state: 'connected' };
    }, async ms => waits.push(ms));
    assert.equal(result.state, 'connected');
    assert.equal(calls, 3);
    assert.deepEqual(waits, [40, 40]);
  });
}
test('status reader never hides persistent missing files or invalid JSON', async () => {
  let calls = 0;
  await assert.rejects(readStatusJson('status', async () => {
    calls++; throw Object.assign(new Error('missing'), { code: 'ENOENT' });
  }, async () => {}), { code: 'ENOENT' });
  assert.equal(calls, 5);
  calls = 0;
  await assert.rejects(readStatusJson('status', async () => { calls++; throw new SyntaxError('invalid JSON'); }, async () => {}), SyntaxError);
  assert.equal(calls, 1);
});

async function fixture(t) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'cua-rdp-keeper-'));
  const process = new EventEmitter();
  process.stderr = new EventEmitter(); process.stderr.setEncoding = () => {};
  process.kill = () => process.emit('exit', 0);
  const f = { root, process, time: Date.now(), state: 'connected', errorCode: undefined, missing: false };
  f.keeper = new RdpKeeper({ spawn: () => process, now: () => f.time, sleep: async ms => { f.time += ms; }, readJson: async () => {
    if (f.missing) throw Object.assign(new Error('missing'), { code: 'ENOENT' });
    return { state: f.state, updatedAt: new Date(f.time).toISOString(), errorCode: f.errorCode, error: f.state === 'failed' ? 'Authentication is required' : undefined };
  } });
  f.config = { mode: 'child-session', guestRoot: 'C:\CuaRdp', expectedParentSessionId: 1,
    expectedParentLogonTime: '134200000000000001', rdp: { address: 'localhost', port: 3389 } };
  t.after(async () => { await f.keeper.stop(); await rm(root, { recursive: true, force: true }); });
  return f;
}

test('keeper fails closed on persistent missing status or a dead launcher', async t => {
  const f = await fixture(t);
  await f.keeper.start(f.config, f.root);
  f.missing = true;
  assert.equal((await f.keeper.status()).state, 'failed');
  f.missing = false;
  f.process.emit('exit', 1);
  const status = await f.keeper.status();
  assert.equal(status.state, 'failed');
  assert.match(status.error, /exited/);
});

test('keeper forwards explicit interactive mode without any credentials and preserves authentication errors', async t => {
  const f = await fixture(t);
  f.state = 'failed'; f.errorCode = 'AUTHENTICATION_REQUIRED';
  await assert.rejects(f.keeper.start({ ...f.config, authentication: 'interactive' }, f.root), { code: 'AUTHENTICATION_REQUIRED' });
  const request = await readJson(path.join(f.root, 'rdp-request.json'));
  assert.equal(request.authentication, 'interactive');
  for (const name of ['credentialPath', 'password', 'userName', 'domain']) assert.equal(request[name], undefined);
});

test('keeper writes a task-mode bootstrap request only while connected', async t => {
  const f = await fixture(t);
  await f.keeper.start(f.config, f.root);
  const id = 'a'.repeat(32);
  await f.keeper.bootstrapTask(id);
  assert.deepEqual(await readJson(path.join(f.root, 'bootstrap.json')), { id, launch: 'task' });
  await assert.rejects(f.keeper.bootstrapTask('not-hex'), /Invalid runId/);
  f.state = 'failed';
  await assert.rejects(f.keeper.bootstrapTask(id), /not ready for guest bootstrap/);
});
