param(
    [Parameter(Mandatory=$false)]
    [switch]$Online,

    [Parameter(Mandatory=$false)]
    [string]$GroupTag,

    [Parameter(Mandatory=$false)]
    [switch]$Assign,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath
)

Write-Host ""
Write-Host "Windows Autopilot Hardware Hash Collection" -ForegroundColor Cyan
Write-Host ""

function Write-LogMessage {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

Write-LogMessage "Checking for Get-WindowsAutopilotInfo script..." -Color Yellow

$scriptInstalled = Get-InstalledScript -Name Get-WindowsAutopilotInfo -ErrorAction SilentlyContinue

if (!$scriptInstalled) {
    Write-LogMessage "Installing Get-WindowsAutopilotInfo script..." -Color Yellow
    try {
        Install-Script -Name Get-WindowsAutopilotInfo -Force -Scope CurrentUser -ErrorAction Stop
        Write-LogMessage "Script installed successfully" -Color Green
    } catch {
        Write-LogMessage "Installation failed: $($_.Exception.Message)" -Color Red
        Write-Host ""
        Write-Host "Manual Installation Steps:" -ForegroundColor Yellow
        Write-Host "1. Open PowerShell as Administrator" -ForegroundColor Cyan
        Write-Host "2. Run: Install-Script -Name Get-WindowsAutopilotInfo -Force" -ForegroundColor Cyan
        Write-Host "3. Re-run this script" -ForegroundColor Cyan
        exit 1
    }
} else {
    Write-LogMessage "Get-WindowsAutopilotInfo script already installed" -Color Green
}

Write-Host ""

if ($Online) {
    Write-LogMessage "Uploading hardware hash to Intune online..." -Color Yellow
    Write-Host ""
    
    try {
        $params = @()
        $params += "-Online"
        
        if ($GroupTag) {
            $params += "-GroupTag"
            $params += $GroupTag
        }
        
        if ($Assign) {
            $params += "-Assign"
        }
        
        Write-LogMessage "Attempting online upload. You will be prompted to authenticate..." -Color Yellow
        
        Get-WindowsAutopilotInfo @params
        
        Write-Host ""
        Write-LogMessage "Hardware hash uploaded successfully to Intune" -Color Green
        
    } catch {
        Write-LogMessage "Online upload failed: $($_.Exception.Message)" -Color Red
        Write-Host ""
        Write-LogMessage "Falling back to offline mode..." -Color Yellow
        
        if (!$OutputPath) {
            $OutputPath = "AutopilotHash_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        }
        
        Get-WindowsAutopilotInfo -OutputFile $OutputPath
        
        Write-Host ""
        Write-LogMessage "Hardware hash saved to: $OutputPath" -Color Green
        Write-LogMessage "Upload this CSV file manually to:" -Color Yellow
        Write-Host "  Intune > Devices > Enroll devices > Windows > Devices > Import" -ForegroundColor Cyan
    }
} else {
    Write-LogMessage "Collecting hardware hash in offline mode..." -Color Yellow
    
    if (!$OutputPath) {
        $OutputPath = "AutopilotHash_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    }
    
    try {
        Get-WindowsAutopilotInfo -OutputFile $OutputPath
        
        Write-Host ""
        Write-LogMessage "Hardware hash saved to: $OutputPath" -Color Green
        Write-Host ""
        Write-Host "Next Steps:" -ForegroundColor Yellow
        Write-Host "1. Go to Microsoft Intune admin center" -ForegroundColor Cyan
        Write-Host "2. Navigate to: Devices > Enroll devices > Windows > Devices" -ForegroundColor Cyan
        Write-Host "3. Click 'Import' and upload this CSV file" -ForegroundColor Cyan
        Write-Host ""
        
    } catch {
        Write-LogMessage "Failed to collect hardware hash: $($_.Exception.Message)" -Color Red
        exit 1
    }
}

Write-Host ""
Write-LogMessage "Script completed" -Color Green
Write-Host ""