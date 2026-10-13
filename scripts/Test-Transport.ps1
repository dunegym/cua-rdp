[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$brokerAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Broker.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'Broker script did not parse.' }
foreach ($name in @('Assert-Owner', 'Invoke-GuestHttp')) {
    $definition = $brokerAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $false)
    if ($null -eq $definition) { throw 'A tested transport function is missing.' }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:transferCalls = 0
$script:largestChunk = 0
$script:renewalForced = $false
function Invoke-Command {
    param($Session, [object[]]$ArgumentList, [scriptblock]$ScriptBlock)
    $script:transferCalls++
    if ($ArgumentList.Count -eq 8 -and -not $script:renewalForced) {
        $ArgumentList[5] = $true
        $script:renewalForced = $true
    }
    $value = & $ScriptBlock @ArgumentList
    if ($value -is [string] -and $value.Length -gt $script:largestChunk) { $script:largestChunk = $value.Length }
    $value
}
$fixture = @'
const http = require('node:http');
let calls = 0;
let heartbeats = 0;
let inputMatched = false;
const body = JSON.stringify({ data: 'x'.repeat(11 * 1024 * 1024), unicode: String.fromCharCode(0x622a, 0x56fe) });
const server = http.createServer((req, res) => {
  if (req.url === '/count') { res.end(JSON.stringify({ calls, heartbeats, inputMatched })); return; }
  if (req.method !== 'POST' || req.headers.authorization !== 'Bearer ' + 'a'.repeat(64)) {
    res.writeHead(403); res.end(); return;
  }
  if (req.url === '/health') {
    heartbeats++;
    req.resume();
    res.end(JSON.stringify({ result: { runId: 'c'.repeat(32), protocol: 2, state: 0, inputDesktop: 'Default' } }));
    return;
  }
  if (req.url !== '/callTool') { res.writeHead(404); res.end(); return; }
  calls++;
  const chunks = [];
  req.on('data', chunk => chunks.push(chunk));
  req.on('end', () => {
    try {
      let value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      for (let i = 0; i < 150; i++) value = value.child;
      inputMatched = value.text === String.fromCharCode(0x4e2d, 0x6587) + String.fromCodePoint(0x1f680);
    } catch {}
    res.setHeader('content-type', 'application/json; charset=utf-8');
    res.end(body);
  });
});
server.listen(0, '127.0.0.1', () => process.stdout.write(String(server.address().port) + '\n'));
process.stdin.resume();
process.stdin.on('end', () => server.close());
'@
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($fixture))
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = (Get-Command node.exe -ErrorAction Stop).Source
$info.Arguments = '-e "eval(Buffer.from(''{0}'',''base64'').toString())"' -f $encoded
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardInput = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$process = $null
$testRoot = Join-Path $env:TEMP ('cua-rdp-transport-test-' + [Guid]::NewGuid().ToString('N'))
$runId = 'c' * 32
$runRoot = Join-Path (Join-Path $testRoot 'runs') $runId
$null = New-Item -ItemType Directory -Path $runRoot
$script:config = @{ guestRoot = $testRoot }
$script:session = [pscustomobject]@{ State = 'Opened' }
$script:OwnerPid = $PID
try {
    $process = [Diagnostics.Process]::Start($info)
    $lineTask = $process.StandardOutput.ReadLineAsync()
    if (-not $lineTask.Wait(10000)) { throw 'Local transport fixture did not start.' }
    $port = [int]$lineTask.Result
    if ($port -lt 1024 -or $port -gt 65535) { throw 'Local transport fixture returned an invalid port.' }
    $run = @{ runId = $runId; token = ('a' * 64); ready = @{ port = $port } }
    # Built from code points so this script stays pure ASCII: Windows PowerShell 5.1
    # decodes BOM-less scripts with the system ANSI codepage, which differs per machine.
    $unicodeText = [string][char]0x4e2d + [string][char]0x6587 + [string][char]0xD83D + [string][char]0xDE80
    $payloadJson = '{"text":"' + $unicodeText + '"}'
    for ($i = 0; $i -lt 150; $i++) { $payloadJson = '{"child":' + $payloadJson + '}' }
    $resultJson = Invoke-GuestHttp $run 'callTool' $payloadJson
    if ($resultJson -isnot [string]) { throw 'The broker must preserve the raw JSON response.' }
    $result = $resultJson | ConvertFrom-Json
    if ($result.data.Length -ne 11534336 -or $result.data.Trim('x').Length -ne 0) { throw 'Large response content was truncated or changed.' }
    $expectedUnicode = ([string][char]0x622a) + [char]0x56fe
    if ($result.unicode -cne $expectedUnicode) { throw 'UTF-8 content did not survive the chunked transport.' }
    $request = [Net.HttpWebRequest]::Create(('http://127.0.0.1:{0}/count' -f $port))
    $request.Proxy = $null
    $request.Timeout = 10000
    $response = $request.GetResponse()
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        try { $count = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    } finally { $response.Dispose() }
    if ($count.calls -ne 1) { throw 'Response chunking repeated the original action.' }
    if ($count.heartbeats -ne 1) { throw 'Transfer did not renew the guest lease with a separate health check.' }
    if (-not $count.inputMatched) { throw 'Deep JSON or Unicode request content was changed.' }
    if ($script:largestChunk -gt 349528 -or $script:transferCalls -lt 40) { throw 'Response transfer did not use bounded chunks.' }
    if (@(Get-ChildItem -LiteralPath $runRoot -Filter 'response-*.json').Count -ne 0) { throw 'The owned response spool file was not cleaned up.' }
    [pscustomobject]@{ passed = 7; payloadBytes = 11534336; actionExecutions = $count.calls; leaseRenewals = $count.heartbeats; preservedRequestDepth = 150; remotingCalls = $script:transferCalls; largestChunkChars = $script:largestChunk; actualHyperVCalls = 0 }
} finally {
    if ($null -ne $process) {
        try { $process.StandardInput.Close(); if (-not $process.WaitForExit(5000)) { $process.Kill(); $process.WaitForExit(5000) | Out-Null } } catch { }
        $process.Dispose()
    }
    $item = Get-Item -LiteralPath $testRoot -Force
    if ($item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -Confirm:$false }
}
