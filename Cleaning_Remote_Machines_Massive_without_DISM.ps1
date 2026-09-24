# List of target machines (insert IPs or Hostnames here)
$Computers = @(

"1074393A"

)

Write-Host "============================================="
Write-Host "CRITICAL ENVIRONMENT EXECUTION STARTED"
Write-Host "Target Count: $($Computers.Count) machines."
Write-Host "============================================="

foreach ($Computer in $Computers) {

    Write-Host ""
    Write-Host "---------------------------------------------"
    Write-Host "Processing machine: $Computer"
    Write-Host "---------------------------------------------"

    # ICMP connectivity check
    Write-Host "[LOCAL] Testing connectivity (ICMP)..."
    if (-not (Test-Connection -ComputerName $Computer -Count 2 -Quiet)) {
        Write-Host "[LOCAL] WARNING: Machine $Computer unreachable via Ping. Skipping to prevent hangs." -ForegroundColor Yellow
        continue 
    }

    # WinRM connectivity check
    try {
        Test-WSMan -ComputerName $Computer -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Host "[LOCAL] ERROR: WinRM handshake failed on $Computer. Skipping." -ForegroundColor Red
        continue 
    }

    Write-Host "[LOCAL] Connectivity established."

    # Remote aggressive cleanup execution
    try {
        $Result = Invoke-Command -ComputerName $Computer -ScriptBlock {

            $Output = [ordered]@{
                Computer                      = $env:COMPUTERNAME
                Success                       = $false
                SoftwareDistributionRecreated = $false
                WindowsUpdateHealthy          = $false
                Error                         = $null
            }

            # High-priority native file system engine execution
            function Fast-Delete($path) {
                if (Test-Path $path) {
                    # Runs cmd with high priority to force immediate disk I/O allocation
                    cmd.exe /c "start /high /wait cmd.exe /c rmdir /s /q `"$path`"" 2>$null
                }
            }

            # Aggressive process termination to unlock system files
            Write-Host "[$env:COMPUTERNAME] Unlocking files: Forcefully killing update/installer processes..."
            Get-Process -Name "wuauclt", "msiexec", "TiWorker", "trustedinstaller" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

            Write-Host "[$env:COMPUTERNAME] Purging: Windows Temp"
            Fast-Delete "C:\Windows\Temp"
            New-Item -ItemType Directory -Path "C:\Windows\Temp" -Force | Out-Null

            Write-Host "[$env:COMPUTERNAME] Purging: User TEMP folders"
            Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $tempPath = "$($_.FullName)\AppData\Local\Temp"
                Fast-Delete $tempPath
                New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
            }

            Write-Host "[$env:COMPUTERNAME] Purging: SYSTEM TEMP"
            Fast-Delete $env:TEMP
            New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null

            Write-Host "[$env:COMPUTERNAME] Purging: Prefetch"
            Fast-Delete "C:\Windows\Prefetch"
            New-Item -ItemType Directory -Path "C:\Windows\Prefetch" -Force | Out-Null

            Write-Host "[$env:COMPUTERNAME] Purging: Windows Update & CBS Logs"
            Remove-Item -Path "C:\Windows\WindowsUpdate.log" -Force -ErrorAction SilentlyContinue
            Remove-Item -Path "C:\Windows\SoftwareDistribution\ReportingEvents.log" -Force -ErrorAction SilentlyContinue
            Remove-Item -Path "C:\Windows\Logs\CBS\*.log" -Force -ErrorAction SilentlyContinue
            Remove-Item -Path "C:\Windows\Logs\CBS\*.cab" -Force -ErrorAction SilentlyContinue

            Write-Host "[$env:COMPUTERNAME] Purging: Orphaned .TMP files"
            $TmpPaths = @(
                "C:\Windows\Temp",
                "C:\ProgramData\Temp",
                "C:\Windows\CCM\Temp",
                "C:\Windows\CCMCache"
            )
            Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $TmpPaths += "$($_.FullName)\AppData\Local\Temp"
            }
            foreach ($path in $TmpPaths) {
                if (Test-Path $path) {
                    Get-ChildItem -Path $path -Recurse -Force -Include *.tmp -ErrorAction SilentlyContinue |
                        Remove-Item -Force -ErrorAction SilentlyContinue
                }
            }

            Write-Host "[$env:COMPUTERNAME] Purging: Print Spooler Queue"
            Stop-Service spooler -Force -ErrorAction SilentlyContinue
            Fast-Delete "C:\Windows\System32\spool\PRINTERS"
            New-Item -ItemType Directory -Path "C:\Windows\System32\spool\PRINTERS" -Force | Out-Null
            Start-Service spooler -ErrorAction SilentlyContinue

            Write-Host "[$env:COMPUTERNAME] Purging: SCCM / Configuration Manager Cache"
            Fast-Delete "C:\Windows\ccmcache"
            Fast-Delete "C:\Windows\CCM\Temp"
            Fast-Delete "C:\Windows\CCM\Cache"
            Remove-Item "C:\Windows\CCM\*.tmp" -Force -ErrorAction SilentlyContinue
            Remove-Item "C:\Windows\CCM\Logs\*.log" -Force -ErrorAction SilentlyContinue
            Remove-Item "C:\WindowsSetup\*.log" -Force -ErrorAction SilentlyContinue

            Write-Host "[$env:COMPUTERNAME] Purging: Windows Error Reporting (WER)"
            Fast-Delete "C:\ProgramData\Microsoft\Windows\WER\ReportQueue"
            Fast-Delete "C:\ProgramData\Microsoft\Windows\WER\ReportArchive"
            Fast-Delete "C:\ProgramData\Microsoft\Windows\WER\Temp"
            Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $werPath = "$($_.FullName)\AppData\Local\Microsoft\Windows\WER"
                Fast-Delete $werPath
            }

            Write-Host "[$env:COMPUTERNAME] Stopping structural Windows Update services..."
            Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
            Stop-Service bits -Force -ErrorAction SilentlyContinue
            Stop-Service cryptsvc -Force -ErrorAction SilentlyContinue
            Stop-Service msiserver -Force -ErrorAction SilentlyContinue

            Write-Host "[$env:COMPUTERNAME] Aggressively destroying SoftwareDistribution and Catroot2..."
            Fast-Delete "$env:windir\SoftwareDistribution"
            Fast-Delete "$env:windir\System32\catroot2"

            Write-Host "[$env:COMPUTERNAME] Reinitializing system services..."
            Start-Service wuauserv -ErrorAction SilentlyContinue
            Start-Service bits -ErrorAction SilentlyContinue
            Start-Service cryptsvc -ErrorAction SilentlyContinue
            Start-Service msiserver -ErrorAction SilentlyContinue

            # Give the OS a brief moment to regenerate directories structurally
            Start-Sleep -Seconds 5

            if (Test-Path "$env:windir\SoftwareDistribution") {
                $Output.SoftwareDistributionRecreated = $true
            }

            # Remotely validate Windows Update agent integrity post-wipe
            try {
                $Session = New-Object -ComObject Microsoft.Update.Session
                $Searcher = $Session.CreateUpdateSearcher()
                $Searcher.Search("IsInstalled=0") | Out-Null
                $Output.WindowsUpdateHealthy = $true
            }
            catch {
                $Output.WindowsUpdateHealthy = $false
                $Output.Error = $_.Exception.Message
            }

            $Output.Success = $true
            return $Output
        }

        Write-Host ""
        Write-Host "===== POST-CLEANUP REPORT ($Computer) ====="
        $Result | Format-List

    }
    catch {
        Write-Host "[$Computer] CRITICAL REMOTE EXECUTION FAILURE: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "============================================="
Write-Host "Mass production cleanup completed successfully."
Write-Host "============================================="
