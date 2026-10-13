import { spawn } from 'node:child_process';
import { writeFile, access } from 'node:fs/promises';
import path from 'node:path';
import { powershellPath, readJson, writeJson, sleep, safeError } from './util.mjs';
import { ROOT } from './location.mjs';

// The keeper atomically replaces its status file every second; a read can collide with the replace instant.
export async function readStatusJson(file, read = readJson, wait = sleep) {
  for (let attempt = 0; ; attempt++) {
    try { return await read(file); }
    catch (error) {
      if (['ENOENT', 'EBUSY', 'EPERM'].includes(error.code) && attempt < 4) { await wait(40); continue; }
      throw error;
    }
  }
}

export class RdpKeeper {
  #deps;
  #observedConnected = false;

  constructor(deps = {}) {
    this.#deps = { spawn, readJson, sleep, now: Date.now, ...deps };
  }
  #process;
  #exit;
  #diagnostic = '';
  #statusPath;
  #stopPath;
  #bootstrapPath;

  async start(config, runDirectory) {
    this.#statusPath = path.join(runDirectory, 'rdp-status.json');
    this.#stopPath = path.join(runDirectory, 'rdp.stop');
    this.#bootstrapPath = path.join(runDirectory, 'bootstrap.json');
    const requestPath = path.join(runDirectory, 'rdp-request.json');
    const script = path.join(ROOT, 'native', 'Start-RdpKeeper.ps1');
    await access(script);
    const child = config.mode === 'child-session' || config.backend === 'child-session';
    const connection = child ? {
      mode: 'child-session', authentication: config.authentication ?? 'background', expectedParentSessionId: config.expectedParentSessionId,
      expectedParentLogonTime: config.expectedParentLogonTime,
      expectedChildSessionId: config.expectedChildSessionId ?? null,
      expectedChildLogonTime: config.expectedChildLogonTime ?? null,
    } : { credentialPath: config.credentialPath };
    await writeJson(requestPath, {
      ...config.rdp, ...connection, guestRoot: config.guestRoot, statusPath: this.#statusPath,
      stopPath: this.#stopPath, bootstrapPath: this.#bootstrapPath,
    });
    this.#process = this.#deps.spawn(powershellPath(), ['-NoLogo', '-NoProfile', '-NonInteractive', '-File', script,
      '-RequestPath', requestPath, '-ParentPid', String(process.pid)], { windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] });
    this.#process.stderr.setEncoding('utf8');
    this.#process.stderr.on('data', chunk => { this.#diagnostic = (this.#diagnostic + chunk).slice(-2000); });
    this.#process.once('error', error => { this.#exit = error.message; });
    this.#process.once('exit', code => { this.#exit = `RDP keeper exited (${code ?? 'signal'})`; });
    const deadline = this.#deps.now() + (child ? (config.authentication === 'interactive' ? 330_000 : 50_000) : 150_000);
    while (this.#deps.now() < deadline) {
      const status = await this.status();
      if (status.state === 'connected') return status;
      if (status.state === 'failed' || status.state === 'stopped') throw Object.assign(new Error(status.error || `RDP keeper ${status.state}`), status.errorCode ? { code: status.errorCode } : {});
      await this.#deps.sleep(250);
    }
    throw new Error(child
      ? 'Child Session login timed out. Check native Child Session availability and the RDP keeper diagnostic. No host-desktop fallback was attempted.'
      : 'RDP login timed out. Check the VM address, NLA credentials, trusted certificate and guest session. No certificate checks were bypassed.');
  }

  async status() {
    const exitStatus = () => ({ state: 'failed', error: safeError(`${this.#exit}${this.#diagnostic ? `: ${this.#diagnostic.trim()}` : ''}`) });
    if (!this.#statusPath) return this.#exit ? exitStatus() : { state: 'stopped' };
    try {
      const status = await readStatusJson(this.#statusPath, this.#deps.readJson, this.#deps.sleep);
      if (status.state === 'failed') return { ...status, error: safeError(`${status.error || 'RDP failed'}${this.#diagnostic ? `: ${this.#diagnostic.trim()}` : ''}`) };
      if (this.#exit) return exitStatus();
      const updatedAt = Date.parse(status.updatedAt);
      if (status.state === 'connected' && (!Number.isFinite(updatedAt) || this.#deps.now() - updatedAt > 10_000)) {
        return { state: 'failed', error: 'RDP keeper heartbeat is stale' };
      }
      if (status.state === 'connected') this.#observedConnected = true;
      return status;
    }
    catch (error) {
      if (error.code === 'ENOENT') return this.#exit
        ? exitStatus()
        : this.#observedConnected
          ? { state: 'failed', error: 'RDP keeper status is unavailable after connection' }
          : { state: 'connecting', missing: true };
      throw error;
    }
  }

  async bootstrap(id, command) {
    const status = await this.status();
    if (status.state !== 'connected') throw new Error('RDP connection is not ready for guest bootstrap');
    await writeJson(this.#bootstrapPath, { id, command });
  }

  // Child Session backend: the controller launches the staged agent with a temporary
  // session-bound scheduled task; the keeper only watches for the startup marker.
  async bootstrapTask(id) {
    if (!/^[a-f0-9]{32}$/u.test(id)) throw new Error('Invalid runId');
    const status = await this.status();
    if (status.state !== 'connected') throw new Error('RDP connection is not ready for guest bootstrap');
    await writeJson(this.#bootstrapPath, { id, launch: 'task' });
  }

  async stop() {
    if (!this.#process || this.#exit) return;
    await writeFile(this.#stopPath, 'stop', { mode: 0o600 });
    const deadline = this.#deps.now() + 6000;
    while (!this.#exit && this.#deps.now() < deadline) await this.#deps.sleep(100);
    if (!this.#exit) {
      this.#process.kill();
      const killDeadline = this.#deps.now() + 3000;
      while (!this.#exit && this.#deps.now() < killDeadline) await this.#deps.sleep(100);
      if (!this.#exit) throw new Error('RDP keeper termination is unconfirmed');
    }
  }
}
