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
# REPORT OUTPUT
# ==========================
$ReportFolder = "D:\jorge"
$ReportPrefix = "install_kb_sep26"
$script:StopRequested = $false

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

$form.Controls.Add($grid)

# ==========================
# FUNCTIONS
# ==========================
function Update-GridRow {
    param($HostName, $Release, $Status, $ExitCode, $PendingReboot, $Detail)
    
    $form.Invoke([Action]{
        foreach ($row in $grid.Rows) {
            if ($row.Cells["Host"].Value -eq $HostName) {
                if ($null -ne $Release) { $row.Cells["Release"].Value = $Release }
                if ($null -ne $Status) { $row.Cells["Status"].Value = $Status }
                if ($null -ne $ExitCode) { $row.Cells["ExitCode"].Value = $ExitCode }
                if ($null -ne $PendingReboot) { $row.Cells["PendingReboot"].Value = $PendingReboot }
                if ($null -ne $Detail) { $row.Cells["Detail"].Value = $Detail }
                break
            }
        }
    })
}

# Gera D:\jorge\install_kb_sep26_<dia>_<hora>.csv com o conteudo atual do grid
function Export-GridReport {
    if (-not (Test-Path $ReportFolder)) {
        New-Item -Path $ReportFolder -ItemType Directory -Force | Out-Null
    }

    $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $path  = Join-Path $ReportFolder "${ReportPrefix}_$stamp.csv"

    $rows = foreach ($row in $grid.Rows) {
        [PSCustomObject]@{
            Hostname      = [string]$row.Cells["Host"].Value
            Release       = [string]$row.Cells["Release"].Value
            Status        = [string]$row.Cells["Status"].Value
            ExitCode      = [string]$row.Cells["ExitCode"].Value
            PendingReboot = [string]$row.Cells["PendingReboot"].Value
            Detail        = [string]$row.Cells["Detail"].Value
        }
    }

    # -UseCulture: usa o separador de lista do Windows (";" em pt-BR) para abrir direto no Excel em colunas
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
        param($ComputerName, $Source23H2, $Source24H2, $Source25H2, $RemoteFolder, $syncHelper)

        function Report ($Status, $Release=$null, $ExitCode="", $Pending="", $Detail="") {
            $syncHelper.UpdateRow($ComputerName, $Release, $Status, $ExitCode, $Pending, $Detail)
        }

        try {
            Report "Checking Ping"
            if (-not (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet)) {
                throw "Host offline or not responding to ping."
            }

            Report "Checking OS & Build"
            $os = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" | 
                Select-Object DisplayVersion, CurrentBuild
            } -ErrorAction Stop

            $release = $os.DisplayVersion
            $build   = $os.CurrentBuild
            $releaseString = "$release ($build)"
            Report "Selecting Source" -Release $releaseString

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

            # --- NOVA VALIDACAO PREVENTIVA (PULA CASO JA INSTALADO) ---
            Report "Checking KB Presence"
            $isInstalledAlready = Invoke-Command -ComputerName $ComputerName -ArgumentList $kbId -ScriptBlock {
                param($id)
                return ($null -ne (Get-HotFix -Id $id -ErrorAction SilentlyContinue))
            }

            if ($isInstalledAlready) {
                Report "Skipped" -ExitCode "0" -Pending "False" -Detail "Already Installed"
                return # Interrompe a execucao deste host e passa para o proximo
            }
            # -----------------------------------------------------------

            $adminShare = "\\$ComputerName\C$\Windows\Temp\CUInstall"
            if (-not (Test-Path $adminShare)) {
                New-Item -Path $adminShare -ItemType Directory -Force | Out-Null
            }

            Report "Copying MSU"
            Copy-Item -Path $msu.FullName -Destination $adminShare -Force

            $remoteMsu = "$RemoteFolder\$($msu.Name)"

            # Execution Logic on Remote Machine
            $installResult = Invoke-Command -ComputerName $ComputerName -ArgumentList $remoteMsu, $RemoteFolder, $kbId -ScriptBlock {
                param($RemoteMsu, $RemoteFolder, $kbId)
                
                function Test-IsInstalled ($id) {
                    $fix = Get-HotFix -Id $id -ErrorAction SilentlyContinue
                    return ($null -ne $fix)
                }

                # Method 1: Silent WUSA
                $wusaLog = "$RemoteFolder\$kbId-wusa.log"
                $procWusa = Start-Process -FilePath "wusa.exe" -ArgumentList "`"$RemoteMsu`" /quiet /norestart /log:`"$wusaLog`"" -Wait -PassThru
                
                Start-Sleep -Seconds 5
                if (Test-IsInstalled -id $kbId -or $procWusa.ExitCode -eq 0 -or $procWusa.ExitCode -eq 3010) {
                    return [PSCustomObject]@{ Method = "WUSA"; ExitCode = $procWusa.ExitCode; Detail = "WUSA Success" }
                }

                # Method 2: Silent DISM Fallback
                $dismLog = "$RemoteFolder\$kbId-dism.log"
                $procDism = Start-Process -FilePath "dism.exe" -ArgumentList "/Online /Add-Package /PackagePath:`"$RemoteMsu`" /Quiet /NoRestart /LogPath:`"$dismLog`"" -Wait -PassThru
                
                if ($procDism.ExitCode -eq 0 -or $procDism.ExitCode -eq 3010) {
                    return [PSCustomObject]@{ Method = "DISM"; ExitCode = $procDism.ExitCode; Detail = "DISM Fallback Success" }
                }

                return [PSCustomObject]@{ Method = "DISM"; ExitCode = $procDism.ExitCode; Detail = "Both Methods Failed" }
            } -ErrorAction Stop

            # Remote Reboot Validation Structure
            $rebootPending = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                $pending = "False"
                if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $pending = "True" }
                if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { $pending = "True" }
                try {
                    $val = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
                    if ($val.PendingFileRenameOperations) { $pending = "True" }
                } catch {}
                return $pending
            }

            if ($installResult.ExitCode -eq 0 -or $installResult.ExitCode -eq 3010) {
                $finalDetail = if ($installResult.ExitCode -eq 3010) { "$($installResult.Detail) (Reboot Req)" } else { $installResult.Detail }
                Report "Finished" -ExitCode $installResult.ExitCode -Pending $rebootPending -Detail $finalDetail
            } else {
                Report "Failed" -ExitCode $installResult.ExitCode -Pending $rebootPending -Detail $installResult.Detail
            }

        } catch {
            Report "Error" -Detail $_.Exception.Message
        }
    }

    # Initialize lightweight Runspace Pool
    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxParallel)
    $runspacePool.Open()
    $syncHelper = [PSCustomObject]@{ Form = $form; Grid = $grid }
    $syncHelper | Add-Member -MemberType ScriptMethod -Name UpdateRow -Value {
        param($h, $rel, $st, $ec, $pr, $dt)
        Update-GridRow $h $rel $st $ec $pr $dt
    }

    $cycle = 0
    $lastReport = ""

    # ==========================
    # LOOP: roda todos os hosts -> gera CSV -> inicia o proximo ciclo, ate clicar em Stop
    # ==========================
    while (-not $script:StopRequested) {
        $cycle++
        $form.Text = "Windows 11 Security Updates Remote Installer - Cycle $cycle"

        $grid.Rows.Clear()
        foreach ($h in $hosts) {
            [void]$grid.Rows.Add($h, "", "Queued", "", "", "")
        }

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
            [void]$powershell.AddArgument($syncHelper)
            $handle = $powershell.BeginInvoke()
            $runningThreads += [PSCustomObject]@{ Instance = $powershell; Handle = $handle }
        }

        $stopSent = $false
        while ($runningThreads.Handle.IsCompleted -contains $false) {
            # Stop: interrompe as threads em execucao e as que ainda estao na fila
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

        foreach ($thread in $runningThreads) {
            try { $thread.Instance.EndInvoke($thread.Handle) } catch {}  # thread parada gera PipelineStoppedException
            $thread.Instance.Dispose()
        }

        if ($script:StopRequested) {
            foreach ($row in $grid.Rows) {
                if ($row.Cells["Status"].Value -notin @("Finished", "Failed", "Skipped", "Error")) {
                    $row.Cells["Status"].Value = "Stopped"
                    $row.Cells["Detail"].Value = "Stopped by user"
                }
            }
        }

        try {
            $lastReport = Export-GridReport
        } catch {
            $lastReport = "Export failed: $($_.Exception.Message)"
            $script:StopRequested = $true
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
