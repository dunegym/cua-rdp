import path from 'node:path';
import { access, lstat, mkdir, readFile, readdir, rm, rmdir, unlink, writeFile } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { ROOT } from './location.mjs';
import { dataRoot, readJson, writeJson, safeError, sleep } from './util.mjs';
import { acquireLock } from './lock.mjs';
import { RdpKeeper } from './rdp.mjs';
import { runPowerShellJson, childSessionState } from './windows.mjs';
import { LocalAgentClient } from './local-agent.mjs';
import { assertIdentity } from './protocol.mjs';

const generation = value => typeof value === 'string' && /^[1-9][0-9]{0,19}$/u.test(value);
const sameText = (a, b) => typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();

export function assertParent(state) {
  if (!state || state.enabled !== true) throw new Error('Windows Child Sessions are disabled. Explicitly enable them with native/Enable-ChildSessions.ps1; desktop_start never changes this system setting.');
  if (state.isConsoleParent !== true || state.parentState !== 0 || state.parentProtocol !== 0 ||
      !Number.isInteger(state.parentSessionId) || state.parentSessionId <= 0 || state.activeConsoleSessionId !== state.parentSessionId) {
    throw new Error('Child Session requires an active local console parent; Session 0, nested Child Sessions and RDP parents are not supported.');
  }
  if (!generation(state.parentLogonTime) || typeof state.machineGuid !== 'string' || !/^S-1-/u.test(state.userSid)) throw new Error('Cannot establish the parent Windows session identity');
  if (state.rdpWrapper) throw new Error('RDP Wrapper conflicts with native Child Sessions; no connection was attempted');
  if (!Number.isInteger(state.rdpPort) || state.rdpPort < 1 || state.rdpPort > 65535) throw new Error('Invalid local RDP port');
}

export function connectionPlan(state, owner) {
  assertParent(state);
  if (state.childSessionId === null) return { expectedChildSessionId: null, expectedChildLogonTime: null };
  const matches = owner?.version === 1 && sameText(owner.machineGuid, state.machineGuid) && owner.userSid === state.userSid &&
    owner.parentSessionId === state.parentSessionId && owner.parentLogonTime === state.parentLogonTime &&
    owner.childSessionId === state.childSessionId && generation(state.childLogonTime) && owner.childLogonTime === state.childLogonTime &&
    state.childUserSid === state.userSid && state.childSessionId !== state.parentSessionId;
  if (!matches) throw new Error('An existing Child Session is not owned by this plugin (or its logon generation changed). It will not be taken over or logged off.');
  if (state.childState !== 4) throw new Error('The owned Child Session is already connected or not safely resumable. Stop its current controller first.');
  return { expectedChildSessionId: state.childSessionId, expectedChildLogonTime: state.childLogonTime };
}

export function assertConnectedChild(state, owner) {
  assertParent(state);
  if (!sameText(state.machineGuid, owner.machineGuid) || state.userSid !== owner.userSid ||
      state.parentSessionId !== owner.parentSessionId || state.parentLogonTime !== owner.parentLogonTime ||
      state.childSessionId !== owner.childSessionId || state.childLogonTime !== owner.childLogonTime ||
      state.childUserSid !== owner.userSid || state.childSessionId === state.parentSessionId || state.childState !== 0 || state.childProtocol !== 2) {
    throw new Error('The owned Child Session changed or disconnected; desktop input is blocked');
  }
}

async function optionalJson(file) {
  try { return await readJson(file); }
  catch (error) { if (error.code === 'ENOENT') return undefined; throw error; }
}

export async function removePartialStage(directory, token, config) {
  let stat;
  try { stat = await lstat(directory); }
  catch (error) { if (error.code === 'ENOENT') return; throw error; }
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('Staged run directory is not an ordinary directory; retained for inspection');
  const parent = await lstat(path.dirname(directory));
  if (!parent.isDirectory() || parent.isSymbolicLink()) throw new Error('Staged runs parent is not an ordinary directory; retained for inspection');
  const files = await readdir(directory, { withFileTypes: true });
  for (const file of files) {
    const match = /^agent\.json\.([0-9]+)\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.tmp$/u.exec(file.name);
    const temporary = match && Number(match[1]) === process.pid;
    if (!file.isFile() || (!['owner.token', 'agent.json'].includes(file.name) && !temporary)) throw new Error('Staged run holds unexpected files; retained for inspection');
    const expected = file.name === 'owner.token' ? token : config && JSON.stringify(config);
    if (!expected) throw new Error('Staged file identity is unconfirmed; retained for inspection');
    const filePath = path.join(directory, file.name);
    const actual = await lstat(filePath);
    if (!actual.isFile() || actual.isSymbolicLink() || actual.size > Buffer.byteLength(expected)) throw new Error('Staged file is not ordinary owned metadata; retained for inspection');
    const bytes = await readFile(filePath);
    if (!Buffer.from(expected).subarray(0, bytes.length).equals(bytes)) throw new Error('Staged metadata was changed; retained for inspection');
  }
  for (const file of files) await unlink(path.join(directory, file.name));
  await rmdir(directory);
}

export class ChildSessionManager {
  #deps;
  #config;
  #state = 'stopped';
  #error;
  #errorCode;
  #runId;
  #token;
  #controlDirectory;
  #runDirectory;
  #owner;
  #identity;
  #agentProcess;
  #keeper;
  #client;
  #unlock;
  #stagedConfig;
  #runtimeInstalled = false;
  #staged = false;
  #stagedDir = false;
  #heartbeat;
  #heartbeatPending = false;
  #queue = Promise.resolve();

  constructor(deps) {
    this.#config = deps.config;
    this.#deps = {
      platform: process.platform, root: dataRoot(), state: childSessionState, createKeeper: () => new RdpKeeper(),
      createClient: (port, token) => new LocalAgentClient(port, token), readJson, optionalJson, writeJson,
      heartbeatMs: 20_000, readyTimeoutMs: 90_000, sleep, acquireLock,
      initialize: config => runPowerShellJson('scripts/child/Initialize-Runtime.ps1', [
        '-RuntimeRoot', config.runtimeRoot, '-PluginRoot', ROOT, '-DriverPath', config.driverPath, '-NodePath', process.execPath,
      ]),
      inspectProcess: pid => runPowerShellJson('scripts/child/Get-AgentProcess.ps1', ['-ProcessId', String(pid)]),
      stopAgent: (root, id, token) => runPowerShellJson('scripts/child/Stop-Agent.ps1', ['-RuntimeRoot', root, '-RunId', id], { input: { token }, timeout: 20_000 }),
      launchAgent: (childSessionId, root, id) => runPowerShellJson('scripts/child/Launch-AgentTask.ps1',
        ['-ChildSessionId', String(childSessionId), '-RuntimeRoot', root, '-RunId', id], { timeout: 60_000 }),
      ...deps,
    };
  }

  #exclusive(action) {
    const result = this.#queue.then(action);
    this.#queue = result.catch(() => {});
    return result;
  }

  summary() {
    return {
      state: this.#state, backend: 'child-session', isolation: 'windows-interactive-session',
      ...(this.#runId ? { runId: this.#runId } : {}),
      ...(this.#identity ? { sessionId: this.#identity.sessionId, parentSessionId: this.#owner.parentSessionId } : {}),
      ...(this.#error ? { error: this.#error } : {}),
      ...(this.#errorCode ? { code: this.#errorCode } : {}),
      ...(this.#unlock && this.#state === 'failed' ? { recovery: 'Controller lock retained until desktop_stop confirms cleanup. Existing Windows sessions are never logged off.' } : {}),
    };
  }

  #failed(error) {
    clearInterval(this.#heartbeat);
    this.#errorCode = error.code;
    this.#state = error.code === 'AUTHENTICATION_REQUIRED' && !this.#unlock ? 'needs-authentication' : 'failed';
    this.#error = safeError(error, [this.#token]);
    return Object.assign(new Error(this.#error), this.#errorCode ? { code: this.#errorCode } : {});
  }

  start({ authentication = 'background', window } = {}) {
    return this.#exclusive(async () => {
      if (!['background', 'interactive'].includes(authentication)) throw new Error('Invalid authentication mode');
      if (window !== undefined && !['visible', 'hidden'].includes(window)) throw new Error('Invalid window mode');
      if (this.#state === 'ready') {
        try { await this.#health(); return this.summary(); }
        catch (error) { throw this.#failed(error); }
      }
      if (this.#unlock) throw new Error('Previous Child Session run needs desktop_stop before restart');
      if (this.#deps.platform !== 'win32') throw new Error('Child Session requires Windows');
      this.#state = 'starting'; this.#error = undefined; this.#errorCode = undefined; this.#runtimeInstalled = false;
      this.#owner = undefined; this.#runId = undefined; this.#controlDirectory = undefined; this.#runDirectory = undefined;
      try {
        this.#unlock = await this.#deps.acquireLock(path.join(this.#deps.root, 'locks'), 'child-session');
        const before = await this.#deps.state();
        const ownerFile = path.join(this.#deps.root, 'child-session.owner.json');
        const plan = connectionPlan(before, await this.#deps.optionalJson(ownerFile));
        const install = await this.#deps.initialize(this.#config);
        if (install.userSid !== before.userSid) throw new Error('Local runtime was installed for a different Windows user');
        this.#runtimeInstalled = true;
        this.#runId = randomBytes(16).toString('hex');
        this.#token = randomBytes(32).toString('hex');
        this.#controlDirectory = path.join(this.#deps.root, 'runs', this.#runId);
        this.#runDirectory = path.join(this.#config.runtimeRoot, 'runs', this.#runId);
        this.#keeper = this.#deps.createKeeper();
        const rdp = await this.#keeper.start({
          mode: 'child-session', authentication, guestRoot: this.#config.runtimeRoot,
          expectedParentSessionId: before.parentSessionId, expectedParentLogonTime: before.parentLogonTime, ...plan,
          rdp: { ...this.#config.rdp, address: 'localhost', port: before.rdpPort },
          window: window ?? this.#config.rdp.window,
        }, this.#controlDirectory);
        const connected = await this.#deps.state();
        if (!Number.isInteger(connected.childSessionId) || connected.childSessionId <= 0 || !generation(connected.childLogonTime) ||
            rdp.childSessionId !== connected.childSessionId || rdp.parentSessionId !== before.parentSessionId ||
            (plan.expectedChildSessionId !== null && (connected.childSessionId !== plan.expectedChildSessionId || connected.childLogonTime !== plan.expectedChildLogonTime))) {
          throw new Error('RDP login did not establish the expected Child Session identity');
        }
        this.#owner = {
          version: 1, machineGuid: before.machineGuid, userSid: before.userSid,
          parentSessionId: before.parentSessionId, parentLogonTime: before.parentLogonTime,
          childSessionId: connected.childSessionId, childLogonTime: connected.childLogonTime,
        };
        assertConnectedChild(connected, this.#owner);
        await this.#deps.writeJson(ownerFile, this.#owner);
        this.#identity = {
          runId: this.#runId, machineGuid: before.machineGuid, userSid: before.userSid,
          sessionId: connected.childSessionId, logonTime: connected.childLogonTime,
        };
        await mkdir(this.#runDirectory);
        this.#stagedDir = true;
        await writeFile(path.join(this.#runDirectory, 'owner.token'), this.#token, { flag: 'wx', mode: 0o600 });
        this.#stagedConfig = {
          version: 1, runId: this.#runId, token: this.#token, expectedMachineGuid: before.machineGuid,
          expectedSessionId: connected.childSessionId, expectedSessionLogonTime: connected.childLogonTime, expectedUserSid: before.userSid,
          driverPath: this.#config.driverPath, readyPath: path.join(this.#runDirectory, 'ready.json'), leaseMs: 180000,
        };
        await this.#deps.writeJson(path.join(this.#runDirectory, 'agent.json'), this.#stagedConfig);
        this.#staged = true;
        await this.#deps.onProgress?.({ phase: 'authenticated', childSessionId: connected.childSessionId });
        // No keyboard input: a temporary session-bound scheduled task starts the staged
        // agent, so a Chinese IME in the child session cannot intercept the bootstrap.
        await this.#keeper.bootstrapTask(this.#runId);
        await this.#deps.launchAgent(connected.childSessionId, this.#config.runtimeRoot, this.#runId);
        const ready = await this.#waitReady();
        assertIdentity(ready, this.#identity);
        this.#agentProcess = await this.#deps.inspectProcess(ready.pid);
        if (this.#agentProcess.pid !== ready.pid || this.#agentProcess.sessionId !== connected.childSessionId ||
            typeof this.#agentProcess.startedAt !== 'string' || !Number.isFinite(Date.parse(this.#agentProcess.startedAt))) {
          throw new Error('Agent PID does not belong to the actual Child Session');
        }
        this.#client = this.#deps.createClient(ready.port, this.#token);
        await this.#health();
        this.#state = 'ready';
        this.#heartbeat = setInterval(() => {
          if (this.#heartbeatPending || this.#state !== 'ready') return;
          this.#heartbeatPending = true;
          this.status().finally(() => { this.#heartbeatPending = false; }).catch(() => {});
        }, this.#deps.heartbeatMs);
        this.#heartbeat.unref();
        return this.summary();
      } catch (error) {
        const message = safeError(error, [this.#token]);
        try { await this.#preserveDiagnostics(message); }
        catch { }
        try { await this.#cleanup(); }
        catch (cleanupError) { throw this.#failed(new Error(`${message} Cleanup: ${safeError(cleanupError, [this.#token])}`)); }
        throw this.#failed(Object.assign(new Error(message), error.code ? { code: error.code } : {}));
      }
    });
  }

  async #preserveDiagnostics(error) {
    if (!this.#runtimeInstalled || !this.#runId) return;
    // Inherit the private runtime ACL. Never copy raw config, owner tokens, logs or authentication screens.
    const target = path.join(this.#config.runtimeRoot, 'diagnostics', this.#runId);
    const status = this.#controlDirectory
      ? await this.#deps.optionalJson(path.join(this.#controlDirectory, 'rdp-status.json')) : undefined;
    const rdp = {};
    for (const key of ['state', 'pid', 'desktop', 'updatedAt', 'parentSessionId', 'childSessionId', 'errorCode', 'bootstrapPhase', 'backgroundReady', 'inputFocusRequired']) {
      if (typeof status?.[key] === 'string' || typeof status?.[key] === 'number' || typeof status?.[key] === 'boolean') rdp[key] = status[key];
    }
    for (const name of ['input', 'inputAtLogon', 'inputBeforeBackground', 'inputAfterBackground']) {
      if (!status?.[name]) continue;
      rdp[name] = {};
      for (const key of ['clientConnected', 'clientStateError', 'formVisible', 'controlVisible', 'threadFocusInControl', 'threadFocusIsInputCapture', 'foregroundIsKeeper', 'inputCapturePresent', 'inputCaptureVisible', 'inputCaptureEnabled']) {
        const value = status[name][key];
        if (typeof value === 'boolean' || typeof value === 'number') rdp[name][key] = value;
      }
    }
    if (status?.error) rdp.error = safeError(status.error, [this.#token]);
    try {
      const reason = (await readFile(path.join(this.#runDirectory, 'bootstrap-error.txt'), 'utf8')).trim();
      if (reason) rdp.bootstrapError = reason.slice(0, 500);
    }
    catch { }
    await this.#deps.writeJson(path.join(target, 'failure.json'), { runId: this.#runId, error: safeError(error, [this.#token]), rdp });
  }

  async #waitReady() {
    const deadline = Date.now() + this.#deps.readyTimeoutMs;
    let lastProgress;
    let lastRdp;
    while (Date.now() < deadline) {
      const rdp = await this.#keeper.status();
      lastRdp = rdp;
      if (rdp.state !== 'connected' || rdp.childSessionId !== this.#identity.sessionId) {
        throw Object.assign(new Error(`Child Session RDP readiness failed during bootstrap: ${JSON.stringify(rdp)}`), rdp.errorCode ? { code: rdp.errorCode } : {});
      }
      const progress = JSON.stringify({ phase: 'bootstrap', step: rdp.bootstrapPhase ?? 'waiting', backgroundReady: rdp.backgroundReady === true, inputFocusRequired: rdp.inputFocusRequired === true });
      if (progress !== lastProgress) {
        await this.#deps.onProgress?.(JSON.parse(progress));
        lastProgress = progress;
      }
      const ready = await this.#deps.optionalJson(path.join(this.#runDirectory, 'ready.json'));
      if (ready) {
        if (!Number.isInteger(ready.pid) || ready.pid <= 0 || !Number.isInteger(ready.port) || ready.port < 1024 || ready.port > 65535) throw new Error('Invalid child agent readiness descriptor');
        if (rdp.backgroundReady === true) return ready;
      }
      try {
        await access(path.join(this.#runDirectory, 'bootstrap-error.txt'));
        const reason = await readFile(path.join(this.#runDirectory, 'bootstrap-error.txt'), 'utf8');
        throw new Error(`Child agent bootstrap failed: ${reason.trim().slice(0, 400)}`);
      }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      await this.#deps.sleep(200);
    }
    if (lastRdp?.bootstrapPhase === 'waiting-input-focus') {
      throw Object.assign(new Error('Interactive agent preparation timed out waiting for RDP input focus. On the next explicit interactive start, click the preparation window title bar and keep it focused until it hides. No bootstrap keys were sent; host focus was not changed.'), { code: 'RDP_INPUT_FOCUS_REQUIRED' });
    }
    throw new Error('Child agent did not become ready. Check Explorer, the Run dialog policy, keyboard layout and driver installation; host input was not used.');
  }

  async #verifySession() {
    const rdp = await this.#keeper.status();
    if (rdp.state !== 'connected' || rdp.childSessionId !== this.#identity.sessionId || rdp.parentSessionId !== this.#owner.parentSessionId || rdp.backgroundReady !== true) throw new Error('Owned Child Session RDP connection is no longer active');
    assertConnectedChild(await this.#deps.state(), this.#owner);
  }

  async #health() {
    await this.#verifySession();
    const process = await this.#deps.inspectProcess(this.#agentProcess.pid);
    if (process.pid !== this.#agentProcess.pid || process.sessionId !== this.#identity.sessionId || process.startedAt !== this.#agentProcess.startedAt) throw new Error('Child agent process exited or its PID was reused');
    const health = await this.#client.request('health', {}, 20_000);
    assertIdentity(health, this.#identity);
    if (health.pid !== this.#agentProcess.pid || health.protocol !== 2 || health.state !== 0 || health.inputDesktop !== 'Default' || health.driverConnected !== true) {
      throw new Error('Child agent is not ready in the verified interactive session');
    }
    return health;
  }

  status() {
    return this.#exclusive(async () => {
      if (this.#state === 'ready') {
        try { await this.#health(); }
        catch (error) { this.#failed(error); }
      }
      return this.summary();
    });
  }

  request(operation, payload = {}) {
    return this.#exclusive(async () => {
      if (this.#state !== 'ready') throw new Error('Child Session is not ready; call desktop_start or clean up with desktop_stop');
      if (!['listTools', 'callTool', 'listResources', 'readResource'].includes(operation)) throw new Error('Unsupported desktop operation');
      try {
        await this.#health();
        return await this.#client.request(operation, payload);
      } catch (error) {
        if (error.code === 'DRIVER_ERROR') throw new Error(safeError(error, [this.#token]));
        throw this.#failed(new Error(`${safeError(error, [this.#token])} No automatic input replay was attempted.`));
      }
    });
  }

  async #cleanup() {
    clearInterval(this.#heartbeat);
    await this.#keeper?.stop();
    if (this.#stagedDir) {
      if (!this.#staged) {
        // The bootstrap has not been sent. Delete only ordinary files containing our own staging bytes.
        await removePartialStage(this.#runDirectory, this.#token, this.#stagedConfig);
        this.#stagedDir = false;
      }
      else {
        try { await this.#client?.request('shutdown', {}, 5000); } catch { }
        const result = await this.#deps.stopAgent(this.#config.runtimeRoot, this.#runId, this.#token);
        if (result?.stopped !== true || result?.retained === true) throw new Error('Child agent cleanup is unconfirmed; controller lock and run files were retained');
        this.#staged = false;
        this.#stagedDir = false;
      }
    }
    if (this.#controlDirectory) await rm(this.#controlDirectory, { recursive: true, force: true });
    await this.#unlock?.();
    this.#unlock = undefined; this.#keeper = undefined; this.#client = undefined;
    this.#stagedConfig = undefined;
    this.#token = undefined; this.#identity = undefined; this.#agentProcess = undefined;
  }

  stop() {
    return this.#exclusive(async () => {
      try {
        const childSessionId = this.#owner?.childSessionId;
        await this.#cleanup();
        this.#state = 'stopped'; this.#error = undefined; this.#errorCode = undefined; this.#runId = undefined;
        return { ...this.summary(), childSessionId, childSessionAndApplications: 'not logged off; only the owned agent and RDP connection were stopped' };
      } catch (error) { throw this.#failed(error); }
    });
  }

  dispose() { return this.stop(); }
}
