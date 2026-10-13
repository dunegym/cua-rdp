import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { acquireLock } from '../src/lock.mjs';

test('per-VM lock excludes concurrent owners and is released only by its nonce', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'cua-rdp-lock-'));
  try {
    const release = await acquireLock(dir, 'vm');
    await assert.rejects(acquireLock(dir, 'vm'), /Another controller/);
    await release();
    assert.deepEqual(await readdir(dir), []);
    const release2 = await acquireLock(dir, 'vm');
    await writeFile(path.join(dir, 'vm.lock'), JSON.stringify({ nonce: 'another-owner' }));
    await release2();
    assert.deepEqual(await readdir(dir), ['vm.lock']);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
