# --- CONFIGURATIONS ---
$ComputerName = "1586774A"
$LocalMsuPath = "\\Njnwksms08v\Automation\KBs\dotnet\*.msu"
$RemoteFolder = "C:\temp\kb\dotnet"

# --- LOCAL FILE RESOLUTION & KB ID ---
$MsuFile = Get-Item -Path $LocalMsuPath -ErrorAction Stop
$FileName = $MsuFile.Name
# FIXED: Changed $Matches to $Matches[0] to extract the actual string string value
$KbId = if ($FileName -match "KB\d+") { $Matches[0] } else { "KB5087058" }

# --- COPY FILE TO REMOTE MACHINE ---
$RemoteSharePath = "\\$ComputerName\c$\temp\kb\dotnet"
if (-not (Test-Path $RemoteSharePath)) { New-Item -ItemType Directory -Path $RemoteSharePath -Force | Out-Null }
Copy-Item -Path $MsuFile.FullName -Destination $RemoteSharePath -Force

# --- REMOTE EXECUTION ---
Invoke-Command -ComputerName $ComputerName -ScriptBlock {
    param($FileName, $KbId, $RemoteFolder)
    $msuPath = Join-Path $RemoteFolder $FileName

    # 1. Check if already installed
    if (Get-HotFix -Id $KbId -ErrorAction SilentlyContinue) {
        Write-Host "$KbId is already installed." -ForegroundColor Green
        return
    }

    # 2. Extract MSU because WUSA usually blocks via WinRM sessions
    Write-Host "Extracting MSU file..." -ForegroundColor Cyan
    $ExtractDir = Join-Path $RemoteFolder "extracted"
    if (-not (Test-Path $ExtractDir)) { New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null }
    expand -f:* $msuPath $ExtractDir | Out-Null
    $cabFile = Get-ChildItem -Path $ExtractDir -Filter "*.cab" | Select-Object -First 1

    # 3. Install via DISM (Reliable method for remote PowerShell execution)
    Write-Host "Installing $KbId via DISM..." -ForegroundColor Cyan
    $dismLog = Join-Path $RemoteFolder "$KbId-dism.log"
    
    $process = Start-Process "dism.exe" -ArgumentList "/online /add-package /packagepath:`"$($cabFile.FullName)`" /logpath:`"$dismLog`" /norestart /quiet" -Wait -PassThru
    $process.WaitForExit()

    # 4. Final Validation & SCCM Sync
    if (Get-HotFix -Id $KbId -ErrorAction SilentlyContinue) {
        Write-Host "$KbId installed successfully!" -ForegroundColor Green
        
        # 5. Trigger SCCM Actions to clear the Software Center view
        Write-Host "Triggering SCCM client cycles to update Software Center..." -ForegroundColor Cyan
        
        # Software Update Scan Cycle
        Invoke-WMIMethod -Namespace root\ccm -Class SMS_CLIENT -Name TriggerSchedule -ArgumentList "{00000000-0000-0000-0000-000000000113}" | Out-Null
        # Software Update Deployment Evaluation Cycle
        Invoke-WMIMethod -Namespace root\ccm -Class SMS_CLIENT -Name TriggerSchedule -ArgumentList "{00000000-0000-0000-0000-000000000108}" | Out-Null
        # Hardware Inventory Cycle
        Invoke-WMIMethod -Namespace root\ccm -Class SMS_CLIENT -Name TriggerSchedule -ArgumentList "{00000000-0000-0000-0000-000000000002}" | Out-Null
        
        Write-Host "SCCM cycles triggered. It may take 2-5 minutes for the Software Center to refresh." -ForegroundColor Green
    } else {
        Write-Error "Installation failed. Check the log file at: $dismLog"
    }
} -ArgumentList $FileName, $KbId, $RemoteFolder
