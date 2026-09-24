# ============================================
# LIST OF COMPUTERS
# ============================================
$Computers = @(

"6058188A"

)

# ============================================
# REMOTE REMEDIATION FOR ERROR 0x8007045B
# ============================================
Write-Host "Initiating mass deployment to $($Computers.Count) machines..." -ForegroundColor Yellow

Invoke-Command -ComputerName $Computers -ScriptBlock {
    Write-Host "Starting repair for error 0x8007045B on $env:COMPUTERNAME" -ForegroundColor Cyan

    # 1. Stop update services for cleanup
    # This prevents file-locking and stops hung processes
    $Services = @("wuauserv", "bits", "cryptsvc", "msiserver")
    foreach ($svc in $Services) {
        if ((Get-Service $svc -ErrorAction SilentlyContinue).Status -eq 'Running') {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        }
    }

    # 2. Clear Windows Update cache (SoftwareDistribution)
    # Corrupted files here often cause the 'hang' leading to the shutdown error
    $WinDir = [System.Environment]::GetFolderPath("Windows")
    $SDPath = Join-Path $WinDir "SoftwareDistribution"
    if (Test-Path $SDPath) {
        Write-Host "[$env:COMPUTERNAME] Purging SoftwareDistribution folder..."
        Remove-Item -Path $SDPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 3. Repair file integrity (SFC and DISM)
    # This fixes failures that cause the installation process to delay and fail
    Write-Host "[$env:COMPUTERNAME] Running DISM and SFC (may take a few minutes)..."
    DISM.exe /Online /Cleanup-Image /RestoreHealth /Quiet
    sfc /scannow

    # 4. Restart services
    # Ensures the machine is ready for new update tasks
    foreach ($svc in $Services) {
        Start-Service -Name $svc -ErrorAction SilentlyContinue
    }

    # 5. Reset Maintenance Task Coordinator (MTC)
    # Ensures new tasks don't conflict with the previous shutdown state
    $MTC = Get-Service -Name "MTC" -ErrorAction SilentlyContinue
    if ($MTC) { 
        Restart-Service -Name "MTC" -Force -ErrorAction SilentlyContinue 
    }

    Write-Host "Remediation completed on $env:COMPUTERNAME" -ForegroundColor Green
} -ErrorAction SilentlyContinue

Write-Host "Full process finished." -ForegroundColor Yellow