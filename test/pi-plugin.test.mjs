import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { createRequire } from 'node:module';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { ROOT } from '../src/location.mjs';

const json = async relative => JSON.parse(await readFile(path.join(ROOT, relative), 'utf8'));

// Pi is a host application, not a dependency of this package, so the integration tests
// below use pi's public SDK only when it can be resolved (PI_PACKAGE_ROOT or node_modules)
// and skip otherwise. CI therefore never depends on a Pi installation.
function resolvePi() {
  if (process.env.PI_PACKAGE_ROOT) {
    const entry = path.join(process.env.PI_PACKAGE_ROOT, 'dist', 'index.js');
    return { root: process.env.PI_PACKAGE_ROOT, entry };
  }
  try { return { root: undefined, entry: createRequire(import.meta.url).resolve('@earendil-works/pi-coding-agent') }; }
  catch { return null; }
}

// Load the shipped extension exactly as Pi does: call the default factory with the
// registered capabilities captured for inspection.
async function loadExtension() {
  const module = await import(pathToFileURL(path.join(ROOT, 'extensions', 'cua-rdp.js')).href);
  const servers = [];
  const commands = [];
  module.default({
    registerMcpServer: (name, config) => servers.push({ name, config }),
    registerCommand: (name, options) => commands.push({ name, options }),
  });
  return { servers, commands };
}

test('the Pi manifest ships the extension and the desktop skill', async () => {
  const manifest = await json('package.json');
  assert.ok(manifest.keywords.includes('pi-package'), 'the gallery discovery keyword must be present');
  assert.deepEqual(manifest.pi.extensions, ['./extensions/cua-rdp.js']);
  assert.deepEqual(manifest.pi.skills, ['./skills']);
  // A package with a manifest loads only what it declares, so both entries must resolve.
  for (const entry of manifest.pi.extensions) assert.ok((await stat(path.join(ROOT, entry))).isFile(), `${entry} must exist`);
  const skill = (await readFile(path.join(ROOT, 'skills', 'desktop', 'SKILL.md'), 'utf8')).replaceAll('\r\n', '\n');
  const frontmatter = /^---\n([\s\S]*?)\n---\n/u.exec(skill)?.[1] ?? '';
  assert.match(frontmatter, /(^|\n)name: desktop(\n|$)/u);
  assert.match(frontmatter, /(^|\n)description: \S/u);
  for (const directory of manifest.pi.skills) assert.ok((await stat(path.join(ROOT, directory))).isDirectory(), `${directory} must exist`);
});

test('the extension registers the bundled desktop server and starts it over stdio', async t => {
  const manifest = await json('package.json');
  const { servers, commands } = await loadExtension();
  assert.deepEqual(commands.map(command => command.name), ['cua-rdp-doctor']);
  assert.equal(servers.length, 1);
  const { name, config } = servers[0];
  assert.equal(name, 'cua-rdp');
  assert.equal(config.exposure, 'direct');
  // Interactive authentication waits up to 330 s and a guest call may take 360 s; the
  // server never sends progress notifications, so the timeout must cover the whole call.
  assert.ok(config.timeout >= 360, 'the per-request timeout must exceed the guest deadlines');
  assert.equal(path.resolve(config.args[0]), path.join(ROOT, 'dist', 'desktop-server.mjs'));
  assert.ok((await stat(config.args[0])).isFile(), 'the packaged server bundle must exist');
  assert.match(path.basename(config.command), /^node(\.exe)?$/u);

  // The registered command must actually speak MCP. Only tool discovery and status are
  // exercised: this test never connects to RDP and never creates a desktop.
  const directory = await mkdtemp(path.join(os.tmpdir(), 'cua-rdp-pi-'));
  const client = new Client({ name: 'cua-rdp-pi-package', version: manifest.version }, { capabilities: {} });
  const transport = new StdioClientTransport({
    command: config.command, args: config.args, cwd: ROOT, stderr: 'pipe',
    env: { ...process.env, CUA_RDP_CONFIG: path.join(directory, 'missing-config.json') },
  });
  let diagnostic = '';
  transport.stderr?.on('data', chunk => { diagnostic += chunk; });
  t.after(async () => {
    try { await client.close(); }
    finally { await rm(directory, { recursive: true, force: true }); }
  });
  await client.connect(transport);
  assert.equal(client.getServerVersion().name, 'cua-rdp');
  assert.equal(client.getServerVersion().version, manifest.version);
  assert.deepEqual((await client.listTools()).tools.map(tool => tool.name).sort(), [
    'desktop_call', 'desktop_read_resource', 'desktop_resources', 'desktop_start', 'desktop_status', 'desktop_stop', 'desktop_tools',
  ]);
  const status = await client.callTool({ name: 'desktop_status', arguments: {} });
  assert.equal(JSON.parse(status.content[0].text).state, 'stopped');
  // An explicitly selected configuration that is missing must fail closed.
  const start = await client.callTool({ name: 'desktop_start', arguments: {} });
  assert.equal(start.isError, true);
  assert.match(start.content[0].text, /Configuration missing/);
  assert.doesNotMatch(diagnostic, /ERR_MODULE_NOT_FOUND|Cannot find module/u);
});

test('Pi loads this package as an extension source', { skip: resolvePi() ? false : 'Set PI_PACKAGE_ROOT (or install @earendil-works/pi-coding-agent) to run the Pi loader check.' }, async () => {
  const pi = resolvePi();
  const { discoverAndLoadExtensions } = await import(pathToFileURL(pi.entry).href);
  const agentDir = await mkdtemp(path.join(os.tmpdir(), 'cua-rdp-pi-agent-'));
  try {
    // An isolated agent directory keeps the developer's own global extensions out of the run.
    const result = await discoverAndLoadExtensions([ROOT], ROOT, agentDir);
    assert.deepEqual(result.errors, [], `Pi reported extension errors: ${JSON.stringify(result.errors)}`);
    assert.equal(result.extensions.length, 1, 'the package must load exactly one extension');
    assert.deepEqual([...result.extensions[0].commands.keys()], ['cua-rdp-doctor']);
    assert.deepEqual(result.runtime.mcpServers.list().map(server => server.name), ['cua-rdp']);
  } finally { await rm(agentDir, { recursive: true, force: true }); }
});
