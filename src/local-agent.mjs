import { unwrapGuest } from './protocol.mjs';

const OPERATIONS = new Set(['health', 'listTools', 'callTool', 'listResources', 'readResource', 'shutdown']);

export class LocalAgentClient {
  #url;
  #token;
  #fetch;

  constructor(port, token, fetchImpl = fetch) {
    if (!Number.isInteger(port) || port < 1024 || port > 65535 || !/^[a-f0-9]{64}$/u.test(token)) throw new Error('Invalid local agent endpoint');
    this.#url = `http://127.0.0.1:${port}`;
    this.#token = token;
    this.#fetch = fetchImpl;
  }

  async request(operation, payload = {}, timeout = 120_000) {
    if (!OPERATIONS.has(operation)) throw new Error('Unsupported local agent operation');
    const body = JSON.stringify(payload);
    if (Buffer.byteLength(body) > 2 * 1024 * 1024) throw Object.assign(new Error('Desktop request exceeds 2 MiB; it was not sent'), { code: 'DRIVER_ERROR' });
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeout);
    try {
      const response = await this.#fetch(`${this.#url}/${operation}`, {
        method: 'POST', redirect: 'error', headers: { authorization: `Bearer ${this.#token}`, 'content-type': 'application/json' },
        body, signal: controller.signal,
      });
      if (response.status !== 200 || !response.body) throw new Error(`Local agent rejected the request (HTTP ${response.status})`);
      const reader = response.body.getReader();
      const chunks = [];
      let bytes = 0;
      try {
        while (true) {
          const chunk = await reader.read();
          if (chunk.done) break;
          bytes += chunk.value.length;
          if (bytes > 64 * 1024 * 1024) { controller.abort(); throw new Error('Desktop response exceeds 64 MiB'); }
          chunks.push(Buffer.from(chunk.value));
        }
      } finally { reader.releaseLock(); }
      return unwrapGuest(JSON.parse(Buffer.concat(chunks).toString('utf8')));
    } catch (error) {
      if (controller.signal.aborted) throw new Error('Desktop request timed out or exceeded its limit; outcome may be unknown. It was not replayed.');
      throw error;
    } finally { clearTimeout(timer); }
  }
}
