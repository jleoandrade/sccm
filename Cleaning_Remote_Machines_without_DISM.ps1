# Ask for target machine
$Computer = Read-Host "Enter target computer name"

Write-Host ""
Write-Host "============================================="
Write-Host "Processing machine: $Computer"
Write-Host "============================================="

# Connectivity check
Write-Host "[LOCAL] Testing connectivity..."
if (-not (Test-Connection -ComputerName $Computer -Count 2 -Quiet)) {
    Write-Host "[LOCAL] ERROR: Machine not reachable via ICMP." -ForegroundColor Red
    exit
}

try {
    Test-WSMan -ComputerName $Computer -ErrorAction Stop | Out-Null
}
catch {
    Write-Host "[LOCAL] ERROR: WinRM not reachable. Enable WinRM on the target." -ForegroundColor Red
    exit
}

Write-Host "[LOCAL] Connectivity OK."

# Remote cleanup
try {
    $Result = Invoke-Command -ComputerName $Computer -ScriptBlock {

        $Output = [ordered]@{
            Computer = $env:COMPUTERNAME
            Success = $false
            SoftwareDistributionRecreated = $false
            WindowsUpdateHealthy = $false
            Error = $null
        }

        function Fast-Delete($path) {
            if (Test-Path $path) {
                cmd.exe /c "rmdir /s /q `"$path`"" 2>$null
            }
        }

        Write-Host "[$env:COMPUTERNAME] Cleaning: Windows Temp"
        Fast-Delete "C:\Windows\Temp"
        New-Item -ItemType Directory -Path "C:\Windows\Temp" -Force | Out-Null

        Write-Host "[$env:COMPUTERNAME] Cleaning: User TEMP folders"
        Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $tempPath = "$($_.FullName)\AppData\Local\Temp"
            Fast-Delete $tempPath
            New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
        }

        Write-Host "[$env:COMPUTERNAME] Cleaning: SYSTEM TEMP"
        Fast-Delete $env:TEMP
        New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null

        Write-Host "[$env:COMPUTERNAME] Cleaning: Prefetch"
        Fast-Delete "C:\Windows\Prefetch"
        New-Item -ItemType Directory -Path "C:\Windows\Prefetch" -Force | Out-Null

        Write-Host "[$env:COMPUTERNAME] Cleaning: Windows Update logs"
        Remove-Item -Path "C:\Windows\WindowsUpdate.log" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "C:\Windows\SoftwareDistribution\ReportingEvents.log" -Force -ErrorAction SilentlyContinue

        Write-Host "[$env:COMPUTERNAME] Cleaning: CBS logs"
        Remove-Item -Path "C:\Windows\Logs\CBS\*.log" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "C:\Windows\Logs\CBS\*.cab" -Force -ErrorAction SilentlyContinue

        Write-Host "[$env:COMPUTERNAME] Cleaning: .TMP files (safe locations only)"

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

        Write-Host "[$env:COMPUTERNAME] Cleaning: Print Spooler"
        Stop-Service spooler -Force -ErrorAction SilentlyContinue
        Fast-Delete "C:\Windows\System32\spool\PRINTERS"
        New-Item -ItemType Directory -Path "C:\Windows\System32\spool\PRINTERS" -Force | Out-Null
        Start-Service spooler -ErrorAction SilentlyContinue

        Write-Host "[$env:COMPUTERNAME] Cleaning: SCCM folders"
        Fast-Delete "C:\Windows\ccmcache"
        Fast-Delete "C:\Windows\CCM\Temp"
        Fast-Delete "C:\Windows\CCM\Cache"
        Remove-Item "C:\Windows\CCM\*.tmp" -Force -ErrorAction SilentlyContinue
        Remove-Item "C:\Windows\CCM\Logs\*.log" -Force -ErrorAction SilentlyContinue
        Remove-Item "C:\Windows\CCMSetup\*.log" -Force -ErrorAction SilentlyContinue

        Write-Host "[$env:COMPUTERNAME] Cleaning: WER"
        Fast-Delete "C:\ProgramData\Microsoft\Windows\WER\ReportQueue"
        Fast-Delete "C:\ProgramData\Microsoft\Windows\WER\ReportArchive"
        Fast-Delete "C:\ProgramData\Microsoft\Windows\WER\Temp"

        Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $werPath = "$($_.FullName)\AppData\Local\Microsoft\Windows\WER"
            Fast-Delete $werPath
        }

        Write-Host "[$env:COMPUTERNAME] Stopping Windows Update services..."
        Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
        Stop-Service bits -Force -ErrorAction SilentlyContinue
        Stop-Service cryptsvc -Force -ErrorAction SilentlyContinue
        Stop-Service msiserver -Force -ErrorAction SilentlyContinue

        Write-Host "[$env:COMPUTERNAME] Removing SoftwareDistribution and catroot2..."
        Fast-Delete "$env:windir\SoftwareDistribution"
        Fast-Delete "$env:windir\System32\catroot2"

        Write-Host "[$env:COMPUTERNAME] Starting Windows Update services..."
        Start-Service wuauserv -ErrorAction SilentlyContinue
        Start-Service bits -ErrorAction SilentlyContinue
        Start-Service cryptsvc -ErrorAction SilentlyContinue
        Start-Service msiserver -ErrorAction SilentlyContinue

        Start-Sleep -Seconds 3

        if (Test-Path "$env:windir\SoftwareDistribution") {
            $Output.SoftwareDistributionRecreated = $true
        }

        try {
            $Session = New-Object -ComObject Microsoft.Update.Session
            $Searcher = $Session.CreateUpdateSearcher()
            $Searcher.Search("IsInstalled=0") | Out-Null
            $Output.WindowsUpdateHealthy = $true
        }
        catch {
            $Output.WindowsUpdateHealthy = $false
        }

        $Output.Success = $true
        return $Output
    }

    Write-Host ""
    Write-Host "===== RESULT ====="
    $Result | Format-List

}
catch {
    Write-Host "[$Computer] ERROR: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""
Write-Host "============================================="
Write-Host "Process completed."
Write-Host "============================================="
