import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdtemp, mkdir, rm, readdir, readFile, writeFile } from 'node:fs/promises';
import { ChildSessionManager, removePartialStage, connectionPlan, assertConnectedChild } from '../src/child-session.mjs';
import { readJson, writeJson } from '../src/util.mjs';

const parent = {
  enabled: true, parentSessionId: 1, parentLogonTime: '134200000000000001', parentState: 0, parentProtocol: 0,
  isConsoleParent: true, activeConsoleSessionId: 1, userSid: 'S-1-5-21-1000', machineGuid: '11111111-1111-1111-1111-111111111111',
  childSessionId: null, childLogonTime: null, childState: null, childProtocol: null, childUserSid: null,
  rdpPort: 3389, rdpWrapper: false,
};
const child = { ...parent, childSessionId: 4, childLogonTime: '134200000000000007', childState: 0, childProtocol: 2, childUserSid: parent.userSid };
const owner = { version: 1, machineGuid: parent.machineGuid, userSid: parent.userSid, parentSessionId: 1,
  parentLogonTime: parent.parentLogonTime, childSessionId: 4, childLogonTime: child.childLogonTime };

async function fixture(t, overrides = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'cua-child-test-'));
  const runtimeRoot = path.join(root, 'runtime');
  const log = [];
  const f = {
    root, runtimeRoot, log, native: { ...parent }, keeperState: 'connected', cleanup: true, bootReady: true,
    actualProcess: { pid: 12345, sessionId: 4, startedAt: '2026-10-10T00:00:00.0000000Z' },
    readyChange: {}, healthChange: {}, keeperChange: {}, callError: undefined,
  };
  const deps = {
    config: { backend: 'child-session', runtimeRoot, driverPath: 'C:\\Cua\\cua-driver.exe', rdp: { width: 1600, height: 900 } },
    root, platform: 'win32', heartbeatMs: 1_000_000, readyTimeoutMs: 20,
    state: async () => ({ ...f.native }),
    initialize: async () => { log.push('initialize'); await mkdir(path.join(runtimeRoot, 'runs'), { recursive: true }); return { userSid: parent.userSid }; },
    createKeeper: () => ({
      start: async (config, directory) => {
        log.push('rdp.start'); f.connection = config;
        assert.equal(config.mode, 'child-session'); assert.equal(config.rdp.address, 'localhost'); assert.equal(config.credentialPath, undefined);
        assert.ok(config.window === undefined || config.window === 'visible' || config.window === 'hidden');
        await mkdir(directory, { recursive: true });
        f.native = { ...child }; f.keeperState = 'connected';
        return { state: 'connected', backgroundReady: true, parentSessionId: 1, childSessionId: 4, ...f.keeperChange };
      },
      status: async () => ({ state: f.keeperState, backgroundReady: true, parentSessionId: 1, childSessionId: 4, ...f.keeperChange }),
      bootstrapTask: async id => {
        log.push('bootstrap'); f.id = id;
      },
      stop: async () => { log.push('rdp.stop'); f.keeperState = 'stopped'; if (f.native.childSessionId) f.native.childState = 4; },
    }),
    launchAgent: async (childSessionId, runtime, id) => {
      log.push('launchAgent');
      assert.equal(childSessionId, 4); assert.equal(runtime, runtimeRoot);
      const agent = await readJson(path.join(runtimeRoot, 'runs', id, 'agent.json'));
      f.token = agent.token;
      assert.equal(agent.expectedSessionLogonTime, child.childLogonTime);
      f.identity = { runId: id, machineGuid: parent.machineGuid, userSid: parent.userSid, sessionId: 4, logonTime: child.childLogonTime };
      if (f.bootReady) await writeJson(path.join(runtimeRoot, 'runs', id, 'ready.json'), { ...f.identity, port: 55555, pid: 12345, ...f.readyChange });
    },
    inspectProcess: async () => ({ ...f.actualProcess }),
    createClient: (_port, token) => {
      assert.equal(token, f.token);
      return { request: async operation => {
        log.push(operation);
        if (operation === 'health') return { ...f.identity, protocol: 2, state: 0, inputDesktop: 'Default', driverConnected: true, pid: 12345, ...f.healthChange };
        if (operation !== 'shutdown' && f.callError) throw f.callError;
        return { content: [{ type: 'image', mimeType: 'image/png', data: 'cGl4ZWxz' }] };
      } };
    },
    stopAgent: async (runtime, id, token) => {
      log.push('stopAgent');
      assert.equal(runtime, runtimeRoot); assert.match(token, /^[a-f0-9]{64}$/u);
      if (!f.cleanup) return { stopped: false, retained: true };
      await rm(path.join(runtimeRoot, 'runs', id), { recursive: true });
      return { stopped: true, retained: false };
    },
  };
  Object.assign(deps, overrides);
  f.manager = new ChildSessionManager(deps);
  t.after(async () => { f.cleanup = true; await f.manager.stop().catch(() => {}); await rm(root, { recursive: true, force: true }); });
  return f;
}

test('fresh child plan requires an enabled active console parent and no conflicting runtime', () => {
  assert.deepEqual(connectionPlan(parent), { expectedChildSessionId: null, expectedChildLogonTime: null });
  for (const change of [{ enabled: false }, { isConsoleParent: false }, { parentSessionId: 0 }, { parentState: 4 },
    { parentProtocol: 2 }, { activeConsoleSessionId: 7 }, { parentLogonTime: 134200000000000000 }, { rdpWrapper: true }, { rdpPort: 0 }]) {
    assert.throws(() => connectionPlan({ ...parent, ...change }));
  }
});

test('only exact owned disconnected child generations can resume', () => {
  const disconnected = { ...child, childState: 4 };
  assert.equal(connectionPlan(disconnected, owner).expectedChildSessionId, 4);
  assert.throws(() => connectionPlan(disconnected), /not owned/);
  assert.throws(() => connectionPlan(child, owner), /already connected/);
  for (const change of [{ childSessionId: 5 }, { childLogonTime: '134200000000000008' }, { parentLogonTime: '134200000000000002' },
    { machineGuid: 'foreign-machine' }, { childUserSid: 'S-1-5-21-999' }, { userSid: 'S-1-5-21-999' }]) {
    assert.throws(() => connectionPlan({ ...disconnected, ...change }, owner), /not owned/);
  }
  for (const childState of [0, 1, 2, 3, 5, 6, 7, 8, 9]) assert.throws(() => connectionPlan({ ...child, childState }, owner));
  assert.doesNotThrow(() => assertConnectedChild(child, owner));
  assert.throws(() => assertConnectedChild(disconnected, owner), /input is blocked/);
});

test('child lifecycle waits for login, actual agent PID and authenticated health; stop preserves ownership', async t => {
  const f = await fixture(t);
  assert.equal((await f.manager.status()).state, 'stopped');
  const [a, b] = await Promise.all([f.manager.start(), f.manager.start()]);
  assert.equal(a.state, 'ready'); assert.equal(a.sessionId, 4); assert.equal(a.runId, b.runId);
  assert.equal(f.log.filter(x => x === 'rdp.start').length, 1);
  assert.deepEqual(await readJson(path.join(f.root, 'child-session.owner.json')), owner);
  const result = await f.manager.request('callTool', { name: 'screenshot', arguments: {} });
  assert.equal(result.content[0].type, 'image');
  const stopped = await f.manager.stop();
  assert.equal(stopped.state, 'stopped'); assert.equal(stopped.childSessionId, 4);
  assert(f.log.indexOf('rdp.stop') < f.log.indexOf('stopAgent'));
  assert.deepEqual(await readdir(path.join(f.runtimeRoot, 'runs')), []);
  assert.deepEqual(await readdir(path.join(f.root, 'locks')), []);
  assert.deepEqual(await readJson(path.join(f.root, 'child-session.owner.json')), owner);
  assert.equal((await f.manager.start()).state, 'ready');
  assert.equal(f.connection.expectedChildSessionId, 4);
  assert.equal(f.connection.expectedChildLogonTime, child.childLogonTime);
});

test('existing foreign child refuses before installation or connection', async t => {
  const f = await fixture(t); f.native = { ...child, childState: 4 };
  await assert.rejects(f.manager.start(), /not owned/);
  assert.deepEqual(f.log, []);
  assert.deepEqual(await readdir(path.join(f.root, 'locks')), []);
});

test('mismatched keeper identity never bootstraps or claims the child', async t => {
  const f = await fixture(t); f.keeperChange = { childSessionId: 99 };
  await assert.rejects(f.manager.start(), /expected Child Session identity/);
  assert(!f.log.includes('bootstrap'));
  await assert.rejects(readJson(path.join(f.root, 'child-session.owner.json')), { code: 'ENOENT' });
});

test('ready descriptors from a wrong session generation are rejected before driver use', async t => {
  const f = await fixture(t); f.readyChange = { logonTime: '134200000000000008' };
  await assert.rejects(f.manager.start(), /identity\/session mismatch/);
  assert(!f.log.includes('health'));
  assert(f.log.includes('stopAgent'));
});

test('agent self-report is insufficient when its actual OS process is in the parent', async t => {
  const f = await fixture(t); f.actualProcess.sessionId = parent.parentSessionId;
  await assert.rejects(f.manager.start(), /actual Child Session/);
  assert(!f.log.includes('health'));
});

test('RDP loss blocks further input and never automatically reconnects', async t => {
  const f = await fixture(t); await f.manager.start(); f.keeperState = 'failed';
  await assert.rejects(f.manager.request('callTool', {}), /RDP connection/);
  assert.equal(f.manager.summary().state, 'failed'); assert(!f.log.includes('callTool'));
  await assert.rejects(f.manager.start(), /desktop_stop/);
  assert.equal(f.log.filter(x => x === 'rdp.start').length, 1);
});

test('changed Windows logon generation blocks input even when RDP still reports connected', async t => {
  const f = await fixture(t); await f.manager.start(); f.native.childLogonTime = '134200000000000008';
  await assert.rejects(f.manager.request('callTool', {}), /changed or disconnected/);
  assert(!f.log.includes('callTool'));
});

test('PID reuse fails health and input closed', async t => {
  const f = await fixture(t); await f.manager.start(); f.actualProcess.startedAt = '2026-10-11T00:00:00.0000000Z';
  await assert.rejects(f.manager.request('callTool', {}), /PID was reused/);
  assert(!f.log.includes('callTool'));
});

test('negative cleanup retains the controller lock until a confirmed retry', async t => {
  const f = await fixture(t); await f.manager.start(); f.cleanup = false;
  await assert.rejects(f.manager.stop(), /cleanup is unconfirmed/);
  assert.match(f.manager.summary().recovery, /lock retained/);
  assert.equal((await readdir(path.join(f.root, 'locks'))).length, 1);
  await assert.rejects(f.manager.start(), /desktop_stop/);
  f.cleanup = true;
  assert.equal((await f.manager.stop()).state, 'stopped');
  assert.deepEqual(await readdir(path.join(f.root, 'locks')), []);
});

test('a staging write failure cleans its own partial run directory', async t => {
  const f = await fixture(t, { writeJson: async (file, value) => {
    if (file.endsWith('agent.json')) throw Object.assign(new Error('ENOSPC: no space left on device'), { code: 'ENOSPC' });
    return writeJson(file, value);
  } });
  await assert.rejects(f.manager.start(), /no space left/);
  assert(!f.log.includes('stopAgent'));
  assert.deepEqual(await readdir(path.join(f.runtimeRoot, 'runs')), []);
  assert.deepEqual(await readdir(path.join(f.root, 'locks')), []);
});

test('bootstrap timeout cleans its staged run without claiming readiness', async t => {
  const f = await fixture(t); f.bootReady = false;
  await assert.rejects(f.manager.start(), /did not become ready/);
  assert(!f.log.includes('health')); assert(f.log.includes('stopAgent'));
  assert.deepEqual(await readdir(path.join(f.runtimeRoot, 'runs')), []);
});

test('driver semantic errors do not discard a healthy child; transport failures are not replayed', async t => {
  const f = await fixture(t); await f.manager.start();
  f.callError = Object.assign(new Error('Resource unsupported'), { code: 'DRIVER_ERROR' });
  await assert.rejects(f.manager.request('listResources'), /Resource unsupported/);
  assert.equal(f.manager.summary().state, 'ready');
  f.callError = new Error('Connection ended');
  await assert.rejects(f.manager.request('callTool', {}), /No automatic input replay/);
  assert.equal(f.manager.summary().state, 'failed');
  assert.equal(f.log.filter(x => x === 'callTool').length, 1);
});

test('status detects a dead driver without returning ready or secrets', async t => {
  const f = await fixture(t); await f.manager.start(); f.healthChange = { driverConnected: false };
  const status = await f.manager.status();
  assert.equal(status.state, 'failed'); assert(!JSON.stringify(status).includes(f.token));
});

test('background is the default and interactive authentication must be explicit on this connection', async t => {
  const f = await fixture(t);
  await f.manager.start();
  assert.equal(f.connection.authentication, 'background');
  await f.manager.stop();
  await f.manager.start({ authentication: 'interactive' });
  assert.equal(f.connection.authentication, 'interactive');
});

test('authentication failure is surfaced without bootstrap, credentials or retained controller lock', async t => {
  let stopped = false;
  const f = await fixture(t, { createKeeper: () => ({
    start: async () => { throw Object.assign(new Error('Windows requires interactive authentication'), { code: 'AUTHENTICATION_REQUIRED' }); },
    stop: async () => { stopped = true; },
  }) });
  await assert.rejects(f.manager.start(), { code: 'AUTHENTICATION_REQUIRED' });
  assert.equal((await f.manager.status()).state, 'needs-authentication');
  assert.equal(stopped, true);
  assert(!f.log.includes('bootstrap'));
  assert.deepEqual(await readdir(path.join(f.root, 'locks')), []);
});


test('failure diagnostics preserve only redacted metadata inside the private runtime', async t => {
  const f = await fixture(t);
  f.bootReady = false;
  await assert.rejects(f.manager.start());
  const runs = await readdir(path.join(f.runtimeRoot, 'diagnostics'));
  assert.equal(runs.length, 1);
  const directory = path.join(f.runtimeRoot, 'diagnostics', runs[0]);
  assert.deepEqual(await readdir(directory), ['failure.json']);
  const diagnostic = await readFile(path.join(directory, 'failure.json'), 'utf8');
  assert(!diagnostic.includes(f.token));
  assert(!diagnostic.includes('owner.token'));
  await assert.rejects(readdir(path.join(f.root, 'diagnostics')), { code: 'ENOENT' });
});

test('partial staging cleanup refuses changed metadata and directories with metadata names', async t => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'cua-partial-stage-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const directory = path.join(root, 'run');
  await mkdir(directory);
  await writeFile(path.join(directory, 'owner.token'), 'foreign-token');
  await assert.rejects(removePartialStage(directory, 'a'.repeat(64), {}), /changed/);
  await rm(path.join(directory, 'owner.token'));
  await mkdir(path.join(directory, 'agent.json'));
  await assert.rejects(removePartialStage(directory, 'a'.repeat(64), {}), /unexpected/);
  assert.deepEqual(await readdir(directory), ['agent.json']);
});

test('partial staging cleanup accepts its own partial temp file but rejects wildcard lookalikes', async t => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'cua-partial-temp-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const directory = path.join(root, 'run');
  await mkdir(directory);
  const config = { runId: 'a'.repeat(32), token: 'b'.repeat(64) };
  const suffix = `${process.pid}.12345678-1234-1234-1234-123456789abc.tmp`;
  const bad = path.join(directory, `agentXjsonX${suffix}`);
  await writeFile(bad, JSON.stringify(config));
  await assert.rejects(removePartialStage(directory, config.token, config), /unexpected/);
  await rm(bad);
  await writeFile(path.join(directory, `agent.json.${suffix}`), '{"run');
  await removePartialStage(directory, config.token, config);
  await assert.rejects(readdir(directory), { code: 'ENOENT' });
});

test('interactive startup cannot return ready until the keeper has entered background mode', async t => {
  let f;
  f = await fixture(t, { readyTimeoutMs: 200, sleep: async () => {
    f.log.push('entered-background');
    f.keeperChange.backgroundReady = true;
  } });
  f.keeperChange.backgroundReady = false;
  const ready = await f.manager.start({ authentication: 'interactive' });
  assert.equal(ready.state, 'ready');
  assert(f.log.includes('entered-background'));
  assert(f.log.indexOf('entered-background') < f.log.indexOf('health'));
});

test('ready.json is not enough while the interactive preparation window remains visible', async t => {
  const f = await fixture(t);
  f.keeperChange.backgroundReady = false;
  await assert.rejects(f.manager.start({ authentication: 'interactive' }), /did not become ready/);
  assert(!f.log.includes('health'));
});

test('input failure preserves its exact stage/code and only non-secret native observations', async t => {
  let f;
  f = await fixture(t, { onProgress: async progress => {
    if (progress.phase !== 'authenticated') return;
    const id = f.manager.summary().runId;
    const agent = await readJson(path.join(f.runtimeRoot, 'runs', id, 'agent.json'));
    f.keeperState = 'failed';
    f.keeperChange = {
      errorCode: 'RDP_INPUT_FAILED', bootstrapPhase: 'open-run',
      error: `SendKeys failed; sensitive ${agent.token}`,
      input: { clientConnected: 1, threadFocusInControl: false, secret: agent.token },
      inputAtLogon: { threadFocusInControl: true },
    };
    await writeJson(path.join(f.root, 'runs', id, 'rdp-status.json'), { state: 'failed', ...f.keeperChange });
  } });
  await assert.rejects(f.manager.start({ authentication: 'interactive' }), { code: 'RDP_INPUT_FAILED' });
  assert.equal(f.log.filter(item => item === 'bootstrap').length, 1);
  const [id] = await readdir(path.join(f.runtimeRoot, 'diagnostics'));
  const diagnostic = await readJson(path.join(f.runtimeRoot, 'diagnostics', id, 'failure.json'));
  assert.equal(diagnostic.rdp.bootstrapPhase, 'open-run');
  assert.equal(diagnostic.rdp.input.clientConnected, 1);
  assert.equal(diagnostic.rdp.input.threadFocusInControl, false);
  assert.equal(diagnostic.rdp.input.secret, undefined);
  assert(!JSON.stringify(diagnostic).includes(f.token));
});

test('interactive focus wait times out with an actionable error, without replay or driver use', async t => {
  const progress = [];
  const f = await fixture(t, { onProgress: async value => { progress.push(value); } });
  f.bootReady = false;
  f.keeperChange = { backgroundReady: false, bootstrapPhase: 'waiting-input-focus', inputFocusRequired: true };
  await assert.rejects(f.manager.start({ authentication: 'interactive' }), { code: 'RDP_INPUT_FOCUS_REQUIRED' });
  assert(progress.some(value => value.step === 'waiting-input-focus' && value.inputFocusRequired === true));
  assert.equal(f.log.filter(value => value === 'bootstrap').length, 1);
  assert(!f.log.includes('health'));
  assert(f.log.includes('rdp.stop'));
  assert.deepEqual(await readdir(path.join(f.root, 'locks')), []);
});

test('focus regained before bootstrap can become ready without reconnecting', async t => {
  let f;
  const progress = [];
  f = await fixture(t, { readyTimeoutMs: 1000, onProgress: async value => {
    progress.push(value);
    if (value.step === 'waiting-input-focus') f.keeperChange = { backgroundReady: true, bootstrapPhase: 'agent-started', inputFocusRequired: false };
  } });
  f.keeperChange = { backgroundReady: false, bootstrapPhase: 'waiting-input-focus', inputFocusRequired: true };
  assert.equal((await f.manager.start({ authentication: 'interactive' })).state, 'ready');
  assert(progress.some(value => value.step === 'agent-started' && value.inputFocusRequired === false));
  assert.equal(f.log.filter(value => value === 'rdp.start').length, 1);
  assert.equal(f.log.filter(value => value === 'bootstrap').length, 1);
});

test('mid-bootstrap focus loss preserves its code and stops without another attempt', async t => {
  let f;
  f = await fixture(t, { onProgress: async value => {
    if (value.phase !== 'authenticated') return;
    f.keeperState = 'failed';
    f.keeperChange = { backgroundReady: false, bootstrapPhase: 'select-command', errorCode: 'RDP_INPUT_FOCUS_REQUIRED', inputFocusRequired: true };
    await writeJson(path.join(f.root, 'runs', f.manager.summary().runId, 'rdp-status.json'), { state: 'failed', ...f.keeperChange });
  } });
  await assert.rejects(f.manager.start({ authentication: 'interactive' }), { code: 'RDP_INPUT_FOCUS_REQUIRED' });
  const [id] = await readdir(path.join(f.runtimeRoot, 'diagnostics'));
  const diagnostic = await readJson(path.join(f.runtimeRoot, 'diagnostics', id, 'failure.json'));
  assert.equal(diagnostic.rdp.inputFocusRequired, true);
  assert.equal(diagnostic.rdp.bootstrapPhase, 'select-command');
  assert.equal(f.log.filter(value => value === 'bootstrap').length, 1);
  assert(!f.log.includes('health'));
});
