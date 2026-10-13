import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';

const OPERATIONS = new Set(['health', 'listTools', 'callTool', 'listResources', 'readResource', 'shutdown']);

export function assertInteractive(actual, expected) {
  if (String(actual.machineGuid).toLowerCase() !== expected.expectedMachineGuid.toLowerCase() ||
      actual.sessionId !== expected.expectedSessionId || actual.sessionId <= 0 ||
      actual.userSid !== expected.expectedUserSid || actual.protocol !== 2 || actual.state !== 0 || actual.inputDesktop !== 'Default' ||
      (expected.expectedSessionLogonTime !== undefined && actual.logonTime !== expected.expectedSessionLogonTime)) {
    throw Object.assign(new Error('The agent must remain in its pinned, active, unlocked RDP session (never console or Session 0)'), { code: 'ISOLATION_LOST' });
  }
}

function authenticated(header, token) {
  const received = Buffer.from(typeof header === 'string' ? header : '');
  const expected = Buffer.from(`Bearer ${token}`);
  return received.length === expected.length && timingSafeEqual(received, expected);
}

async function readBody(request) {
  let length = 0;
  const chunks = [];
  for await (const chunk of request) {
    length += chunk.length;
    if (length > 2 * 1024 * 1024) throw new Error('Request exceeds 2 MiB');
    chunks.push(chunk);
  }
  const result = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
  if (!result || typeof result !== 'object' || Array.isArray(result)) throw new Error('Payload must be an object');
  return result;
}

export async function createGuestService({ config, identity, driver, onClose = () => {}, now = Date.now, shouldStop = async () => false }) {
  const initial = await identity();
  assertInteractive(initial, config);
  let lastRequest = now();
  let closing;
  let queue = Promise.resolve();
  let pending = 0;
  const server = http.createServer(async (request, response) => {
    const send = (status, body) => {
      if (response.destroyed || response.writableEnded) return;
      response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
      response.end(JSON.stringify(body));
    };
    if (!authenticated(request.headers.authorization, config.token) || request.headers.origin !== undefined) {
      send(403, { error: { message: 'Forbidden' } }); request.resume(); return;
    }
    if (request.headers.host !== `127.0.0.1:${server.address()?.port}` || request.method !== 'POST') {
      send(400, { error: { message: 'Loopback POST required' } }); request.resume(); return;
    }
    const operation = request.url?.slice(1);
    if (!OPERATIONS.has(operation)) { send(404, { error: { message: 'Unknown operation' } }); request.resume(); return; }
    if (closing) { send(503, { error: { message: 'Agent is stopping' } }); request.resume(); return; }
    if (pending >= 8) { send(429, { error: { message: 'Agent queue full; input was not accepted' } }); request.resume(); return; }
    pending++;
    try {
      const payload = await readBody(request);
      lastRequest = now();
      if (operation === 'shutdown') {
        send(200, { result: { stopped: true } });
        setImmediate(() => { close().catch(() => {}); });
        return;
      }
      const work = queue.then(async () => {
        if (closing) throw new Error('Agent is stopping');
        if (request.aborted || response.destroyed) throw new Error('Request was cancelled before execution');
        const actual = await identity();
        assertInteractive(actual, config);
        if (operation === 'health') return { ...actual, runId: config.runId, pid: process.pid, driverConnected: driver.connected !== false };
        if (driver.connected === false) throw Object.assign(new Error('cua-driver exited; refusing automatic restart'), { code: 'DRIVER_UNAVAILABLE' });
        try {
          switch (operation) {
            case 'listTools': return await driver.listTools(payload);
            case 'listResources': return await driver.listResources(payload);
            case 'readResource': {
              if (typeof payload.uri !== 'string' || payload.uri.length > 4096) throw new Error('A resource URI is required');
              return await driver.readResource({ uri: payload.uri });
            }
            case 'callTool': {
              if (typeof payload.name !== 'string' || !/^[a-zA-Z0-9_.-]{1,128}$/u.test(payload.name)) throw new Error('Invalid driver tool name');
              if (!payload.arguments || typeof payload.arguments !== 'object' || Array.isArray(payload.arguments)) throw new Error('Tool arguments must be an object');
              return await driver.callTool({ name: payload.name, arguments: payload.arguments });
            }
          }
        } catch (error) {
          const unavailable = driver.connected === false || error.code === -32000 || error.code === -32001;
          throw Object.assign(new Error(error.message || 'Driver operation failed'), { code: unavailable ? 'DRIVER_UNAVAILABLE' : 'DRIVER_ERROR' });
        }
      });
      queue = work.catch(() => {});
      const result = await work;
      send(200, { result });
    } catch (error) {
      const message = String(error.message || 'Guest operation failed').split(config.token).join('[redacted]').slice(0, 2000);
      send(200, { error: { message, code: error.code || 'GUEST_FAILURE' } });
    } finally { pending--; }
  });
  server.requestTimeout = 15_000;
  server.headersTimeout = 10_000;
  server.maxHeadersCount = 30;
  server.on('clientError', (_error, socket) => socket.destroy());
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  let checkingStop = false;
  const timer = setInterval(async () => {
    if (checkingStop || closing) return;
    checkingStop = true;
    try {
      if (now() - lastRequest > config.leaseMs || await shouldStop()) await close();
    } catch { await close().catch(() => {}); }
    finally { checkingStop = false; }
  }, Math.min(1000, config.leaseMs));
  timer.unref();

  function close() {
    if (closing) return closing;
    closing = (async () => {
      clearInterval(timer);
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
      await driver.close();
      await onClose();
    })();
    return closing;
  }
  return { port: server.address().port, initial, close };
}
