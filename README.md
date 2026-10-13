# cua-rdp

A Claude Code plugin that runs `cua-driver` inside a **native Windows RDP Child Session**, in the background: no desktop switching, no locking, and no keyboard or mouse input sent to the current parent desktop. No virtual machine or second Windows account is required. Whether a Windows password is required is decided by system security policy, and reconnects may ask every time. Existing Hyper-V configurations keep working.

Version **0.3.0**. Local regression tests and real-connection acceptance are two separate checks; `npm run verify` never creates a Child Session or enables system features.

## How it works

This uses Windows' dedicated **Child Session** mechanism, not an ordinary `mstsc localhost` multi-user logon. The concurrency limits of ordinary RDP do not apply to Child Sessions.

1. Capability and current-child checks through `WTSIsChildSessionsEnabled` / `WTSGetChildSessionId`.
2. The system RDP ActiveX control is hosted on the parent session's **Default desktop**; background mode uses an off-screen no-activate/tool window and never calls parent-desktop focus or input APIs. `ConnectToChildSession=true` is set before connecting. Authentication on a private desktop stalled on the local Insider build; that is a local test observation, not a guarantee about all Windows builds. The remote VM backend still uses a private Win32 desktop.
3. Waits for the real `OnLoginComplete`, then verifies parent/child SessionIds, user SID, MachineGuid and logon timestamps.
4. The Child Session backend starts the agent and `cua-driver mcp --direct` inside the child session through a **one-shot temporary scheduled task** (bound to the child session ID, current-user interactive token, least privilege, deleted immediately after launch). **No keyboard input is injected**, so a Chinese IME in the child session cannot intercept the bootstrap, and the parent session's cua-driver daemon is never reused. The Hyper-V backend keeps its fixed remote SendKeys keyboard bootstrap.
5. Claude Code's stdio MCP is bridged to the child-session driver over a local loopback endpoint with a random per-run token, forwarding tools, screenshots, resources and errors verbatim.

No RDP Wrapper, system DLL patches, `tscon`, persistent scheduled tasks, services, autostart entries, host input injection, or Session 0 GUI. The plugin never changes the firewall, the ordinary RDP switch, certificate trust, or PowerShell execution policy.

**A Child Session is interactive-session isolation, not a security sandbox.** It shares the user, filesystem, network and application configuration with the parent desktop. If you need a separate OS/filesystem, use the [Hyper-V backend](docs/hyperv.md). An application's own single-instance or cross-session IPC may reach the parent session; tasks should use applications that support multiple instances with separate configuration directories, and verify that operated windows belong to the child session.

## Quick start

### 1. Build and check

Marketplace installs are ready to use: Claude Code installs the npm dependencies and the repository ships the built guest agent (`dist/guest-agent.cjs`); CI keeps that bundle identical to the sources. For a source checkout, build first:

```powershell
npm ci
npm run build
npm run doctor
```

Requires Windows, Node.js **22+**, Windows PowerShell 5.1, the system RDP ActiveX control, and a locally installed `cua-driver` **0.34.0+**. cua-driver is neither bundled nor auto-downloaded.

The current implementation only accepts an **active local console parent session**. Launching from an RDP parent session, a Child Session, Session 0, or an inactive console is explicitly refused; no nesting or fallback is attempted.

When the default configuration file `%LOCALAPPDATA%\CuaRdp\config.json` does not exist, the Child Session backend is selected automatically:

- Driver: `%LOCALAPPDATA%\Programs\Cua\cua-driver\bin\cua-driver.exe`
- Private runtime directory: `%LOCALAPPDATA%\CuaRdp\child`
- Resolution: 1600 × 900

If the driver lives elsewhere, set this before starting Claude Code:

```powershell
$env:CUA_RDP_DRIVER = "D:\Tools\cua-driver\cua-driver.exe"
```

`doctor` is read-only: it creates no desktop and does not auto-repair system settings. An existing v1 configuration still selects Hyper-V; see "Configuration" below for switching.

### 2. Enable the feature explicitly, only if it is not enabled

If `doctor` reports that Child Sessions are disabled, the user explicitly runs, in a suitably privileged PowerShell:

```powershell
.\native\Enable-ChildSessions.ps1 -WhatIf
.\native\Enable-ChildSessions.ps1
```

This is a standalone system-settings action, not an implied side effect of `desktop_start`. The script only calls the official `WTSEnableChildSessions(true)`; it installs no patches, elevates nothing, and changes no firewall rules — run it with whatever rights your system requires. Tests never do this.

### 3. Load the plugin

Install directly from this GitHub repository as a one-plugin marketplace:

```text
/plugin install cua-rdp@dunegym/cua-rdp
```

For local development, load the working copy instead:

```powershell
claude plugin validate "E:\Repository\cua-rdp" --strict
claude --plugin-dir "E:\Repository\cua-rdp"
```

Substitute your actual path. This loads the plugin locally without touching global Claude configuration. In a new session, check the plugin's `desktop` server with `/mcp`.

```text
/cua-rdp:desktop status
/cua-rdp:desktop start
/cua-rdp:desktop Open Notepad in the background, type child session test, verify, then stop.
/cua-rdp:desktop stop
```

The `rdp-operator` subagent follows the same flow. The plugin does not call model APIs on its own and needs no extra Anthropic API key.

### 4. When the system requires a password

By default `desktop_start({})` uses `authentication: "background"` and never opens a visible authentication window. If Windows requires interactive credentials the start fails (returning `AUTHENTICATION_REQUIRED` / `needs-authentication` when the authentication event is recognized); other disconnects report their actual error and are never guessed into certificate or Credential Guard failures.

Only when the user explicitly allows a visible logon window, call:

```json
{"authentication":"interactive"}
```

This is a `desktop_start` argument: the user types the password directly into a Windows window; the plugin never reads or stores it, and certificate warnings are judged by the user too. After authentication succeeds and identity is verified, the **same connection** briefly keeps its preparation window while the temporary scheduled task completes the agent bootstrap inside the child session. The RDP window is then kept **by default as a watch window** (`window: "visible"`): it has normal minimize/maximize/resize chrome and a taskbar entry, minimizing keeps it in the taskbar, closing (x) parks it in the notification tray (the connection stays until `desktop_stop`), and maximizing scales the child desktop through `SmartSizing`. Pass `{"window":"hidden"}` — or set `"rdp": {"window": "hidden"}` in the configuration — for the original fully hidden off-screen keeper; background mode never shows a window before a connection is established. Computer tasks are accepted only after the agent is ready in the verified child session, regardless of window mode. The authentication stage uses the current desktop, so interactive mode is not fully unattended.

Disconnecting and reconnecting may still require the password. A single logon never guarantees the next one is prompt-free; when running several tasks, keep the current connection and `desktop_stop` at the end. The plugin does not disable Credential Guard or NLA and does not change credential-delegation policy.

## Configuration

Optional Child Session configuration:

```json
{
  "version": 2,
  "backend": "child-session",
  "driverPath": "C:\\Users\\You\\AppData\\Local\\Programs\\Cua\\cua-driver\\bin\\cua-driver.exe",
  "runtimeRoot": "C:\\Users\\You\\AppData\\Local\\CuaRdp\\child",
  "rdp": { "width": 1600, "height": 900, "window": "visible" }
}
```

`rdp.window` selects the post-start RDP window: `"visible"` (default) keeps a watch window that can be minimized, maximized, resized and parked in the tray, and `"hidden"` keeps the original off-screen keeper. `desktop_start` accepts a per-call `window` override with the same values.

Keep the file in a user-private directory. For example, save it as `%LOCALAPPDATA%\CuaRdp\child-session.json` (keeping any existing Hyper-V configuration), then set this before starting Claude Code:

```powershell
$env:CUA_RDP_CONFIG = Join-Path $env:LOCALAPPDATA "CuaRdp\child-session.json"
```

An explicitly selected configuration that is missing or invalid is an error; the plugin never silently falls back to the default backend. Do not put passwords or bearer tokens here.

`runtimeRoot` must be a safe ASCII path on a local disk, at most 160 characters, and **must not contain spaces**; this is a conservative constraint kept consistent with the Hyper-V keyboard bootstrap (upper-case, unquoted command). If your user directory contains non-ASCII characters or the path is too long, explicitly choose another writable ASCII path. Driver and Node.exe paths may contain Unicode. The initialization script only creates/updates directories it owns, with an ACL limited to the current user, Administrators and SYSTEM; foreign directories, reparse points, or uncleaned run records are refused rather than overwritten.

Inside the child session the agent is started directly by the scheduled task, so it does not depend on the Run dialog or keyboard layout; the local PowerShell execution policy must allow local scripts (the default RemoteSigned is fine — no Bypass needed).

## MCP tools

| Tool | Purpose |
| --- | --- |
| `desktop_start` | Establish the selected backend, start and verify the driver; returns `ready` only on success |
| `desktop_status` | Inspect state; when running, verifies identity, processes and connection; creates no desktop |
| `desktop_stop` | Stop this controller's own agent and connection; never logs off the session or closes other applications |
| `desktop_tools` | Read the driver's current tool schemas, with per-page name filtering and cursor pagination |
| `desktop_call` | Forward a call with `tool` and `arguments`; preserves images and tool errors |
| `desktop_resources` | List the child-desktop driver resources |
| `desktop_read_resource` | Read driver skill / Windows guide resources |

Discover schemas before acting. The existing parent-desktop `mcp__cua-driver__*` tools are a different backend and are never a substitute for a failing child desktop. The driver's `session` is a task label, not a Windows SessionId.

## Ownership and lifecycle

- Only one connected Child Session exists at a time. When another program already holds a connected child session, the plugin refuses to take over; it never disconnects or logs it off.
- Each user gets a controller file lock; the native keeper additionally holds a machine-wide named mutex across sessions. Stale locks are never stolen.
- Parent and child SessionIds **plus the exact logon timestamps** are persisted; only an exactly matching, self-created, disconnected child session may be reconnected. A recycled Windows SessionId cannot be impersonated.
- Before readiness, the agent PID's owning SessionId and process start time are queried through the OS; connection and identity are re-checked before every call, and the agent re-checks the active RDP/Default desktop before executing tools.
- `desktop_stop` stops this controller's RDP keeper first, then closes its own agent/driver. When cleanup is unconfirmed, locks and diagnostics are retained — "stop requested" is never treated as "cleaned up".
- **Stopping is not logging off.** The child session and other applications are not terminated by the plugin; the same session can be reconnected later, so a blank desktop is not guaranteed. When the parent user logs off, Windows ends their Child Session.
- If the main controller crashes, a Job Object closes the RDP worker; the agent exits via its stop marker or a lease of at most 180 seconds. Lost contact never triggers automatic replay of clicks, input, or launch tasks.
- Clipboard, drive, printer, serial-port, smart-card, device and audio redirection are all disabled. The local bridge listens only on `127.0.0.1` with a random port, uses a random per-run token, rejects browser Origins, and never exposes a listening port.
- "Background" does not mean a model keeps working after Claude Code exits. Sleep, parent-session switch/lock, RDP disconnect, or driver exit makes operations fail and input stop.

## Verification and troubleshooting

```powershell
npm run verify
```

Verification covers Node lifecycle/authentication/MCP tests, PowerShell installation and cleanup tests, an 11 MiB UTF-8 Hyper-V chunked-transfer test, and a connection-free self-test of the real RDP ActiveX. The native self-test creates a temporary private Win32 desktop for remote mode and an off-screen window on Default for Child Session mode, reads Child Session properties, verifies the parent input desktop is unchanged, and checks Job Object cleanup; it never calls Connect, never enables Child Sessions, and never touches existing clones.

Requests are capped at 2 MiB and responses at 64 MiB. An input timeout means the outcome may be unknown; nothing is retried automatically. `skills/desktop/evals/evals.json` contains deployment-acceptance cases and does not mean those GUI operations have passed.

Real-environment acceptance should separately confirm: `desktop_start` returns `backend: child-session` with the child SessionId; screenshots/windows are obtained through the agent; a test runs inside the child session and its result is read back; the parent desktop's focus and clipboard are unchanged; after stopping, the agent has exited and the retained child session can be reconnected. Never experiment with a foreign clone that has unsaved work.

**Real-machine status (Windows 11 Insider 28120): the full interactive chain passed acceptance on 2026-10-13** — authentication → scheduled-task bootstrap → `state: ready` → driver tool/schema/skill reads → child-desktop screenshot (1600×900) → parent focus/cursor/clipboard/input-desktop unchanged throughout and after → clean stop. **GUI-task acceptance also passed the same day** (`node test/probe-gui.mjs --run --interactive-authentication`): Notepad was launched inside the verified child session (window ownership cross-checked against the child SessionId), a 32-character line was typed through background UIA delivery, and the complete text was read back from the child session's accessibility tree, with the parent desktop again unchanged. Known cosmetic limitation recorded by that probe: Win11 packaged Notepad is a single-instance XAML application — new launches hand off to the first surviving process (so `kill_app` is rightly refused for the untracked pid), posted background keys are dropped, and its save prompt is an in-window dialog; leftover child-session windows may remain and are harmless (the plugin never guarantees a blank desktop). The historical root causes were located with read-only evidence and fixed: first, the `SendKeys` keyData array used the WM_KEYDOWN lParam layout described by the Microsoft documentation, while the actual client expects **raw set-1 scan codes** (low byte plus the `0x0100` extended flag); under the lParam layout every call returned S_OK while no key reached the child session. Second, a keyboard bootstrap cannot reliably bypass the child session's Chinese IME (the caps-lock direct-English scheme was still intercepted by the pinyin composition window, losing case and fragments in real testing), so the child-session bootstrap now uses a one-shot temporary scheduled task and sends no keys at all. Background mode remains unavailable on this machine: Windows Security demands a password on every connection, and prompt-free connections are server-terminated at NLA negotiation (disconnect code 2055/0x807, before any credential exchange); this is system policy, not a defect the plugin can fix.

Real probes:

```powershell
node test/probe-child-session.mjs --run
# Only when the user explicitly allows a visible Windows logon window:
node test/probe-child-session.mjs --run --interactive-authentication
# GUI-task acceptance (Notepad: launch, type, read back, verify session ownership):
node test/probe-gui.mjs --run --interactive-authentication
```

The probe performs ownership checks through the public controller and stops its own connection in `finally`; it never logs off a session. Interactive mode establishes the parent-desktop observation baseline after the preparation window hides itself and `backgroundReady=true`; if the background transition never happens it reports `not-established` instead of claiming success. Background mode compares focus, cursor, clipboard and input desktop from before the connection. Actively moving the mouse or switching windows during the test also fails that comparison.

Common blockers:

- **Feature disabled / unsupported**: check `doctor` first; run the enable script explicitly only when needed. The plugin never falls back to plain localhost RDP.
- **Logon timeout / repeated failures**: read the actual error. Credential Guard may block reuse of the current Windows logon credentials, and Windows Security may ask for the password every time; use the interactive option only with explicit user consent. A timeout alone does not prove the credential service is broken — the plugin never restarts services or lowers security settings.
- **Another clone exists / your own clone is still connected**: stop the current controller first. Never delete ownership records to impersonate another program's session.
- **Agent not ready**: check the PowerShell execution policy (local scripts must be runnable), the driver path, `<runtimeRoot>\runs\<runId>` `bootstrap-error.txt` / `agent.stderr.log`, and whether a policy blocks temporary scheduled tasks. A failure never falls back to the parent desktop.
- **Unconfirmed cleanup / stale locks**: call `desktop_stop` first. If the controller already crashed, wait for the lease to expire, verify the corresponding Node/driver/keeper processes are gone, then handle that runId's private files and locks manually. Never delete just because a lock looks old; `%LOCALAPPDATA%\CuaRdp\child-session.owner.json` is the session ownership record, not a lock, and should be kept after a normal stop.
- **A single-instance application lands on the parent desktop**: use a separate instance/user-data directory or switch to Hyper-V; the plugin never operates parent windows to work around application limits.
- **Execution policy denied**: deploy according to your organization's signed/execution policy; ExecutionPolicy Bypass is not used.

Internal interfaces: [Child Session contract](docs/child-session-contract.md), [Hyper-V contract](docs/implementation-contract.md), and [native components](native/README.md). Runtime state lives in the user data directory, never in the plugin install directory.

## References

- [Windows Child Sessions](https://learn.microsoft.com/en-us/windows/win32/termserv/child-sessions)
- [IMsRdpExtendedSettings / ConnectToChildSession](https://learn.microsoft.com/en-us/windows/win32/termserv/imsrdpextendedsettings-property)
- [WTSEnableChildSessions](https://learn.microsoft.com/en-us/windows/win32/api/wtsapi32/nf-wtsapi32-wtsenablechildsessions)
- [WTSGetChildSessionId](https://learn.microsoft.com/en-us/windows/win32/api/wtsapi32/nf-wtsapi32-wtsgetchildsessionid)
- [CreateDesktop](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-createdesktopw)
- [Claude Code plugins](https://code.claude.com/docs/en/plugins/create.md)

The plugin implements its own no-parent-activation RDP keeper, strict session ownership checks, and a keyboard-free one-shot scheduled-task bootstrap; it never automatically logs off a child session.
