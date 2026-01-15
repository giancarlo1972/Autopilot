# Step 1: Bypass execution policy for this session
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# Step 2: Install required modules
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Install-Module WindowsAutopilotIntune -MinimumVersion 5.4 -Force
Install-Module Microsoft.Graph.Authentication -Force
Install-Module Microsoft.Graph.Groups -Force
Install-Module Microsoft.Graph.Identity.DirectoryManagement -Force

# Step 3: Import modules
Import-Module WindowsAutopilotIntune
Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Groups
Import-Module Microsoft.Graph.Identity.DirectoryManagement

# Step 4: Connect to Graph (approve permissions)
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All","Device.Read.All","Group.Read.All"

# Step 5: Get profiles and export to folder
$targetDir = "C:\Autopilot"
New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

$profiles = Get-AutopilotProfile
$profiles | ForEach-Object {
    $profileDir = Join-Path $targetDir $_.displayName
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    $_ | ConvertTo-AutopilotConfigurationJSON | Set-Content -Path "$profileDir\AutopilotConfigurationFile.json" -Encoding Ascii
}

# Step 6: (Manual) Copy desired profile's JSON to provisioning folder
# Example: Copy-Item "C:\Autopilot\YourProfileName\AutopilotConfigurationFile.json" "C:\Windows\Provisioning\Autopilot\" -Force

# Step 7: Clean up temp folder when done
# Remove-Item -Path $targetDir -Recurse -Force
