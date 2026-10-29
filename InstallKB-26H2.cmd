<# : InstallKB.cmd - batch launcher. PowerShell reads this block as a comment and ignores it.
@echo off
setlocal
title Windows 11 CU Installer

rem ---------------------------------------------------------------------------
rem  1. Ask for administrator rights when not elevated (same as "Run as administrator").
rem     A mapped drive letter (e.g. H:\) is turned into its \\server\share path first,
rem     because the elevated session does not see the drive letters of the user.
rem ---------------------------------------------------------------------------
net session >nul 2>&1
if errorlevel 1 (
    powershell.exe -NoProfile -Command "$f = '%~f0'; $d = Get-PSDrive -Name $f.Substring(0, 1) -ErrorAction SilentlyContinue; if ($d.DisplayRoot) { $f = $d.DisplayRoot.TrimEnd('\') + $f.Substring(2) }; Start-Process -FilePath $f -Verb RunAs"
    exit /b
)

rem ---------------------------------------------------------------------------
rem  2. KB_HOME = folder of this file. The script saves its reports there and looks
rem     for PsExec.exe there, so InstallKB.cmd works from any folder.
rem ---------------------------------------------------------------------------
set "KB_HOME=%~dp0"

rem ---------------------------------------------------------------------------
rem  3. PowerShell only runs .ps1 files: copy this file to a temporary .ps1,
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
#  PowerShell script starts here. The setting to change each month is $KBSource below.
#  (Line numbers are 47 higher than in install_kb_loop.ps1.)
# ============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================================
#  THE ONLY SETTING TO CHANGE EACH MONTH
# ============================================================================
# Server folder with the MSU of each Windows 11 release. {RELEASE} is replaced by 23H2, 24H2, 25H2 and 26H2,
# so this one line points to the four folders. Each release folder must hold exactly one .msu.
$KBSource = "\\SERVER\Sources\Manual-installations\2026-09_Cumulative_Update_for_Windows_11_{RELEASE}"

# ============================================================================
#  EVERYTHING BELOW WORKS AS IT IS (optional settings)
# ============================================================================
$Source23H2 = $KBSource.Replace("{RELEASE}", "23H2")
$Source24H2 = $KBSource.Replace("{RELEASE}", "24H2")
$Source25H2 = $KBSource.Replace("{RELEASE}", "25H2")
$Source26H2 = $KBSource.Replace("{RELEASE}", "26H2")

$RemoteFolder = "C:\Windows\Temp\CUInstall"
$MaxParallel  = 15

# Expected build (UBR = number after the dot in the OS Build, e.g. 26100.9445 -> 9445).
# 0 = the "already installed" check uses only the KB (Get-HotFix). This is the safe default:
# an old UBR left here would make machines without the new CU be skipped as "already installed".
# To also check the build, fill in the values of the month (e.g. 23H2 = 7582, 24H2/25H2 = 9445 for 2026-09).
# 24H2, 25H2 and 26H2 share one servicing branch: same UBR, only the build differs (26100 / 26200 / 26300).
$ExpectedUBR = @{
    "23H2" = 0
    "24H2" = 0
    "25H2" = 0
    "26H2" = 0
}

# Folder of InstallKB.cmd (set by the launcher), or of this .ps1 when it is run directly
$AppFolder = if ($env:KB_HOME) { $env:KB_HOME.TrimEnd('\') } elseif ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).ProviderPath }

# Reports and logs: "InstallKB_Report" next to InstallKB.cmd. If that folder is read-only, the first
# writable one of: Documents, the user profile, the temporary folder (empty entries are skipped)
function Get-WritableFolder ([string[]]$BaseFolders) {
    foreach ($base in $BaseFolders) {
        if (-not $base) { continue }
        $folder = Join-Path $base "InstallKB_Report"
        try {
            New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
            $probe = Join-Path $folder ".write_test"
            Set-Content -Path $probe -Value "" -ErrorAction Stop
            Remove-Item -Path $probe -Force -ErrorAction SilentlyContinue
            return $folder
        } catch { }
    }
    return (Join-Path ([System.IO.Path]::GetTempPath()) "InstallKB_Report")
}
$ReportFolder = Get-WritableFolder @($AppFolder, [Environment]::GetFolderPath("MyDocuments"), $env:USERPROFILE, [System.IO.Path]::GetTempPath())
$LogFolder    = Join-Path $ReportFolder "logs"   # remote logs: <ReportFolder>\logs\<host>\

# CSV name: install_kb_<month taken from $KBSource>_<date>_<time>.csv
$KBMonth      = if ($KBSource -match '\d{4}-\d{2}') { $Matches[0] } else { Get-Date -Format "yyyy-MM" }
$ReportPrefix = "install_kb_$KBMonth"

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
# PsExec is found automatically: next to InstallKB.cmd, in a PSTools subfolder, in the PATH, or in D:\Jorge\PSTools
$PsExecPath = @(
    (Join-Path $AppFolder "PsExec.exe"),
    (Join-Path $AppFolder "PsExec64.exe"),
    (Join-Path $AppFolder "PSTools\PsExec.exe"),
    (Join-Path $AppFolder "PSTools\PsExec64.exe"),
    (Get-Command PsExec.exe, PsExec64.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Path),
    "D:\Jorge\PSTools\PsExec.exe"
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $PsExecPath) { $PsExecPath = Join-Path $AppFolder "PsExec.exe" }   # not found: the error message says where to put it

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
$IconBase64 = "AAABAAQAEBAAAAEAIABoBAAARgAAABgYAAABACAAiAkAAK4EAAAgIAAAAQAgAKgQAAA2DgAAMDAAAAEAIACoJQAA3h4AACgAAAAQAAAAIAAAAAEAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/AJkK/wChn/8Apfb/AKL9/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKL9/wCl9v8AoZ//AJkK/wChnv8Arf//AKH+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof7/AK3//wChnv8Aof7/AKL9/wGh/v8Bof//AKH//wCh//8Bof//AaH//wCh//8Bof//AaH//wGh//8Bof//AKD+/wCi/f8Aof7/AKH//wCh//8AoP//AJ///wCh//8Cov//AKD//wCf//8AoP//AKD//wCf//8An///AKH//wKi//8Aof//AKH//wCh//8Aof//CaT//xGn//8Fo///AJ7//wWj//8aq///DKb//w+n//8UqP//Fan//wGi//8Anf//AKH//wCh//8Fo///AJr//3jN///u+f//B6P//yKs///h9P//s+T//yyx///p9///5fX//+H0///a8f//Ub///wCd//8Dov//BaP//wCa//+F0v///////z64///u+f//1PD//xCj//8bq////////3LL//8Emf//4vT//+X2//8Anf//AqH//wWj//8Amv//f9D///z+///y+v//v+f//xGl//8Am///Jq////3+//+s4P//b8X//+f2//+S1///AJ3//wOi//8Fo///AJr//37P///9/v///////43V//8Amf//Ap///yWv///9/v//zOz//7Tk///6/f//Q7r//wCc//8Dov//BaP//wCa//+F0v///////17E////////mNn//wCZ//8irv///////2zJ//8NpP///////5/c//8Amf//BKP//wWj//8Amv//eM3//+75//8Cov//P7f///L6//94zf//G6v//+34///l9f//4vT//8zs//8zs///AJ7//wKi//8Aof//AKH//wmk//8Rp///BaP//wCd//8Kpf//HKv//wWj//8Rp///FKj//xOo//8AoP//AJ7//wCi//8Aof//AKH//wCh//8AoP//AJ///wCh//8Cov//AKD//wCe//8Aof//AJ///wCf//8An///AKH//wKi//8Aof//AKH//wCh/v8Aov3/AaH+/wGh//8Aof//AKH//wGh//8Bof//AKH//wGh//8Bof//AaH//wCh//8AoP7/AKL9/wCh/v8AoZ7/AK3//wCh/v8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH+/wCt//8AoZ7/AJkK/wChn/8Apfb/AKL9/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKL9/wCl9v8AoZ//AJkKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACgAAAAYAAAAMAAAAAEAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/wCbEv8ApZz/AKTr/wCi/v8Aof7/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH+/wCi/v8ApOv/AKWc/wCbEgAAAAD/AKET/wCizP8Arf//AKL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aov//AK3//wCizP8AoRP/AJ+e/wCu//8AoPr/AKH+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof7/AKD6/wCu//8An57/AKDx/wCj/f8Aof7/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH+/wCj/f8AoPH/AKL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aov//AKH+/wCh//8Aof//AqL//wSj//8Eov//AKH//wCh//8Aof//A6L//wSj//8Eov//AKH//wOi//8Eo///BKP//wSj//8Eo///BKL//wKi//8Aof//AKH//wCh//8Aof7/AKH//wCh//8Aof//AJ7//wCa//8Am///AKH//wCh//8Cov//AJz//wCa//8Amv//AKD//wCc//8Amv//AJr//wCa//8Amv//AJv//wCf//8Cov//AKH//wCh//8Aof//AKH//wKh//8Anv//LrL//3/Q//9yy///B6T//wKh//8AnP//WsL//37Q//+G0///F6n//1jB//9/0P//gND//4TS//9+z///XsT//xuq//8Anf//AaL//wCh//8Aof//AKH//wSi//8Am///Y8b////////1+///EKf//wCZ//93zf////////////+L1P//BJv//8nr///////////////+/////////////+z4//84tP//AZ3//wKi//8Aof//AKH//wSi//8Am///WsL///v9///h9P//AJ///3bM/////////////2/K//8Amf//AJ3//7Xj///7/f//mNn//xGh//8jrP//yOv///////+j3f//AJv//wSi//8Aof//AKH//wSi//8Am///XMP////////c8v//iNP/////////////cMr//wCa//8Go///AJ3//7fk////////idP//wCS//8Al///q+D///////+j3f//AJv//wSi//8Aof//AKH//wSi//8Am///XcP////////5/f////////P7//9px///AJv//wSi//8Dov//AJ3//7nl////////2fH//6nc//+75v///P7//+Dz//84tP//AZ3//wKi//8Aof//AKH//wSi//8Am///XcP////////8/v///////+D0//8Qpv//AJ3//wSj//8Cov//AJ3//7rm////////9Pv//+r2/////////////6Ld//8AnP//AqL//wCh//8Aof//AKH//wSi//8Am///XMP////////i9P//uub////////V8P//Han//wCd//8Go///AJ3//7fk////////kdf//wCV//8psP//9fv///////9Auf//AJz//wOi//8Aof//AKH//wSi//8Am///WsL///v9///d8v//CqT//6jg////////1fD//xup//8AnP//AJ7//7Tj///7/f//l9n//wyd//9Auf//9Pv///////9Lvf//AJv//wOi//8Aof//AKH//wSi//8Am///Y8b////////3/P//C6X//wGd//+n3////////+75//82s///AJr//8rr/////////////////////////////8nr//8NpP//AaD//wGh//8Aof//AKH//wKh//8Anv//LrL//3/Q//9yy///CKT//wCf//8Cof//bsn//4bS//9hxf//AJ3//17E//9/0P//f9D//4PS//93zf//UL7//wij//8An///AaH//wCh//8Aof//AKH//wCh//8Aof//AJ7//wCa//8Am///AKH//wGi//8Aof//AJv//wCZ//8AnP//AKL//wCc//8Amv//AJr//wCa//8Amv//AJv//wCg//8Bov//AKH//wCh//8Aof//AKH+/wCh//8Aof//AqL//wSj//8Eov//AKH//wCh//8Bof//BKL//wSj//8Dov//AKH//wOi//8Eo///BKP//wSj//8Eo///A6L//wGh//8Aof//AKH//wCh//8Aof7/AKL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aov//AKDx/wCj/f8Aof7/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH+/wCj/f8AoPH/AJ+e/wCu//8AoPr/AKH+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof7/AKD6/wCu//8An57/AKET/wCizP8Arf//AKL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aov//AK3//wCizP8AoRMAAAAA/wCbEv8ApZz/AKTr/wCi/v8Aof7/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH+/wCi/v8ApOv/AKWc/wCbEgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAoAAAAIAAAAEAAAAABACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/wB/AgAAAAD/AI0S/wClhv8Apdv/AKL8/wCh/v8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof7/AKL8/wCl2/8ApYb/AI0SAAAAAP8AfwIAAAAA/wCbKf8Aptf/AKv//wCk//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKT//wCr//8Aptf/AJspAAAAAP8AmxL/AKLc/wCs//8Aofr/AKD+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP7/AKH6/wCs//8Aotz/AJsS/wCgh/8ArP//AKD6/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKD6/wCs//8AoIf/AKDh/wCk/v8AoP7/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP7/AKT+/wCg4f8Aof7/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Bof//AaH//wGh//8Aof//AKH//wCh//8Aof//AKH//wGh//8Bof//AaH//wGh//8Aof//AaH//wGh//8Bof//AaH//wGh//8Bof//AaH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCf//8An///AKD//wCh//8Aof//AKH//wGi//8Aof//AJ///wCf//8An///AKD//wCh//8An///AJ///wCf//8An///AJ///wCg//8Aof//A6L//wKi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Eov//Eaf//xGn//8Ppv//AKH//wCh//8Cov//AJ///wCg//8Sp///D6b//xSo//8Pp///BKL//xGn//8Rp///Eaf//xGn//8Rp///Dqb//wGh//8Am///AJ7//wGi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Dov//AJz//zi2///u+f//7vn//83t//8Do///AaL//wCf//8Iof//s+P//+v4///v+f//3/P//ySr//9Nvf//7vn//+v4///u+f//7vn//+75///n9v//0u///5ra//8mrv//AJ3//wGi//8Aof//AKH//wCh//8Aof//AKH//wOi//8AnP//Pbf/////////////3/P//wek//8An///CaL//7vm//////////////L6//89tv//AJb//17E/////////////////////////////////////////////+v4//8irP//AZ///wKi//8Aof//AKH//wCh//8Aof//A6L//wCc//88t////v////7////e8///AqD//wmh//+95/////////3+///r+P//M7L//wCc//8BnP//WcL///7////9/v//y+z//yat//8or///Srv//97z///5/f///////4TS//8Amv//BKL//wCh//8Aof//AKH//wCh//8Dov//AJz//zy3/////////////9fw//8NpP//vef////////+/v//6/j//zKy//8Am///CKT//wCb//9awv/////////////B6P//AJv//wCh//8AlP//f9D////////8/v//odz//wCb//8Eov//AKH//wCh//8Aof//AKH//wOi//8AnP//PLf////////+////4PP//8Tp/////////////+r4//8xsf//AJv//wSj//8Eov//AJv//1rC/////////////8Ho//8Am///AJ///wqh//+25P////////////95zv//AJr//wSi//8Aof//AKH//wCh//8Aof//A6L//wCc//88t/////////3+//////////////v+///d8///MrL//wCb//8Eo///AKH//wSi//8Am///WsL////////9/v//7/n//7nl//+55f//2PH////////9/v//0O7//xWn//8Bn///AaH//wCh//8Aof//AKH//wCh//8Dov//AJz//zy3/////////f7////////6/f///////3nO//8Alf//CKT//wCh//8Aof//BKL//wCb//9awv////////z+/////////////////////////P7//+P1//8irf//AJz//wKi//8Aof//AKH//wCh//8Aof//AKH//wOi//8AnP//PLf////////+/v//9fv///7/////////+Pz//1/E//8Amv//BaP//wCh//8Eov//AJv//1rC/////////v///9nx//9ewv//YcL//6vg///+/////////7rm//8EoP//AqH//wCh//8Aof//AKH//wCh//8Aof//A6L//wCc//88t//////////////S7v//V8D///v+/////////////2HE//8Amv//BKP//wSi//8Am///WsL/////////////vuf//wCW//8Al///AqL///L6/////////////yOu//8Anv//AqL//wCh//8Aof//AKH//wCh//8Dov//AJz//zy3///+/////v///9/z//8AnP//Tr3///r9///+/////////2PF//8Amf//B6T//wCb//9awv///v////7////I6///Fab//xem//9dw///+f3///v+///8/v//H63//wCe//8Cov//AKH//wCh//8Aof//AKH//wOi//8AnP//PLf/////////////3PL//wml//8Amf//Tbz///j9/////////////2jH//8Am///AJv//1rC/////////f7///z+///u+f//8Pn//////////////////7nl//8Bnv//AqH//wCh//8Aof//AKH//wCh//8Aof//A6L//wCc//88t//////////////c8v//BKP//wSj//8Amv//Sbv//+/5///8/v///////27J//8Al///XMP////////8/v//////////////////9fv//9/z//+Z2f//FKf//wGf//8Bov//AKH//wCh//8Aof//AKH//wCh//8Aof//AKD//wmk//8nr///J6///yKt//8Bof//AKH//wOi//8Anf//Gqv//yev//8mr///LbL//wCg//8Opv//J6///yev//8nr///Jq///yav//8drP//B6T//wCb//8An///AKL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKD//wCe//8Anv//AJ7//wCh//8Aof//AKH//wKi//8An///AJ7//wCe//8Anf//AKH//wCg//8Anv//AJ7//wCe//8Anv//AJ7//wCe//8AoP//A6L//wGh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AqL//wKi//8Cov//AKH//wCh//8Aof//AKH//wKi//8Cov//AqL//wKi//8Aof//AaH//wKi//8Cov//AqL//wKi//8Cov//AqL//wGh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof7/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH+/wCg4f8ApP7/AKD+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKD+/wCk/v8AoOH/AKCH/wCs//8AoPr/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoPr/AKz//wCgh/8AmxL/AKLc/wCs//8Aofr/AKD+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP7/AKH6/wCs//8Aotz/AJsSAAAAAP8Amyn/AKbX/wCr//8ApP//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCk//8Aq///AKbX/wCbKQAAAAD/AH8CAAAAAP8AjRL/AKWG/wCl2/8Aovz/AKH+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh/v8Aovz/AKXb/wClhv8AjRIAAAAA/wB/AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKAAAADAAAABgAAAAAQAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/wCqAwAAAAD/AIkN/wCmaP8ApsD/AKPv/wCi/v8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aov7/AKPv/wCmwP8Apmj/AIkNAAAAAP8AqgMAAAAAAAAAAAAAAAD/AKoDAAAAAP8AoEb/AKXW/wCq//8Ap///AKP//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKP//wCn//8Aqv//AKXW/wCgRgAAAAD/AKoDAAAAAP8AqgMAAAAA/wCfa/8Aqf//AKf//wCg/P8Aof3/AKH+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH+/wCh/f8AoPz/AKf//wCp//8An2sAAAAA/wCqAwAAAAD/AKJC/wCp//8Ao/3/AKD8/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKD8/wCj/f8Aqf//AKJCAAAAAP8AnA3/AKHc/wCn//8AoPz/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCg/P8Ap///AKHc/wCcDf8An2j/AKr//wCf/P8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8An/z/AKr//wCfaP8AoMT/AKf+/wCh/f8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof3/AKf+/wCgxP8AofL/AKP//wCg/v8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP7/AKP//wCh8v8Aov//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AaH//wGh//8Bof//AaH//wGh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AaH//wGh//8Bof//AaH//wGh//8Bof//AKH//wGh//8Bof//AaH//wGh//8Bof//AaH//wGh//8Bof//AaH//wGh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKD//wCf//8An///AJ///wCg//8Aof//AKH//wCh//8Aof//AKH//wCh//8Cov//AJ///wCf//8An///AJ///wCf//8An///AKH//wCg//8An///AJ///wCf//8An///AJ///wCf//8An///AJ///wCg//8Aof//A6L//wOi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//Dqb//xGn//8Rp///Eaf//w6m//8Aof//AKH//wCh//8Aof//AKH//wKh//8Anv//EKf//xGn//8Rp///EKf//xCn//8Yqv//AKD//wql//8Rp///Eaf//xGn//8Rp///Eaf//xGn//8Rp///Eaf//wql//8AoP//AJv//wCc//8Bof//AaL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP//w+n//+75///p9///7vn//8Ho//8AoP//AKH//wCh//8Aof//BKL//wCa//92zf//7Pj//+z4///t+P//6/j///L6//9ew///AJf//4/W///u+f//6vj//+75///u+f//7fn//+34///t+P//7Pj//+P1///N7f//n9v//069//8An///AJ///wGi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP//1e/////////+/////////9Pu//8AoP//AKH//wGh//8Eov//AJr//3nN/////////////////////////////23J//8Anf//AJv//5ra//////////////////////////////////////////////////////////////////+25P//EKX//wKf//8Bof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP//0O7///7////5/f///v///87t//8AoP//AaH//wSi//8Amv//e87////////7/v///P7///v+////////Zcb//wCZ//8HpP//AJv//5bZ///+////+v7///7////+/////f7///3+///9/v/////////////+////+/7///r9////////qN///wCc//8Cov//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP//0e7////////6/f///////8/t//8AoP//BKL//wCa//99z/////////v+///9/v///f7///////9lxv//AJr//wWj//8Eov//AJv//5fZ////////+v3////////6/f//Qrr//yet//8qsP//MrH//3jN///3/P///v////3////8/v///v7//ySu//8Anv//AqL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP//0e7////////6/f///////9Dt//8Cof//AJv//4DQ////////+/7///3+///9/v///////2PF//8Amv//BKL//wCh//8Eov//AJv//5fZ////////+v3////////5/f//GKr//wCb//8An///AJ7//wCV//+J1P////////v+///8/v///////0++//8Am///A6L//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP//0e7////////6/f///////8/t//8Amf//gtH////////7/v///f7///3+////////YcT//wCa//8Eo///AKH//wCh//8Eov//AJv//5fZ////////+v3////////5/f//JK7//wSg//8Go///CaT//wed//9Sv/////////v+///8/v///v///1TA//8Am///BKL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP//0e7////////6/f///////8jr//+B0P////////v+///9/v///f7///////9fw///AJr//wSj//8Aof//AKH//wCh//8Eov//AJv//5fZ////////+v3////////5/f//GKr//wCb//8An///AJ7//wCV//+H0/////////v9///9/v///////zK0//8Anf//AqL//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP//0e7////////9/v////////v+/////////f7///7//////////////13D//8Amv//BaP//wCh//8Aof//AKH//wCh//8Eov//AJv//5fZ////////+v3////////6/f//Qrr//yet//8qsP//MrH//3bM///2/P///v////r9////////y+z//wOf//8Cof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP//0e7////////9/v/////////////9/v///v////3+///2/P//XcP//wCa//8Fo///AKH//wCh//8Aof//AKH//wCh//8Eov//AJv//5fZ////////+/7//////////////v7///3+///9/v///////////////////v/////////k9f//LLD//wCd//8Cov//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP//0e7////////9/v////////7////+////+/7///////+K1P//AJT//wik//8Aof//AKH//wCh//8Aof//AKH//wCh//8Eov//AJv//5fZ////////+/7///////////////////////////////////n9///9/v///v///7vm//8PpP//AJ3//wKi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP//0e7////////9/v///////////////////f7///3////t+P//Tr3//wCa//8Fo///AKH//wCh//8Aof//AKH//wCh//8Eov//AJv//5fZ////////+/7/////////////8Pn//+34///t+P//+/7////////+/////f7///L6//+A0P//AJ7//wKi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP//0e7////////8/v///////+r3///w+v////////z+////////+v3//0+9//8Amv//BaP//wCh//8Aof//AKH//wCh//8Eov//AJv//5fZ////////+v3////////5/f//L7P//xGl//8VqP//Jqv//63h/////////P7/////////////Pbj//wCc//8Dov//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP//0e7////////6/f///////8Tp//85tP//8Pr////////7/f///v////z+//9Sv///AJr//wWj//8Aof//AKH//wCh//8Eov//AJv//5fZ////////+v3////////5/f//Haz//wCd//8Bof//AJv//ySu///9/v////////r9///+/v//itT//wCa//8Eo///AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP//0e7////////6/f///////9Pv//8Amf//OLT//+75////////+/3///7////9/v//VsD//wCa//8Fo///AKH//wCh//8Eov//AJv//5fZ////////+v3////////5/f//Haz//wCd//8Bof//AJv//ySu///9/v///v////v9///+////ltj//wCb//8Eov//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP//0e7////////6/f///////8/t//8Cov//AJv//zWz///s+P////////r9///+/////v///1nB//8Amv//BaP//wCh//8Eov//AJv//5fZ////////+v3////////5/f//L7P//xGl//8VqP//J6z//67h/////////f7///r9////////es7//wCa//8Eo///AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP//0e7///7////6/f///v///8/t//8AoP//BaP//wCb//8xsv//6vf////////6/f///f7///////9dw///AJr//wSi//8Eov//AJv//5fZ///+////+v7///7////+////7/n//+34///t+P//+/7////////9/v//+/3///7/////////K7H//wCe//8Cov//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP//0e7////////7/f///////8/t//8AoP//AKH//wWj//8Am///LrD//+j3/////////P7///7/////////YcT//wCa//8Go///AJv//5fZ/////////P7///////////////////////////////////////////////////////9wyv//AJz//wKi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP//0e7////////6/f///////8/t//8AoP//AKH//wCh//8Eo///AJz//yuw///f8////f7///z+///8/v///////2TG//8Cn///AJv//5fZ////////+/7//////////////v7///3+///9/v//+v3//+/5///U7///nNr//zq1//8AnP//AqH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//IK3//yev//8mr///J6///yCt//8Aof//AKH//wCh//8Aof//A6L//wCd//8Rp///J7D//yev//8mr///J6///yux//8Bof//AKD//xeq//8nr///J6///yev//8nr///J6///yev//8nr///Iq7//xWp//8Bof//AJv//wCd//8Cov//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AJ7//wCe//8Anv//AJ7//wCe//8Aof//AKH//wCh//8Aof//AKH//wKi//8An///AJ7//wCe//8Anv//AJ3//wCd//8Aof//AKH//wCf//8Anv//AJ7//wCe//8Anv//AJ7//wCe//8Anv//AJ7//wCf//8Aof//A6L//wOi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AqL//wKi//8Cov//AqL//wKi//8Aof//AKH//wCh//8Aof//AKH//wCh//8Bof//AqL//wKi//8Cov//AqL//wKi//8Aof//AKH//wGh//8Cov//AqL//wKi//8Cov//AqL//wKi//8Cov//AqL//wGh//8Bof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aov//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCi//8AofL/AKP//wCg/v8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8AoP7/AKP//wCh8v8AoMT/AKf+/wCh/f8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof3/AKf+/wCgxP8An2j/AKr//wCf/P8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8An/z/AKr//wCfaP8AnA3/AKHc/wCn//8AoPz/AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCg/P8Ap///AKHc/wCcDQAAAAD/AKJC/wCp//8Ao/3/AKD8/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKD8/wCj/f8Aqf//AKJCAAAAAP8AqgMAAAAA/wCfa/8Aqf//AKf//wCg/P8Aof3/AKH+/wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH+/wCh/f8AoPz/AKf//wCp//8An2sAAAAA/wCqAwAAAAD/AKoDAAAAAP8AoEb/AKXW/wCq//8Ap///AKP//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKP//wCn//8Aqv//AKXW/wCgRgAAAAD/AKoDAAAAAAAAAAAAAAAA/wCqAwAAAAD/AIkN/wCmaP8ApsD/AKPv/wCi/v8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aof//AKH//wCh//8Aov7/AKPv/wCmwP8Apmj/AIkNAAAAAP8AqgMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
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

# Right side of the top bar: KB month and where the reports are saved (full text in the tooltip)
$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Text = "KB $KBMonth   |   Reports: $ReportFolder"
$lblInfo.Location = New-Object System.Drawing.Point(660, 19)
$lblInfo.Size = New-Object System.Drawing.Size(($form.ClientSize.Width - 676), 20)
$lblInfo.TextAlign = "MiddleRight"
$lblInfo.AutoEllipsis = $true
$lblInfo.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#BDBDBD")
$pnlHeader.Controls.Add($lblInfo)
$tipInfo = New-Object System.Windows.Forms.ToolTip
$tipInfo.SetToolTip($lblInfo, "KB source: $KBSource`r`nReports: $ReportFolder`r`nPsExec: $PsExecPath")

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

# Creates <ReportFolder>\install_kb_<month>_<date>_<time>.csv with the current grid content
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

    # One line ($KBSource) feeds the four release folders, so it must contain {RELEASE}
    if ($KBSource -notlike "*{RELEASE}*") {
        [void][System.Windows.Forms.MessageBox]::Show("The KB source must contain {RELEASE} (replaced by 23H2, 24H2, 25H2 and 26H2):`r`n$KBSource", "KB source")
        return
    }

    $btnInstall.Enabled = $false
    $btnLoad.Enabled = $false
    $btnStop.Text = "Stop Process"
    $btnStop.Enabled = $true
    $script:StopRequested = $false

    # Parallel Execution Code Block
    $ScriptBlock = {
        param($ComputerName, $Source23H2, $Source24H2, $Source25H2, $Source26H2, $RemoteFolder, $syncState, $ExpectedUBR, $CleanupScriptText, $LogFolder, $FreeSpaceMarginGB, $Timeouts, $PsExecPath, $CopyOrder)

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

        # Copies the host logs to <ReportFolder>\logs\<host>\ (date/time prefix keeps the history)
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
                "26H2" { $source = $Source26H2 }
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
            # Positional: this order must match param() of $ScriptBlock exactly
            [void]$powershell.AddArgument($hostName)
            [void]$powershell.AddArgument($Source23H2)
            [void]$powershell.AddArgument($Source24H2)
            [void]$powershell.AddArgument($Source25H2)
            [void]$powershell.AddArgument($Source26H2)
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
