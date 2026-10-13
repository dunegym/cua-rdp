import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { DesktopManager } from './desktop.mjs';
import { createMcpServer } from './mcp.mjs';
import { safeError } from './util.mjs';

const manager = new DesktopManager();
const server = createMcpServer(manager);
let closing;
function shutdown() {
  if (closing) return closing;
  closing = (async () => {
    const deadline = setTimeout(() => process.exit(1), 35_000);
    deadline.unref();
    try { await manager.dispose(); }
    catch (error) { process.stderr.write(`cua-rdp cleanup: ${safeError(error)}\n`); }
    await server.close();
    clearTimeout(deadline);
  })();
  return closing;
}
server.onclose = () => { shutdown().catch(() => { process.exitCode = 1; }); };
process.stdin.on('end', () => { shutdown().catch(() => { process.exitCode = 1; }); });
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { shutdown().then(() => process.exit(0), () => process.exit(1)); });
await server.connect(new StdioServerTransport());
