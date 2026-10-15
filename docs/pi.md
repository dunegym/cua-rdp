# Pi integration

This repository is a [Pi package](https://pi.dev/packages) next to its Codex and Claude Code plugin manifests. Pi loads the `desktop` skill and registers the bundled `dist/desktop-server.mjs` MCP server, so the same seven `desktop_*` tools and the same Windows Child Session / Hyper-V backends are available without a second implementation.

Nothing here changes what the plugin does: it never enables Child Sessions, never adopts a foreign child session, never logs a session off and never sends host input. See the [README](../README.md) for prerequisites and the [Child Session contract](child-session-contract.md) for internals.

## Install

```bash
pi install ./cua-rdp                        # local checkout: extension and skill
pi install git:github.com/dunegym/cua-rdp   # git source
pi -e ./cua-rdp                             # one invocation, extension only, not saved
pi -e ./cua-rdp --skill ./skills/desktop    # one invocation, extension and skill
```

Requirements are unchanged: Windows, Node.js 22+, Windows PowerShell 5.1, the system RDP ActiveX control, and a locally installed `cua-driver` 0.34.0+. The two bundles under `dist/` are committed, so a Pi install never runs a build. `CUA_RDP_DRIVER` and `CUA_RDP_CONFIG` are read from the environment Pi was started with, exactly as for the other clients:

```powershell
$env:CUA_RDP_DRIVER = "D:\Tools\cua-driver\cua-driver.exe"
$env:CUA_RDP_CONFIG = Join-Path $env:LOCALAPPDATA "CuaRdp\child-session.json"
```

## What the package provides

| Resource | Path | Effect |
| --- | --- | --- |
| Extension | `extensions/cua-rdp.js` | Registers the `cua-rdp` MCP server and the `/cua-rdp-doctor` command |
| Skill | `skills/desktop/SKILL.md` | The `desktop` skill, loaded as `/skill:desktop` |
| MCP server | `dist/desktop-server.mjs` | The seven `desktop_*` tools, run over stdio with `node` |

`package.json` declares both resource paths under `pi`. Pi loads only what a package declares once a manifest exists, so a new skill or extension must be added there too.

Pi cannot ship MCP server configuration in a package, which is why the extension exists instead of a `mcp.json` entry. Registration matches the other clients' manifests: server name `cua-rdp`, `command: node`, the absolute path to the packaged `dist/desktop-server.mjs`, and no environment overrides.

### Tool names and exposure

Pi prefixes server tools with the server namespace, so the tools appear as:

```text
mcp__cua_rdp__desktop_start        mcp__cua_rdp__desktop_call
mcp__cua_rdp__desktop_status       mcp__cua_rdp__desktop_resources
mcp__cua_rdp__desktop_stop         mcp__cua_rdp__desktop_read_resource
mcp__cua_rdp__desktop_tools
```

They are registered with `direct` exposure: the set is small and task-oriented, and the skill calls the tools by name. They remain callable from `codemode` scripts as well (`await tools.mcp__cua_rdp__desktop_status({})`), which is useful to combine a status check with other work or to keep large driver output out of context.

The per-call timeout is 420 seconds. A background `desktop_start` normally needs a few seconds, but interactive authentication may wait up to 330 seconds for the Windows logon window and a guest call may take up to 360 seconds; the server sends no progress notifications, so a shorter timeout would cut a legitimate call off. Failed or timed-out input is never replayed automatically.

### The `/cua-rdp-doctor` command

`/cua-rdp-doctor` runs the same read-only `doctor` report as `npm run doctor` and prints it as a transcript line or a notification: Node version, host platform, configuration source, the bundled agent, the `cua-driver` executable, and the native Child Session state. It creates no desktop, connects to nothing, and repairs nothing. A missing MCP tool set or a failing `desktop_start` is usually explained by this report.

## Use

Select the skill explicitly with `/skill:desktop`, or just ask for the task:

```text
/cua-rdp-doctor
Use CUA RDP to check the desktop status.
Use CUA RDP to open Notepad in the child desktop, type a test line, verify it, then stop.
```

The skill's flow is the same as in the other clients: `desktop_status` → `desktop_start` → `desktop_resources` / `desktop_tools` for the driver's schemas → `desktop_call` for the task → `desktop_stop`. Only `state: ready` from `desktop_start` allows computer work, and the report always names the actual `backend`.

Background authentication stays the default. Windows may require a password on every connection; report that blocker instead of opening windows, and use `desktop_start({authentication:"interactive"})` only when the user explicitly allows a visible Windows logon window. Passwords never enter chat, tool arguments or Pi's settings.

## Differences from the Codex and Claude Code plugins

- **Subagent mapping**: `agents/rdp-operator.md` is a Claude Code subagent definition with no Pi equivalent. Pi users can delegate the same flow with a subagent package or a prompt template; the skill is the portable part.
- **MCP configuration**: Codex and Claude Code read `mcp.json` / `.mcp.json`. Pi has no manifest field for servers, so the extension registers the server per session. A same-named server in `~/.pi/agent/mcp.json` or `.pi/mcp.json` takes precedence over the extension registration.
- **Trust**: a project-local package declaration in `.pi/settings.json` loads only after [project trust](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/security.md#understand-project-trust) is granted, because the extension executes code.
- **Permissions**: every MCP call goes through Pi's tool pipeline, so `tool_call` handlers and permission extensions apply. `desktop_status`, `desktop_tools`, `desktop_resources` and `desktop_read_resource` carry `readOnlyHint`; `desktop_start`, `desktop_stop` and `desktop_call` may change state and are the ones a permission gate should confirm.

## Checks

```bash
npm test        # includes test/pi-plugin.test.mjs
npm run check   # syntax-checks extensions/*.js as well
npm run verify  # adds the Windows PowerShell and ActiveX self-tests
```

`test/pi-plugin.test.mjs` verifies the manifest, loads the extension with a stub API, starts the registered server over stdio to confirm the tool set and the fail-closed missing-config path, and — when Pi itself is resolvable — loads the package through Pi's own public `discoverAndLoadExtensions`. That last check is skipped unless Pi can be found, so CI does not depend on a Pi installation:

```powershell
$env:PI_PACKAGE_ROOT = "E:\Tool\NPM_GLOBAL\node_modules\@earendil-works\pi-coding-agent"
npm test
```

No test in this repository connects to RDP, enables Child Sessions or creates a desktop.
