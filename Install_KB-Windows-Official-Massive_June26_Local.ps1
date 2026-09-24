# --- SCRIPT CONFIGURATIONS ---
# Replace with your computer list (you can load from a TXT using: Get-Content "C:\path\to\list.txt")
$ComputerList  = @(

"1583109A"

)  
$LocalMsuPath  = "\\Njnwksms08v\Automation\KBs\23h2\*.msu"
$RemoteFolder  = "C:\temp\kb\23h2"

# --- LOCAL FILE RESOLUTION ---
$MsuFile = Get-Item -Path $LocalMsuPath -ErrorAction Stop
$FileName = $MsuFile.Name

# Extracts the KB ID from the file name
if ($FileName -match "KB\d+") {
    $KbId = $Matches[0]
} else {
    $KbId = "KB-Installation"
}

# --- MASS COPY PROCESS ---
Write-Host "Starting directory creation and file copy to target machines..." -ForegroundColor Cyan

$OnlineComputers = @()

foreach ($ComputerName in $ComputerList) {
    if (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet) {
        $RemoteSharePath = "\\$ComputerName\c$\temp\kb\23h2"
        $OnlineComputers += $ComputerName
        
        try {
            if (-not (Test-Path $RemoteSharePath)) {
                New-Item -ItemType Directory -Path $RemoteSharePath -Force | Out-Null
            }
            Copy-Item -Path $MsuFile.FullName -Destination $RemoteSharePath -Force
            Write-Host "[$ComputerName] File copied successfully." -ForegroundColor Green
        } catch {
            Write-Warning "[$ComputerName] Error copying file: $_"
        }
    } else {
        Write-Warning "[$ComputerName] Machine offline. Skipping copy."
    }
}

if ($OnlineComputers.Count -eq 0) {
    Write-Warning "No online machines available for installation. Exiting script."
    exit
}

# --- MASS REMOTE EXECUTION ---
Write-Host "`nTriggering batch installation on online machines..." -ForegroundColor Cyan

# Running the installation as a job
$Job = Invoke-Command -ComputerName $OnlineComputers -ScriptBlock {
    param($FileName, $KbId, $RemoteFolder)

    $msuPath = Join-Path $RemoteFolder $FileName

    # Internal function to validate if the KB is already installed
    function Test-KBInstalled ($KbId) {
        $search = Get-HotFix -Id $KbId -ErrorAction SilentlyContinue
        return ($null -ne $search)
    }

    # Pre-check before starting
    if (Test-KBInstalled -KbId $KbId) {
        return "SUCCESS: $KbId is already installed."
    }

    # Method 1: WUSA
    $wusaLog = Join-Path $RemoteFolder "$KbId-wusa.log"
    $process = Start-Process "wusa.exe" -ArgumentList "`"$msuPath`" /quiet /norestart /log:`"$wusaLog`"" -Wait -PassThru
    
    Start-Sleep -Seconds 15

    if (Test-KBInstalled -KbId $KbId) {
        return "SUCCESS: $KbId installed via WUSA."
    }

    # Method 2: DISM Fallback
    $dismLog = Join-Path $RemoteFolder "$KbId-dism.log"
    $dismCmd = "dism /online /add-package /packagepath:`"$msuPath`" /logpath:`"$dismLog`" /norestart"
    
    cmd.exe /c $dismCmd
    Start-Sleep -Seconds 20

    # Final post-DISM validation
    if (Test-KBInstalled -KbId $KbId) {
        return "SUCCESS: $KbId installed via DISM."
    } else {
        return "ERROR: Installation failed. Check logs in $RemoteFolder"
    }

} -ArgumentList $FileName, $KbId, $RemoteFolder -AsJob

# Displays live tracking progress in the console safely
Write-Host "Waiting for background deployments to complete..." -ForegroundColor Yellow

# Wait for the job to finish completely before pulling the results to avoid buffer cutoffs
$null = Wait-Job $Job

# Process and colorize the results
Get-Job $Job | Receive-Job | ForEach-Object {
    if ($_.PSObject.Properties['Value']) {
        $OutputText = $_.Value
    } else {
        $OutputText = $_.ToString()
    }

    $Color = if ($OutputText -match "SUCCESS") { "Green" } else { "Red" }
    Write-Host "[$($_.PSComputerName)] $OutputText" -ForegroundColor $Color
}

# Clear the job from memory after completion
Remove-Job $Job
Write-Host "`nDeployment process finished." -ForegroundColor Cyan
