import { spawn } from 'node:child_process';
import { powershellPath, safeError } from './util.mjs';
import { ROOT } from './location.mjs';
import path from 'node:path';

export class Broker {
  #child;
  #nextId = 0;
  #pending = new Map();
  #buffer = '';
  #closed = false;
  #queue = Promise.resolve();

  constructor(file, { spawnProcess = spawn } = {}) {
    this.#child = spawnProcess(powershellPath(), [
      '-NoLogo', '-NoProfile', '-NonInteractive', '-File', path.join(ROOT, 'scripts', 'Broker.ps1'),
      '-ConfigPath', file, '-OwnerPid', String(process.pid),
    ], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    this.#child.stdout.setEncoding('utf8');
    this.#child.stdin.on('error', () => this.#fail(new Error('Windows broker input closed')));
    this.#child.stdout.on('error', () => this.#fail(new Error('Windows broker output closed')));
    this.#child.stdout.on('data', chunk => this.#receive(chunk));
    // Broker stderr may contain PowerShell's serialized arguments; it is intentionally not forwarded.
    this.#child.stderr.resume();
    this.#child.on('error', error => this.#fail(new Error(`Could not start the Windows broker: ${safeError(error)}`)));
    this.#child.on('exit', code => this.#fail(new Error(`Windows broker exited (${code ?? 'signal'}). Check Hyper-V permission and saved credentials.`)));
  }

  #fail(error) {
    this.#closed = true;
    for (const pending of this.#pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.#pending.clear();
  }

  #receive(chunk) {
    this.#buffer += chunk;
    if (this.#buffer.length > 64 * 1024 * 1024) {
      this.#fail(new Error('Broker response exceeds 64 MiB'));
      this.#child.kill();
      return;
    }
    let newline;
    while ((newline = this.#buffer.indexOf('\n')) >= 0) {
      const line = this.#buffer.slice(0, newline).replace(/^﻿/u, '').trim();
      this.#buffer = this.#buffer.slice(newline + 1);
      if (!line) continue;
      let message;
      try { message = JSON.parse(line); }
      catch { this.#fail(new Error('Broker emitted invalid JSON; operation was not retried')); this.#child.kill(); return; }
      const pending = this.#pending.get(message.id);
      if (!pending) continue;
      this.#pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) pending.reject(new Error(message.error.message || 'Windows broker failed'));
      else pending.resolve(message.result);
    }
  }

  request(method, params = {}, timeout = 150_000) {
    const run = () => new Promise((resolve, reject) => {
      if (this.#closed) { reject(new Error('Windows broker is closed')); return; }
      const id = ++this.#nextId;
      const timer = setTimeout(() => {
        this.#fail(new Error(`Broker ${method} timed out; outcome is unknown. The action was not retried.`));
        this.#child.kill();
      }, timeout);
      this.#pending.set(id, { resolve, reject, timer });
      this.#child.stdin.write(`${JSON.stringify({ id, method, params })}\n`, error => {
        if (error) this.#fail(new Error('Windows broker input closed'));
      });
    });
    const result = this.#queue.then(run);
    this.#queue = result.catch(() => {});
    return result;
  }

  async close() {
    if (this.#closed) return;
    this.#child.stdin.end();
    await new Promise(resolve => {
      const timer = setTimeout(() => { this.#child.kill(); resolve(); }, 5000);
      this.#child.once('exit', () => { clearTimeout(timer); resolve(); });
    });
    this.#fail(new Error('Broker closed'));
  }
}
