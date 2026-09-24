# ============================
# MASS SYSTEM MAINTENANCE TOOL
# REMOTE + ASCII PROGRESS + SUMMARY
# ============================

Clear-Host

# ============================
# GLOBALS
# ============================

$Global:ProgressStyle = "A"   # A = centered percent, B = percent after bar


# ============================
# ASCII PROGRESS BAR
# ============================

function Show-AsciiProgress {
    param(
        [string]$Activity,
        [double]$Percent
    )

    $width = 50
    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }

    $filled = [int]([math]::Round($width * ($Percent / 100)))
    if ($filled -gt $width) { $filled = $width }
    $empty = $width - $filled

    $percentText = ("{0:N1}%%" -f $Percent)

    switch ($Global:ProgressStyle) {
        "A" {
            $barChars = ("=" * $filled) + (" " * $empty)
            $centerPos = [int]($width / 2 - ($percentText.Length / 2))
            if ($centerPos -lt 0) { $centerPos = 0 }
            if ($centerPos + $percentText.Length -gt $width) {
                $centerPos = $width - $percentText.Length
            }

            $barArray = $barChars.ToCharArray()
            for ($i = 0; $i -lt $percentText.Length; $i++) {
                $idx = $centerPos + $i
                if ($idx -ge 0 -and $idx -lt $barArray.Length) {
                    $barArray[$idx] = $percentText[$i]
                }
            }
            $finalBar = -join $barArray
            Write-Host "$Activity"
            Write-Host "[$finalBar]"
        }
        "B" {
            $barFilled = "=" * $filled
            $barEmpty  = " " * $empty
            $finalBar  = "$barFilled$barEmpty"
            Write-Host "$Activity"
            Write-Host "[$finalBar $percentText]"
        }
    }

    Write-Host ""
}


# ============================
# SUMMARY REPORT
# ============================

function Show-Summary {
    param(
        [string]$Machine,
        [string]$Operation,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [string]$Status = "Success"
    )

    $duration = New-TimeSpan -Start $StartTime -End $EndTime

    Write-Host "==============================================="
    Write-Host "                SUMMARY REPORT                 "
    Write-Host "==============================================="
    Write-Host " Target Machine : $Machine"
    Write-Host " Operation      : $Operation"
    Write-Host " Status         : $Status"
    Write-Host " Started At     : $StartTime"
    Write-Host " Finished At    : $EndTime"
    Write-Host " Duration       : $($duration.ToString())"
    Write-Host "==============================================="
    Write-Host ""
}


# ============================
# REMOTE EXECUTION WRAPPER
# ============================

function Invoke-Remote {
    param(
        [string]$Machine,
        [scriptblock]$ScriptBlock
    )
    Invoke-Command -ComputerName $Machine -ScriptBlock $ScriptBlock
}


# ============================
# OPERATIONS (CLEANUP, DISM, SFC, WU)
# ============================

function Run-FullCleanup {
    param($Machine)

    $start = Get-Date
    $status = "Success"

    try {
        $steps = 7
        $step = 0

        Show-AsciiProgress "Full Cleanup - Windows Temp" (($step++ / $steps) * 100)
        Invoke-Remote $Machine {
            Remove-Item "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
        }

        Show-AsciiProgress "Full Cleanup - User Temp" (($step++ / $steps) * 100)
        Invoke-Remote $Machine {
            Get-ChildItem "C:\Users" -Directory | ForEach-Object {
                Remove-Item "$($_.FullName)\AppData\Local\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        Show-AsciiProgress "Full Cleanup - System Temp" (($step++ / $steps) * 100)
        Invoke-Remote $Machine {
            Remove-Item $env:TEMP\* -Recurse -Force -ErrorAction SilentlyContinue
        }

        Show-AsciiProgress "Full Cleanup - Prefetch" (($step++ / $steps) * 100)
        Invoke-Remote $Machine {
            Remove-Item "C:\Windows\Prefetch\*" -Recurse -Force -ErrorAction SilentlyContinue
        }

        Show-AsciiProgress "Full Cleanup - CBS Logs" (($step++ / $steps) * 100)
        Invoke-Remote $Machine {
            Remove-Item "C:\Windows\Logs\CBS\*.log" -Force -ErrorAction SilentlyContinue
        }

        Show-AsciiProgress "Full Cleanup - SCCM" (($step++ / $steps) * 100)
        Run-SCCMCleanup $Machine

        Show-AsciiProgress "Full Cleanup - WER" (($step++ / $steps) * 100)
        Run-WERCleanup $Machine

    }
    catch {
        $status = "Failed: $($_.Exception.Message)"
    }

    $end = Get-Date
    Show-Summary $Machine "Full Cleanup" $start $end $status
}

function Run-SCCMCleanup {
    param($Machine)

    $start = Get-Date
    $status = "Success"

    try {
        Show-AsciiProgress "SCCM Cleanup" 50
        Invoke-Remote $Machine {
            Remove-Item "C:\Windows\ccmcache\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
        Show-AsciiProgress "SCCM Cleanup" 100
    }
    catch {
        $status = "Failed: $($_.Exception.Message)"
    }

    $end = Get-Date
    Show-Summary $Machine "SCCM Cleanup" $start $end $status
}

function Run-WERCleanup {
    param($Machine)

    $start = Get-Date
    $status = "Success"

    try {
        Show-AsciiProgress "WER Cleanup" 50
        Invoke-Remote $Machine {
            Remove-Item "C:\ProgramData\Microsoft\Windows\WER\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
        Show-AsciiProgress "WER Cleanup" 100
    }
    catch {
        $status = "Failed: $($_.Exception.Message)"
    }

    $end = Get-Date
    Show-Summary $Machine "WER Cleanup" $start $end $status
}

function Run-DISM {
    param($Machine)

    $start = Get-Date
    $status = "Success"

    try {
        $steps = 6
        $step = 0

        Show-AsciiProgress "DISM - ScanHealth" (($step++ / $steps) * 100)
        Invoke-Remote $Machine { DISM /Online /Cleanup-Image /ScanHealth }

        Show-AsciiProgress "DISM - CheckHealth" (($step++ / $steps) * 100)
        Invoke-Remote $Machine { DISM /Online /Cleanup-Image /CheckHealth }

        Show-AsciiProgress "DISM - RestoreHealth" (($step++ / $steps) * 100)
        Invoke-Remote $Machine { DISM /Online /Cleanup-Image /RestoreHealth }

        Show-AsciiProgress "DISM - RestoreHealth (ScratchDir)" (($step++ / $steps) * 100)
        Invoke-Remote $Machine {
            if (-not (Test-Path "C:\Temp")) { New-Item -ItemType Directory -Path "C:\Temp" }
            DISM /Online /Cleanup-Image /RestoreHealth /ScratchDir:C:\Temp
        }

        Show-AsciiProgress "DISM - AnalyzeComponentStore" (($step++ / $steps) * 100)
        Invoke-Remote $Machine { DISM /Online /Cleanup-Image /AnalyzeComponentStore }

        Show-AsciiProgress "DISM - StartComponentCleanup" (($step++ / $steps) * 100)
        Invoke-Remote $Machine { DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase }

    }
    catch {
        $status = "Failed: $($_.Exception.Message)"
    }

    $end = Get-Date
    Show-Summary $Machine "DISM Repairs" $start $end $status
}

function Run-SFC {
    param($Machine)

    $start = Get-Date
    $status = "Success"

    try {
        Show-AsciiProgress "SFC Scan" 50
        Invoke-Remote $Machine { sfc /scannow }
        Show-AsciiProgress "SFC Scan" 100
    }
    catch {
        $status = "Failed: $($_.Exception.Message)"
    }

    $end = Get-Date
    Show-Summary $Machine "SFC Scan" $start $end $status
}

function Run-WURepair {
    param($Machine)

    $start = Get-Date
    $status = "Success"

    try {
        Show-AsciiProgress "Windows Update Repair" 50
        Invoke-Remote $Machine {
            Stop-Service wuauserv -Force
            Stop-Service bits -Force
            Stop-Service cryptsvc -Force
            Stop-Service msiserver -Force
            Start-Sleep -Seconds 3
            Start-Service cryptsvc
            Start-Service bits
            Start-Service msiserver
            Start-Service wuauserv
        }
        Show-AsciiProgress "Windows Update Repair" 100
    }
    catch {
        $status = "Failed: $($_.Exception.Message)"
    }

    $end = Get-Date
    Show-Summary $Machine "Windows Update Repair" $start $end $status
}

function Run-FullMode {
    param($Machine)

    $start = Get-Date
    $status = "Success"

    try {
        Run-FullCleanup $Machine
        Run-DISM $Machine
        Run-SFC $Machine
        Run-WURepair $Machine
    }
    catch {
        $status = "Failed: $($_.Exception.Message)"
    }

    $end = Get-Date
    Show-Summary $Machine "FULL MODE (Everything)" $start $end $status
}


# ============================
# MASS EXECUTION MENU
# ============================

Write-Host "==============================================="
Write-Host " MASS SYSTEM MAINTENANCE TOOL "
Write-Host "==============================================="
Write-Host ""
Write-Host "Enter machine names separated by commas:"
$inputList = Read-Host "Example: PC01, PC02, PC03"

$machines = $inputList.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

if ($machines.Count -eq 0) {
    Write-Host "No machines provided."
    exit
}

Write-Host ""
Write-Host "Select the operation to run on ALL machines:"
Write-Host "[1] Full Cleanup"
Write-Host "[2] Run DISM Repairs"
Write-Host "[3] Run SFC Scan"
Write-Host "[4] Windows Update Repair"
Write-Host "[5] Cleanup SCCM"
Write-Host "[6] Cleanup WER"
Write-Host "[7] FULL MODE (Everything)"
Write-Host "==============================================="

$op = Read-Host "Choose an option"

foreach ($machine in $machines) {

    Write-Host ""
    Write-Host "==============================================="
    Write-Host " Processing machine: $machine"
    Write-Host "==============================================="

    if (-not (Test-Connection -ComputerName $machine -Count 1 -Quiet)) {
        Write-Host "Skipping $machine (offline)"
        continue
    }

    try {
        Test-WSMan -ComputerName $machine -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Host "Skipping $machine (WinRM unavailable)"
        continue
    }

    switch ($op) {
        "1" { Run-FullCleanup $machine }
        "2" { Run-DISM $machine }
        "3" { Run-SFC $machine }
        "4" { Run-WURepair $machine }
        "5" { Run-SCCMCleanup $machine }
        "6" { Run-WERCleanup $machine }
        "7" { Run-FullMode $machine }
        default { Write-Host "Invalid option."; exit }
    }
}

Write-Host ""
Write-Host "==============================================="
Write-Host " MASS EXECUTION COMPLETED "
Write-Host "==============================================="
