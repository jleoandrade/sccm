<#
.SYNOPSIS
    Resets Windows Update, BITS, Delivery Optimization and SCCM update components on remote computers.

.EXAMPLE
    .\Reset-UpdateComponents.ps1 -ComputerName PC01, PC02

.EXAMPLE
    .\Reset-UpdateComponents.ps1 -ComputerName (Get-Content .\computers.txt)
#>

param(
    # Target computers. If omitted, PowerShell prompts for them one by one (empty line to finish).
    [Parameter(Mandatory)]
    [string[]]$ComputerName
)

# Everything inside this block runs on the remote computer
$ScriptBlock = {
    # Any error stops the block, so failures are reported instead of hidden
    $ErrorActionPreference = 'Stop'
    $name = $env:COMPUTERNAME

    # Services that lock the files and folders reset below (cryptsvc locks catroot2)
    $services = 'ccmexec', 'wuauserv', 'bits', 'cryptsvc', 'dosvc'

    # Renames a file or folder to "<name>.old" instead of deleting it, so it can be restored
    function Backup-Item($Path) {
        if (-not (Test-Path $Path)) { return }                              # Nothing to do
        $backup = "$Path.old"
        if (Test-Path $backup) { Remove-Item $backup -Recurse -Force }      # Drop backup from a previous run
        Rename-Item -Path $Path -NewName (Split-Path $backup -Leaf)
    }

    try {
        Write-Host "[$name] Stopping services..." -ForegroundColor Yellow
        Stop-Service -Name $services -Force

        Write-Host "[$name] Resetting Windows Update cache (SoftwareDistribution, catroot2)..."
        Backup-Item "$env:windir\SoftwareDistribution"
        Backup-Item "$env:windir\System32\catroot2"

        Write-Host "[$name] Resetting local machine policy file (Registry.pol)..."
        Backup-Item "$env:windir\System32\GroupPolicy\Machine\Registry.pol"

        Write-Host "[$name] Clearing BITS job queue..."
        Remove-Item "$env:ProgramData\Microsoft\Network\Downloader\*" -Recurse -Force

        Write-Host "[$name] Removing Delivery Optimization policy key (GPO reapplies it if still assigned)..."
        $doPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
        if (Test-Path $doPolicy) { Remove-Item $doPolicy -Recurse -Force }
    }
    finally {
        # Always runs, even after an error, so the machine is never left with services stopped
        Write-Host "[$name] Starting services..." -ForegroundColor Yellow
        Start-Service -Name $services -ErrorAction Continue                 # Try every service even if one fails
    }

    Write-Host "[$name] Clearing Delivery Optimization cache..."
    Delete-DeliveryOptimizationCache -Force                                 # Needs dosvc running

    Write-Host "[$name] Reapplying computer Group Policy (rebuilds Registry.pol)..."
    gpupdate /target:computer /force | Out-Null

    Write-Host "[$name] Triggering SCCM policy and update cycles..." -ForegroundColor Green
    $schedules = @(
        '{00000000-0000-0000-0000-000000000021}'  # Machine Policy Retrieval
        '{00000000-0000-0000-0000-000000000022}'  # Machine Policy Evaluation
        '{00000000-0000-0000-0000-000000000113}'  # Software Updates Scan
        '{00000000-0000-0000-0000-000000000108}'  # Software Updates Deployment Evaluation
    )

    foreach ($id in $schedules) {
        # ccmexec reports "Running" before its WMI provider is ready, so retry for up to 2 minutes
        for ($try = 1; $try -le 12; $try++) {
            try {
                Invoke-CimMethod -Namespace 'root\ccm' -ClassName 'SMS_Client' -MethodName 'TriggerSchedule' -Arguments @{ sScheduleID = $id } | Out-Null
                break
            }
            catch {
                if ($try -eq 12) { throw }                                  # Give up and report the error
                Start-Sleep -Seconds 10
            }
        }
    }

    # Only reached if nothing above failed
    Write-Host "[$name] Done." -ForegroundColor Green
}

foreach ($computer in $ComputerName) {
    Write-Host "`n=== $computer ===" -ForegroundColor Cyan
    # Connection errors (offline, access denied, WinRM blocked) and errors thrown remotely are shown in red.
    # No -ErrorAction Stop here on purpose: it would abort the remote block mid-way and could leave services stopped.
    Invoke-Command -ComputerName $computer -ScriptBlock $ScriptBlock
}
