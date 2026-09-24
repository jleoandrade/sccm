Clear-Host
Write-Host "=== MASS REMOTE FIX FOR SCCM ERRORS 0x80240022 ===" -ForegroundColor Cyan

# ============================================
# LIST OF COMPUTERS
# ============================================
$Computers = @(
    "1074134A"
    # Add more:
    # "1080747A"
    # "1080748A"
)

# ============================================
# REMOTE SCRIPT EXECUTED ON CLIENT
# ============================================
$RemoteScript = {

    Write-Host "=== Running Fix on $env:COMPUTERNAME ===" -ForegroundColor Cyan

    # 1. Stop update-related services
    Write-Host "[1] Stopping update services..." -ForegroundColor Yellow
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Stop-Service bits -Force -ErrorAction SilentlyContinue
    Stop-Service cryptsvc -Force -ErrorAction SilentlyContinue
    Stop-Service DoSvc -Force -ErrorAction SilentlyContinue

    # 2. Delete Catroot2
    Write-Host "[2] Deleting Catroot2..." -ForegroundColor Yellow
    try {
        Remove-Item "C:\Windows\System32\catroot2" -Recurse -Force -ErrorAction SilentlyContinue
    } catch {}

    # 3. Delete ALL SoftwareDistribution variants
    Write-Host "[3] Deleting ALL SoftwareDistribution folders..." -ForegroundColor Yellow
    $SDPaths = @(
        "C:\Windows\SoftwareDistribution",
        "C:\Windows\SoftwareDistribution.old",
        "C:\Windows\SoftwareDistribution.bak"
    )

    foreach ($path in $SDPaths) {
        if (Test-Path $path) {
            try {
                Remove-Item "$path\*" -Recurse -Force -ErrorAction SilentlyContinue
            } catch {}
        }
    }

    # 4. Reset Delivery Optimization cache
    Write-Host "[4] Resetting Delivery Optimization..." -ForegroundColor Yellow
    try {
        Remove-Item "C:\ProgramData\Microsoft\Windows\DeliveryOptimization\*" -Recurse -Force -ErrorAction SilentlyContinue
    } catch {}

    # 5. Restart services
    Write-Host "[5] Restarting services..." -ForegroundColor Yellow
    Start-Service cryptsvc -ErrorAction SilentlyContinue
    Start-Service bits -ErrorAction SilentlyContinue
    Start-Service wuauserv -ErrorAction SilentlyContinue
    Start-Service DoSvc -ErrorAction SilentlyContinue

    # 6. Run SFC (fast integrity check)
    Write-Host "[6] Running SFC scan..." -ForegroundColor Yellow
    sfc /scannow | Out-Null

    # 7. Restart SCCM Client
    Write-Host "[7] Restarting SCCM Client (CcmExec)..." -ForegroundColor Yellow
    Restart-Service CcmExec -Force -ErrorAction SilentlyContinue

    # Wait for CcmExec to be Running
    for ($i = 1; $i -le 30; $i++) {
        $svc = Get-Service CcmExec -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") { break }
        Start-Sleep -Seconds 3
    }

    # 8. Trigger SCCM cycles
    Write-Host "[8] Triggering SCCM update cycles..." -ForegroundColor Yellow

    $Triggers = @{
        "Machine Policy"  = "{00000000-0000-0000-0000-000000000021}"
        "Update Scan"     = "{00000000-0000-0000-0000-000000000113}"
        "Deployment Eval" = "{00000000-0000-0000-0000-000000000108}"
    }

    foreach ($t in $Triggers.Keys) {
        Write-Host "Triggering: $t"
        try {
            Invoke-WmiMethod -Namespace "root\ccm" -Class SMS_Client -Name TriggerSchedule `
                -ArgumentList $Triggers[$t] -ErrorAction Stop | Out-Null
        } catch {
            Write-Host "Warning: $t could not be triggered (WMI/permissions)." -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 2
    }

    Write-Host "=== Fix completed on $env:COMPUTERNAME ===" -ForegroundColor Green
}

# ============================================
# MASS EXECUTION LOOP
# ============================================
foreach ($PC in $Computers) {

    Write-Host "`n--------------------------------------------------"
    Write-Host "Processing: $PC" -ForegroundColor Cyan

    # Skip if offline
    if (-not (Test-Connection -ComputerName $PC -Count 1 -Quiet)) {
        Write-Host "SKIPPED: $PC is offline." -ForegroundColor Yellow
        continue
    }

    Write-Host "$PC is online. Executing fix..." -ForegroundColor Green

    try {
        Invoke-Command -ComputerName $PC -ScriptBlock $RemoteScript -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: Failed to execute on $PC. Skipping." -ForegroundColor Red
        continue
    }
}

Write-Host "`n=== MASS EXECUTION COMPLETED ===" -ForegroundColor Cyan
