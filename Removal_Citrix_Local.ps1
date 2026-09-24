# Ensure the script is running as Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as an Administrator. Please restart PowerShell as Administrator."
    Exit
}

# Define local folder path
$targetLocalPath = "C:\temp\remove_citrix_tool"

# 1. Forcefully kill running Citrix processes and stop services
Write-Host "Stopping Citrix processes and services to unlock files..." -ForegroundColor Cyan
Get-Process -Name "*citrix*", "*receiver*" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Service -Name "*citrix*" -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue

Start-Sleep -Seconds 3

# 2. Run the cleanup utility locally
$exePath = Join-Path $targetLocalPath "ReceiverCleanupUtility.exe"
if (Test-Path $exePath) {
    Write-Host "Executing ReceiverCleanupUtility.exe..." -ForegroundColor Cyan
    Start-Process -FilePath $exePath -ArgumentList "/silent" -Wait -NoNewWindow
} else {
    Write-Error "CRITICAL ERROR: Executable was not found at $exePath"
    Exit
}

Start-Sleep -Seconds 5

# 3. Deep cleanup of folders using simple path loops
Write-Host "Starting directory cleanup..." -ForegroundColor Cyan

# Clear temporary caches
if (Test-Path "C:\Windows\Temp") { Get-ChildItem "C:\Windows\Temp" -Recurse -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path "C:\Windows\ccmcache") { Get-ChildItem "C:\Windows\ccmcache" -Recurse -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }

# Delete Program Files folders
if (Test-Path "C:\Program Files") { Get-ChildItem "C:\Program Files" -Filter "*citrix*" -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path "C:\Program Files (x86)") { Get-ChildItem "C:\Program Files (x86)" -Filter "*citrix*" -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }

# Delete AppData folders for all profiles
if (Test-Path "C:\Users") {
    $userProfiles = Get-ChildItem "C:\Users" -Directory
    foreach ($profile in $userProfiles) {
        if ($profile.Name -notmatch "Public|Default|All Users|NetworkService|LocalService") {
            $localApp = Join-Path $profile.FullName "AppData\Local"
            $roamingApp = Join-Path $profile.FullName "AppData\Roaming"
            
            if (Test-Path $localApp) { Get-ChildItem $localApp -Filter "*citrix*" -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path $roamingApp) { Get-ChildItem $roamingApp -Filter "*citrix*" -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

Write-Host "Process completed successfully on the local machine!" -ForegroundColor Green
