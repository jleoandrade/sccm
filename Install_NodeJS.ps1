# Ask for the remote machine name
$computer = Read-Host "Enter the remote computer name"

Write-Host "Installing Node.js on $computer..."

Invoke-Command -ComputerName $computer -ScriptBlock {

    # Official Node.js MSI (32-bit) – change to x64 if needed
    $url  = "https://nodejs.org/dist/v20.11.1/node-v20.11.1-x86.msi"
    $path = "C:\Temp\nodejs-installer.msi"
    $installPath = "C:\Program Files\nodejs\node.exe"

    # Create C:\Temp if it does not exist
    if (-not (Test-Path "C:\Temp")) {
        New-Item -Path "C:\" -Name "Temp" -ItemType Directory | Out-Null
    }

    Write-Host "Downloading Node.js installer..."
    try {
        Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: Failed to download Node.js installer."
        exit 1
    }

    Write-Host "Running silent installation..."
    try {
        Start-Process "msiexec.exe" -ArgumentList "/i `"$path`" /qn /norestart" -Wait -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: Node.js installer failed to run."
        exit 1
    }

    # Wait a moment for installation to finalize
    Start-Sleep -Seconds 5

    # Validate installation
    if (Test-Path $installPath) {
        Write-Host "SUCCESS: Node.js is installed at $installPath"
    }
    else {
        Write-Host "ERROR: Node.js installation did not complete successfully."
        exit 1
    }
}

Write-Host "Process completed on $computer."
