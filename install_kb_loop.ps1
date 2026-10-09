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
$form = New-Object System.Windows.Forms.Form
$form.Text = "Windows 11 Security Updates Remote Installer"
$form.Size = New-Object System.Drawing.Size(1050, 700)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$txtHosts = New-Object System.Windows.Forms.TextBox
$txtHosts.Multiline = $true
$txtHosts.ScrollBars = "Vertical"
$txtHosts.Location = New-Object System.Drawing.Point(10, 35)
$txtHosts.Size = New-Object System.Drawing.Size(250, 515)
$form.Controls.Add($txtHosts)

$lblHosts = New-Object System.Windows.Forms.Label
$lblHosts.Text = "Hosts - 1 per line"
$lblHosts.Location = New-Object System.Drawing.Point(10, 10)
$lblHosts.Size = New-Object System.Drawing.Size(200, 20)
$form.Controls.Add($lblHosts)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = "Stop Process"
$btnStop.Location = New-Object System.Drawing.Point(10, 560)
$btnStop.Size = New-Object System.Drawing.Size(250, 35)
$btnStop.Enabled = $false
$form.Controls.Add($btnStop)

$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = "Load hosts.txt"
$btnLoad.Location = New-Object System.Drawing.Point(10, 605)
$btnLoad.Size = New-Object System.Drawing.Size(120, 35)
$form.Controls.Add($btnLoad)

$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = "Install CU"
$btnInstall.Location = New-Object System.Drawing.Point(140, 605)
$btnInstall.Size = New-Object System.Drawing.Size(120, 35)
$form.Controls.Add($btnInstall)

$lblCounters = New-Object System.Windows.Forms.Label
$lblCounters.Text = ""
$lblCounters.Location = New-Object System.Drawing.Point(275, 10)
$lblCounters.Size = New-Object System.Drawing.Size(750, 20)
$lblCounters.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblCounters)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(275, 35)
$grid.Size = New-Object System.Drawing.Size(750, 605)
$grid.AllowUserToAddRows = $false
$grid.ReadOnly = $true
$grid.RowHeadersVisible = $false
$grid.SelectionMode = "FullRowSelect"
$grid.AutoSizeColumnsMode = "Fill"

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
        { $_ -in "Finished", "Skipped" } { $color = [System.Drawing.Color]::LightGreen; break }
        { $_ -in "Failed", "Error" }     { $color = [System.Drawing.Color]::LightCoral; break }
        "Stopped"                        { $color = [System.Drawing.Color]::LightGray;  break }
        "Queued"                         { $color = [System.Drawing.Color]::White;      break }
        default                          { $color = [System.Drawing.Color]::LightYellow }  # in progress
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

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName  = $PsExecPath
            $psi.Arguments = "\\$ComputerName -accepteula -nobanner -s -n $($Timeouts.PsExecConnectSec) " +
                             "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\Windows\Temp\CUInstall\$id.ps1"
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
                $resultFile = "$share\$id.result.xml"
                if (-not (Test-Path $resultFile)) {
                    $lastLine = $errReader.Result -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1
                    throw "PsExec failed (exit $($proc.ExitCode)): $lastLine"
                }
                $result = Import-Clixml -Path $resultFile
            } finally {
                if (-not $proc.HasExited) { try { $proc.Kill() } catch {} }   # stops the local PsExec only
                $proc.Dispose()
                Remove-Item -Path "$share\$id.*" -Force -ErrorAction SilentlyContinue
            }
            if (-not $result.Ok) { throw "Remote error: $($result.Error)" }
            return $result.Output
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

            $msu = Get-ChildItem -Path $source -Filter *.msu -File | Select-Object -First 1
            if (-not $msu) { throw "No .msu file found in source folder" }

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
