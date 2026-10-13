<# : InstallKB.cmd - batch launcher. PowerShell reads this block as a comment and ignores it.
@echo off
setlocal
title Windows 11 CU Installer

rem ---------------------------------------------------------------------------
rem  1. Ask for administrator rights when not elevated (same as "Run as administrator")
rem ---------------------------------------------------------------------------
net session >nul 2>&1
if errorlevel 1 (
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

rem ---------------------------------------------------------------------------
rem  2. PowerShell only runs .ps1 files: copy this file to a temporary .ps1,
rem     run it (window hidden, GUI only) and delete the copy at the end.
rem     A startup error is shown in a message box instead of a hidden console.
rem ---------------------------------------------------------------------------
set "PSFILE=%TEMP%\InstallKB_%RANDOM%%RANDOM%.ps1"
copy /y "%~f0" "%PSFILE%" >nul
if errorlevel 1 (
    echo Could not create "%PSFILE%".
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "try { & '%PSFILE%' } catch { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Windows 11 CU Installer - error') }"

del "%PSFILE%" >nul 2>&1
endlocal
exit /b
#>

# ============================================================================
#  PowerShell script starts here. Edit the configuration below as usual.
#  (Line numbers are 39 higher than in install_kb_loop.ps1.)
# ============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ==========================
# KB SOURCES
# ==========================
$Source23H2 = "\\SERVER\Sources\Manual-installations\2026-09_Cumulative_Update_for_Windows_11_23H2"
$Source24H2 = "\\SERVER\Sources\Manual-installations\2026-09_Cumulative_Update_for_Windows_11_24H2"
$Source25H2 = "\\SERVER\Sources\Manual-installations\2026-09_Cumulative_Update_for_Windows_11_25H2"

$RemoteFolder = "C:\Windows\Temp\CUInstall"
$MaxParallel  = 15

# ==========================
# EXPECTED BUILD (UBR) - CU 2026-09
# ==========================
# UBR = number after the dot in the OS Build (e.g. 26100.9445 -> 9445)
# 23H2: KB5122880 = 22631.7582 | 24H2/25H2: KB5124008 = 26100.9445 / 26200.9445
# Set to 0 to disable the UBR check for that release (falls back to Get-HotFix only)
$ExpectedUBR = @{
    "23H2" = 7582
    "24H2" = 9445
    "25H2" = 9445
}

# ==========================
# REPORT OUTPUT / LOOP
# ==========================
$ReportFolder = "D:\jorge\InstallKB_Report"
$LogFolder    = Join-Path $ReportFolder "logs"   # remote logs: D:\jorge\InstallKB_Report\logs\<host>\
$ReportPrefix = "install_kb_sep26"
$CycleIntervalSeconds = 180   # 3-minute pause between cycles
$FreeSpaceMarginGB    = 10    # required free space on C: = MSU size + this margin (the CU installation also consumes disk space)

# Fast connectivity timeouts (milliseconds)
$Timeouts = @{
    PingMs           = 1000    # per ping attempt (2 attempts)
    WinRMPortMs      = 3000    # TCP connect to WinRM port 5985 / SMB port 445
    SessionOpenMs    = 20000   # max wait to open a remote session (Invoke-Command default is 3 minutes)
    PsExecConnectSec = 10      # PsExec -n: max wait to connect to the host
    PsExecAttempts   = 3       # PsExec tries when the command never started on the host (e.g. "Error communicating with PsExec service")
}

# ==========================
# REMOTE ACCESS FALLBACK
# ==========================
# WinRM is tried first. If it fails, the script uses PsExec (runs as SYSTEM) + the admin share \\host\C$
$PsExecPath = "D:\Jorge\PSTools\PsExec.exe"

# MSU copy order (the next method is tried automatically if one fails):
#   Push = this PC copies the MSU to \\host\C$\Windows\Temp\CUInstall
#   Pull = the host copies the MSU directly from the Source share (via PsExec as SYSTEM;
#          the computer account, e.g. "Domain Computers", needs read access to the Source share)
$CopyOrder = @("Push", "Pull")
$script:StopRequested = $false

# ==========================
# DISK CLEANUP (runs on the remote host when free space is low or the copy fails because the disk is full)
# ==========================
$DiskCleanupScript = {

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

    Write-Host "[$env:COMPUTERNAME] Running safe WinSxS cleanup..."
    Dism.exe /Online /Cleanup-Image /StartComponentCleanup | Out-Null

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

# ==========================
# GUI SETUP
# ==========================
# Color palette (change the hex values here to restyle the whole window)
$Theme = @{
    Header      = "#1A1A1A"   # top bar and grid column headers
    Accent      = "#A100FF"   # purple: primary button, top bar strip
    AccentSoft  = "#F3E8FF"   # light purple: selected row, rows in progress
    Page        = "#F5F5F7"   # window background
    Card        = "#FFFFFF"   # text box and grid background
    Text        = "#1A1A1A"
    TextMuted   = "#6B6B6B"
    Border      = "#E3E3E3"
    SuccessSoft = "#E7F6EC"   # Finished / Skipped rows
    ErrorSoft   = "#FDE8E8"   # Failed / Error rows
    StoppedSoft = "#EDEDEF"   # Stopped rows
}
function Get-ThemeColor ($Name) { [System.Drawing.ColorTranslator]::FromHtml($Theme[$Name]) }

$fontRegular = New-Object System.Drawing.Font("Segoe UI", 9)
$fontBold    = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

$form = New-Object System.Windows.Forms.Form
$form.Text = "Windows 11 Security Updates Remote Installer"
$form.Size = New-Object System.Drawing.Size(1050, 768)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = Get-ThemeColor "Page"
$form.ForeColor = Get-ThemeColor "Text"
$form.Font = $fontRegular

# Window / taskbar / Alt+Tab icon: purple "KB" badge (16, 24, 32 and 48 px).
# Embedded as text so the .cmd stays a single file. If it fails, the program opens without the icon.
$IconBase64 = "AAABAAQAEBAAAAEAIABoBAAARgAAABgYAAABACAAiAkAAK4EAAAgIAAAAQAgAKgQAAA2DgAAMDAAAAEAIACoJQAA3h4AACgAAAAQAAAAIAAAAAEAIAAAAAAAQAQAAAAAAAAAAAAAAAAAAAAAAAD/AJkK/wChn/8Apfb/AKL9/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKL9/wCl9v8AoZ//AJkK/wChnv8Arf//AKH+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof7/AK3//wChnv8Aof7/AKL9/wCg/v8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKD+/wCi/f8Aof7/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//VMD///////8cq///AKH//xKo///g9P//uOX//1XA///////////////////0+///vuf//ySu//8Aof//AKH//1TA////////HKv//wGh//+25P//3/P//xKo//9UwP///////yqw//8Qp///I67//9nx//+r4P//AKH//wCh//9UwP///////zy3//9+z///9/z//zKz//8Aof//VMD///////8qsP//EKf//yav///Z8f//mdn//wCh//8Aof//VMD////////y+v///f7//2HF//8Aof//AKH//1TA////////////////////////r+L//wik//8Aof//AKH//1TA////////YMT///b8//9ox///AKH//wCh//9UwP///////xyr//8Aof//Rrv///////84tv//AKH//wCh//9UwP///////xyr//9JvP//9/z//2fH//8Aof//VMD///////8qsP//EKf//1XA////////TL3//wCh//8Aof//VMD///////8cq///AKH//06+///5/f//Zcb//1TA///////////////////t+P//mdn//wSi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh/v8Aov3/AKD+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP7/AKL9/wCh/v8AoZ7/AK3//wCh/v8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH+/wCt//8AoZ7/AJkK/wChn/8Apfb/AKL9/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKL9/wCl9v8AoZ//AJkKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACgAAAAYAAAAMAAAAAEAIAAAAAAAYAkAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/wCbEv8ApZz/AKTr/wCi/v8Aof7/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH+/wCi/v8ApOv/AKWc/wCbEgAAAAD/AKET/wCizP8Arf//AKL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aov//AK3//wCizP8AoRP/AJ+e/wCu//8AoPr/AKH+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof7/AKD6/wCu//8An57/AKDx/wCj/f8Aof7/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH+/wCj/f8AoPH/AKL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aov//AKH+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof7/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Qp/////////T7//8Aof//AKH//wCh//8Dov//wej///////+Z2f//EKf/////////////////////////////6ff//7Tj//80tP//AKH//wCh//8Aof//AKH//wCh//8Qp/////////T7//8Aof//AKH//wCh//+G0v///////8vs//8HpP//EKf////////6/f//gND//4DQ//+C0f//qd////7////w+f//Hqz//wCh//8Aof//AKH//wCh//8Qp/////////T7//8Aof//AKH//0m8///+////7fj//x+s//8Aof//EKf////////0+///AKH//wCh//8Aof//AKH//6zg////////Y8X//wCh//8Aof//AKH//wCh//8Qp/////////j8//8Qp///HKv//+z4///+////Sbz//wCh//8Aof//EKf////////0+///AKH//wCh//8Aof//AKH//6rg////////W8P//wCh//8Aof//AKH//wCh//8Qp//////////////b8v//yuv///////+C0f//AKH//wCh//8Aof//EKf////////5/f//fM///3zP//9/0P//quD///7////E6f//CKT//wCh//8Aof//AKH//wCh//8Qp/////////n9///j9f///////8bq//8Cov//AKH//wCh//8Aof//EKf//////////////////////////////////7zm//8Qp///AKH//wCh//8Aof//AKH//wCh//8Qp/////////T7//8mr///6Pf///j8//9Gu///AKH//wCh//8Aof//EKf////////0+///AKH//wCh//8Go///csv///////+q4P//AKH//wCh//8Aof//AKH//wCh//8Qp/////////T7//8Aof//LLH//+z4///2/P//QLn//wCh//8Aof//EKf////////0+///AKH//wCh//8Aof//LbL////////g9P//AKH//wCh//8Aof//AKH//wCh//8Qp/////////T7//8Aof//AKH//zO0///w+f//9Pv//zu3//8Aof//EKf////////6/f//gND//4DQ//+H0///1/D///////+p3///AKH//wCh//8Aof//AKH//wCh//8Qp/////////T7//8Aof//AKH//wCh//86tv//9Pv///H6//81tf//EKf////////////////////////6/f//4fT//5bY//8Rp///AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof7/AKL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aov//AKDx/wCj/f8Aof7/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH+/wCj/f8AoPH/AJ+e/wCu//8AoPr/AKH+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof7/AKD6/wCu//8An57/AKET/wCizP8Arf//AKL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aov//AK3//wCizP8AoRMAAAAA/wCbEv8ApZz/AKTr/wCi/v8Aof7/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH+/wCi/v8ApOv/AKWc/wCbEgAAAACAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAQAoAAAAIAAAAEAAAAABACAAAAAAAIAQAAAAAAAAAAAAAAAAAAAAAAAA/wB/AgAAAAD/AI0S/wClhv8Apdv/AKL8/wCh/v8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof7/AKL8/wCl2/8ApYb/AI0SAAAAAP8AfwIAAAAA/wCbKf8Aptf/AKv//wCk//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKT//wCr//8Aptf/AJspAAAAAP8AmxL/AKLc/wCs//8Aofr/AKD+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP7/AKH6/wCs//8Aotz/AJsS/wCgh/8ArP//AKD6/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKD6/wCs//8AoIf/AKDh/wCk/v8AoP7/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP7/AKT+/wCg4f8Aof7/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wKi//8Eov//A6L//wCh//8Aof//AKH//wCh//8Bof//BKL//wSi//8Cov//AKH//wOi//8Eov//BKL//wSi//8Eov//BKL//wSi//8Eov//AqL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AJ3//wCb//8Anf//AKH//wCh//8Aof//AKL//wCg//8Am///AJr//wCd//8Aof//AJv//wCb//8Am///AJv//wCb//8Am///AJr//wCb//8An///AqL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AqL//wCd//9mxv//n9z//23J//8Anv//AqL//wKi//8Anv//FKj//5fZ//+j3f//asj//wCf//+M1f//n9z//57b//+g3P//n9z//5/c//+S1///aMf//xuq//8Anf//AaL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Dov//AJv//67h////////u+X//wCc//8Eov//BKL//wCd//+25P////////n9//8ssP//A6D//+75////////////////////////////////////////7Pj//0a6//8Anf//A6L//wCh//8Aof//AKH//wCh//8Aof//AKH//wOi//8Am///odz///v+//+u4P//AZ3//wek//8Amv//hNL////////4/P//PLf//wCZ//8HpP//1vD///v+//+E0v//I6j//yiw//8lrv//QLb//8bq////////2/L//wei//8Bof//AaH//wCh//8Aof//AKH//wCh//8Aof//A6L//wCb//+j3f///////6rf//8AnP//AJz//1K//////////////2vJ//8Amv//A6L//wSj///Z8f///////2/K//8AmP//AKH//wCg//8Alv//R7v///z+///2/P//H63//wCe//8Cov//AKH//wCh//8Aof//AKH//wCh//8Dov//AJv//6Td////////ze3//wih//8jrf//7/n///////+a2v//AJv//wWj//8AoP//BKP//9nx////////asj//wCU//8Anf//AJz//wCa//9+z////////+T1//8LpP//AaD//wGh//8Aof//AKH//wCh//8Aof//AKH//wOi//8Am///pt7/////////////0O7//9Du////////x+r//wWg//8Dof//AqL//wCg//8Eo///3PL////////I6///ntn//6Dc//+e2///uuX///n9///h9P//U7///wCc//8Dov//AKH//wCh//8Aof//AKH//wCh//8Aof//A6L//wCb//+l3v///////+H0/////////////+b2//8Sp///AZ///wKi//8Bof//AKD//wSj///d8v//////////////////////////////////4/X//0W5//8Amf//AqL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Dov//AJv//6Pd////////ot3//0y8///9////8/r//13D//8Amv//BKL//wGh//8AoP//BKP//9rx////////htL//yWp//8qsP//K67//3jN///+////7Pj//yWu//8Bn///AqL//wCh//8Aof//AKH//wCh//8Aof//AKH//wOi//8Am///o93///////+y4///AJX//17D/////////////2PF//8Amv//BaP//wCg//8Eo///2fH///////9ox///AJP//wCd//8AmP//AJz//+T1////////a8j//wCa//8Eov//AKH//wCh//8Aof//AKH//wCh//8Aof//A6L//wCb//+h3P//+/7//6zg//8Cnv//AJv//1vC///+/////////2LF//8Amf//AKH//wSj///W8P//+/7//4XS//8lqf//KrD//yyu//95zv//+Pz///////9Zwv//AJv//wSi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Dov//AJv//67h////////u+X//wCc//8HpP//AJr//1zD/////////////3rO//8Dnv//BqP//+z4////////////////////////////////////////vOb//wui//8BoP//AaH//wCh//8Aof//AKH//wCh//8Aof//AKH//wKi//8Anf//Zsb//5/c//9tyf//AJ7//wKi//8Eo///AJr//1XA//+f2///o93//ySu//8BoP//jNT//5/c//+e2///oNz//6Dc//+d2///htL//1G+//8Cof//AJ///wGh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Anf//AJv//wCd//8Aof//AKH//wCh//8Cov//AJ3//wCb//8Amv//AKH//wCh//8AnP//AJv//wCb//8Am///AJv//wCb//8Amv//AJv//wCh//8Bof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wKi//8Eov//A6L//wCh//8Aof//AKH//wCh//8Dov//BKL//wOi//8Aof//AKH//wOi//8Eov//BKL//wSi//8Eov//BKL//wSi//8Dov//AaH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof7/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH+/wCg4f8ApP7/AKD+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKD+/wCk/v8AoOH/AKCH/wCs//8AoPr/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoPr/AKz//wCgh/8AmxL/AKLc/wCs//8Aofr/AKD+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP7/AKH6/wCs//8Aotz/AJsSAAAAAP8Amyn/AKbX/wCr//8ApP//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCk//8Aq///AKbX/wCbKQAAAAD/AH8CAAAAAP8AjRL/AKWG/wCl2/8Aovz/AKH+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh/v8Aovz/AKXb/wClhv8AjRIAAAAA/wB/AkAAAAKAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAAFAAAACKAAAADAAAABgAAAAAQAgAAAAAACAJQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/wCqAwAAAAD/AIkN/wCmaP8ApsD/AKPv/wCi/v8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aov7/AKPv/wCmwP8Apmj/AIkNAAAAAP8AqgMAAAAAAAAAAAAAAAD/AKoDAAAAAP8AoEb/AKXW/wCq//8Ap///AKP//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKP//wCn//8Aqv//AKXW/wCgRgAAAAD/AKoDAAAAAP8AqgMAAAAA/wCfa/8Aqf//AKf//wCg/P8Aof3/AKH+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH+/wCh/f8AoPz/AKf//wCp//8An2sAAAAA/wCqAwAAAAD/AKJC/wCp//8Ao/3/AKD8/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKD8/wCj/f8Aqf//AKJCAAAAAP8AnA3/AKHc/wCn//8AoPz/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCg/P8Ap///AKHc/wCcDf8An2j/AKr//wCf/P8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8An/z/AKr//wCfaP8AoMT/AKf+/wCh/f8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof3/AKf+/wCgxP8AofL/AKP//wCg/v8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP7/AKP//wCh8v8Aov//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wSi//8Eov//BKL//wKi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AqL//wSi//8Eov//BKL//wKi//8Aof//AaL//wSi//8Eov//BKL//wSi//8Eov//BKL//wSi//8Eov//BKL//wOi//8Cov//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCb//8Am///AJv//wCe//8Aof//AKH//wCh//8Aof//AKH//wCh//8Bov//AJ7//wCb//8Am///AJr//wCc//8Aov//AJ///wCb//8Am///AJv//wCb//8Am///AJv//wCb//8Am///AJv//wCc//8Anv//AKH//wOi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//BqP//1jC//9gxP//YMT//zS0//8Anv//AqL//wCh//8Aof//AKH//wKi//8Anf//LLH//2DE//9cw///YcX//0a7//8AnP//JK7//2DE//9exP//YMT//2DE//9gxP//YMT//1/E//9fxP//XcP//0y9//8or///AKD//wCb//8Cov//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wGh//8AoP//EKf///v+/////////////5PX//8Amv//BKP//wCh//8Aof//AqL//wGe//8aqf//6Pb//////////////////0W6//8Al///Zcb////////////////////////////////////////////////////////6/f//y+v//1jA//8AnP//AqH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wGh//8AoP//D6f//+f3///7/v//+/7//4jT//8Amv//BKP//wCh//8Bof//A6H//wKe///B6f////////X7////////VsH//wCa//8AnP//W8L///v+///3/f//+/7///////////////////////////////////////////////////////9/z///AJz//wOi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wGh//8AoP//D6f//+v4/////////////4rU//8Amv//BKP//wCh//8Eov//AJr//5DX////////9/z///////+J1P//AJr//wik//8Am///XcP////////7/v///////2TG//9Btv//Qrr//0G5//9Cuf//S7v//3/P///t+P//+/7///v9////////MbP//wCd//8Cov//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wGh//8AoP//D6f//+v4/////////////4vU//8Amv//BKP//wSj//8Amv//XMP////////4/P///////7fl//8Anf//BKH//wWi//8Am///XcP////////7/v///////yWv//8AmP//AJ3//wCc//8AnP//AJ3//wCW//9Iu////v////n9///+////ftD//wCa//8Eo///AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wGh//8AoP//D6f//+v4/////////////4fT//8Dm///CKT//wCd//8usf//9vz///r9////////3fP//xKl//8Bn///AqL//wSi//8Am///XcP////////7/v///////zO0//8Dnv//BaP//wOi//8Dov//BaL//wai//8JpP//6vf////////+////lNf//wCa//8Eov//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wGh//8AoP//D6f//+v4/////////////5XY//8Al///AqD//w6k///Z8f////////r9///2/P//MLL//wCc//8Dov//AKH//wSi//8Am///XcP////////7/v///////zCz//8Anf//AqL//wCh//8Aof//AaH//wCa//8bq///9vz///v9////////eM3//wCa//8Eo///AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wGh//8AoP//D6f//+v4/////////P7///f8//9+z///B53//63h////////9/z///////9awv//AJr//wSj//8Aof//AKH//wSi//8Am///XcP////////7/v///////y+z//8Anf//AaL//wCh//8Aof//B6P//yyu//+45f///v/////////2/P//Iaz//wGf//8Cov//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wGh//8AoP//D6f//+v4/////////v//////////////1/H////////7/v///////4nU//8Amv//BKL//wCh//8Aof//AKH//wSi//8Am///XcP////////7/v///////9rx///R7f//0u7//9Hu///S7v//3PL///3//////////////+T1//9Ju///AJz//wKi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wGh//8AoP//D6f//+v4/////////v////z+//////////////z+////////reH//wKf//8Dof//AaH//wCh//8Aof//AKH//wSi//8Am///XcP////////7/v////////////////////////////////////////3+///p9///eMz//wSg//8Anf//AqL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wGh//8AoP//D6f//+v4/////////////5TY//+t4v////////j8////////T77//wCY//8GpP//AKH//wCh//8Aof//AKH//wSi//8Am///XcP////////7/v///////8jr//+75f//vOb//7vm//+95v//2fH////////7/v//5fX//2rH//8Anv//AqL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wGh//8AoP//D6f//+v4/////////////4PR//8Em///w+n////////5/f//8/r//0S5//8Amv//BKP//wCh//8Aof//AKH//wSi//8Am///XcP////////7/v///////yew//8Amf//AJ7//wCd//8Anv//BZ7//3PL//////////////////83tf//AJ3//wKi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wGh//8AoP//D6f//+v4/////////////47V//8AmP//DqT//8Lp/////////P7///b8//9Fuf//AJr//wSj//8Aof//AKH//wSi//8Am///XcP////////7/v///////zO0//8En///BqT//wSj//8Fo///AqH//wSj///p9////v////7///+L1P//AJr//wSi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wGh//8AoP//D6f//+v4/////////////4rU//8Bm///AaD//wyj///D6f////////v9///3/P//Rrr//wCa//8Eo///AKH//wSi//8Am///XcP////////7/v///////ymw//8Amv//AJ///wCe//8Anv//AJn//xWp///x+v///f7///3+//+b2v//AJv//wSi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wGh//8AoP//D6f//+v4/////////////4rU//8Amv//B6T//wCf//8No///xOr////////7/f//+P3//0i6//8Amv//BKP//wSi//8Am///XcP////////7/v///////0++//8mrP//KLD//yev//8qsP//SLn//7vm////////9vz///////9xy///AJr//wSj//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wGh//8AoP//D6f//+f3///7/f//+/3//4jT//8Amv//BKP//wKi//8An///DqP//8Xq////////+f3///T7//9Guv//AJj//waj//8Am///W8L///v9///3/P//+/3///r9///6/f//+v3///r9///7/f/////////////+/////////+D0//8Vp///AaD//wGh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wGh//8AoP//EKf///z+/////////////5TY//8Amf//BKP//wCh//8Cov//AJ7//w+k///H6v//////////////////XsP//wOg//8Am///ZMb////////////////////////////////////////////////////////6/f//tOP//ySs//8Anv//AqL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP//B6T//3XM//9/0P//f9D//0W6//8Anf//AqL//wCh//8Aof//AqL//wCe//8Qp///e87//33P//+A0P//es7//wyl//8Anf//L7L//3/Q//99z///f9D//3/Q//9/0P//f9D//3/Q//9+0P//c8v//1XA//8mrv//AJ3//wCe//8Bov//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCb//8Amv//AJr//wCd//8Aov//AKH//wCh//8Aof//AKH//wGi//8AoP//AJr//wCa//8Amv//AJr//wCh//8Aof//AJ7//wCa//8Amv//AJr//wCa//8Amv//AJr//wCa//8Amv//AJr//wCb//8Anv//AqL//wKi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wSi//8Eo///BKP//wKi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Bof//BKP//wSj//8Eo///A6L//wCh//8Aof//AqL//wSj//8Eo///BKP//wSj//8Eo///BKP//wSj//8Eo///BKP//wSi//8Cov//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aov//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCi//8AofL/AKP//wCg/v8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP7/AKP//wCh8v8AoMT/AKf+/wCh/f8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof3/AKf+/wCgxP8An2j/AKr//wCf/P8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8An/z/AKr//wCfaP8AnA3/AKHc/wCn//8AoPz/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCg/P8Ap///AKHc/wCcDQAAAAD/AKJC/wCp//8Ao/3/AKD8/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKD8/wCj/f8Aqf//AKJCAAAAAP8AqgMAAAAA/wCfa/8Aqf//AKf//wCg/P8Aof3/AKH+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH+/wCh/f8AoPz/AKf//wCp//8An2sAAAAA/wCqAwAAAAD/AKoDAAAAAP8AoEb/AKXW/wCq//8Ap///AKP//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKP//wCn//8Aqv//AKXW/wCgRgAAAAD/AKoDAAAAAAAAAAAAAAAA/wCqAwAAAAD/AIkN/wCmaP8ApsD/AKPv/wCi/v8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aov7/AKPv/wCmwP8Apmj/AIkNAAAAAP8AqgMAAAAAAAAAANAAAAAACwAAoAAAAAAFAABAAAAAAAIAAIAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAAAAAEAAEAAAAAAAgAAoAAAAAAFAADQAAAAAAsAAA=="
try {
    $form.Icon = New-Object System.Drawing.Icon([System.IO.MemoryStream]::new([Convert]::FromBase64String($IconBase64)))
} catch { }

# Top bar: dark background + purple strip underneath
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Location = New-Object System.Drawing.Point(0, 0)
$pnlHeader.Size = New-Object System.Drawing.Size($form.ClientSize.Width, 56)
$pnlHeader.BackColor = Get-ThemeColor "Header"
$form.Controls.Add($pnlHeader)

$lblBadge = New-Object System.Windows.Forms.Label
$lblBadge.Text = "KB"
$lblBadge.TextAlign = "MiddleCenter"
$lblBadge.Location = New-Object System.Drawing.Point(16, 14)
$lblBadge.Size = New-Object System.Drawing.Size(28, 28)
$lblBadge.BackColor = Get-ThemeColor "Accent"
$lblBadge.ForeColor = [System.Drawing.Color]::White
$lblBadge.Font = $fontBold
$pnlHeader.Controls.Add($lblBadge)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Windows 11 Security Updates Remote Installer"
$lblTitle.Location = New-Object System.Drawing.Point(54, 15)
$lblTitle.Size = New-Object System.Drawing.Size(600, 26)
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$pnlHeader.Controls.Add($lblTitle)

$pnlStrip = New-Object System.Windows.Forms.Panel
$pnlStrip.Location = New-Object System.Drawing.Point(0, 56)
$pnlStrip.Size = New-Object System.Drawing.Size($form.ClientSize.Width, 3)
$pnlStrip.BackColor = Get-ThemeColor "Accent"
$form.Controls.Add($pnlStrip)

# Buttons: Primary = purple filled, Dark = black filled, Outline = white with dark border
function Set-ButtonStyle ($Button, $Style) {
    $Button.FlatStyle = "Flat"
    $Button.Font = $fontBold
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    switch ($Style) {
        "Primary" { $Button.BackColor = Get-ThemeColor "Accent"; $Button.ForeColor = [System.Drawing.Color]::White; $Button.FlatAppearance.BorderSize = 0 }
        "Dark"    { $Button.BackColor = Get-ThemeColor "Header"; $Button.ForeColor = [System.Drawing.Color]::White; $Button.FlatAppearance.BorderSize = 0 }
        "Outline" { $Button.BackColor = Get-ThemeColor "Card";   $Button.ForeColor = Get-ThemeColor "Text"; $Button.FlatAppearance.BorderColor = Get-ThemeColor "Text"; $Button.FlatAppearance.BorderSize = 1 }
    }
}

$txtHosts = New-Object System.Windows.Forms.TextBox
$txtHosts.Multiline = $true
$txtHosts.ScrollBars = "Vertical"
$txtHosts.Location = New-Object System.Drawing.Point(10, 103)
$txtHosts.Size = New-Object System.Drawing.Size(250, 515)
$txtHosts.BorderStyle = "FixedSingle"
$txtHosts.BackColor = Get-ThemeColor "Card"
$txtHosts.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.Controls.Add($txtHosts)

$lblHosts = New-Object System.Windows.Forms.Label
$lblHosts.Text = "HOSTS  -  1 PER LINE"
$lblHosts.Location = New-Object System.Drawing.Point(10, 78)
$lblHosts.Size = New-Object System.Drawing.Size(250, 20)
$lblHosts.Font = $fontBold
$form.Controls.Add($lblHosts)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = "Stop Process"
$btnStop.Location = New-Object System.Drawing.Point(10, 628)
$btnStop.Size = New-Object System.Drawing.Size(250, 35)
$btnStop.Enabled = $false
Set-ButtonStyle $btnStop "Dark"
$form.Controls.Add($btnStop)

$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = "Load hosts.txt"
$btnLoad.Location = New-Object System.Drawing.Point(10, 673)
$btnLoad.Size = New-Object System.Drawing.Size(120, 35)
Set-ButtonStyle $btnLoad "Outline"
$form.Controls.Add($btnLoad)

$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = "Install CU"
$btnInstall.Location = New-Object System.Drawing.Point(140, 673)
$btnInstall.Size = New-Object System.Drawing.Size(120, 35)
Set-ButtonStyle $btnInstall "Primary"
$form.Controls.Add($btnInstall)

$lblCounters = New-Object System.Windows.Forms.Label
$lblCounters.Text = ""
$lblCounters.Location = New-Object System.Drawing.Point(275, 78)
$lblCounters.Size = New-Object System.Drawing.Size(750, 20)
$lblCounters.Font = $fontBold
$form.Controls.Add($lblCounters)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(275, 103)
$grid.Size = New-Object System.Drawing.Size(750, 605)
$grid.AllowUserToAddRows = $false
$grid.ReadOnly = $true
$grid.RowHeadersVisible = $false
$grid.SelectionMode = "FullRowSelect"
$grid.AutoSizeColumnsMode = "Fill"
$grid.BackgroundColor = Get-ThemeColor "Card"
$grid.BorderStyle = "FixedSingle"
$grid.GridColor = Get-ThemeColor "Border"
$grid.CellBorderStyle = "SingleHorizontal"
$grid.EnableHeadersVisualStyles = $false    # required for the custom header colors
$grid.ColumnHeadersBorderStyle = "None"
$grid.ColumnHeadersHeightSizeMode = "DisableResizing"
$grid.ColumnHeadersHeight = 34
$grid.ColumnHeadersDefaultCellStyle.BackColor = Get-ThemeColor "Header"
$grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
$grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = Get-ThemeColor "Header"
$grid.ColumnHeadersDefaultCellStyle.Font = $fontBold
$grid.DefaultCellStyle.Font = $fontRegular
$grid.DefaultCellStyle.ForeColor = Get-ThemeColor "Text"
$grid.DefaultCellStyle.SelectionBackColor = Get-ThemeColor "Accent"
$grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
$grid.RowTemplate.Height = 26

[void]$grid.Columns.Add("Host","Host")
[void]$grid.Columns.Add("Release","Release (Build)")
[void]$grid.Columns.Add("Status","Status")
[void]$grid.Columns.Add("ExitCode","Exit Code")
[void]$grid.Columns.Add("PendingReboot","Pending Reboot")
[void]$grid.Columns.Add("Detail","Detail")

# Extra columns: hidden in the grid, exported to the CSV
foreach ($col in "KB","Method","Ping","WinRM","Access","CopyMode","BuildBefore","BuildAfter","ExpectedBuild","FreeSpaceGB","RequiredSpaceGB","DiskCleanup","LogPath","StartTime","EndTime","Duration") {
    $idx = $grid.Columns.Add($col, $col)
    $grid.Columns[$idx].Visible = $false
}

$form.Controls.Add($grid)

# ==========================
# FUNCTIONS
# ==========================
# Row color based on Status
function Set-RowColor {
    param($Row)
    switch ([string]$Row.Cells["Status"].Value) {
        { $_ -in "Finished", "Skipped" } { $color = Get-ThemeColor "SuccessSoft"; break }
        { $_ -in "Failed", "Error" }     { $color = Get-ThemeColor "ErrorSoft";   break }
        "Stopped"                        { $color = Get-ThemeColor "StoppedSoft"; break }
        "Queued"                         { $color = Get-ThemeColor "Card";        break }
        default                          { $color = Get-ThemeColor "AccentSoft" }  # in progress
    }
    if ($Row.DefaultCellStyle.BackColor -ne $color) { $Row.DefaultCellStyle.BackColor = $color }
}

# Counters above the grid
function Update-Counters {
    $counts = @{ Finished = 0; Skipped = 0; Failed = 0; Error = 0; Stopped = 0; Queued = 0; Running = 0 }
    foreach ($row in $grid.Rows) {
        $st = [string]$row.Cells["Status"].Value
        if ($counts.ContainsKey($st) -and $st -ne "Running") { $counts[$st]++ } else { $counts["Running"]++ }
    }
    $lblCounters.Text = "Total: $($grid.Rows.Count)  |  Finished: $($counts.Finished)  |  Skipped: $($counts.Skipped)  |  " +
                        "Failed: $($counts.Failed)  |  Error: $($counts.Error)  |  In progress: $($counts.Running)  |  " +
                        "Queued: $($counts.Queued)  |  Stopped: $($counts.Stopped)"
}

# Copies the data written by the worker threads ($syncState) into the grid.
# Runs only on the UI thread: worker threads never touch the form.
function Sync-Grid {
    foreach ($row in $grid.Rows) {
        $data = $syncState[[string]$row.Cells["Host"].Value]
        if ($null -eq $data) { continue }
        foreach ($key in $data.Keys) {
            if ([string]$row.Cells[$key].Value -ne [string]$data[$key]) { $row.Cells[$key].Value = $data[$key] }
        }
        Set-RowColor $row
    }
    Update-Counters
}

# Creates D:\jorge\InstallKB_Report\install_kb_sep26_<date>_<time>.csv with the current grid content
function Export-GridReport {
    param($Cycle)

    if (-not (Test-Path $ReportFolder)) {
        New-Item -Path $ReportFolder -ItemType Directory -Force | Out-Null
    }

    $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $path  = Join-Path $ReportFolder "${ReportPrefix}_$stamp.csv"

    $rows = foreach ($row in $grid.Rows) {
        [PSCustomObject]@{
            Cycle         = $Cycle
            Hostname      = [string]$row.Cells["Host"].Value
            Release       = [string]$row.Cells["Release"].Value
            Status        = [string]$row.Cells["Status"].Value
            ExitCode      = [string]$row.Cells["ExitCode"].Value
            PendingReboot = [string]$row.Cells["PendingReboot"].Value
            Detail        = [string]$row.Cells["Detail"].Value
            KB            = [string]$row.Cells["KB"].Value
            Method        = [string]$row.Cells["Method"].Value
            Ping          = [string]$row.Cells["Ping"].Value
            WinRM         = [string]$row.Cells["WinRM"].Value
            Access        = [string]$row.Cells["Access"].Value
            CopyMode      = [string]$row.Cells["CopyMode"].Value
            BuildBefore   = [string]$row.Cells["BuildBefore"].Value
            BuildAfter    = [string]$row.Cells["BuildAfter"].Value
            ExpectedBuild = [string]$row.Cells["ExpectedBuild"].Value
            FreeSpaceGB_C = [string]$row.Cells["FreeSpaceGB"].Value
            RequiredSpaceGB = [string]$row.Cells["RequiredSpaceGB"].Value
            DiskCleanup   = [string]$row.Cells["DiskCleanup"].Value
            LogPath       = [string]$row.Cells["LogPath"].Value
            StartTime     = [string]$row.Cells["StartTime"].Value
            EndTime       = [string]$row.Cells["EndTime"].Value
            Duration      = [string]$row.Cells["Duration"].Value
        }
    }

    # -UseCulture: uses the Windows list separator (";" in pt-BR) so the file opens in Excel with separate columns
    $rows | Export-Csv -Path $path -NoTypeInformation -UseCulture -Encoding UTF8
    return $path
}

# ==========================
# LOAD HOSTS BUTTON 
# ==========================
$btnLoad.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*"
    if ($dialog.ShowDialog() -eq "OK") {
        $txtHosts.Text = (Get-Content $dialog.FileName) -join "`r`n"
    }
})

# ==========================
# STOP BUTTON
# ==========================
$btnStop.Add_Click({
    $script:StopRequested = $true
    $btnStop.Enabled = $false
    $btnStop.Text = "Stopping..."
})

# ==========================
# INSTALL BUTTON 
# ==========================
$btnInstall.Add_Click({
    $hosts = $txtHosts.Text -split "`r?`n" | 
        ForEach-Object { $_.Trim() } | 
        Where-Object { $_ } | 
        Select-Object -Unique

    if ($hosts.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Please provide at least one host.")
        return
    }

    $btnInstall.Enabled = $false
    $btnLoad.Enabled = $false
    $btnStop.Text = "Stop Process"
    $btnStop.Enabled = $true
    $script:StopRequested = $false

    # Parallel Execution Code Block
    $ScriptBlock = {
        param($ComputerName, $Source23H2, $Source24H2, $Source25H2, $RemoteFolder, $syncState, $ExpectedUBR, $CleanupScriptText, $LogFolder, $FreeSpaceMarginGB, $Timeouts, $PsExecPath, $CopyOrder)

        # Fast ping using .NET with a real timeout (Test-Connection waits ~4s per attempt on offline hosts)
        function Test-Ping ($Name, $TimeoutMs) {
            $ping = New-Object System.Net.NetworkInformation.Ping
            try {
                for ($i = 0; $i -lt 2; $i++) {
                    try {
                        if ($ping.Send($Name, $TimeoutMs).Status -eq 'Success') { return $true }
                    } catch {
                        return $false   # name could not be resolved
                    }
                }
                return $false
            } finally {
                $ping.Dispose()
            }
        }

        # Fast WinRM check: TCP connect to port 5985 with a timeout (Test-WSMan has no timeout and can hang)
        function Test-TcpPort ($Name, $Port, $TimeoutMs) {
            $client = New-Object System.Net.Sockets.TcpClient
            try {
                $connect = $client.BeginConnect($Name, $Port, $null, $null)
                if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
                $client.EndConnect($connect)
                return $true
            } catch {
                return $false
            } finally {
                $client.Close()
            }
        }

        # Script that PsExec runs on the host: executes the code, saves the result to a .xml file read back over C$
        $PsExecWrapper = @'
$ErrorActionPreference = 'Stop'
$base = 'C:\Windows\Temp\CUInstall'
$id   = '__ID__'
try {
    $a = @()
    if (Test-Path "$base\$id.args.xml") { $a = [object[]](Import-Clixml "$base\$id.args.xml") }
    $code = {
__CODE__
    }
    $res = @{ Ok = $true; Output = (& $code @a) }
} catch {
    $res = @{ Ok = $false; Error = $_.Exception.Message }
}
New-Item -ItemType Directory -Path $base -Force | Out-Null
Export-Clixml -InputObject $res -Path "$base\$id.result.xml"
'@

        # Runs a script block on the host.
        #   WinRM : Invoke-Command
        #   PsExec: writes the code to \\host\C$\Windows\Temp\CUInstall, runs it as SYSTEM with PsExec, reads the result over C$
        # $Via empty = use the access method detected for this host ($Access)
        function Invoke-Remote ([scriptblock]$Code, [object[]]$Arguments = @(), [string]$Via = "", [int]$TimeoutMinutes = 5) {
            if (-not $Via) { $Via = $Access }
            if ($Via -eq "WinRM") {
                return Invoke-Command -ComputerName $ComputerName -ScriptBlock $Code -ArgumentList $Arguments -ErrorAction Stop
            }

            if (-not (Test-Path $PsExecPath)) { throw "PsExec not found: $PsExecPath" }
            $id    = [guid]::NewGuid().ToString("N").Substring(0, 12)
            $share = "\\$ComputerName\C$\Windows\Temp\CUInstall"
            New-Item -ItemType Directory -Path $share -Force -ErrorAction Stop | Out-Null
            if ($Arguments.Count -gt 0) { Export-Clixml -InputObject $Arguments -Path "$share\$id.args.xml" -ErrorAction Stop }
            $PsExecWrapper.Replace("__ID__", $id).Replace("__CODE__", $Code.ToString()) |
                Set-Content -Path "$share\$id.ps1" -Encoding UTF8 -ErrorAction Stop

            $resultFile = "$share\$id.result.xml"
            try {
                for ($attempt = 1; $attempt -le $Timeouts.PsExecAttempts; $attempt++) {
                    $run = Invoke-PsExec -ScriptName "$id.ps1" -TimeoutMinutes $TimeoutMinutes
                    if (Test-Path $resultFile) { break }

                    # PsExec separates its progress lines with a bare carriage return, so split on both CR and LF
                    $lastLine = $run.StdErr -split "[\r\n]+" | Where-Object { $_.Trim() } | Select-Object -Last 1
                    # "<program> exited on <host> with error code N" = the command really ran: never run it twice.
                    # Without it the command never started (e.g. "Error communicating with PsExec service"), so a retry is safe.
                    $commandRan = $run.StdErr -match 'exited on .+ with error code'
                    if ($commandRan -or $attempt -eq $Timeouts.PsExecAttempts) {
                        throw "PsExec failed (exit $($run.ExitCode), attempt $attempt of $($Timeouts.PsExecAttempts)): $lastLine"
                    }
                    Start-Sleep -Seconds (10 * $attempt)   # give the previous PSEXESVC time to stop, then retry
                }
                $result = Import-Clixml -Path $resultFile
            } finally {
                Remove-Item -Path "$share\$id.*" -Force -ErrorAction SilentlyContinue
            }
            if (-not $result.Ok) { throw "Remote error: $($result.Error)" }
            return $result.Output
        }

        # Runs PsExec once on this host and waits for it. Returns its exit code and error output.
        function Invoke-PsExec ($ScriptName, $TimeoutMinutes) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName  = $PsExecPath
            # no -nobanner: older PsExec versions (e.g. v2.11) reject it and exit with -1
            $psi.Arguments = "\\$ComputerName -accepteula -s -n $($Timeouts.PsExecConnectSec) " +
                             "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\Windows\Temp\CUInstall\$ScriptName"
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true
            $psi.RedirectStandardInput  = $true    # closed right away, otherwise PsExec can wait for input forever
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true

            $proc = [System.Diagnostics.Process]::Start($psi)
            try {
                $proc.StandardInput.Close()
                $outReader = $proc.StandardOutput.ReadToEndAsync()   # drain output so PsExec never blocks
                $errReader = $proc.StandardError.ReadToEndAsync()
                $deadline  = (Get-Date).AddMinutes($TimeoutMinutes)
                while (-not $proc.WaitForExit(500)) {                 # short waits keep the Stop button responsive
                    if ((Get-Date) -gt $deadline) { throw "PsExec timeout after $TimeoutMinutes min" }
                }
                return [PSCustomObject]@{ ExitCode = $proc.ExitCode; StdErr = $errReader.Result }
            } finally {
                if (-not $proc.HasExited) { try { $proc.Kill() } catch {} }   # stops the local PsExec only
                $proc.Dispose()
            }
        }

        # Runs on the host: release, build, UBR and free space on C:
        $InfoBlock = {
            $cv   = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
            [PSCustomObject]@{
                DisplayVersion = $cv.DisplayVersion
                CurrentBuild   = $cv.CurrentBuild
                UBR            = $cv.UBR
                FreeSpaceGB    = [math]::Round($disk.FreeSpace / 1GB, 2)
            }
        }

        # Runs on the host (Pull): copies the MSU from the Source share to the local folder, returns the copied size
        $PullBlock = {
            param($SourceFile, $DestFolder)
            New-Item -ItemType Directory -Path $DestFolder -Force | Out-Null
            Copy-Item -Path $SourceFile -Destination $DestFolder -Force
            (Get-Item -Path (Join-Path $DestFolder (Split-Path $SourceFile -Leaf))).Length
        }

        # Thread only writes data; the UI thread copies it to the grid (Sync-Grid)
        $hostState = @{}
        function Report ([hashtable]$Values) {
            foreach ($key in $Values.Keys) { $hostState[$key] = $Values[$key] }
            $syncState[$ComputerName] = $hostState.Clone()
        }

        function Get-FreeSpaceGB {
            Invoke-Remote -Code {
                [math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB, 2)
            }
        }

        # Runs the cleanup script on the host and returns the free space (GB) after it
        function Invoke-DiskCleanup ($Reason) {
            $before = Get-FreeSpaceGB
            Report @{ Status = "Disk Cleanup"; DiskCleanup = "Running"; Detail = "$Reason - running cleanup" }
            $result = Invoke-Remote -Code ([scriptblock]::Create($CleanupScriptText)) -TimeoutMinutes 60 |
                Select-Object -Last 1
            $after = Get-FreeSpaceGB
            Report @{ DiskCleanup = "Done (WU healthy: $($result.WindowsUpdateHealthy))"; FreeSpaceGB = "$before -> $after" }
            return $after
        }

        # Copies the host logs to D:\jorge\InstallKB_Report\logs\<host>\ (date/time prefix keeps the history)
        function Save-RemoteLogs {
            try {
                $remoteDir = "\\$ComputerName\C$\Windows\Temp\CUInstall"
                $cbsLog    = "\\$ComputerName\C$\Windows\Logs\CBS\CBS.log"
                $localDir  = Join-Path $LogFolder $ComputerName
                $stamp     = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

                $files = @()
                if (Test-Path $remoteDir) {
                    $files += Get-ChildItem -Path $remoteDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne ".msu" }
                }
                if (Test-Path $cbsLog) { $files += Get-Item $cbsLog }
                if ($files.Count -eq 0) { return "No remote logs found" }

                New-Item -Path $localDir -ItemType Directory -Force | Out-Null
                $copied = 0
                foreach ($f in $files) {
                    try {
                        Copy-Item -Path $f.FullName -Destination (Join-Path $localDir "${stamp}_$($f.Name)") -Force -ErrorAction Stop
                        $copied++
                    } catch {}
                }
                if ($copied -eq 0) { return "Log copy failed" }
                return "$localDir ($copied file(s))"
            } catch {
                return "Log copy failed: $($_.Exception.Message)"
            }
        }

        # 0x80070070 = ERROR_DISK_FULL | 0x80070027 = ERROR_HANDLE_DISK_FULL
        function Test-IsDiskFull ($ErrorRecord) {
            $hr = $ErrorRecord.Exception.HResult
            return ($hr -eq -2147024784 -or $hr -eq -2147024857 -or
                    $ErrorRecord.Exception.Message -match 'not enough space')
        }

        function Copy-MsuToHost ($MsuPath, $Destination) {
            if (-not (Test-Path $Destination)) {
                New-Item -Path $Destination -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }
            Copy-Item -Path $MsuPath -Destination $Destination -Force -ErrorAction Stop
        }

        # Copies the MSU to the host trying each method in $CopyOrder (Push / Pull). Returns the method that worked.
        function Copy-Msu ($MsuFile, $AdminShare) {
            $failures = @()
            foreach ($method in $CopyOrder) {
                try {
                    if ($method -eq "Push") {
                        Copy-MsuToHost -MsuPath $MsuFile.FullName -Destination $AdminShare
                    } else {
                        $size = Invoke-Remote -Code $PullBlock -Arguments $MsuFile.FullName, $RemoteFolder -Via "PsExec" -TimeoutMinutes 60
                        if ([int64]$size -ne $MsuFile.Length) { throw "copied file size mismatch ($size of $($MsuFile.Length) bytes)" }
                    }
                    return $method
                } catch {
                    if (Test-IsDiskFull $_) { throw }   # disk full: the caller runs the cleanup and retries
                    $failures += "${method}: $($_.Exception.Message)"
                }
            }
            throw ($failures -join " | ")
        }

        # Pending reboot + current build (CurrentBuild.UBR)
        $GetStateBlock = {
            $pending = "False"
            if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $pending = "True" }
            if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { $pending = "True" }
            try {
                $val = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
                if ($val.PendingFileRenameOperations) { $pending = "True" }
            } catch {}
            $cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
            return [PSCustomObject]@{ Pending = $pending; Build = "$($cv.CurrentBuild).$($cv.UBR)"; UBR = [int]$cv.UBR }
        }

        $startTime = Get-Date
        $hostReachable = $false   # only collect logs if remote access (WinRM or PsExec) worked
        $Access = ""              # WinRM or PsExec, detected below
        Report @{ StartTime = $startTime.ToString("yyyy-MM-dd HH:mm:ss") }

        try {
            Report @{ Status = "Checking Ping" }

            # Every Invoke-Command in this thread gives up opening the session after SessionOpenMs (does not limit the install itself)
            $PSSessionOption = New-PSSessionOption -OpenTimeout ([int]$Timeouts.SessionOpenMs)

            if (-not (Test-Ping -Name $ComputerName -TimeoutMs $Timeouts.PingMs)) {
                Report @{ Ping = "Failed" }
                throw "Host offline or not responding to ping."
            }
            Report @{ Ping = "OK"; Status = "Checking Access" }

            # --- REMOTE ACCESS: WinRM first; PsExec + admin share (C$) when WinRM fails ---
            if (Test-TcpPort -Name $ComputerName -Port 5985 -TimeoutMs $Timeouts.WinRMPortMs) {
                try {
                    $os = Invoke-Remote -Code $InfoBlock -Via "WinRM"
                    $Access = "WinRM"
                    Report @{ WinRM = "OK" }
                } catch {
                    Report @{ WinRM = "Failed: " + ($_.Exception.Message -split "`r?`n")[0] }
                }
            } else {
                Report @{ WinRM = "Failed: port 5985 not reachable" }
            }

            if (-not $Access) {
                if (-not (Test-Path $PsExecPath)) { throw "WinRM failed and PsExec was not found at $PsExecPath" }
                if (-not (Test-TcpPort -Name $ComputerName -Port 445 -TimeoutMs $Timeouts.WinRMPortMs)) {
                    throw "WinRM failed and the admin share is not reachable (port 445)"
                }
                Report @{ Status = "Checking OS & Build (PsExec)" }
                $os = Invoke-Remote -Code $InfoBlock -Via "PsExec" -TimeoutMinutes 3
                $Access = "PsExec"
            }
            Report @{ Access = $Access }
            $hostReachable = $true
            # -----------------------------------------------------------

            $release     = $os.DisplayVersion
            $build       = $os.CurrentBuild
            $ubr         = [int]$os.UBR
            $expectedUbr = [int]$ExpectedUBR[$release]

            Report @{
                Status        = "Selecting Source"
                Release       = "$release ($build.$ubr)"
                BuildBefore   = "$build.$ubr"
                ExpectedBuild = $(if ($expectedUbr -gt 0) { "$build.$expectedUbr" } else { "Not configured" })
                FreeSpaceGB   = $os.FreeSpaceGB
            }

            switch ($release) {
                "23H2" { $source = $Source23H2 }
                "24H2" { $source = $Source24H2 }
                "25H2" { $source = $Source25H2 }
                default { throw "Unsupported Release: $release" }
            }

            # Each Source folder must hold exactly one .msu; the messages name the folder and the reason
            if (-not (Test-Path -LiteralPath $source)) {
                throw "Source folder for $release not found or no access: $source"
            }
            $msuFiles = @(Get-ChildItem -LiteralPath $source -Filter *.msu -File -ErrorAction Stop)
            if ($msuFiles.Count -eq 0) { throw "No .msu file found in the $release source folder: $source" }
            if ($msuFiles.Count -gt 1) {
                throw "More than one .msu in the $release source folder (keep only one): $($msuFiles.Name -join ', ')"
            }
            $msu = $msuFiles[0]

            $kbId = "KB-Install"
            if ($msu.Name -match "KB\d+") { 
                $kbId = $Matches[0]
            }
            Report @{ KB = $kbId }

            # --- PRE-CHECK: BUILD (UBR) + Get-HotFix ---
            Report @{ Status = "Checking Build/KB" }
            $ubrOk = ($expectedUbr -gt 0 -and $ubr -ge $expectedUbr)

            $isInstalledAlready = Invoke-Remote -Arguments $kbId -Code {
                param($id)
                return ($null -ne (Get-HotFix -Id $id -ErrorAction SilentlyContinue))
            }

            if ($ubrOk -or $isInstalledAlready) {
                $state = Invoke-Remote -Code $GetStateBlock
                if ($ubrOk) {
                    $skipDetail = "Already Installed (build $build.$ubr)"
                } elseif ($expectedUbr -gt 0) {
                    $skipDetail = "KB found (Get-HotFix) but build is $build.$ubr < $build.$expectedUbr - reboot needed to apply"
                } else {
                    $skipDetail = "Already Installed (Get-HotFix)"
                }
                Report @{ Status = "Skipped"; ExitCode = "0"; PendingReboot = $state.Pending; BuildAfter = $state.Build; Detail = $skipDetail }
                return # Stops processing this host and moves on to the next one
            }
            # -----------------------------------------------------------

            $adminShare = "\\$ComputerName\C$\Windows\Temp\CUInstall"

            # --- FREE SPACE CHECK BEFORE COPY ---
            $requiredGB = [math]::Round(($msu.Length / 1GB) + $FreeSpaceMarginGB, 2)
            Report @{ Status = "Checking Disk Space"; RequiredSpaceGB = $requiredGB }
            $cleanupDone = $false

            if ($os.FreeSpaceGB -lt $requiredGB) {
                $freeNow = Invoke-DiskCleanup -Reason "Low disk space: $($os.FreeSpaceGB) GB free, $requiredGB GB required"
                $cleanupDone = $true
                if ($freeNow -lt $requiredGB) {
                    throw "Insufficient disk space after cleanup: $freeNow GB free, $requiredGB GB required"
                }
            }
            # -----------------------------------------------------------

            # --- COPY WITH DISK CLEANUP + RETRY IF THE DISK IS FULL ---
            Report @{ Status = "Copying MSU" }
            try {
                $copyMode = Copy-Msu -MsuFile $msu -AdminShare $adminShare
            } catch {
                $copyError = $_
                if (-not (Test-IsDiskFull $copyError)) {
                    throw "Copy failed: $($copyError.Exception.Message)"
                }
                if ($cleanupDone) {
                    throw "Copy failed - disk full even after cleanup: $($copyError.Exception.Message)"
                }

                [void](Invoke-DiskCleanup -Reason "Disk full during copy")

                Report @{ Status = "Copying MSU (retry)" }
                try {
                    $copyMode = Copy-Msu -MsuFile $msu -AdminShare $adminShare
                } catch {
                    throw "Copy failed after disk cleanup: $($_.Exception.Message)"
                }
                Report @{ Detail = "Copy OK after disk cleanup" }
            }
            Report @{ CopyMode = $copyMode }
            # -----------------------------------------------------------

            $remoteMsu = "$RemoteFolder\$($msu.Name)"

            # Execution Logic on Remote Machine
            Report @{ Status = "Installing" }
            $installResult = Invoke-Remote -Arguments $remoteMsu, $RemoteFolder, $kbId -TimeoutMinutes 120 -Code {
                param($RemoteMsu, $RemoteFolder, $kbId)
                
                function Test-IsInstalled ($id) {
                    $fix = Get-HotFix -Id $id -ErrorAction SilentlyContinue
                    return ($null -ne $fix)
                }

                # Method 1: Silent WUSA
                $wusaLog = "$RemoteFolder\$kbId-wusa.log"
                $procWusa = Start-Process -FilePath "wusa.exe" -ArgumentList "`"$RemoteMsu`" /quiet /norestart /log:`"$wusaLog`"" -Wait -PassThru
                
                Start-Sleep -Seconds 5
                if ((Test-IsInstalled -id $kbId) -or $procWusa.ExitCode -in 0, 3010) {
                    return [PSCustomObject]@{ Method = "WUSA"; ExitCode = $procWusa.ExitCode; Detail = "WUSA Success" }
                }

                # Method 2: Silent DISM Fallback
                $dismLog = "$RemoteFolder\$kbId-dism.log"
                $procDism = Start-Process -FilePath "dism.exe" -ArgumentList "/Online /Add-Package /PackagePath:`"$RemoteMsu`" /Quiet /NoRestart /LogPath:`"$dismLog`"" -Wait -PassThru
                
                if ($procDism.ExitCode -eq 0 -or $procDism.ExitCode -eq 3010) {
                    return [PSCustomObject]@{ Method = "DISM"; ExitCode = $procDism.ExitCode; Detail = "DISM Fallback Success" }
                }

                return [PSCustomObject]@{ Method = "DISM"; ExitCode = $procDism.ExitCode; Detail = "Both Methods Failed" }
            }

            # Pending reboot + build after installation
            $state = Invoke-Remote -Code $GetStateBlock
            Report @{ Method = $installResult.Method; PendingReboot = $state.Pending; BuildAfter = $state.Build }

            if ($installResult.ExitCode -eq 0 -or $installResult.ExitCode -eq 3010) {
                $finalDetail = if ($installResult.ExitCode -eq 3010) { "$($installResult.Detail) (Reboot Req)" } else { $installResult.Detail }
                if ($expectedUbr -gt 0) {
                    # The UBR only changes after a reboot
                    if ($state.UBR -ge $expectedUbr) { $finalDetail += " - build OK ($($state.Build))" }
                    else { $finalDetail += " - build updates after reboot" }
                }
                Report @{ Status = "Finished"; ExitCode = $installResult.ExitCode; Detail = $finalDetail }
            } else {
                Report @{ Status = "Collecting Logs" }
                $logPath = Save-RemoteLogs
                Report @{ Status = "Failed"; ExitCode = $installResult.ExitCode; Detail = $installResult.Detail; LogPath = $logPath }
            }

        } catch {
            $errorMessage = $_.Exception.Message
            $logPath = ""
            if ($hostReachable) {
                Report @{ Status = "Collecting Logs" }
                $logPath = Save-RemoteLogs
            }
            Report @{ Status = "Error"; Detail = $errorMessage; LogPath = $logPath }
        } finally {
            $endTime = Get-Date
            Report @{
                EndTime  = $endTime.ToString("yyyy-MM-dd HH:mm:ss")
                Duration = ($endTime - $startTime).ToString("hh\:mm\:ss")
            }
        }
    }

    # Initialize lightweight Runspace Pool
    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxParallel)
    $runspacePool.Open()
    # Thread-safe table: host -> latest values written by its worker thread
    $syncState = [hashtable]::Synchronized(@{})

    $cycle = 0
    $lastReport = ""
    $cleanupScriptText = $DiskCleanupScript.ToString()

    # ==========================
    # LOOP: run all hosts -> create CSV -> pause 3 min -> next cycle, until Stop is clicked
    # ==========================
    while (-not $script:StopRequested) {
        $cycle++
        $form.Text = "Windows 11 Security Updates Remote Installer - Cycle $cycle"

        $syncState.Clear()
        $grid.Rows.Clear()
        foreach ($h in $hosts) {
            [void]$grid.Rows.Add($h, "", "Queued", "", "", "")
        }
        Update-Counters

        $runningThreads = @()
        foreach ($hostName in $hosts) {
            $powershell = [powershell]::Create()
            $powershell.RunspacePool = $runspacePool
            [void]$powershell.AddScript($ScriptBlock)
            [void]$powershell.AddArgument($hostName)
            [void]$powershell.AddArgument($Source23H2)
            [void]$powershell.AddArgument($Source24H2)
            [void]$powershell.AddArgument($Source25H2)
            [void]$powershell.AddArgument($RemoteFolder)
            [void]$powershell.AddArgument($syncState)
            [void]$powershell.AddArgument($ExpectedUBR)
            [void]$powershell.AddArgument($cleanupScriptText)
            [void]$powershell.AddArgument($LogFolder)
            [void]$powershell.AddArgument($FreeSpaceMarginGB)
            [void]$powershell.AddArgument($Timeouts)
            [void]$powershell.AddArgument($PsExecPath)
            [void]$powershell.AddArgument($CopyOrder)
            $handle = $powershell.BeginInvoke()
            $runningThreads += [PSCustomObject]@{ Instance = $powershell; Handle = $handle; HostName = $hostName }
        }

        $stopSent = $false
        $nextSync = Get-Date
        while ($runningThreads.Handle.IsCompleted -contains $false) {
            # Refresh the grid every 500 ms
            if ((Get-Date) -ge $nextSync) {
                Sync-Grid
                $nextSync = (Get-Date).AddMilliseconds(500)
            }

            # Stop: interrupts running threads and the ones still queued
            if ($script:StopRequested -and -not $stopSent) {
                foreach ($thread in $runningThreads) {
                    if (-not $thread.Handle.IsCompleted) {
                        [void]$thread.Instance.BeginStop($null, $null)
                    }
                }
                $stopSent = $true
            }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        Sync-Grid   # final state of this cycle, before checks and CSV export

        foreach ($thread in $runningThreads) {
            $threadError = $null
            try {
                [void]$thread.Instance.EndInvoke($thread.Handle)
            } catch {
                # a stopped thread throws PipelineStoppedException; any other exception means the thread crashed
                $threadError = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
            }
            if (-not $threadError -and $thread.Instance.Streams.Error.Count -gt 0) {
                $threadError = $thread.Instance.Streams.Error[0].ToString()
            }

            # A thread that never reported a status crashed silently: show why instead of leaving it as Queued
            if (-not $script:StopRequested) {
                foreach ($row in $grid.Rows) {
                    if ($row.Cells["Host"].Value -eq $thread.HostName -and $row.Cells["Status"].Value -eq "Queued") {
                        $row.Cells["Status"].Value = "Error"
                        $row.Cells["Detail"].Value = "Worker thread failed: $threadError"
                        Set-RowColor $row
                        break
                    }
                }
            }
            $thread.Instance.Dispose()
        }
        Update-Counters

        if ($script:StopRequested) {
            foreach ($row in $grid.Rows) {
                if ($row.Cells["Status"].Value -notin @("Finished", "Failed", "Skipped", "Error")) {
                    $row.Cells["Status"].Value = "Stopped"
                    $row.Cells["Detail"].Value = "Stopped by user"
                    Set-RowColor $row
                }
            }
            Update-Counters
        }

        try {
            $lastReport = Export-GridReport -Cycle $cycle
        } catch {
            $lastReport = "Export failed: $($_.Exception.Message)"
            $script:StopRequested = $true
        }

        # Pause between cycles (Stop interrupts the wait)
        $resumeAt = (Get-Date).AddSeconds($CycleIntervalSeconds)
        while (-not $script:StopRequested -and (Get-Date) -lt $resumeAt) {
            $left = $resumeAt - (Get-Date)
            $form.Text = "Windows 11 Security Updates Remote Installer - Cycle $cycle done - next cycle in {0:mm\:ss}" -f $left
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200
        }
    }

    $runspacePool.Close()
    $runspacePool.Dispose()
    $form.Text = "Windows 11 Security Updates Remote Installer"
    $btnStop.Text = "Stop Process"
    $btnStop.Enabled = $false
    $btnInstall.Enabled = $true
    $btnLoad.Enabled = $true
    [System.Windows.Forms.MessageBox]::Show("Process stopped after $cycle cycle(s).`r`nLast report: $lastReport")
})
$form.ShowDialog() | Out-Null
