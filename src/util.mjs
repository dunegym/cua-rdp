import { readFile, mkdir, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
export const dataRoot = () => path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), '.local', 'share'), 'CuaRdp');
export const configPath = () => path.resolve(process.env.CUA_RDP_CONFIG || path.join(dataRoot(), 'config.json'));
export const powershellPath = () => path.win32.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
export const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

export function object(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be an object`);
  return value;
}

export function text(value, label, max = 4096) {
  if (typeof value !== 'string' || !value.length || value.length > max || /[\x00-\x1f]/u.test(value)) {
    throw new Error(`${label} must be nonempty text without control characters (max ${max})`);
  }
  return value;
}

export function integer(value, label, min, max) {
  if (!Number.isInteger(value) || value < min || value > max) throw new Error(`${label} must be an integer from ${min} to ${max}`);
  return value;
}

export async function readJson(file) {
  return JSON.parse((await readFile(file, 'utf8')).replace(/^\uFEFF/u, ''));
}

export async function writeJson(file, value) {
  await mkdir(path.dirname(file), { recursive: true });
  const temp = `${file}.${process.pid}.${randomUUID()}.tmp`;
  await writeFile(temp, JSON.stringify(value), { mode: 0o600, flag: 'wx' });
  await rename(temp, file);
}

export function safeError(error, secrets = []) {
  let message = error instanceof Error ? error.message : String(error);
  for (const secret of secrets) if (secret) message = message.split(secret).join('[redacted]');
  return message.replace(/Bearer\s+\S+/giu, 'Bearer [redacted]').slice(0, 2000);
}
