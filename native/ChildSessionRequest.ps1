function Get-RdpRequestMode($Request) {
    if ($null -eq $Request.PSObject.Properties['mode']) { return 'hyperv' }
    if ($Request.mode -isnot [string] -or $Request.mode -cnotin @('hyperv', 'child-session')) { throw 'RDP mode must be hyperv or child-session.' }
    return [string]$Request.mode
}

function Read-ChildSessionExpectation($Request) {
    foreach ($name in @('expectedParentSessionId', 'expectedParentLogonTime', 'expectedChildSessionId', 'expectedChildLogonTime')) {
        if ($null -eq $Request.PSObject.Properties[$name]) { throw "Child Session request requires $name." }
    }
    foreach ($name in @('credentialPath', 'password', 'userName', 'domain')) {
        if ($null -ne $Request.PSObject.Properties[$name]) { throw 'Child Session requests must not contain credentials.' }
    }
    if ($Request.address -isnot [string] -or $Request.address -ine 'localhost') { throw 'Child Session mode requires address localhost.' }
    if (($Request.expectedParentSessionId -isnot [int] -and $Request.expectedParentSessionId -isnot [long]) -or $Request.expectedParentLogonTime -isnot [string]) {
        throw 'The expected parent ID must be an integer and its logon generation a decimal string.'
    }
    if ($null -eq $Request.expectedChildSessionId) {
        if ($null -ne $Request.expectedChildLogonTime) { throw 'A fresh Child Session request requires a null child ID and logon generation.' }
    }
    elseif (($Request.expectedChildSessionId -isnot [int] -and $Request.expectedChildSessionId -isnot [long]) -or $Request.expectedChildLogonTime -isnot [string]) {
        throw 'The expected child ID must be an integer and its logon generation a decimal string.'
    }
    return [CuaRdp.Native.ChildSessionExpectation]::new([int]$Request.expectedParentSessionId, [string]$Request.expectedParentLogonTime,
        [Nullable[int]]$Request.expectedChildSessionId, [string]$Request.expectedChildLogonTime)
}

function Get-InteractiveAuthentication($Request) {
    if ($null -eq $Request.PSObject.Properties['authentication']) { return $false }
    if ($Request.authentication -isnot [string] -or $Request.authentication -cnotin @('background', 'interactive')) { throw 'authentication must be background or interactive.' }
    if ($Request.authentication -ceq 'interactive' -and (Get-RdpRequestMode $Request) -cne 'child-session') { throw 'Interactive authentication is only supported for Child Session.' }
    return $Request.authentication -ceq 'interactive'
}

function Get-WindowVisibility($Request) {
    if ($null -eq $Request.PSObject.Properties['window']) { return $false }
    if ($Request.window -isnot [string] -or $Request.window -cnotin @('hidden', 'visible')) { throw 'window must be hidden or visible.' }
    if ($Request.window -ceq 'visible' -and (Get-RdpRequestMode $Request) -cne 'child-session') { throw 'A visible watch window is only supported for Child Session.' }
    return $Request.window -ceq 'visible'
}
