# Hyper-V transport contract

This document covers the optional legacy Hyper-V backend of the conventional Claude Code stdio MCP plugin. The default native Child Session backend has its own [contract](child-session-contract.md). For Hyper-V, the host is Windows + local Hyper-V; the guest is a dedicated licensed Windows VM with Node.js >=22 and cua-driver installed. Remote mode forbids host/loopback connections; only the separate Child Session mode permits localhost through its dedicated ActiveX property.

## Host configuration

Default `%LOCALAPPDATA%\CuaRdp\config.json`, override `CUA_RDP_CONFIG`.

```json
{
  "version": 1,
  "vmId": "Hyper-V VM GUID",
  "guestMachineGuid": "guest registry MachineGuid",
  "credentialPath": "absolute host path to Export-Clixml PSCredential",
  "guestRoot": "C:\\ProgramData\\CuaRdp",
  "autoStartVm": true,
  "rdp": {"address": "guest DNS name or IPv4", "port": 3389, "width": 1600, "height": 900}
}
```

Guest install configuration `guestRoot\guest-config.json`: `{version:1,nodePath:<absolute exe>,driverPath:<absolute cua-driver.exe>,userSid:<dedicated account SID>}`. Driver always starts directly with `mcp --direct`, never a shared daemon socket. Mutable state and credentials stay outside the plugin directory.

## PowerShell broker

`powershell.exe -NoLogo -NoProfile -NonInteractive -File scripts/Broker.ps1 -ConfigPath <path> -OwnerPid <node pid>`.

stdin/stdout UTF-8 NDJSON. Requests `{id:<integer>,method,params:{}}`; responses `{id,result:<object>}` or `{id,error:{message:<safe diagnostic>}}`. stdout is protocol-only. One request at a time. No credentials in protocol/CLI/logs.

- `prepare`: start only configured existing VM if allowed, establish persistent PowerShell Direct using saved credential. Verify guest MachineGuid equals pinned value and differs from host. Return `{hostMachineGuid,guestMachineGuid,addresses:[IPv4],computerName}`. Discover addresses from inside that guest, not host DNS guesses.
- `stage`: params `{runId:<32 lowercase hex>,token:<64 lowercase hex>}`. Require exactly one active RDP session belonging to guest-config.userSid; ensure the credential resolves to that SID. Create run folder `guestRoot\runs\<runId>`. Write `agent.json` (below). Return `{sessionId,userSid,machineGuid}`. No scheduled tasks, services, startup entries, or other persistence.
- The host asks the RDP ActiveX keeper to send the fixed bootstrap command to the remote Run dialog using its direct SendKeys interface, never host SendInput. Command: `POWERSHELL.EXE -NOPROFILE -FILE <GUESTROOT>\START-AGENT.PS1 -RUNID <RUNID>` typed while Caps Lock holds the session IME in direct-English mode (upper case, unquoted; the guest normalizes the run ID case). Only space-free ASCII guestRoot with letters/numbers/backslash/dot/underscore/hyphen is accepted. No token/password in this command. The dedicated guest must have a normal unlocked Explorer desktop. This is a one-shot UI bootstrap, not a persistent login hook.
- `attach`: params `{runId}`. Poll this staged run's `ready.json` <=30s. Return descriptor after checking runId, sessionId, machineGuid and userSid. A keystroke delivery is never treated as successful startup.
- `request`: params `{runId,operation,payloadJson:<serialized JSON object>}`. POST via PowerShell Direct to guest loopback `http://127.0.0.1:<ready.port>/<operation>` with `Authorization: Bearer <token>`, UTF-8 JSON body, <=120s HTTP timeout. Execute the HTTP operation once, spool its response in the private run folder and transfer it in bounded 256 KiB chunks (maximum response 64 MiB). During long transfers, authenticated health requests renew the lease every 20s. Return `{json:<raw UTF-8 response string>}` so PowerShell's JSON-depth limit cannot alter driver output; Node parses the guest envelope `{result:...}` / `{error:{code,message}}`. The host allows up to 360s for operation plus transfer. Allowed operations: `health`, `listTools`, `callTool`, `listResources`, `readResource`. No guest network listener is exposed beyond loopback.
- `stop`: params `{runId}`. Best-effort authenticated `/shutdown`, wait for the owned agent to exit; remove only that run folder when safe. Never log off, shut down VM, or kill unrelated applications.
- EOF/finally: clean up owned runs and dispose PSSession. Fail closed on connection failures; no input replays.

Guest `agent.json`: `{version:1,runId,token,expectedMachineGuid,expectedSessionId,expectedUserSid,driverPath,readyPath,leaseMs:180000}`. `readyPath` is the absolute path of this run's `ready.json`. The one-shot bootstrap runs `guestRoot\Start-Agent.ps1 -RunId <hex>`, which reads configs, then starts `nodePath guestRoot\guest-agent.cjs --config <agent.json>` inside that interactive RDP session. Log output stays in run folder.

Guest descriptor `ready.json`: `{runId,port,pid,sessionId,machineGuid,userSid}`. Guest reads actual session identity by `powershell.exe -NoProfile -NonInteractive -File guestRoot\Get-InteractiveState.ps1`, returning only compact JSON `{machineGuid,sessionId,userSid,protocol:2,state:0,inputDesktop:"Default"}`. Protocol 2 = RDP, state 0 = active. Session 0, console, locked and disconnected sessions are rejected, at startup and before every driver operation.

## RDP keeper

`native/Start-RdpKeeper.ps1 -RequestPath <path> -ParentPid <host node pid>`. Request `{address,port,width,height,credentialPath,statusPath,stopPath}`. Native helper creates a private Win32 desktop and starts its own ActiveX host there without ever switching the input desktop. It holds the RDP connection open/non-minimized, validates server certificates, uses NLA, and disables redirections. Password is read from DPAPI CLIXML in worker, never passed by Node. Status file `{state:"connecting"|"connected"|"failed"|"stopped",pid,desktop,error?}`. Only successful login means connected. Parent death, stop file or timeout closes only the owned keeper.

## Node ownership

One host MCP process owns one desktop run. A per-VM exclusive lock prevents another instance using the same guest simultaneously. Host checks resolved RDP address belongs to guest and is not loopback/host. Address is resolved and checked immediately before connecting. Keepalive every 20s; guest self-terminates after 180s with no authenticated request. Stop keeps guest/apps running but ends the driver and RDP connection. MCP EOF invokes stop; no unrequested VM creation, certificate import, account creation or host settings edits.
