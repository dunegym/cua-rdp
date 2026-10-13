import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { rm } from 'node:fs/promises';
import { loadConfig, verifyAddress, bootstrapCommand } from './config.mjs';
import { acquireLock } from './lock.mjs';
import { Broker } from './broker.mjs';
import { RdpKeeper } from './rdp.mjs';
import { configPath, dataRoot, safeError } from './util.mjs';

import { assertIdentity, unwrapGuest as unwrap } from './protocol.mjs';

export class HyperVDesktopManager {
  #state = 'stopped';
  #error;
  #config;
  #runId;
  #token;
  #directory;
  #broker;
  #keeper;
  #unlock;
  #staged = false;
  #identity;
  #queue = Promise.resolve();
  #heartbeat;
  #heartbeatPending = false;
  #deps;

  constructor(deps = {}) {
    this.#deps = {
      platform: process.platform, file: configPath(), root: dataRoot(), loadConfig,
      acquireLock, verifyAddress, createBroker: file => new Broker(file),
      createKeeper: () => new RdpKeeper(), heartbeatMs: 20_000, ...deps,
    };
  }

  #exclusive(action) {
    const result = this.#queue.then(action);
    this.#queue = result.catch(() => {});
    return result;
  }

  summary() {
    return {
      state: this.#state, ...(this.#runId ? { runId: this.#runId } : {}),
      ...(this.#config ? { vmId: this.#config.vmId } : {}),
      ...(this.#identity ? { sessionId: this.#identity.sessionId, isolation: 'hyper-v-rdp' } : {}),
      ...(this.#error ? { error: this.#error } : {}),
      ...(this.#unlock && this.#state === 'failed' ? { recovery: 'Lock retained until desktop_stop confirms guest cleanup; see README troubleshooting.' } : {}),
    };
  }

  start() {
    return this.#exclusive(async () => {
      if (this.#state === 'ready') { await this.#health(); return this.summary(); }
      if (this.#unlock) throw new Error('Previous run needs desktop_stop before another start');
      if (this.#deps.platform !== 'win32') throw new Error('The host requires Windows with local Hyper-V');
      this.#state = 'starting';
      this.#error = undefined;
      try {
        this.#config = await this.#deps.loadConfig(this.#deps.file);
        this.#unlock = await this.#deps.acquireLock(path.join(this.#deps.root, 'locks'), this.#config.vmId);
        this.#runId = randomBytes(16).toString('hex');
        this.#token = randomBytes(32).toString('hex');
        this.#directory = path.join(this.#deps.root, 'runs', this.#runId);
        this.#broker = this.#deps.createBroker(this.#deps.file);
        const facts = await this.#broker.request('prepare');
        if (String(facts.guestMachineGuid).toLowerCase() !== this.#config.guestMachineGuid ||
            String(facts.hostMachineGuid).toLowerCase() === this.#config.guestMachineGuid) {
          throw new Error('Pinned guest identity mismatch, or target is the host');
        }
        await this.#deps.verifyAddress(this.#config.rdp.address, facts.addresses);
        this.#keeper = this.#deps.createKeeper();
        await this.#keeper.start(this.#config, this.#directory);
        // A lost stage reply can still have created files; cleanup owns the run from this point.
        this.#staged = true;
        const session = await this.#broker.request('stage', { runId: this.#runId, token: this.#token });
        this.#identity = { runId: this.#runId, machineGuid: this.#config.guestMachineGuid, sessionId: session.sessionId, userSid: session.userSid };
        assertIdentity({ ...session, runId: this.#runId }, this.#identity);
        await this.#keeper.bootstrap(this.#runId, bootstrapCommand(this.#config.guestRoot, this.#runId));
        const ready = await this.#broker.request('attach', { runId: this.#runId }, 45_000);
        assertIdentity(ready, this.#identity);
        await this.#health();
        this.#state = 'ready';
        this.#heartbeat = setInterval(() => {
          if (this.#heartbeatPending || this.#state !== 'ready') return;
          this.#heartbeatPending = true;
          this.status().catch(() => {}).finally(() => { this.#heartbeatPending = false; });
        }, this.#deps.heartbeatMs);
        this.#heartbeat.unref();
        return this.summary();
      } catch (error) {
        this.#error = safeError(error, [this.#token]);
        try { await this.#cleanup(); }
        catch (cleanupError) { this.#error += ` Cleanup: ${safeError(cleanupError, [this.#token])}`; }
        this.#state = 'failed';
        throw new Error(this.#error);
      }
    });
  }

  async #health() {
    const status = await this.#keeper.status();
    if (status.state !== 'connected') throw new Error('Background RDP disconnected. No desktop operations will be sent.');
    const health = unwrap(await this.#broker.request('request', { runId: this.#runId, operation: 'health', payloadJson: '{}' }, 30_000));
    assertIdentity(health, this.#identity);
    if (health.driverConnected === false) throw new Error('Guest cua-driver is no longer connected');
    if (health.protocol !== 2 || health.state !== 0 || health.inputDesktop !== 'Default') throw new Error('Guest is not an active, unlocked RDP desktop');
    return health;
  }

  status() {
    return this.#exclusive(async () => {
      if (this.#state === 'ready') {
        try { await this.#health(); }
        catch (error) { this.#state = 'failed'; this.#error = safeError(error, [this.#token]); clearInterval(this.#heartbeat); }
      }
      return this.summary();
    });
  }

  request(operation, payload = {}) {
    return this.#exclusive(async () => {
      if (this.#state !== 'ready') throw new Error('Desktop is not ready. Call desktop_start, or desktop_stop to clean up a failed run.');
      if (!['listTools', 'callTool', 'listResources', 'readResource'].includes(operation)) throw new Error('Unsupported guest operation');
      try {
        const status = await this.#keeper.status();
        if (status.state !== 'connected') throw new Error('RDP disconnected; input was not sent');
        return unwrap(await this.#broker.request('request', { runId: this.#runId, operation, payloadJson: JSON.stringify(payload) }, 360_000));
      } catch (error) {
        if (error.code === 'DRIVER_ERROR') throw new Error(safeError(error, [this.#token]));
        this.#error = safeError(error, [this.#token]);
        this.#state = 'failed';
        clearInterval(this.#heartbeat);
        throw new Error(`${this.#error} No automatic replay was attempted.`);
      }
    });
  }

  async #cleanup() {
    clearInterval(this.#heartbeat);
    const errors = [];
    let guestStopped = !this.#staged;
    try { await this.#keeper?.stop(); } catch (error) { errors.push(error); }
    if (!errors.length && this.#staged && this.#broker) {
      try {
        const result = await this.#broker.request('stop', { runId: this.#runId }, 30_000);
        if (result?.stopped !== true || result?.retained === true) throw new Error('Guest cleanup is not confirmed; the VM lock and run files were retained');
        guestStopped = true; this.#staged = false;
      } catch (error) { errors.push(error); }
    }
    if (guestStopped) {
      try { await this.#broker?.close(); } catch (error) { errors.push(error); }
      if (!errors.length) {
        if (this.#directory) await rm(this.#directory, { recursive: true, force: true });
        await this.#unlock?.();
        this.#unlock = undefined;
        this.#identity = undefined;
        this.#token = undefined;
        this.#broker = undefined;
        this.#keeper = undefined;
      }
    }
    if (errors.length) throw new Error(errors.map(error => safeError(error, [this.#token])).join('; '));
  }

  async dispose() {
    try { return await this.stop(); }
    finally { await this.#broker?.close(); }
  }

  stop() {
    return this.#exclusive(async () => {
      try {
        await this.#cleanup();
        this.#state = 'stopped'; this.#error = undefined; this.#runId = undefined;
        return { ...this.summary(), guestVmAndApplications: 'left running; no logoff or VM shutdown' };
      } catch (error) {
        this.#state = 'failed'; this.#error = safeError(error, [this.#token]);
        throw new Error(this.#error);
      }
    });
  }
}
