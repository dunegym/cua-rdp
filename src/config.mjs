import path from 'node:path';
import dns from 'node:dns/promises';
import os from 'node:os';
import net from 'node:net';
import { object, text, integer, readJson, configPath, dataRoot } from './util.mjs';

const GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;

export function validateRuntimeRoot(value, label = 'runtimeRoot') {
  text(value, label, 160);
  const components = value.slice(3).replace(/\\$/u, '').split('\\');
  if (!/^[A-Za-z]:\\[A-Za-z0-9._\\-]+$/u.test(value) || components.some(p => !p || p === '..' || p === '.' || /[.]$/u.test(p) || /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/iu.test(p))) {
    throw new Error(`${label} must be a safe absolute Windows directory (ASCII letters, digits, _, -, .; spaces are not typeable through the IME-safe keyboard bootstrap)`);
  }
  return value.replace(/\\$/u, '');
}

export function defaultChildConfig(env = process.env) {
  const local = env.LOCALAPPDATA || path.win32.join(os.homedir(), 'AppData', 'Local');
  return validateConfig({
    version: 2, backend: 'child-session',
    driverPath: env.CUA_RDP_DRIVER || path.win32.join(local, 'Programs', 'Cua', 'cua-driver', 'bin', 'cua-driver.exe'),
    runtimeRoot: path.win32.join(local, 'CuaRdp', 'child'), rdp: {},
  });
}

function childConfig(raw) {
  text(raw.driverPath, 'driverPath');
  if (!/^[A-Za-z]:\\/u.test(raw.driverPath) || !/\.exe$/iu.test(raw.driverPath)) throw new Error('driverPath must be an absolute local Windows executable path');
  const rdp = object(raw.rdp ?? {}, 'rdp');
  if (rdp.window !== undefined && !['visible', 'hidden'].includes(rdp.window)) throw new Error('rdp.window must be "visible" or "hidden"');
  return {
    version: 2, backend: 'child-session', driverPath: raw.driverPath,
    runtimeRoot: validateRuntimeRoot(raw.runtimeRoot ?? path.win32.join(dataRoot(), 'child')),
    rdp: { width: integer(rdp.width ?? 1600, 'rdp.width', 800, 3840), height: integer(rdp.height ?? 900, 'rdp.height', 600, 2160), window: rdp.window ?? 'visible' },
  };
}

export function validateConfig(raw) {
  object(raw, 'config');
  if (raw.version === 2 && (raw.backend ?? 'child-session') === 'child-session') return childConfig(raw);
  if (raw.version !== 1 || (raw.backend !== undefined && raw.backend !== 'hyperv')) throw new Error('Unsupported config version/backend; use child-session version 2 or Hyper-V version 1');
  for (const field of ['vmId', 'guestMachineGuid']) {
    if (!GUID.test(raw[field])) throw new Error(`config.${field} must be a GUID`);
  }
  text(raw.credentialPath, 'config.credentialPath');
  if (!path.win32.isAbsolute(raw.credentialPath)) throw new Error('credentialPath must be an absolute Windows path');
  const guestRoot = validateRuntimeRoot(raw.guestRoot, 'config.guestRoot');
  if (raw.autoStartVm !== undefined && typeof raw.autoStartVm !== 'boolean') throw new Error('autoStartVm must be boolean');
  object(raw.rdp, 'config.rdp');
  text(raw.rdp.address, 'config.rdp.address', 253);
  if (!/^[a-z0-9][a-z0-9.-]*$/iu.test(raw.rdp.address)) throw new Error('RDP address must be a DNS hostname or IPv4, without port or URL');
  const rdp = {
    address: raw.rdp.address,
    port: integer(raw.rdp.port ?? 3389, 'rdp.port', 1, 65535),
    width: integer(raw.rdp.width ?? 1600, 'rdp.width', 800, 3840),
    height: integer(raw.rdp.height ?? 900, 'rdp.height', 600, 2160),
  };
  return {
    version: 1, backend: 'hyperv', vmId: raw.vmId.toLowerCase(), guestMachineGuid: raw.guestMachineGuid.toLowerCase(),
    credentialPath: raw.credentialPath, guestRoot,
    autoStartVm: raw.autoStartVm ?? false, rdp,
  };
}

export async function loadConfig(file = configPath()) {
  try { return validateConfig(await readJson(file)); }
  catch (error) {
    if (error.code === 'ENOENT') {
      if (!process.env.CUA_RDP_CONFIG && path.resolve(file) === configPath()) return defaultChildConfig();
      throw new Error(`Configuration missing: ${file}. An explicitly selected config is never replaced by defaults; see README.md.`);
    }
    throw error;
  }
}

export async function verifyAddress(address, guestAddresses, { lookup = dns.lookup, interfaces = os.networkInterfaces } = {}) {
  if (!Array.isArray(guestAddresses) || !guestAddresses.length) throw new Error('The configured VM has no usable IPv4 address');
  const guest = new Set(guestAddresses.filter(ip => net.isIPv4(ip)));
  const local = new Set(Object.values(interfaces()).flat().filter(Boolean).map(entry => entry.address));
  const resolved = net.isIPv4(address) ? [{ address }] : await lookup(address, { all: true });
  if (!resolved.length) throw new Error('RDP address did not resolve to IPv4');
  for (const entry of resolved) {
    const ip = entry.address;
    if (!net.isIPv4(ip) || /^127\.|^0\.|^169\.254\./u.test(ip) || Number(ip.split('.')[0]) >= 224 || local.has(ip) || !guest.has(ip)) {
      throw new Error('RDP target must resolve only to this VM, never localhost, the host, multicast, or another machine');
    }
  }
  return resolved.map(entry => entry.address);
}

export function bootstrapCommand(guestRoot, runId) {
  if (!/^[a-f0-9]{32}$/u.test(runId)) throw new Error('Invalid runId');
  const root = guestRoot.replace(/\\+$/u, '');
  if (/\s/u.test(root)) throw new Error('Guest root must not contain spaces; the fixed keyboard bootstrap types the path unquoted');
  // Byte-identical to native BootstrapKeyboard.CommandFor: typed while Caps Lock forces direct
  // English input so a Chinese IME cannot compose the letters; the guest normalizes the id case.
  const command = `POWERSHELL.EXE -NOPROFILE -FILE ${root.toUpperCase()}\\START-AGENT.PS1 -RUNID ${runId.toUpperCase()}`;
  if (command.length > 259) throw new Error('Guest path is too long for the Windows Run dialog');
  return command;
}
