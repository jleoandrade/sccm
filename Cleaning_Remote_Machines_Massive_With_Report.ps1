# Create the local report folder if it does not exist
$LogPath = "C:\temp"
if (-not (Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }

# Format the file name with current date and time
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$CsvFile = "$LogPath\cleaned_machines_data_$Timestamp.csv"

# List of remote machines
$Computers = @(

    "1589094A"
    "1079982A"
)

# Initialize array to store CSV results
$Report = @()

# Main execution
$TotalMachines = $Computers.Count
$MachineIndex = 0

foreach ($Computer in $Computers) {

    $MachineIndex++
    Write-Host ""
    Write-Host "============================================="
    Write-Host "Processing machine: $Computer ($MachineIndex of $TotalMachines)"
    Write-Host "============================================="

    # Record the process start time for this machine
    $StartTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Progress bar for machine-level execution
    Write-Progress -Activity "Cleaning remote machines" `
                   -Status "Processing $Computer" `
                   -PercentComplete (($MachineIndex / $TotalMachines) * 100)

    # Initialize report variables for this machine
    $Status = "Failed"
    $Details = ""
    $DriveSizeGB = "N/A"
    $FreeBeforeGB = "N/A"
    $FreeAfterGB = "N/A"
    $SpaceSavedGB = "N/A"

    # Connectivity test (Ping)
    Write-Host "[$Computer] Testing connectivity..."
    if (Test-Connection -ComputerName $Computer -Count 1 -Quiet) {
        
        try {
            # Collect disk metrics BEFORE cleanup
            Write-Host "[$Computer] Collecting disk space before cleanup..."
            $DiskBefore = Invoke-Command -ComputerName $Computer -ScriptBlock { 
                Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" 
            } -ErrorAction Stop
            
            if ($DiskBefore) {
                $DriveSizeGB = [math]::Round($DiskBefore.Size / 1GB, 2)
                $FreeBeforeGB = [math]::Round($DiskBefore.FreeSpace / 1GB, 2)
            }

            # Run cleanup block
            Invoke-Command -ComputerName $Computer -ScriptBlock {

                Write-Host "[$env:COMPUTERNAME] Cleaning: C:\Windows\Temp"
                Get-ChildItem -Path "C:\Windows\Temp" -Recurse -Force -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

                Write-Host "[$env:COMPUTERNAME] Cleaning: User Temp"
                Get-ChildItem -Path "$env:LOCALAPPDATA\Temp" -Recurse -Force -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

                Write-Host "[$env:COMPUTERNAME] Cleaning: WER ReportQueue (today only)"
                Get-ChildItem -Path "C:\ProgramData\Microsoft\Windows\WER\ReportQueue" -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -ge (Get-Date).Date } |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

                Write-Host "[$env:COMPUTERNAME] Cleaning: C:\Windows\ccmcache"
                Get-ChildItem -Path "C:\Windows\ccmcache" -Recurse -Force -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

                # Stop Windows Update related services
                Write-Host "[$env:COMPUTERNAME] Stopping Windows Update services..."
                Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
                Stop-Service -Name bits -Force -ErrorAction SilentlyContinue
                Stop-Service -Name cryptsvc -Force -ErrorAction SilentlyContinue
                Stop-Service -Name msiserver -Force -ErrorAction SilentlyContinue

                # Clean Windows Update cache
                Write-Host "[$env:COMPUTERNAME] Cleaning Windows Update cache..."
                Remove-Item -Path "$env:windir\SoftwareDistribution" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "$env:windir\System32\catroot2" -Recurse -Force -ErrorAction SilentlyContinue

                # Restart services
                Write-Host "[$env:COMPUTERNAME] Restarting Windows Update services..."
                Start-Service -Name wuauserv -ErrorAction SilentlyContinue
                Start-Service -Name bits -ErrorAction SilentlyContinue
                Start-Service -Name cryptsvc -ErrorAction SilentlyContinue
                Start-Service -Name msiserver -ErrorAction SilentlyContinue

                # Run Disk Cleanup silently
                Write-Host "[$env:COMPUTERNAME] Running Disk Cleanup..."
                Start-Process -FilePath CleanMgr.exe -ArgumentList '/sagerun:1' -WindowStyle Hidden -Wait

                Write-Host "[$env:COMPUTERNAME] Cleanup completed."
            }

            # Collect disk metrics AFTER cleanup
            Write-Host "[$Computer] Collecting disk space after cleanup..."
            $DiskAfter = Invoke-Command -ComputerName $Computer -ScriptBlock { 
                Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" 
            } -ErrorAction Stop
            
            if ($DiskAfter) {
                $FreeAfterGB = [math]::Round($DiskAfter.FreeSpace / 1GB, 2)
                $SpaceSavedGB = [math]::Round($FreeAfterGB - $FreeBeforeGB, 2)
            }

            Write-Host "[$Computer] SUCCESS" -ForegroundColor Green
            $Status = "Success"
            $Details = "Cleanup executed successfully."
        }
        catch {
            $Details = $_.Exception.Message
            Write-Host "[$Computer] ERROR: $Details" -ForegroundColor Red
        }
    }
    else {
        $Details = "Offline / No ping response."
        Write-Host "[$Computer] ERROR: Machine unreachable." -ForegroundColor Red
    }

    # Record the process end time for this machine
    $EndTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Add current machine data to the report array
    $Report += [PSCustomObject]@{
        ComputerName   = $Computer
        StartTime      = $StartTime
        EndTime        = $EndTime
        DriveSizeGB    = $DriveSizeGB
        FreeSpaceBeforeGB = $FreeBeforeGB
        FreeSpaceAfterGB  = $FreeAfterGB
        SpaceSavedGB   = $SpaceSavedGB
        Status         = $Status
        Details        = $Details
    }
}

# Export all collected data to the CSV file
$Report | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "============================================="
Write-Host "All machines processed."
Write-Host "Report generated at: $CsvFile"
Write-Host "============================================="
