Clear-Host
Write-Host "=== MASS REMOTE FIX FOR SCCM ERROR 0x80D02002 ===" -ForegroundColor Cyan

# ============================================
# LIST OF MACHINES
# ============================================
$Computers = @(
    "1080746A"
)

# ============================================
# REMOTE SCRIPT
# ============================================
$RemoteScript = {

    Write-Host "=== Running Fix on $env:COMPUTERNAME ===" -ForegroundColor Cyan

    # 1. Remove WSUS policies
    Write-Host "[1] Removing legacy WSUS policies..." -ForegroundColor Yellow
    $WUReg = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    $Keys = @(
        "SetPolicyDrivenUpdateSourceForDriverUpdates",
        "SetPolicyDrivenUpdateSourceForFeatureUpdates",
        "SetPolicyDrivenUpdateSourceForOtherUpdates",
        "SetPolicyDrivenUpdateSourceForQualityUpdates",
        "UpdateServiceUrlAlternate"
    )

    if (Test-Path $WUReg) {
        foreach ($k in $Keys) {
            try { Remove-ItemProperty -Path $WUReg -Name $k -ErrorAction SilentlyContinue } catch {}
        }
    }

    # 2. Reset Delivery Optimization
    Write-Host "[2] Resetting Delivery Optimization..." -ForegroundColor Yellow
    Stop-Service DoSvc -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\ProgramData\Microsoft\Windows\DeliveryOptimization\*" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service DoSvc -ErrorAction SilentlyContinue

    # 3. Reset Windows Update
    Write-Host "[3] Resetting Windows Update components..." -ForegroundColor Yellow
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Stop-Service bits -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\Windows\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service bits -ErrorAction SilentlyContinue
    Start-Service wuauserv -ErrorAction SilentlyContinue

    # 4. Clear CCMCache
    Write-Host "[4] Clearing SCCM CCMCache..." -ForegroundColor Yellow
    $Cache = "C:\Windows\ccmcache"
    if (Test-Path $Cache) {
        Remove-Item "$Cache\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "CCMCache cleared."
    }

    # 5. Restart CcmExec
    Write-Host "[5] Restarting SCCM Client service..." -ForegroundColor Yellow
    Restart-Service CcmExec -Force -ErrorAction SilentlyContinue

    # Wait for CcmExec
    Write-Host "Waiting for CcmExec to fully start..." -ForegroundColor Yellow
    for ($i=1; $i -le 30; $i++) {
        if ((Get-Service CcmExec -ErrorAction SilentlyContinue).Status -eq "Running") { break }
        Start-Sleep -Seconds 3
    }

    # Wait for WMI
    Write-Host "Waiting for WMI (root\ccm)..." -ForegroundColor Yellow
    for ($i=1; $i -le 20; $i++) {
        try {
            Get-WmiObject -Namespace "root\ccm" -Class SMS_Client -ErrorAction Stop | Out-Null
            break
        } catch { Start-Sleep -Seconds 2 }
    }

    # 6. Trigger SCCM cycles
    Write-Host "[6] Triggering SCCM update cycles..." -ForegroundColor Yellow

    $Triggers = @{
        "Machine Policy" = "{00000000-0000-0000-0000-000000000021}"
        "Update Scan"    = "{00000000-0000-0000-0000-000000000113}"
        "Deployment Eval"= "{00000000-0000-0000-0000-000000000108}"
    }

    foreach ($t in $Triggers.Keys) {
        Write-Host "Triggering: $t"
        try {
            Invoke-WmiMethod -Namespace "root\ccm" -Class SMS_Client -Name TriggerSchedule `
                -ArgumentList $Triggers[$t] -ErrorAction Stop | Out-Null
        } catch {
            Write-Host "Warning: $t could not be triggered." -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 2
    }

    Write-Host "=== Fix completed on $env:COMPUTERNAME ===" -ForegroundColor Green
}

# ============================================
# MASSIVE EXECUTION
# ============================================
foreach ($PC in $Computers) {

    Write-Host "`n--------------------------------------------------"
    Write-Host "Processing: $PC" -ForegroundColor Cyan

    # Teste de conectividade
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
