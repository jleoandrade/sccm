# Prompt for remote machine name
$machine = Read-Host "Enter the remote machine name"

Write-Host ""
Write-Host "Target remote machine: $machine"
Write-Host ""

# Test connectivity
if (-not (Test-Connection -ComputerName $machine -Count 1 -Quiet)) {
    Write-Host "The machine is not reachable."
    exit
}

# =====================================================================
# 1. Ask before killing Adobe processes
# =====================================================================
Write-Host "=== Adobe Processes on Remote Machine ==="

$remoteProcesses = Invoke-Command -ComputerName $machine -ScriptBlock {
    Get-Process | Where-Object { $_.ProcessName -like "*adobe*" -or $_.ProcessName -like "*acrobat*" } |
    Select-Object ProcessName, Id
}

if ($remoteProcesses) {
    $remoteProcesses | Format-Table -AutoSize
    $kill = Read-Host "Do you want to kill these Adobe processes? (Y/N)"

    if ($kill -match '^[Yy]$') {
        Invoke-Command -ComputerName $machine -ScriptBlock {
            $procs = Get-Process | Where-Object { $_.ProcessName -like "*adobe*" -or $_.ProcessName -like "*acrobat*" }
            foreach ($p in $procs) {
                try {
                    Stop-Process -Id $p.Id -Force -ErrorAction Stop
                    Write-Host "Killed process: $($p.ProcessName) (PID $($p.Id))"
                }
                catch {
                    Write-Host "Failed to kill process $($p.ProcessName): $($_.Exception.Message)"
                }
            }
        }
    }
} else {
    Write-Host "No Adobe processes found."
}
Write-Host ""

# =====================================================================
# 2. Ask before stopping Adobe services
# =====================================================================
Write-Host "=== Adobe Services on Remote Machine ==="

$remoteServices = Invoke-Command -ComputerName $machine -ScriptBlock {
    Get-Service | Where-Object { $_.DisplayName -like "*Adobe*" -or $_.Name -like "*Adobe*" } |
    Select-Object Name, DisplayName, Status
}

if ($remoteServices) {
    $remoteServices | Format-Table -AutoSize
    $stop = Read-Host "Do you want to stop these Adobe services? (Y/N)"

    if ($stop -match '^[Yy]$') {
        Invoke-Command -ComputerName $machine -ScriptBlock {
            $services = Get-Service | Where-Object { $_.DisplayName -like "*Adobe*" -or $_.Name -like "*Adobe*" }
            foreach ($svc in $services) {
                try {
                    if ($svc.Status -ne "Stopped") {
                        Stop-Service -Name $svc.Name -Force -ErrorAction Stop
                        Write-Host "Stopped service: $($svc.Name)"
                    }
                }
                catch {
                    Write-Host "Failed to stop service $($svc.Name): $($_.Exception.Message)"
                }
            }
        }
    }
} else {
    Write-Host "No Adobe services found."
}
Write-Host ""

# =====================================================================
# 3. Installed Adobe software from remote registry
# =====================================================================
Write-Host "=== Installed Adobe Products (Remote Registry) ==="

$registryPaths = @(
    "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)

$installedAdobe = @()

foreach ($path in $registryPaths) {
    try {
        $reg = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', $machine)
        $sub = $reg.OpenSubKey($path)

        if ($sub) {
            foreach ($key in $sub.GetSubKeyNames()) {
                $appKey = $sub.OpenSubKey($key)
                $name = $appKey.GetValue("DisplayName")
                if ($name -like "*Adobe*") {
                    $installedAdobe += [PSCustomObject]@{
                        DisplayName     = $name
                        DisplayVersion  = $appKey.GetValue("DisplayVersion")
                        Publisher       = $appKey.GetValue("Publisher")
                        InstallDate     = $appKey.GetValue("InstallDate")
                        UninstallString = $appKey.GetValue("UninstallString")
                    }
                }
            }
        }
    }
    catch {
        Write-Host "Error reading registry path ${path}: $($_.Exception.Message)"
    }
}

if ($installedAdobe.Count -gt 0) {
    $installedAdobe | Format-Table -AutoSize
} else {
    Write-Host "No Adobe software found in remote registry."
}
Write-Host ""

# =====================================================================
# 4. Adobe registry keys on remote machine
# =====================================================================
Write-Host "=== Adobe Registry Keys on Remote Machine ==="

$adobeRegKeys = @(
    "SOFTWARE\Adobe",
    "SOFTWARE\WOW6432Node\Adobe"
)

foreach ($key in $adobeRegKeys) {
    $reg = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', $machine)
    if ($reg.OpenSubKey($key)) {
        Write-Host "Found registry key: HKLM:\${key}"
    } else {
        Write-Host "Registry key not found: HKLM:\${key}"
    }
}
Write-Host ""

# =====================================================================
# 5. Adobe folders on remote machine
# =====================================================================
Write-Host "=== Adobe Folders on Remote Machine ==="

$foldersToCheck = @(
    "\\$machine\C$\Program Files\Adobe",
    "\\$machine\C$\Program Files (x86)\Adobe",
    "\\$machine\C$\ProgramData\Adobe",
    "\\$machine\C$\Users\*\AppData\Local\Adobe",
    "\\$machine\C$\Users\*\AppData\Roaming\Adobe"
)

foreach ($folder in $foldersToCheck) {
    if (Test-Path $folder) {
        Write-Host "Found folder: ${folder}"
    } else {
        Write-Host "Folder not found: ${folder}"
    }
}
Write-Host ""

# =====================================================================
# 6. Optional uninstall
# =====================================================================
if ($installedAdobe.Count -gt 0) {
    $doUninstall = Read-Host "Do you want to uninstall Adobe products on the remote machine? (Y/N)"
    if ($doUninstall -match '^[Yy]$') {
        foreach ($app in $installedAdobe) {
            Write-Host ""
            Write-Host "Product: $($app.DisplayName)"
            Write-Host "UninstallString: $($app.UninstallString)"

            $confirm = Read-Host "Uninstall this product? (Y/N)"
            if ($confirm -match '^[Yy]$') {
                Invoke-Command -ComputerName $machine -ScriptBlock {
                    param($cmd)
                    Start-Process -FilePath "cmd.exe" -ArgumentList "/c $cmd" -Wait
                } -ArgumentList $app.UninstallString
            }
        }
    }
}
Write-Host ""

# =====================================================================
# 7. Optional cleanup
# =====================================================================
$doCleanup = Read-Host "Do you want to attempt cleanup of leftover Adobe folders and registry keys? (Y/N)"
if ($doCleanup -match '^[Yy]$') {

    Write-Host ""
    Write-Host "Cleanup of folders:"
    foreach ($folder in $foldersToCheck) {
        if (Test-Path $folder) {
            $confirmFolder = Read-Host "Delete folder '${folder}'? (Y/N)"
            if ($confirmFolder -match '^[Yy]$') {
                try {
                    Remove-Item -Path $folder -Recurse -Force -ErrorAction Stop
                    Write-Host "Deleted folder: ${folder}"
                }
                catch {
                    Write-Host "Error deleting folder ${folder}: $($_.Exception.Message)"
                }
            }
        }
    }

    Write-Host ""
    Write-Host "Cleanup of registry keys:"
    foreach ($key in $adobeRegKeys) {
        $reg = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', $machine)
        if ($reg.OpenSubKey($key)) {
            $confirmKey = Read-Host "Delete registry key '${key}'? (Y/N)"
            if ($confirmKey -match '^[Yy]$') {
                try {
                    Invoke-Command -ComputerName $machine -ScriptBlock {
                        param($rk)
                        Remove-Item -Path "HKLM:\$rk" -Recurse -Force
                    } -ArgumentList $key

                    Write-Host "Deleted registry key: ${key}"
                }
                catch {
                    Write-Host "Error deleting registry key ${key}: $($_.Exception.Message)"
                }
            }
        }
    }
}

Write-Host ""
Write-Host "Script completed."
