<#
.SYNOPSIS
    Renames a Windows device to <TYPE><SERIAL>, in one pass or as two explicit
    steps using the same script.

.DESCRIPTION
    The name is derived from chassis type and BIOS serial, so it is
    deterministic. Running the script twice on the same machine always produces
    the same name, which is what makes the two-step mode safe.

    Stages:
      -Stage AD     Rename the Active Directory computer object only.
      -Stage Local  Rename the local machine only.
      -Stage Both   Both, in the correct order (default).

    Order matters. AD is renamed first so that when the machine renames itself
    the directory already agrees, which preserves the trust relationship. A
    local rename without the matching AD change is what produces "the security
    database on the server does not have a computer account for this
    workstation trust relationship" at next sign-in.

    The AD rename is performed over LDAP via ADSI, so RSAT is not required.

    Idempotent at every stage: if a name is already correct that stage is
    skipped.

.PARAMETER Stage
    AD, Local, or Both. Default Both.

.PARAMETER DomainCredential
    Credential with rights to rename the computer object. Required for the AD
    stage unless the current user already has those rights.

.PARAMETER Restart
    Restart after a successful local rename.

.PARAMETER Prefix
    Override automatic type detection (for example "SV").

.EXAMPLE
    .\Set-StandardComputerName-v3.ps1 -WhatIf
    .\Set-StandardComputerName-v3.ps1 -Stage AD    -DomainCredential (Get-Credential)
    .\Set-StandardComputerName-v3.ps1 -Stage Local -Restart
    .\Set-StandardComputerName-v3.ps1 -DomainCredential (Get-Credential) -Restart
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('AD','Local','Both')]
    [string]$Stage = 'Both',

    [System.Management.Automation.PSCredential]$DomainCredential,
    [switch]$Restart,

    [ValidatePattern('^[A-Za-z]{1,4}$')]
    [string]$Prefix,

    [string]$LogPath = 'C:\ProgramData\ComputerRename.log'
)

function Write-Log {
    param([string]$Message, [string]$Colour = 'White')
    Write-Host $Message -ForegroundColor $Colour
    try {
        "{0}  {1}" -f (Get-Date -Format 's'), $Message |
            Out-File -FilePath $LogPath -Append -Encoding utf8
    } catch { }
}

Write-Log "=== Computer rename (stage: $Stage) ===" Cyan

# --- 1. Device type prefix --------------------------------------------------
if ($Prefix) {
    $type = $Prefix.ToUpper()
    Write-Log "Prefix supplied: $type"
}
else {
    $cs       = Get-CimInstance Win32_ComputerSystem
    $chassis  = (Get-CimInstance Win32_SystemEnclosure).ChassisTypes
    $portable = 8,9,10,11,12,14,18,21,30,31,32
    $server   = 17,23,28,29

    $isVirtual = $cs.Model -match 'Virtual|VMware|KVM|Xen|Hyper-V' -or
                 $cs.Manufacturer -match 'Microsoft Corporation.*Virtual|VMware|Xen|QEMU'

    $type = if     ($isVirtual)                                  { 'VM' }
            elseif ($chassis | Where-Object { $_ -in $server })   { 'SV' }
            elseif ($chassis | Where-Object { $_ -in $portable }) { 'LT' }
            else                                                 { 'DT' }

    Write-Log "Chassis: $($chassis -join ',')  Model: $($cs.Model)"
    Write-Log "Detected type: $type"
}

# --- 2. Serial --------------------------------------------------------------
$rawSerial = (Get-CimInstance Win32_BIOS).SerialNumber
if ($null -eq $rawSerial) { $rawSerial = '' }
$rawSerial = $rawSerial.Trim()

$placeholders = @('To Be Filled By O.E.M.','System Serial Number','Default string',
                  'None','Not Specified','Not Applicable','0123456789','INVALID',
                  'Chassis Serial Number','Serial Number')

if ([string]::IsNullOrWhiteSpace($rawSerial) -or $placeholders -contains $rawSerial) {
    Write-Log "ABORT: BIOS serial missing or placeholder ('$rawSerial')." Red
    exit 1
}

$serial = ($rawSerial -replace '[^A-Za-z0-9-]','').ToUpper()
if ([string]::IsNullOrWhiteSpace($serial)) {
    Write-Log "ABORT: serial contained no usable characters." Red
    exit 1
}

# --- 3. Build the name ------------------------------------------------------
$available = 15 - $type.Length
if ($serial.Length -gt $available) {
    $serial = $serial.Substring($serial.Length - $available)
    Write-Log "Serial truncated to fit 15 characters." Yellow
}
$newName = ("$type$serial").Trim('-')

if ($newName -match '^\d+$') {
    Write-Log "ABORT: generated name '$newName' is all digits." Red
    exit 1
}

$oldName        = $env:COMPUTERNAME
$isDomainJoined = (Get-CimInstance Win32_ComputerSystem).PartOfDomain

Write-Log "Current name : $oldName"
Write-Log "Target name  : $newName" Cyan
Write-Log "Domain joined: $isDomainJoined"

if (-not $PSCmdlet.ShouldProcess($oldName, "Rename to $newName (stage $Stage)")) {
    Write-Log "WhatIf: no change made." Yellow
    exit 0
}

# --- 4. AD helpers ----------------------------------------------------------
function New-AdEntry {
    param([string]$Path, [System.Management.Automation.PSCredential]$Credential)
    if ($Credential) {
        New-Object DirectoryServices.DirectoryEntry(
            $Path, $Credential.UserName, $Credential.GetNetworkCredential().Password)
    } else {
        New-Object DirectoryServices.DirectoryEntry($Path)
    }
}

function Get-AdComputerDn {
    param([string]$Name, [System.Management.Automation.PSCredential]$Credential)
    $root     = New-AdEntry -Path "LDAP://RootDSE" -Credential $Credential
    $domainDn = $root.defaultNamingContext
    $searchRoot = New-AdEntry -Path "LDAP://$domainDn" -Credential $Credential
    $searcher = New-Object DirectoryServices.DirectorySearcher($searchRoot)
    $searcher.Filter = "(&(objectClass=computer)(cn=$Name))"
    [void]$searcher.PropertiesToLoad.Add('distinguishedname')
    $found = $searcher.FindOne()
    if (-not $found) { return $null }
    return $found.Properties['distinguishedname'][0]
}

function Rename-AdComputerObject {
    param(
        [string]$CurrentName,
        [string]$NewName,
        [System.Management.Automation.PSCredential]$Credential
    )

    # Already renamed?
    if (Get-AdComputerDn -Name $NewName -Credential $Credential) {
        Write-Log "AD object '$NewName' already exists. AD stage already done." Green
        return $true
    }

    $dn = Get-AdComputerDn -Name $CurrentName -Credential $Credential
    if (-not $dn) { throw "Computer object '$CurrentName' not found in the directory." }
    Write-Log "AD object: $dn"

    $obj = New-AdEntry -Path "LDAP://$dn" -Credential $Credential

    try {
        $deny = $obj.ObjectSecurity.Access | Where-Object {
            $_.AccessControlType -eq 'Deny' -and $_.ActiveDirectoryRights -match 'Delete'
        }
        if ($deny) {
            Write-Log "NOTE: object is protected from accidental deletion." Yellow
            Write-Log "      Clear that flag in ADUC if the rename is denied." Yellow
        }
    } catch { }

    $obj.Rename("CN=$NewName")
    $obj.Put('sAMAccountName', "$NewName`$")
    $obj.SetInfo()
    Write-Log "AD object renamed to $NewName (sAMAccountName $NewName`$)." Green
    return $true
}

# --- 5. Stage: AD -----------------------------------------------------------
if ($Stage -in 'AD','Both') {
    if (-not $isDomainJoined) {
        Write-Log "Not domain-joined; skipping the AD stage." Yellow
    }
    else {
        if (-not $DomainCredential) {
            Write-Log "No -DomainCredential supplied. Using the current user's rights." Yellow
        }
        try {
            [void](Rename-AdComputerObject -CurrentName $oldName -NewName $newName -Credential $DomainCredential)
            Write-Log "AD stage complete." Green
            if ($Stage -eq 'Both') {
                Write-Log "Waiting 10 seconds for the directory to settle..."
                Start-Sleep -Seconds 10
            }
        }
        catch {
            Write-Log "AD stage FAILED: $($_.Exception.Message)" Red
            Write-Log "Check OU permissions and the accidental-deletion flag." Yellow
            if ($Stage -eq 'Both') {
                Write-Log "Stopping before the local rename, to avoid breaking the trust." Red
                exit 1
            }
            exit 1
        }
    }
}

if ($Stage -eq 'AD') {
    Write-Log "Done. Run again with -Stage Local on the device to complete the rename." Cyan
    exit 0
}

# --- 6. Stage: Local --------------------------------------------------------
if ($oldName -eq $newName) {
    Write-Log "Local machine already named correctly." Green
    exit 0
}

try {
    Rename-Computer -NewName $newName -Force -ErrorAction Stop
    Write-Log "Local machine renamed to $newName." Green
}
catch {
    Write-Log "Local rename FAILED: $($_.Exception.Message)" Red
    Write-Log "If the AD stage succeeded, the directory now holds '$newName'." Yellow
    Write-Log "Re-run with -Stage Local once the cause is resolved." Yellow
    exit 1
}

if ($Restart) {
    Write-Log "Restarting to apply the new name..." Yellow
    Restart-Computer -Force
} else {
    Write-Log "Restart required for the new name to take effect." Yellow
}
exit 0
