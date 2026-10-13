import { loadConfig } from './config.mjs';
import { configPath, safeError } from './util.mjs';
import { HyperVDesktopManager } from './manager.mjs';
import { ChildSessionManager } from './child-session.mjs';

export class DesktopManager {
  #implementation;
  #backend;
  #state = 'stopped';
  #error;
  #queue = Promise.resolve();
  #deps;

  constructor(deps = {}) {
    this.#deps = { file: configPath(), loadConfig, ...deps };
  }

  #exclusive(action) {
    const result = this.#queue.then(action);
    this.#queue = result.catch(() => {});
    return result;
  }

  summary() {
    if (this.#implementation) return { ...this.#implementation.summary(), backend: this.#backend };
    return { state: this.#state, ...(this.#error ? { error: this.#error } : {}) };
  }

  start({ authentication = 'background' } = {}) {
    return this.#exclusive(async () => {
      try {
        if (!['background', 'interactive'].includes(authentication)) throw new Error('Invalid authentication mode');
        if (!this.#implementation) {
          const config = await this.#deps.loadConfig(this.#deps.file);
          this.#backend = config.backend ?? (config.vmId ? 'hyperv' : 'child-session');
          const options = { ...this.#deps, config, loadConfig: async () => config };
          this.#implementation = this.#deps.createBackend
            ? this.#deps.createBackend(this.#backend, options)
            : this.#backend === 'hyperv' ? new HyperVDesktopManager(options) : new ChildSessionManager(options);
        }
        if (authentication === 'interactive' && this.#backend !== 'child-session') throw new Error('Interactive authentication is only supported for Child Session');
        await this.#implementation.start({ authentication });
        return this.summary();
      } catch (error) {
        this.#state = 'failed'; this.#error = safeError(error);
        throw error;
      }
    });
  }

  status() {
    return this.#exclusive(async () => {
      await this.#implementation?.status();
      return this.summary();
    });
  }

  request(operation, payload) {
    return this.#exclusive(async () => {
      if (!this.#implementation) throw new Error('Desktop is not ready. Call desktop_start first.');
      return this.#implementation.request(operation, payload);
    });
  }

  stop() {
    return this.#exclusive(async () => {
      const result = await this.#implementation?.stop();
      this.#implementation = undefined;
      this.#state = 'stopped'; this.#error = undefined;
      return result ? { ...result, backend: this.#backend } : this.summary();
    });
  }

  dispose() {
    return this.#exclusive(async () => { await this.#implementation?.dispose(); });
  }
}
