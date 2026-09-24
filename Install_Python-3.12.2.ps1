# Ask for the remote machine name
$computer = Read-Host "Enter the remote computer name"

Write-Host "Starting Python 3.12 installation on $computer..."

Invoke-Command -ComputerName $computer -ScriptBlock {

    # Official Python 3.12.2 (64-bit) installer
    $url  = "https://www.python.org/ftp/python/3.12.2/python-3.12.2-amd64.exe"
    $path = "C:\Temp\python312.exe"

    # Expected installation path
    $exePath = "C:\Program Files\Python312\python.exe"

    # Ensure TLS 1.2+
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {}

    # Create C:\Temp if needed
    if (-not (Test-Path "C:\Temp")) {
        New-Item -Path "C:\" -Name "Temp" -ItemType Directory | Out-Null
    }

    Write-Host "Downloading Python installer..."

    try {
        Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: Failed to download Python installer."
        Write-Host "Details: $($_.Exception.Message)"
        exit 1
    }

    Write-Host "Download completed. Running silent installation..."

    # Silent install parameters (official)
    $arguments = "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0"

    try {
        $process = Start-Process $path -ArgumentList $arguments -PassThru -WindowStyle Hidden -ErrorAction Stop

        while (-not $process.HasExited) {
            Start-Sleep -Seconds 1
        }
    }
    catch {
        Write-Host "ERROR: Python installer failed to run."
        Write-Host "Details: $($_.Exception.Message)"
        exit 1
    }

    Start-Sleep -Seconds 3

    # Validate installation
    if (Test-Path $exePath) {
        Write-Host "SUCCESS: Python 3.12 installed successfully!"
        Write-Host "Executable located at: $exePath"
    }
    else {
        Write-Host "ERROR: Python installation did not complete successfully."
        exit 1
    }
}

Write-Host "Process completed on $computer."
