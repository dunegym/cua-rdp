import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { object, safeError } from './util.mjs';

const empty = { type: 'object', properties: {}, additionalProperties: false };
const tools = [
  { name: 'desktop_start', description: 'Start a native RDP Child Session (default) or configured Hyper-V desktop with cua-driver. Background startup never opens a logon window. authentication=interactive allows a visible Windows login on this connection; the user completes sign-in, the agent is launched by a one-shot session-bound scheduled task (no keyboard input, no focus handling), and the preparation window hides itself when the agent is ready. Never enables system features or adopts foreign child sessions.',
    inputSchema: { type: 'object', properties: { authentication: { type: 'string', enum: ['background', 'interactive'], description: 'background (default): no visible authentication. interactive: explicitly allow a Windows password/certificate prompt on this connection; credentials are entered directly into Windows and never saved.' } }, additionalProperties: false } },
  { name: 'desktop_status', description: 'Inspect owned desktop lifecycle; when running, verify the guest identity, unlocked RDP session and keeper connection. Does not start a desktop.', inputSchema: empty, annotations: { readOnlyHint: true } },
  { name: 'desktop_stop', description: 'Stop this controller\'s driver and hidden RDP connection. Does not log off the Child Session or VM, close other applications, or disable system features.', inputSchema: empty },
  { name: 'desktop_tools', description: 'Get the guest cua-driver tool names and exact JSON input schemas (optionally filter by name). Call after desktop_start; follow nextCursor for more pages.',
    inputSchema: { type: 'object', properties: { filter: { type: 'string', maxLength: 128 }, cursor: { type: 'string', maxLength: 4096 } }, additionalProperties: false }, annotations: { readOnlyHint: true } },
  { name: 'desktop_call', description: 'Invoke a cua-driver tool only inside the isolated guest RDP session. Fetch its exact schema with desktop_tools first. Preserves images and tool errors. No automatic input retries.',
    inputSchema: { type: 'object', properties: { tool: { type: 'string', pattern: '^[a-zA-Z0-9_.-]{1,128}$' }, arguments: { type: 'object', additionalProperties: true } }, required: ['tool', 'arguments'], additionalProperties: false } },
  { name: 'desktop_resources', description: 'List cua-driver resources in the isolated guest (including driver skill documentation when available).',
    inputSchema: { type: 'object', properties: { cursor: { type: 'string', maxLength: 4096 } }, additionalProperties: false }, annotations: { readOnlyHint: true } },
  { name: 'desktop_read_resource', description: 'Read a cua-driver resource, such as skill://cua-driver/SKILL.md or WINDOWS.md, from the guest. Returns embedded MCP resources without touching host applications.',
    inputSchema: { type: 'object', properties: { uri: { type: 'string', minLength: 1, maxLength: 4096 } }, required: ['uri'], additionalProperties: false }, annotations: { readOnlyHint: true } },
];
const jsonResult = value => ({ content: [{ type: 'text', text: JSON.stringify(value, null, 2) }] });

function validateArgs(name, args) {
  object(args, 'arguments');
  const schema = tools.find(tool => tool.name === name)?.inputSchema;
  if (!schema) throw new Error('Unknown tool');
  for (const key of Object.keys(args)) if (!Object.hasOwn(schema.properties, key)) throw new Error(`Unexpected argument: ${key}`);
  for (const key of schema.required || []) if (!Object.hasOwn(args, key)) throw new Error(`Missing argument: ${key}`);
  for (const [key, value] of Object.entries(args)) {
    const field = schema.properties[key];
    if (field.type === 'object') object(value, key);
    else if (typeof value !== 'string' || value.length > (field.maxLength || 4096) || value.length < (field.minLength || 0) || (field.enum && !field.enum.includes(value)) || (field.pattern && !new RegExp(field.pattern, 'u').test(value))) {
      throw new Error(`Invalid ${key}`);
    }
  }
}

export function createMcpServer(manager) {
  const server = new Server({ name: 'cua-rdp', version: '0.3.2' }, {
    capabilities: { tools: {} },
    instructions: 'Use desktop_start, then desktop_tools and desktop_call for isolated guest operations. Read the guest cua-driver skill before GUI work. Never replace failed guest calls with host cua-driver tools. Stop after the task; use desktop_status to verify isolation.',
  });
  server.setRequestHandler(ListToolsRequestSchema, () => ({ tools }));
  server.setRequestHandler(CallToolRequestSchema, async request => {
    const { name, arguments: args = {} } = request.params;
    try {
      validateArgs(name, args);
      switch (name) {
        case 'desktop_start': return jsonResult(await manager.start(args));
        case 'desktop_status': return jsonResult(await manager.status());
        case 'desktop_stop': return jsonResult(await manager.stop());
        case 'desktop_tools': {
          const result = await manager.request('listTools', args.cursor ? { cursor: args.cursor } : {});
          const matching = args.filter ? result.tools.filter(tool => tool.name.includes(args.filter)) : result.tools;
          return jsonResult({ ...result, tools: matching });
        }
        case 'desktop_call': return await manager.request('callTool', { name: args.tool, arguments: args.arguments });
        case 'desktop_resources': return jsonResult(await manager.request('listResources', args));
        case 'desktop_read_resource': {
          const result = await manager.request('readResource', args);
          return { content: result.contents.map(resource => ({ type: 'resource', resource })) };
        }
      }
    } catch (error) { return { ...jsonResult({ error: safeError(error), ...(error.code ? { code: error.code } : {}) }), isError: true }; }
  });
  return server;
}
