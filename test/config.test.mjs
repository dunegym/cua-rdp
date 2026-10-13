import test from 'node:test';
import assert from 'node:assert/strict';
import { validateConfig, verifyAddress, bootstrapCommand, defaultChildConfig, loadConfig } from '../src/config.mjs';
import path from 'node:path';
import os from 'node:os';
import { mkdtemp, rm } from 'node:fs/promises';

export const sample = {
  version: 1, vmId: '11111111-1111-1111-1111-111111111111',
  guestMachineGuid: '22222222-2222-2222-2222-222222222222', credentialPath: 'C:\\private\\credential.xml',
  guestRoot: 'C:\\ProgramData\\CuaRdp', autoStartVm: true, rdp: { address: 'guest.test' },
};
const interfaces = () => ({ Ethernet: [{ address: '192.168.1.1' }] });

test('config applies safe defaults and does not retain unknown secrets', () => {
  const config = validateConfig({ ...sample, password: 'not-used' });
  assert.equal(config.rdp.port, 3389);
  assert.equal(config.rdp.width, 1600);
  assert.equal(config.password, undefined);
});

test('config rejects invalid path, command injection, port, resolution and VM identity', () => {
  for (const guestRoot of ['relative', 'C:\\safe\\..\\other', 'C:\\test&calc', 'C:\\test"', '\\\\server\\share', 'C:\\test.', 'C:\\test dir']) {
    assert.throws(() => validateConfig({ ...sample, guestRoot }));
  }
  assert.throws(() => validateConfig({ ...sample, vmId: 'not-a-guid' }));
  assert.throws(() => validateConfig({ ...sample, rdp: { address: 'https://host' } }));
  assert.throws(() => validateConfig({ ...sample, rdp: { address: 'host', width: 9000 } }));
  assert.throws(() => validateConfig({ ...sample, rdp: { address: 'host', port: 0 } }));
  assert.throws(() => validateConfig({ ...sample, autoStartVm: 'true' }));
});

test('RDP address must be a non-host guest IP, even for DNS aliases', async () => {
  const opts = { interfaces, lookup: async () => [{ address: '192.168.1.20' }] };
  assert.deepEqual(await verifyAddress('guest.test', ['192.168.1.20'], opts), ['192.168.1.20']);
  for (const ip of ['127.0.0.1', '0.0.0.0', '169.254.1.1', '192.168.1.1', '224.0.0.1', '255.255.255.255']) {
    await assert.rejects(verifyAddress(ip, [ip], opts), /RDP target/);
  }
  await assert.rejects(verifyAddress('alias.test', ['192.168.1.20'], { ...opts, lookup: async () => [{ address: '192.168.1.1' }] }));
  await assert.rejects(verifyAddress('other.test', ['192.168.1.20'], { ...opts, lookup: async () => [{ address: '192.168.1.30' }] }));
  await assert.rejects(verifyAddress('mixed.test', ['192.168.1.20'], { ...opts, lookup: async () => [{ address: '192.168.1.20' }, { address: '127.0.0.1' }] }));
  await assert.rejects(verifyAddress('dual-stack.test', ['192.168.1.20'], { ...opts, lookup: async () => [{ address: '192.168.1.20' }, { address: '2001:db8::1' }] }));
});

test('child default needs no VM or credentials and keeps driver overrides', () => {
  const config = defaultChildConfig({ LOCALAPPDATA: 'C:\\Users\\Example\\AppData\\Local' });
  assert.equal(config.backend, 'child-session');
  assert.equal(config.version, 2);
  assert.equal(config.driverPath, 'C:\\Users\\Example\\AppData\\Local\\Programs\\Cua\\cua-driver\\bin\\cua-driver.exe');
  assert.equal(config.credentialPath, undefined); assert.equal(config.vmId, undefined);
  assert.deepEqual(config.rdp, { width: 1600, height: 900, window: 'visible' });
  assert.equal(defaultChildConfig({ LOCALAPPDATA: 'C:\\Private', CUA_RDP_DRIVER: 'D:\\Tools\\cua-driver.exe' }).driverPath, 'D:\\Tools\\cua-driver.exe');
  assert.equal(validateConfig({ ...sample }).backend, 'hyperv');
});

test('child config rejects unsupported backends, unsafe roots and remote executable paths', () => {
  const raw = { version: 2, backend: 'child-session', runtimeRoot: 'C:\\Private\\Child', driverPath: 'C:\\Cua\\cua-driver.exe' };
  for (const change of [{ backend: 'hyperv' }, { version: 1 }, { runtimeRoot: 'C:\\a&b' }, { runtimeRoot: 'C:\\a b' }, { runtimeRoot: 'C:\\用户\\runtime' },
    { driverPath: '\\\\host\\cua.exe' }, { driverPath: 'cua.exe' }, { driverPath: 'C:\\Cua\\script.cmd' }, { rdp: { width: 10 } }, { rdp: { window: 'docked' } }]) {
    assert.throws(() => validateConfig({ ...raw, ...change }));
  }
  assert.equal(validateConfig({ ...raw, rdp: { window: 'hidden' } }).rdp.window, 'hidden');
  assert.equal(validateConfig({ ...raw, driverPath: 'C:\\用户\\cua-driver.exe' }).driverPath, 'C:\\用户\\cua-driver.exe');
});

test('explicitly selected missing config never falls back to a different backend', async t => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'cua-config-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await assert.rejects(loadConfig(path.join(root, 'missing.json')), /explicitly selected config/);
});

test('bootstrap is fixed, unquoted upper case, IME-safe, and contains only the run ID', () => {
  const id = 'a'.repeat(32);
  assert.equal(bootstrapCommand(sample.guestRoot, id), `POWERSHELL.EXE -NOPROFILE -FILE C:\\PROGRAMDATA\\CUARDP\\START-AGENT.PS1 -RUNID ${id.toUpperCase()}`);
  assert.equal(bootstrapCommand('C:\\Root\\', id), bootstrapCommand('C:\\Root', id));
  assert.throws(() => bootstrapCommand(sample.guestRoot, 'a;calc'));
  assert.throws(() => bootstrapCommand('C:\\a b', id), /spaces/);
});
