import { mkdir, open, readFile, unlink } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

export async function acquireLock(root, vmId) {
  await mkdir(root, { recursive: true });
  const file = path.join(root, `${vmId}.lock`);
  const nonce = randomUUID();
  let handle;
  try { handle = await open(file, 'wx', 0o600); }
  catch (error) {
    if (error.code !== 'EEXIST') throw error;
    throw new Error(`Another controller owns this VM, or its lock needs manual recovery: ${file}. Stop that controller first; stale locks are never stolen automatically.`);
  }
  try { await handle.writeFile(JSON.stringify({ pid: process.pid, nonce, createdAt: new Date().toISOString() })); }
  finally { await handle.close(); }
  return async () => {
    try {
      const contents = JSON.parse(await readFile(file, 'utf8'));
      if (contents.nonce === nonce) await unlink(file);
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  };
}
