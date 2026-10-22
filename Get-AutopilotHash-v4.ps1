<#
.SYNOPSIS
    Collects the Windows Autopilot hardware hash, with preflight network checks,
    a no-internet fallback, direct Intune Autopilot registration with
    confirmation, and optional upload to ServiceNow.

.DESCRIPTION
    Runs a short preflight (time sync, IPv6 state, connectivity), then collects
    the hardware hash directly from WMI (no downloads) and always writes a CSV.
    With -Online it then imports the device into Intune Autopilot through Graph
    and waits until the device is actually listed before reporting success.

    Preflight matters at OOBE: clock skew beyond a few minutes breaks Entra join
    and Intune enrolment, and a half-working IPv6 path causes connections to stall
    before falling back to IPv4.

    Diagnostics always run and only report. Changes are made only when you pass a
    fix switch (or -Prep for the recommended set).

    IPv6 handling, two options:
      -PreferIPv4  : sets Tcpip6 DisabledComponents = 0x20. This does NOT disable
                     IPv6; it makes the prefix policy table prefer IPv4 over IPv6.
                     IPv6 stays bound and functional, just deprioritised. Unlike
                     0xFF (full disable) it does not risk breaking components.
                     Requires a REBOOT to take effect.
      -DisableIPv6 : hard per-adapter unbind (ms_tcpip6). Immediate, no reboot,
                     but heavier-handed. Use only if -PreferIPv4 is insufficient.

    -Prep enables -FixTime and -PreferIPv4.

    All console output is also written to a log file next to the CSV.

.PARAMETER Prep
    Equivalent to -FixTime -PreferIPv4.

.PARAMETER FixTime
    Set the time zone, start the Windows Time service, configure NTP and force a
    resync. If NTP is blocked, sets the clock from a plain-HTTP Date header.

.PARAMETER TimeZone
    Time zone applied by -FixTime. Default 'Eastern Standard Time'.

.PARAMETER PreferIPv4
    Set DisabledComponents = 0x20 (prefer IPv4 over IPv6). Requires reboot.

.PARAMETER DisableIPv6
    Unbind IPv6 from all physical adapters (immediate, no reboot).

.PARAMETER Online
    Import the device into Intune Autopilot via Graph, then confirm it is listed.
    Sign-in uses a device code shown on screen (works at OOBE, no modules needed). Needs an account with
    DeviceManagementServiceConfig.ReadWrite.All (Intune admin).

.PARAMETER TenantId
    Entra tenant for -Online. Defaults to Mountainside.

.PARAMETER GroupTag
    Optional Autopilot group tag (applied with -Online).

.PARAMETER OutputPath
    Full path for the CSV. Defaults to the script's own folder, then C:\Temp.

.PARAMETER Upload
    After a successful CSV, post the record to ServiceNow.
    Requires AP_SNOW_* environment variables. Secrets are never hardcoded.

.EXAMPLE
    .\Get-AutopilotHash-v4.ps1
    .\Get-AutopilotHash-v4.ps1 -Prep
    .\Get-AutopilotHash-v4.ps1 -Prep -Upload
    .\Get-AutopilotHash-v4.ps1 -Online -GroupTag "Corp" -Prep
#>

[CmdletBinding()]
param(
    [switch]$Online,
    [string]$GroupTag,
    [string]$OutputPath,
    [switch]$Prep,
    [switch]$FixTime,
    [switch]$PreferIPv4,
    [switch]$DisableIPv6,
    [switch]$Upload,
    [string]$TimeZone = 'Eastern Standard Time',
    [string]$TenantId = 'b78d25b1-934c-433c-8534-477f0b8978f8'
)

$ErrorActionPreference = 'Stop'
if ($Prep) { $FixTime = $true; $PreferIPv4 = $true }

# --- Logging ----------------------------------------------------------------
$script:LogFile = $null
function Say {
    param([string]$m,[string]$c='White')
    Write-Host $m -ForegroundColor $c
    if ($script:LogFile) {
        try { "{0}  {1}" -f (Get-Date -Format 's'), $m |
              Out-File -FilePath $script:LogFile -Append -Encoding utf8 } catch { }
    }
}
function Head { param([string]$m) Write-Host ""; Say "--- $m " Cyan }

Write-Host ""
Say "Windows Autopilot Hardware Hash Collection (v4)" Cyan

# --- 1. Elevation check -----------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole(
              [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Say "ERROR: This script must run elevated (or as SYSTEM at OOBE)." Red
    Say "Right-click PowerShell > Run as administrator, then re-run." Yellow
    exit 1
}
Say "Running elevated as: $($id.Name)" Green

# --- 2. Decide output location (early, so logging works from here on) -------
if (-not $OutputPath) {
    $dir = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Temp' }
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $serialForName = (Get-CimInstance Win32_BIOS).SerialNumber.Trim() -replace '[\\/:*?"<>|]',''
    $OutputPath = Join-Path $dir "AutopilotHash_$serialForName.csv"
}
$script:LogFile = [IO.Path]::ChangeExtension($OutputPath, '.log')
Say "Output file: $OutputPath" Cyan
Say "Log file   : $script:LogFile" Cyan

# --- 3. Preflight: network --------------------------------------------------
Head "Preflight"
$rebootNeeded = $false

$v6 = Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue |
      Where-Object { $_.Enabled }

if ($PreferIPv4) {
    try {
        $tcp6 = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'
        if (-not (Test-Path $tcp6)) { New-Item -Path $tcp6 -Force | Out-Null }
        $cur = (Get-ItemProperty -Path $tcp6 -Name DisabledComponents -ErrorAction SilentlyContinue).DisabledComponents
        if ($cur -eq 0x20) {
            Say "IPv6 already set to prefer IPv4 (DisabledComponents=0x20)." Green
        } else {
            New-ItemProperty -Path $tcp6 -Name DisabledComponents -PropertyType DWord -Value 0x20 -Force | Out-Null
            Say "IPv6 set to prefer IPv4 (DisabledComponents=0x20)." Green
            Say "  Takes effect after REBOOT. IPv6 stays enabled, just deprioritised." Yellow
            $rebootNeeded = $true
        }
    } catch {
        Say "Could not set DisabledComponents: $($_.Exception.Message)" Red
    }
}
elseif ($DisableIPv6) {
    if ($v6) {
        foreach ($a in $v6) {
            try {
                Disable-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip6 -ErrorAction Stop
                Say "IPv6 unbound on $($a.Name)" Green
            } catch {
                Say "Could not unbind IPv6 on $($a.Name): $($_.Exception.Message)" Red
            }
        }
    } else {
        Say "IPv6 not bound on any adapter." Green
    }
}
else {
    if ($v6) {
        Say ("IPv6 enabled on: " + ($v6.Name -join ', ')) Yellow
        Say "  (run with -PreferIPv4 [recommended] or -DisableIPv6)" Yellow
    } else {
        Say "IPv6 not bound on any adapter." Green
    }
}

# Time
# Two independent checks, because either one alone can lie:
#   1. Is w32time running and synced to a real source? (w32tm prints its errors to
#      stdout, so "The service has not been started (0x80070426)" used to be read
#      as a valid source name and the fix was skipped.)
#   2. How far off is the clock really? Measured against the Date header of a
#      plain-HTTP endpoint. Plain HTTP on purpose: HTTPS fails certificate validity
#      checks when the clock is badly wrong, which is exactly the case we care about.
$MaxSkewSec = 120

function Get-NetUtc {
    foreach ($u in 'http://www.msftconnecttest.com/connecttest.txt','http://www.google.com/generate_204') {
        try {
            $r = Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
            $d = $r.Headers['Date']; if ($d -is [array]) { $d = $d[0] }
            if ($d) { return [DateTimeOffset]::Parse($d, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
        } catch { }
    }
    return $null
}

function Get-TimeState {
    $ErrorActionPreference = 'Continue'   # native stderr must not throw under the script-wide 'Stop'
    $svc = Get-Service w32time -ErrorAction SilentlyContinue
    $st  = [ordered]@{
        Service = if ($svc) { "$($svc.Status) (startup: $($svc.StartType))" } else { 'not present' }
        Running = [bool]($svc -and $svc.Status -eq 'Running')
        Source  = $null
        LastSync= $null
        SkewSec = $null
    }
    if ($st.Running) {
        $src = (& w32tm /query /source 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $src -notmatch 'error|0x8') { $st.Source = $src }
        $status = (& w32tm /query /status 2>&1 | Out-String)
        if ($status -match 'Last Successful Sync Time:\s*(.+)') { $st.LastSync = $Matches[1].Trim() }
    }
    $net = Get-NetUtc
    if ($net) { $st.SkewSec = [int][math]::Round(((Get-Date).ToUniversalTime() - $net).TotalSeconds) }
    [pscustomobject]$st
}

function Show-TimeState($t) {
    Say "Time service: $($t.Service)"
    Say "Time source : $(if ($t.Source) { $t.Source } else { '(none - service stopped or query failed)' })"
    if ($t.LastSync) { Say "Last sync   : $($t.LastSync)" }
    Say "Time zone   : $((Get-TimeZone).Id)"
    Say "Local time  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
    Say "Clock skew  : $(if ($null -ne $t.SkewSec) { "$($t.SkewSec)s vs internet time" } else { 'unknown (no HTTP time reference reachable)' })"
}

function Test-TimeOk($t) {
    if (-not $t.Running -or -not $t.Source) { return $false }
    if ($t.Source -match 'Local CMOS Clock|Free-running') { return $false }
    if ($null -ne $t.SkewSec -and [math]::Abs($t.SkewSec) -gt $MaxSkewSec) { return $false }
    if ($isDomain -and $t.Source -match 'time\.windows\.com') {
        Say "  WARNING: domain-joined but syncing from the internet, not a DC." Red
        return $false
    }
    return $true
}

$isDomain = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
if ($isDomain) { Say "Machine is domain-joined: time must come from the domain controllers." Yellow }

$t = Get-TimeState
Show-TimeState $t
$timeOk = Test-TimeOk $t

if (-not $timeOk) {
    if (-not $t.Running) { Say "Windows Time service is not running - the clock is not being synced at all." Yellow }
    else                 { Say "Time is not synchronised to an external source, or the clock is off." Yellow }
    Say "  Clock skew beyond ~5 minutes breaks Entra join and enrolment." Yellow

    if ($FixTime) {
        $ErrorActionPreference = 'Continue'
        try {
            if ($TimeZone -and (Get-TimeZone).Id -ne $TimeZone) {
                Set-TimeZone -Id $TimeZone -ErrorAction Stop
                Say "  Time zone set to $TimeZone" Green
            }
        } catch { Say "  Could not set time zone '$TimeZone': $($_.Exception.Message)" Red }

        try {
            Set-Service w32time -StartupType Automatic -ErrorAction Stop
            if ((Get-Service w32time).Status -ne 'Running') { Start-Service w32time -ErrorAction Stop }
            Say "  Windows Time service started." Green
        } catch {
            Say "  Could not start Windows Time service: $($_.Exception.Message)" Red
        }

        # /syncfromflags:ALL = use the domain hierarchy (DCs) whenever the machine is
        # domain-joined, and fall back to time.windows.com only while it is not.
        # Do NOT use /syncfromflags:manual here: that setting survives the hybrid join
        # and pins the PC to internet time instead of the DC, which breaks Kerberos.
        & w32tm /config /manualpeerlist:"time.windows.com,0x9" /syncfromflags:ALL /update 2>&1 | Out-Null
        Restart-Service w32time -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        $resync = (& w32tm /resync /force 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            Say "  NTP resync failed: $resync" Yellow
            Say "  (outbound UDP 123 may be blocked - will fall back to HTTP time)" Yellow
        }
        Start-Sleep -Seconds 3

        # Fallback: NTP blocked or slow -> set the clock directly from internet time.
        $t = Get-TimeState
        if ($null -ne $t.SkewSec -and [math]::Abs($t.SkewSec) -gt $MaxSkewSec) {
            $net = Get-NetUtc
            if ($net) {
                Set-Date -Date $net.ToLocalTime() | Out-Null
                Say "  Clock set from HTTP time (was off by $($t.SkewSec)s)." Green
                $t = Get-TimeState
            }
        }
        $ErrorActionPreference = 'Stop'

        Say "  After fix:" Cyan
        Show-TimeState $t
        if (Test-TimeOk $t) { Say "  Time OK." Green }
        elseif ($null -ne $t.SkewSec -and [math]::Abs($t.SkewSec) -le $MaxSkewSec) {
            Say "  Clock is correct now; NTP source not confirmed yet (it will settle after setup)." Yellow
        }
        else { Say "  Time is STILL wrong - do not continue to enrolment until fixed." Red }
    } else {
        Say "  (run with -FixTime or -Prep to start the service, resync and correct the clock)" Yellow
    }
}

foreach ($h in 'login.microsoftonline.com','ztd.dds.microsoft.com','enterpriseregistration.windows.net') {
    $r = Test-NetConnection -ComputerName $h -Port 443 -WarningAction SilentlyContinue
    if ($r.TcpTestSucceeded) { Say "Reachable: $h" Green }
    else                     { Say "UNREACHABLE: $h" Red }
}

# --- 4. Collect the hash (direct WMI - same source the official script reads) --
# No PowerShell Gallery dependency: this always works offline, and the CSV is
# always written first so there is a fallback even if the Intune upload fails.
Head "Hash collection"
try {
    $serial = (Get-CimInstance Win32_BIOS).SerialNumber.Trim()
    $hash   = (Get-CimInstance -Namespace root/cimv2/mdm/dmmap `
                -ClassName MDM_DevDetail_Ext01 `
                -Filter "InstanceID='Ext' AND ParentID='./DevDetail'").DeviceHardwareData
    if (-not $hash) { throw "Hardware hash is empty - check TPM state and OS build." }
    'Device Serial Number,Windows Product ID,Hardware Hash' |
        Out-File -FilePath $OutputPath -Encoding ascii -Force
    "$serial,,$hash" | Out-File -FilePath $OutputPath -Encoding ascii -Append
}
catch {
    Say "FAILED: $($_.Exception.Message)" Red
    exit 1
}

# --- 6. Verify the result ---------------------------------------------------
if (-not (Test-Path $OutputPath)) { Say "FAILED: no output file produced." Red; exit 1 }
$lines = Get-Content $OutputPath
if ($lines.Count -lt 2 -or [string]::IsNullOrWhiteSpace($lines[1])) {
    Say "FAILED: output file has no device row." Red; exit 1
}
$fields = $lines[1].Split(',')
if ($fields.Count -lt 3 -or [string]::IsNullOrWhiteSpace($fields[2])) {
    Say "FAILED: hardware hash field is empty." Red; exit 1
}
$deviceSerial = $fields[0]
$deviceHash   = $fields[2]

Head "Result"
Say "SUCCESS" Green
Say "  Serial : $deviceSerial" Cyan
Say "  Hash   : $($deviceHash.Substring(0,[Math]::Min(40,$deviceHash.Length)))..." Cyan
Say "  File   : $OutputPath" Cyan

# --- 6b. Register in Intune (Autopilot) and CONFIRM it landed ----------------
# Pure REST: device-code sign-in + Graph calls with Invoke-RestMethod.
# No Graph PowerShell module - Connect-MgGraph crashes at OOBE ("An error
# occurred when writing to a listener") because the setup profile is incomplete.
# Client ID = Microsoft Graph Command Line Tools (already consented in the tenant).
$script:GraphToken = $null

function Get-GraphTokenDeviceCode {
    param([string]$Tenant,[string]$Scope)
    $cid = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $dc = Invoke-RestMethod -Method Post -UseBasicParsing `
            -Uri "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/devicecode" `
            -Body @{ client_id = $cid; scope = $Scope }

    Write-Host ""
    Say "=================================================================" Yellow
    Say "  On your phone or another PC, open:  $($dc.verification_uri)" Yellow
    Say "  Enter this code:                    $($dc.user_code)" Green
    Say "  Sign in with an Intune admin account. Waiting..." Yellow
    Say "=================================================================" Yellow
    Write-Host ""

    $interval = [int]$dc.interval; if ($interval -lt 5) { $interval = 5 }
    $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $tok = Invoke-RestMethod -Method Post -UseBasicParsing `
                     -Uri "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/token" `
                     -Body @{ grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                              client_id   = $cid
                              device_code = $dc.device_code }
            Say "Signed in." Green
            return $tok.access_token
        } catch {
            $err = $null
            try { $err = ($_.ErrorDetails.Message | ConvertFrom-Json) } catch { }
            switch ($err.error) {
                'authorization_pending' { continue }
                'slow_down'             { $interval += 5; continue }
                'authorization_declined'{ throw "Sign-in was declined." }
                'expired_token'         { throw "The code expired before sign-in completed. Re-run the script." }
                default {
                    $msg = if ($err) { "$($err.error): $($err.error_description)" } else { $_.Exception.Message }
                    throw "Sign-in failed - $msg"
                }
            }
        }
    }
    throw "The code expired before sign-in completed. Re-run the script."
}

function Invoke-Graph {
    param([string]$Method,[string]$Path,$Body)
    $p = @{ Method = $Method; Uri = "https://graph.microsoft.com/$Path"; UseBasicParsing = $true
            Headers = @{ Authorization = "Bearer $script:GraphToken" } }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 5); $p.ContentType = 'application/json' }
    try { Invoke-RestMethod @p }
    catch {
        $detail = $_.ErrorDetails.Message
        throw "Graph $Method $Path failed: $($_.Exception.Message) $detail"
    }
}

function Register-AutopilotDevice {
    param([string]$Serial,[string]$Hash,[string]$Tag,[string]$Tenant)
    $ErrorActionPreference = 'Stop'

    $script:GraphToken = Get-GraphTokenDeviceCode -Tenant $Tenant `
        -Scope 'https://graph.microsoft.com/DeviceManagementServiceConfig.ReadWrite.All'

    $apBase = 'beta/deviceManagement/windowsAutopilotDeviceIdentities'
    $find   = { (Invoke-Graph GET "$apBase`?`$filter=contains(serialNumber,'$Serial')").value }

    # Already registered? Report and stop - re-importing a known device just errors.
    $existing = & $find
    if ($existing) {
        $e = @($existing)[0]
        Say "Already registered in Autopilot." Green
        Say "  Group tag : $($e.groupTag)" Cyan
        Say "  Profile   : $($e.deploymentProfileAssignmentStatus)" Cyan
        return $true
    }

    # Import
    $body = @{
        '@odata.type'      = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
        serialNumber       = $Serial
        hardwareIdentifier = $Hash
        groupTag           = $(if ($Tag) { $Tag } else { '' })
        productKey         = ''
        state              = @{ deviceImportStatus = 'pending'; deviceRegistrationId = ''; deviceErrorCode = 0; deviceErrorName = '' }
    }
    $imp = Invoke-Graph POST 'beta/deviceManagement/importedWindowsAutopilotDeviceIdentities' $body
    Say "Import submitted. Waiting for Intune to process it (usually 1-5 min)..." Yellow

    $deadline = (Get-Date).AddMinutes(15)
    do {
        Start-Sleep -Seconds 20
        $s = (Invoke-Graph GET "beta/deviceManagement/importedWindowsAutopilotDeviceIdentities/$($imp.id)").state
        Say "  Import status: $($s.deviceImportStatus)"
    } while ($s.deviceImportStatus -notin 'complete','error' -and (Get-Date) -lt $deadline)

    if ($s.deviceImportStatus -eq 'error') {
        Say "IMPORT FAILED: $($s.deviceErrorName) (code $($s.deviceErrorCode))" Red
        if ($s.deviceErrorCode -in 806,808) {
            Say "  The device is registered to ANOTHER tenant (e.g. reseller/previous owner)." Yellow
            Say "  It must be deregistered there first, or released via the OEM/reseller." Yellow
        }
        return $false
    }
    if ($s.deviceImportStatus -ne 'complete') {
        Say "Import still not complete after 15 minutes - check Intune later." Yellow
        return $false
    }

    # Import done -> nudge an Autopilot sync, clean up the import record, confirm listing
    try { Invoke-Graph POST 'beta/deviceManagement/windowsAutopilotSettings/sync' | Out-Null } catch { }
    try { Invoke-Graph DELETE "beta/deviceManagement/importedWindowsAutopilotDeviceIdentities/$($imp.id)" | Out-Null } catch { }

    $deadline = (Get-Date).AddMinutes(15)
    do {
        Start-Sleep -Seconds 30
        $dev = & $find
    } while (-not $dev -and (Get-Date) -lt $deadline)

    if (-not $dev) {
        Say "Import completed but the device is not listed in Autopilot yet. Check again in 15 min." Yellow
        return $false
    }
    $d = @($dev)[0]
    Say "CONFIRMED in Intune Autopilot devices." Green
    Say "  Serial    : $($d.serialNumber)" Cyan
    Say "  Group tag : $($d.groupTag)" Cyan
    Say "  Profile   : $($d.deploymentProfileAssignmentStatus)  (wait for 'assigned...' before setup)" Cyan
    return $true
}

if ($Online) {
    Head "Intune registration"
    try {
        $ok = Register-AutopilotDevice -Serial $deviceSerial -Hash $deviceHash -Tag $GroupTag -Tenant $TenantId
        if (-not $ok) { Say "CSV is on disk at $OutputPath for manual import." Yellow }
    } catch {
        Say "Intune registration failed: $($_.Exception.Message)" Red
        Say "CSV is on disk at $OutputPath for manual import." Yellow
    } finally {
        $script:GraphToken = $null
    }
}

# --- 7. Optional ServiceNow upload ------------------------------------------
# Secrets come from environment variables, never from this file. Scope the
# ServiceNow account to a single staging table so a leaked credential is
# worth as little as possible.
function Send-ToServiceNow {
    param([string]$FilePath,[string]$Serial,[string]$Hash)

    $Instance = $env:AP_SNOW_INSTANCE   # e.g. mountainside  (from *.service-now.com)
    $Table    = $env:AP_SNOW_TABLE      # e.g. u_autopilot_import
    $User     = $env:AP_SNOW_USER
    $Pass     = $env:AP_SNOW_PASS

    foreach ($v in 'Instance','Table','User','Pass') {
        if (-not (Get-Variable $v -ValueOnly)) {
            throw "ServiceNow upload: missing $v (set the AP_SNOW_* environment variables)."
        }
    }

    $b64  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$User`:$Pass"))
    $hdr  = @{ Authorization = "Basic $b64" }
    $base = "https://$Instance.service-now.com/api/now"

    $body = @{ serial_number   = $Serial
               u_hardware_hash = $Hash
               u_source        = 'Get-AutopilotHash v4' } | ConvertTo-Json

    $rec   = Invoke-RestMethod -Method Post -Uri "$base/table/$Table" `
               -Headers $hdr -ContentType 'application/json' -Body $body
    $sysId = $rec.result.sys_id

    $name = Split-Path $FilePath -Leaf
    Invoke-RestMethod -Method Post `
        -Uri "$base/attachment/file?table_name=$Table&table_sys_id=$sysId&file_name=$name" `
        -Headers $hdr -ContentType 'text/csv' -InFile $FilePath | Out-Null

    Say "  ServiceNow record $sysId created, $name attached." Green
}

if ($Upload) {
    Head "Upload"
    try {
        Send-ToServiceNow -FilePath $OutputPath -Serial $deviceSerial -Hash $deviceHash
    } catch {
        Say "Upload failed: $($_.Exception.Message)" Red
        Say "CSV is still on disk at $OutputPath for manual handling." Yellow
    }
}

Write-Host ""
if (-not $Online) {
    Say "Next: Intune > Devices > Enrollment > Windows Autopilot > Devices > Import" Yellow
    Say "  (or re-run with -Online to register it directly)" Yellow
}
Say "Wait for Profile status = Assigned before booting the machine into setup." Yellow
if ($rebootNeeded) { Say "Reboot pending: the prefer-IPv4 change applies after restart." Yellow }
Write-Host ""
exit 0