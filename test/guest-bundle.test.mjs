import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, copyFile, writeFile, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { ROOT } from '../src/location.mjs';

const exec = promisify(execFile);
test('built guest bundle refuses a mismatched session before launching any driver', {
  skip: process.platform !== 'win32' || !existsSync(path.join(ROOT, 'dist', 'guest-agent.cjs')),
}, async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'cua-rdp-guard-test-'));
  try {
    await copyFile(path.join(ROOT, 'dist', 'guest-agent.cjs'), path.join(dir, 'guest-agent.cjs'));
    await copyFile(path.join(ROOT, 'guest', 'Get-InteractiveState.ps1'), path.join(dir, 'Get-InteractiveState.ps1'));
    const runId = 'a'.repeat(32);
    const runDir = path.join(dir, 'runs', runId);
    await mkdir(runDir, { recursive: true });
    const configPath = path.join(runDir, 'agent.json');
    await writeFile(configPath, JSON.stringify({ version: 1, runId, token: 'b'.repeat(64), expectedMachineGuid: 'not-the-host',
      expectedSessionId: 99999, expectedUserSid: 'S-1-impossible', driverPath: 'C:\\this-driver-must-not-be-started.exe',
      readyPath: path.join(runDir, 'ready.json'), leaseMs: 180000 }));
    await assert.rejects(exec(process.execPath, [path.join(dir, 'guest-agent.cjs'), '--config', configPath], { windowsHide: true, timeout: 20000 }), error => {
      // Interactive machines reject at the identity mismatch; a session-0 CI runner cannot even
      // query an interactive state and must fail closed the same way — before any driver launch.
      assert.match(error.stderr, /pinned, active, unlocked RDP session|Get-InteractiveState\.ps1/);
      assert.doesNotMatch(error.stderr, /ENOENT|fileURLToPath|import.meta/);
      return true;
    });
    assert.equal(existsSync(path.join(runDir, 'ready.json')), false);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
