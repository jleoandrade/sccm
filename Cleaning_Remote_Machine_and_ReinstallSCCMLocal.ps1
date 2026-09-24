# Get computer name
$ComputerName = Read-Host "Enter computer name"

if (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet) {
    Write-Host "Connected to $ComputerName. Starting Deep Maintenance..." -ForegroundColor Green

    # 1. CLEANUP PHASE
    Invoke-Command -ComputerName $ComputerName -ScriptBlock {
        Write-Host "Cleaning temporary folders and SCCM cache..."
        
        # Stop necessary services
        Stop-Service -Name wuauserv, ccmexec -Force -ErrorAction SilentlyContinue

        # Clean Windows Temp and SCCM Cache
        Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "C:\Windows\ccmcache\*" -Recurse -Force -ErrorAction SilentlyContinue
        
        # Clean Software Distribution & WER
        Remove-Item -Path "C:\Windows\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "C:\ProgramData\Microsoft\Windows\WER\*" -Recurse -Force -ErrorAction SilentlyContinue

        # Clean all User Profile Temp folders
        Get-ChildItem -Path "C:\Users" | ForEach-Object {
            $userTemp = "$($_.FullName)\AppData\Local\Temp"
            if (Test-Path $userTemp) {
                Remove-Item -Path "$userTemp\*" -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # Clear SCCM Inventory/Scan History (WMI & DataStore)
        Get-ChildItem -Path "C:\Windows\CCM\*.sdf" -ErrorAction SilentlyContinue | Remove-Item -Force
        
        Start-Service -Name ccmexec -ErrorAction SilentlyContinue
    }

    # 2. REINSTALLATION PHASE
    Write-Host "Executing Force Reinstallation..." -ForegroundColor Cyan
    Invoke-Command -ComputerName $ComputerName -ScriptBlock {
        if (Test-Path "C:\Windows\ccmsetup\ccmsetup.exe") {
            Start-Process -FilePath "C:\Windows\ccmsetup\ccmsetup.exe" -ArgumentList "/forceinstall" -Wait
        }
    }

    # 3. POLICY & CYCLE PHASE
    Write-Host "Triggering Retrieval Policy and Scan Cycles..." -ForegroundColor Yellow
    Invoke-Command -ComputerName $ComputerName -ScriptBlock {
        $Cycles = @(
            "{00000000-0000-0000-0000-000000000021}", # Machine Policy Retrieval
            "{00000000-0000-0000-0000-000000000113}", # Software Update Scan
            "{00000000-0000-0000-0000-000000000114}"  # Software Update Deployment Evaluation
        )
        foreach ($Cycle in $Cycles) {
            Invoke-WMIMethod -Namespace root\ccm -Class SMS_Client -Name TriggerSchedule -ArgumentList $Cycle
        }
    }

    Write-Host "Process complete for $ComputerName." -ForegroundColor Green
} else {
    Write-Host "Machine $ComputerName is offline." -ForegroundColor Red
}
Pause
