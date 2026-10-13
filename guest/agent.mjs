import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import path from 'node:path';
import { rm, access } from 'node:fs/promises';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { createGuestService, assertInteractive } from './service.mjs';
import { readJson, writeJson, powershellPath, object, text, integer, safeError } from '../src/util.mjs';

const run = promisify(execFile);
const configFile = process.argv[2] === '--config' ? process.argv[3] : undefined;
let client;
let service;
let config;

async function main() {
  if (process.platform !== 'win32') throw new Error('The guest agent requires Windows');
  if (!configFile || !path.isAbsolute(configFile)) throw new Error('Usage: guest-agent.cjs --config <absolute agent.json>');
  config = object(await readJson(configFile), 'agent config');
  if (config.version !== 1 || !/^[a-f0-9]{32}$/u.test(config.runId) || !/^[a-f0-9]{64}$/u.test(config.token)) throw new Error('Invalid agent config');
  integer(config.expectedSessionId, 'expectedSessionId', 1, 0x7fffffff);
  if (config.expectedSessionLogonTime !== undefined && (typeof config.expectedSessionLogonTime !== 'string' || !/^[1-9][0-9]{0,19}$/u.test(config.expectedSessionLogonTime))) throw new Error('Invalid expectedSessionLogonTime');
  integer(config.leaseMs, 'leaseMs', 10_000, 180_000);
  text(config.expectedMachineGuid, 'expectedMachineGuid');
  text(config.expectedUserSid, 'expectedUserSid');
  text(config.driverPath, 'driverPath');
  if (!path.isAbsolute(config.driverPath) || !/\.exe$/iu.test(config.driverPath)) throw new Error('driverPath must be an absolute executable path');
  const readyPath = path.join(path.dirname(configFile), 'ready.json');
  const shouldStop = async () => {
    try { await access(path.join(path.dirname(configFile), 'stop.requested')); return true; }
    catch (error) { if (error.code === 'ENOENT') return false; throw error; }
  };
  if (await shouldStop()) throw new Error('Run was stopped before guest startup');
  if (path.resolve(config.readyPath) !== readyPath) throw new Error('readyPath must be in this run directory');
  const guestRoot = path.resolve(path.dirname(configFile), '..', '..');
  const identity = async () => {
    const { stdout } = await run(powershellPath(), ['-NoLogo', '-NoProfile', '-NonInteractive', '-File', path.join(guestRoot, 'Get-InteractiveState.ps1')],
      { timeout: 10_000, maxBuffer: 64 * 1024, windowsHide: true, encoding: 'utf8' });
    return JSON.parse(stdout.trim().replace(/^﻿/u, ''));
  };
  assertInteractive(await identity(), config);
  const env = {};
  const allowed = new Set(['path', 'systemroot', 'windir', 'systemdrive', 'userprofile', 'localappdata', 'appdata', 'programdata',
    'temp', 'tmp', 'homedrive', 'homepath', 'username', 'userdomain', 'programfiles', 'programfiles(x86)', 'commonprogramfiles']);
  for (const [key, value] of Object.entries(process.env)) if (allowed.has(key.toLowerCase())) env[key] = value;
  env.CUA_DRIVER_PERMISSION_MODE = 'standard';
  const transport = new StdioClientTransport({ command: config.driverPath, args: ['mcp', '--direct'], env,
    cwd: path.dirname(config.driverPath), stderr: 'pipe' });
  // Driver diagnostics may include page contents. Do not copy them into host-facing logs.
  transport.stderr?.resume();
  client = new Client({ name: 'cua-rdp-guest', version: '0.3.1' }, { capabilities: {} });
  let connected = false;
  client.onclose = () => { connected = false; };
  await client.connect(transport, { timeout: 20_000 });
  connected = true;
  const driver = {
    get connected() { return connected; },
    listTools: params => client.listTools(params, { timeout: 30_000 }),
    listResources: params => client.listResources(params, { timeout: 30_000 }),
    readResource: params => client.readResource(params, { timeout: 30_000 }),
    callTool: params => client.callTool(params, undefined, { timeout: 110_000, maxTotalTimeout: 110_000 }),
    close: () => client.close(),
  };
  if (await shouldStop()) throw new Error('Run was stopped while the driver was starting');
  service = await createGuestService({ config, identity, driver, shouldStop,
    onClose: () => rm(readyPath, { force: true }) });
  await writeJson(readyPath, { runId: config.runId, port: service.port, pid: process.pid,
    sessionId: service.initial.sessionId, machineGuid: service.initial.machineGuid, userSid: service.initial.userSid,
    logonTime: service.initial.logonTime });
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => { service.close().catch(() => {}); });
}

main().catch(async error => {
  process.stderr.write(`${safeError(error, [config?.token])}\n`);
  await service?.close().catch(() => {});
  await client?.close().catch(() => {});
  process.exitCode = 1;
});
