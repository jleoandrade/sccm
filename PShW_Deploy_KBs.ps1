Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ==========================
# KB SOURCES
# ==========================
$Source23H2 = "\\NJNWKSMS08V\Sources\Manual-installations\2026-06_Cumulative_Update_for_Windows_11_23H2"
$Source24H2 = "\\NJNWKSMS08V\Sources\Manual-installations\2026-06_Cumulative_Update_for_Windows_11_24H2"
$Source25H2 = "\\NJNWKSMS08V\Sources\Manual-installations\2026-06_Cumulative_Update_for_Windows_11_25H2"

$RemoteFolder = "C:\Windows\Temp\CUInstall"
$MaxParallel = 10

# ==========================
# GUI
# ==========================
$form = New-Object System.Windows.Forms.Form
$form.Text = "PSHInfoView - Windows 11 CU Remote Installer"
$form.Size = New-Object System.Drawing.Size(1050, 700)
$form.StartPosition = "CenterScreen"

$txtHosts = New-Object System.Windows.Forms.TextBox
$txtHosts.Multiline = $true
$txtHosts.ScrollBars = "Vertical"
$txtHosts.Location = New-Object System.Drawing.Point(10, 35)
$txtHosts.Size = New-Object System.Drawing.Size(250, 560)
$form.Controls.Add($txtHosts)

$lblHosts = New-Object System.Windows.Forms.Label
$lblHosts.Text = "Hosts - 1 por linha"
$lblHosts.Location = New-Object System.Drawing.Point(10, 10)
$lblHosts.Size = New-Object System.Drawing.Size(200, 20)
$form.Controls.Add($lblHosts)

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
$grid.AutoSizeColumnsMode = "Fill"

[void]$grid.Columns.Add("Host","Host")
[void]$grid.Columns.Add("Release","Windows Release")
[void]$grid.Columns.Add("Status","Status")
[void]$grid.Columns.Add("ExitCode","Exit Code")
[void]$grid.Columns.Add("PendingReboot","Pending Reboot")
[void]$grid.Columns.Add("Detail","Detail")

$form.Controls.Add($grid)

# ==========================
# FUNCTIONS
# ==========================
function Test-PendingReboot {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
        "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
    )

    $pending = $false

    if (Test-Path $paths[0]) { $pending = $true }
    if (Test-Path $paths[1]) { $pending = $true }

    try {
        $value = Get-ItemProperty -Path $paths[2] -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($value.PendingFileRenameOperations) { $pending = $true }
    } catch {}

    return $pending
}

function Get-MsuFromFolder {
    param($Folder)

    $msu = Get-ChildItem -Path $Folder -Filter *.msu -File -ErrorAction Stop | Select-Object -First 1

    if (-not $msu) {
        throw "Nenhum arquivo .msu encontrado em $Folder"
    }

    return $msu.FullName
}

function Update-GridRow {
    param($HostName, $Release, $Status, $ExitCode, $PendingReboot, $Detail)

    foreach ($row in $grid.Rows) {
        if ($row.Cells["Host"].Value -eq $HostName) {
            $row.Cells["Release"].Value = $Release
            $row.Cells["Status"].Value = $Status
            $row.Cells["ExitCode"].Value = $ExitCode
            $row.Cells["PendingReboot"].Value = $PendingReboot
            $row.Cells["Detail"].Value = $Detail
            return
        }
    }
}

# ==========================
# LOAD HOSTS BUTTON 
# ==========================
$btnLoad.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*"

    if ($dialog.ShowDialog() -eq "OK") {
        $txtHosts.Text = Get-Content $dialog.FileName | Out-String
    }
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
        [System.Windows.Forms.MessageBox]::Show("Informe ao menos um host.")
        return
    }

    $btnInstall.Enabled = $false
    $btnLoad.Enabled = $false
    $grid.Rows.Clear()

    foreach ($h in $hosts) {
        [void]$grid.Rows.Add($h, "", "Queued", "", "", "")
    }

    $jobs = @()

    foreach ($hostName in $hosts) {

        while (($jobs | Where-Object { $_.State -eq "Running" }).Count -ge $MaxParallel) {
            Start-Sleep -Milliseconds 500

            foreach ($job in $jobs | Where-Object { $_.State -ne "Running" -and $_.State -ne "Consumed" }) {
                $result = Receive-Job $job
                Update-GridRow $result.Host $result.Release $result.Status $result.ExitCode $result.PendingReboot $result.Detail
                $job.State | Out-Null
                $job | Add-Member -NotePropertyName State -NotePropertyValue "Consumed" -Force
            }

            [System.Windows.Forms.Application]::DoEvents()
        }

        $job = Start-Job -ArgumentList $hostName, $Source23H2, $Source24H2, $Source25H2, $RemoteFolder -ScriptBlock {
            param($ComputerName, $Source23H2, $Source24H2, $Source25H2, $RemoteFolder)

            $output = [ordered]@{
                Host = $ComputerName
                Release = ""
                Status = ""
                ExitCode = ""
                PendingReboot = ""
                Detail = ""
            }

            try {
                if (-not (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet)) {
                    throw "Host offline ou sem resposta de ping."
                }

                $os = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                    Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" |
                    Select-Object ProductName, DisplayVersion, CurrentBuild
                }

                $release = $os.DisplayVersion
                $output.Release = $release

                switch ($release) {
                    "23H2" { $source = $Source23H2 }
                    "24H2" { $source = $Source24H2 }
                    "25H2" { $source = $Source25H2 }
                    default { throw "Release não suportado: $release" }
                }

                $msu = Get-ChildItem -Path $source -Filter *.msu -File | Select-Object -First 1

                if (-not $msu) {
                    throw "Nenhum .msu encontrado em $source"
                }

                $adminShare = "\\$ComputerName\C$\Windows\Temp\CUInstall"

                if (-not (Test-Path $adminShare)) {
                    New-Item -Path $adminShare -ItemType Directory -Force | Out-Null
                }

                $output.Status = "Copying MSU"
                Copy-Item -Path $msu.FullName -Destination $adminShare -Force

                $remoteMsu = Join-Path $RemoteFolder $msu.Name

                $output.Status = "Installing"

                $install = Invoke-Command -ComputerName $ComputerName -ArgumentList $remoteMsu, $RemoteFolder -ScriptBlock {
                    param($RemoteMsu, $RemoteFolder)

                    $log = Join-Path $RemoteFolder "DISM_CU_Install.log"

                    $proc = Start-Process `
                        -FilePath "dism.exe" `
                        -ArgumentList "/Online /Add-Package /PackagePath:`"$RemoteMsu`" /Quiet /NoRestart /LogPath:`"$log`"" `
                        -Wait `
                        -PassThru

                    $pending = $false

                    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
                        $pending = $true
                    }

                    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
                        $pending = $true
                    }

                    try {
                        $pfr = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
                        if ($pfr.PendingFileRenameOperations) {
                            $pending = $true
                        }
                    } catch {}

                    [PSCustomObject]@{
                        ExitCode = $proc.ExitCode
                        PendingReboot = $pending
                        LogPath = $log
                    }
                }

                $output.ExitCode = $install.ExitCode
                $output.PendingReboot = if ($install.PendingReboot) { "YES" } else { "NO" }

                switch ($install.ExitCode) {
                    0 { $output.Status = "Completed" }
                    3010 { $output.Status = "Completed - Reboot Required"; $output.PendingReboot = "YES" }
                    default { $output.Status = "Failed" }
                }

                $output.Detail = "Log: $($install.LogPath)"
            }
            catch {
                $output.Status = "Error"
                $output.Detail = $_.Exception.Message
            }

            [PSCustomObject]$output
        }

        $jobs += $job
        Update-GridRow $hostName "" "Started" "" "" ""
        [System.Windows.Forms.Application]::DoEvents()
    }

    while (($jobs | Where-Object { $_.State -eq "Running" }).Count -gt 0) {
        Start-Sleep -Milliseconds 700

        foreach ($job in $jobs | Where-Object { $_.State -ne "Running" -and $_.State -ne "Consumed" }) {
            $result = Receive-Job $job
            Update-GridRow $result.Host $result.Release $result.Status $result.ExitCode $result.PendingReboot $result.Detail
            $job | Add-Member -NotePropertyName State -NotePropertyValue "Consumed" -Force
        }

        [System.Windows.Forms.Application]::DoEvents()
    }

    foreach ($job in $jobs | Where-Object { $_.State -ne "Consumed" }) {
        $result = Receive-Job $job
        Update-GridRow $result.Host $result.Release $result.Status $result.ExitCode $result.PendingReboot $result.Detail
    }

    Remove-Job $jobs -Force -ErrorAction SilentlyContinue

    $btnInstall.Enabled = $true
    $btnLoad.Enabled = $true

    [System.Windows.Forms.MessageBox]::Show("Processo concluído.")
})

$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
