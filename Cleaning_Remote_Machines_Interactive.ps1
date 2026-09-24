    # ============================
    # ADVANCED SYSTEM MAINTENANCE TOOL
    # MENU + REMOTE + ASCII PROGRESS + SUMMARY
    # OPTION B (ONLY FINAL SUMMARY)
    # ============================

    Clear-Host

    # ============================
    # GLOBALS
    # ============================

    $Global:ProgressStyle = "A"   # A = centered percent, B = percent after bar


    # ============================
    # FUNCTION: CONNECT TO MACHINE
    # ============================

    function Connect-ToMachine {
        param([switch]$Silent)

        if (-not $Silent) { Clear-Host }

        $Global:TargetComputer = Read-Host "Enter target computer name"

        Write-Host "Testing connectivity to $TargetComputer..."

        if (-not (Test-Connection -ComputerName $TargetComputer -Count 2 -Quiet)) {
            Write-Host "ERROR: Machine not reachable." -ForegroundColor Red
            return $false
        }

        try {
            Test-WSMan -ComputerName $TargetComputer -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Host "ERROR: WinRM not available on target." -ForegroundColor Red
            return $false
        }

        Write-Host "Connection OK.`n"
        return $true
    }

    # Initial connection
    if (-not (Connect-ToMachine)) { exit }


    # ============================
    # REMOTE EXECUTION WRAPPER
    # ============================

    function Invoke-Remote {
        param($ScriptBlock)
        Invoke-Command -ComputerName $TargetComputer -ScriptBlock $ScriptBlock
    }


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
                # Style A: percentage centered inside the bar
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
                # Style B: percentage after the bar
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
    # SUMMARY REPORT FUNCTION
    # ============================

    function Show-Summary {
        param(
            [string]$Operation,
            [datetime]$StartTime,
            [datetime]$EndTime,
            [string]$Status = "Success"
        )

        $duration = New-TimeSpan -Start $StartTime -End $EndTime

        Write-Host "==============================================="
        Write-Host "                SUMMARY REPORT                 "
        Write-Host "==============================================="
        Write-Host " Target Machine : $TargetComputer"
        Write-Host " Operation      : $Operation"
        Write-Host " Status         : $Status"
        Write-Host " Started At     : $StartTime"
        Write-Host " Finished At    : $EndTime"
        Write-Host " Duration       : $($duration.ToString())"
        Write-Host "==============================================="
        Write-Host ""
    }


    # ============================
    # CLEANUP FUNCTIONS
    # ============================

    function Cleanup-Full {

        $start = Get-Date
        $status = "Success"

        try {
            $steps = 7
            $step = 0

            Show-AsciiProgress -Activity "Full Cleanup - Windows Temp" -Percent (($step++ / $steps) * 100)
            Invoke-Remote {
                function Fast-Delete($path) { if (Test-Path $path) { cmd.exe /c "rmdir /s /q `"$path`"" 2>$null } }
                Fast-Delete "C:\Windows\Temp"
                New-Item -ItemType Directory -Path "C:\Windows\Temp" -Force | Out-Null
            }

            Show-AsciiProgress -Activity "Full Cleanup - User Temp" -Percent (($step++ / $steps) * 100)
            Invoke-Remote {
                function Fast-Delete($path) { if (Test-Path $path) { cmd.exe /c "rmdir /s /q `"$path`"" 2>$null } }
                Get-ChildItem "C:\Users" -Directory | ForEach-Object {
                    $p = "$($_.FullName)\AppData\Local\Temp"
                    Fast-Delete $p
                    New-Item -ItemType Directory -Path $p -Force | Out-Null
                }
            }

            Show-AsciiProgress -Activity "Full Cleanup - System Temp" -Percent (($step++ / $steps) * 100)
            Invoke-Remote {
                function Fast-Delete($path) { if (Test-Path $path) { cmd.exe /c "rmdir /s /q `"$path`"" 2>$null } }
                Fast-Delete $env:TEMP
                New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
            }

            Show-AsciiProgress -Activity "Full Cleanup - Prefetch" -Percent (($step++ / $steps) * 100)
            Invoke-Remote {
                function Fast-Delete($path) { if (Test-Path $path) { cmd.exe /c "rmdir /s /q `"$path`"" 2>$null } }
                Fast-Delete "C:\Windows\Prefetch"
                New-Item -ItemType Directory -Path "C:\Windows\Prefetch" -Force | Out-Null
            }

            Show-AsciiProgress -Activity "Full Cleanup - CBS Logs" -Percent (($step++ / $steps) * 100)
            Invoke-Remote {
                Remove-Item "C:\Windows\Logs\CBS\*.log" -Force -ErrorAction SilentlyContinue
                Remove-Item "C:\Windows\Logs\CBS\*.cab" -Force -ErrorAction SilentlyContinue
            }

            Show-AsciiProgress -Activity "Full Cleanup - SCCM" -Percent (($step++ / $steps) * 100)
            Cleanup-SCCM

            Show-AsciiProgress -Activity "Full Cleanup - WER" -Percent (($step++ / $steps) * 100)
            Cleanup-WER

        }
        catch {
            $status = "Failed: $($_.Exception.Message)"
        }

        $end = Get-Date
        Show-Summary -Operation "Full Cleanup" -StartTime $start -EndTime $end -Status $status
    }

    function Cleanup-SCCM {

        $start = Get-Date
        $status = "Success"

        try {
            Show-AsciiProgress -Activity "SCCM Cleanup" -Percent 50

            Invoke-Remote {
                function Fast-Delete($path) { if (Test-Path $path) { cmd.exe /c "rmdir /s /q `"$path`"" 2>$null } }
                Fast-Delete "C:\Windows\ccmcache"
                Fast-Delete "C:\Windows\CCM\Temp"
                Fast-Delete "C:\Windows\CCM\Cache"
                Remove-Item "C:\Windows\CCM\*.tmp" -Force -ErrorAction SilentlyContinue
                Remove-Item "C:\Windows\CCM\Logs\*.log" -Force -ErrorAction SilentlyContinue
                Remove-Item "C:\Windows\CCMSetup\*.log" -Force -ErrorAction SilentlyContinue
            }

            Show-AsciiProgress -Activity "SCCM Cleanup" -Percent 100
        }
        catch {
            $status = "Failed: $($_.Exception.Message)"
        }

        $end = Get-Date
        Show-Summary -Operation "SCCM Cleanup" -StartTime $start -EndTime $end -Status $status
    }

    function Cleanup-WER {

        $start = Get-Date
        $status = "Success"

        try {
            Show-AsciiProgress -Activity "WER Cleanup" -Percent 50

            Invoke-Remote {
                function Fast-Delete($path) { if (Test-Path $path) { cmd.exe /c "rmdir /s /q `"$path`"" 2>$null } }
                Fast-Delete "C:\ProgramData\Microsoft\Windows\WER\ReportQueue"
                Fast-Delete "C:\ProgramData\Microsoft\Windows\WER\ReportArchive"
                Fast-Delete "C:\ProgramData\Microsoft\Windows\WER\Temp"

                Get-ChildItem "C:\Users" -Directory | ForEach-Object {
                    Fast-Delete "$($_.FullName)\AppData\Local\Microsoft\Windows\WER"
                }
            }

            Show-AsciiProgress -Activity "WER Cleanup" -Percent 100
        }
        catch {
            $status = "Failed: $($_.Exception.Message)"
        }

        $end = Get-Date
        Show-Summary -Operation "WER Cleanup" -StartTime $start -EndTime $end -Status $status
    }


    # ============================
    # DISM + SFC + WU REPAIR
    # ============================

    function Run-DISM {

        $start = Get-Date
        $status = "Success"

        try {
            $steps = 6
            $step = 0

            Show-AsciiProgress -Activity "DISM - ScanHealth" -Percent (($step++ / $steps) * 100)
            Invoke-Remote { DISM.exe /Online /Cleanup-Image /ScanHealth | Out-Null }

            Show-AsciiProgress -Activity "DISM - CheckHealth" -Percent (($step++ / $steps) * 100)
            Invoke-Remote { DISM.exe /Online /Cleanup-Image /CheckHealth | Out-Null }

            Show-AsciiProgress -Activity "DISM - RestoreHealth" -Percent (($step++ / $steps) * 100)
            Invoke-Remote { DISM.exe /Online /Cleanup-Image /RestoreHealth | Out-Null }

            Show-AsciiProgress -Activity "DISM - RestoreHealth (ScratchDir)" -Percent (($step++ / $steps) * 100)
            Invoke-Remote {
                if (-not (Test-Path "C:\Temp")) { New-Item -ItemType Directory -Path "C:\Temp" | Out-Null }
                DISM.exe /Online /Cleanup-Image /RestoreHealth /ScratchDir:C:\Temp | Out-Null
            }

            Show-AsciiProgress -Activity "DISM - AnalyzeComponentStore" -Percent (($step++ / $steps) * 100)
            Invoke-Remote { DISM.exe /Online /Cleanup-Image /AnalyzeComponentStore | Out-Null }

            Show-AsciiProgress -Activity "DISM - StartComponentCleanup /ResetBase" -Percent (($step++ / $steps) * 100)
            Invoke-Remote { DISM.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase | Out-Null }

        }
        catch {
            $status = "Failed: $($_.Exception.Message)"
        }

        $end = Get-Date
        Show-Summary -Operation "DISM Repairs" -StartTime $start -EndTime $end -Status $status
    }

    function Run-SFC {

        $start = Get-Date
        $status = "Success"

        try {
            Show-AsciiProgress -Activity "SFC Scan" -Percent 50
            Invoke-Remote { sfc /scannow | Out-Null }
            Show-AsciiProgress -Activity "SFC Scan" -Percent 100
        }
        catch {
            $status = "Failed: $($_.Exception.Message)"
        }

        $end = Get-Date
        Show-Summary -Operation "SFC Scan" -StartTime $start -EndTime $end -Status $status
    }

    function Repair-WindowsUpdate {

        $start = Get-Date
        $status = "Success"

        try {
            Show-AsciiProgress -Activity "Windows Update Repair - Restarting services" -Percent 50

            Invoke-Remote {
                Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
                Stop-Service bits -Force -ErrorAction SilentlyContinue
                Stop-Service cryptsvc -Force -ErrorAction SilentlyContinue
                Stop-Service msiserver -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
                Start-Service cryptsvc
                Start-Service bits
                Start-Service msiserver
                Start-Service wuauserv
            }

            Show-AsciiProgress -Activity "Windows Update Repair - Testing Windows Update" -Percent 90

            Invoke-Remote {
                try {
                    $Session = New-Object -ComObject Microsoft.Update.Session
                    $Searcher = $Session.CreateUpdateSearcher()
                    $Searcher.Search("IsInstalled=0") | Out-Null
                    Write-Host "[WU] Windows Update is healthy."
                }
                catch {
                    Write-Host "[WU] Windows Update still unhealthy. Reboot may be required."
                }
            }

            Show-AsciiProgress -Activity "Windows Update Repair" -Percent 100
        }
        catch {
            $status = "Failed: $($_.Exception.Message)"
        }

        $end = Get-Date
        Show-Summary -Operation "Windows Update Repair" -StartTime $start -EndTime $end -Status $status
    }


    # ============================
    # FULL MODE (EVERYTHING)
    # ============================

    function Run-FullMode {

        $start = Get-Date
        $status = "Success"

        try {
            Cleanup-Full
            Run-DISM
            Run-SFC
            Repair-WindowsUpdate
        }
        catch {
            $status = "Failed: $($_.Exception.Message)"
        }

        $end = Get-Date
        Show-Summary -Operation "FULL MODE (Everything)" -StartTime $start -EndTime $end -Status $status
    }


    # ============================
    # TOGGLE PROGRESS STYLE
    # ============================

    function Toggle-ProgressStyle {
        if ($Global:ProgressStyle -eq "A") {
            $Global:ProgressStyle = "B"
        }
        else {
            $Global:ProgressStyle = "A"
        }
        Write-Host "Progress bar style changed to: $ProgressStyle"
        Write-Host "Style A: [=====73.0%=====     ]"
        Write-Host "Style B: [=====     ] 73.0%"
        Write-Host ""
    }


    # ============================
    # MENU
    # ============================

    function Show-Menu {
        Write-Host "==============================================="
        Write-Host "        ADVANCED SYSTEM MAINTENANCE TOOL        "
        Write-Host " Target: $TargetComputer"
        Write-Host " Progress Style: $ProgressStyle"
        Write-Host "==============================================="
        Write-Host "[1] Full Cleanup"
        Write-Host "[2] Run DISM Repairs"
        Write-Host "[3] Run SFC Scan"
        Write-Host "[4] Windows Update Repair"
        Write-Host "[5] Cleanup SCCM"
        Write-Host "[6] Cleanup WER"
        Write-Host "[7] FULL MODE (Everything)"
        Write-Host "[8] Toggle Progress Bar Style (A/B)"
        Write-Host "[9] Reconnect to another machine"
        Write-Host "[0] Exit"
        Write-Host "==============================================="
    }

    do {
        Show-Menu
        $choice = Read-Host "Select an option"

        switch ($choice) {
            "1" { Cleanup-Full }
            "2" { Run-DISM }
            "3" { Run-SFC }
            "4" { Repair-WindowsUpdate }
            "5" { Cleanup-SCCM }
            "6" { Cleanup-WER }
            "7" { Run-FullMode }
            "8" { Toggle-ProgressStyle }
            "9" { 
                if (Connect-ToMachine) {
                    Write-Host "Switched to new machine: $TargetComputer"
                }
            }
            "0" { Write-Host "Exiting..."; break }
            default { Write-Host "Invalid option." }
        }

        Write-Host ""
        Pause

    } while ($choice -ne "0")

#1567288A - Shank - em progresso. 
