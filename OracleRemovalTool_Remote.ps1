# Requests the name or IP of the remote machine
Write-Host "=== REMOTE CONFIGURATION ===" -ForegroundColor Cyan
$computerName = Read-Host "Enter the remote machine name or IP"

# Tests the connection before proceeding
if (-not (Test-Connection -ComputerName $computerName -Count 1 -Quiet)) {
    Write-Host "Could not connect to $computerName. Please check the network." -ForegroundColor Red
    Exit
}

# Block of commands to be executed on the remote machine
$remoteScript = {
    # 1. Finds Oracle environment variables by querying the System Registry directly
    Write-Host "`n=== 1. ORACLE ENVIRONMENT VARIABLES ON $env:COMPUTERNAME ===" -ForegroundColor Cyan

    $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
    $targetVars = @("ORACLE_HOME", "ORACLE_SID", "TNS_ADMIN", "PATH")
    $envFound = $false
    foreach ($var in $targetVars) {
        $value = (Get-ItemProperty -Path $registryPath -Name $var -ErrorAction SilentlyContinue).$var
        if ($value) {
            $envFound = $true
            if ($var -eq "PATH") {
                # Filters only Oracle paths inside the PATH variable to avoid clutter
                $oraclePaths = $value.Split(';') | Where-Object { $_ -like "*Oracle*" -or $_ -like "*app*" }
                foreach ($path in $oraclePaths) {
                    Write-Host "Found in PATH: $path"
                }
            } else {
                Write-Host "Found: $var = $value"
            }
        }
    }
    if (-not $envFound) {
        Write-Host "No standard Oracle system variables were found." -ForegroundColor Yellow
    }

    # 2. Shows installed Oracle folders
    Write-Host "`n=== 2. INSTALLED ORACLE FOLDERS ===" -ForegroundColor Cyan
    $oraclePaths = Get-ChildItem -Path "C:\Programs" -Directory -Recurse -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -eq "Oracle" -or $_.Name -eq "app" }
    foreach ($path in $oraclePaths) {
        Write-Host "Found: $($path.FullName)"
    }

    # 3. Locates the deinstall.bat file
    Write-Host "`n=== 3. LOCATING DEINSTALL.BAT ===" -ForegroundColor Cyan
    $deinstallFile = Get-ChildItem -Path "C:\Programs" -Filter "deinstall.bat" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($deinstallFile) {
        $deinstallPath = $deinstallFile.FullName
        Write-Host "Uninstall script found at: $deinstallPath" -ForegroundColor Green

        # Uses [PSCustomObject] to safely wrap the return value without breaking screen formatting
        return [PSCustomObject]@{ DeinstallPath = $deinstallPath }
    } else {
        Write-Host "The deinstall.bat file was not found on the remote system." -ForegroundColor Red
        return $null
    }
}

# Executes the search remotely and captures the return object
$resultadoRemoto = Invoke-Command -ComputerName $computerName -ScriptBlock $remoteScript
$deinstallPathRemoto = $resultadoRemoto.DeinstallPath

# 4. Asks locally whether to execute deinstall.bat on the remote machine
if ($deinstallPathRemoto) {
    Write-Host "`n=== 4. REMOTE EXECUTION CONFIRMATION ===" -ForegroundColor Cyan
    $confirmation = Read-Host "Would you like to execute deinstall.bat on the remote machine $computerName? (Y/N)"

    if ($confirmation -match "^[Yy]$") {
        Write-Host "Starting remote uninstallation on $computerName..." -ForegroundColor Yellow

        # Executes deinstall.bat remotely, auto-answering every prompt with "Y"
        Invoke-Command -ComputerName $computerName -ScriptBlock {
            param($path)
            $dir = Split-Path -Parent $path

            # Creates a temp file with multiple "Y" lines to feed as stdin,
            # covering every interactive prompt the script might ask
            $answerFile = Join-Path $env:TEMP "deinstall_autoanswers.txt"
            1..30 | ForEach-Object { "Y" } | Out-File -FilePath $answerFile -Encoding ascii -Force

            Start-Process -FilePath $path -WorkingDirectory $dir -NoNewWindow -Wait -RedirectStandardInput $answerFile

            # Cleans up the temp answer file after execution
            Remove-Item -Path $answerFile -ErrorAction SilentlyContinue
        } -ArgumentList $deinstallPathRemoto

        Write-Host "Process completed on the remote server." -ForegroundColor Green
    } else {
        Write-Host "Remote execution canceled by the user." -ForegroundColor Yellow
    }
}