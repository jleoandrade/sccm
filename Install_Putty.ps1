# Ask for the remote machine name
$computer = Read-Host "Enter the remote computer name"

Write-Host "Installing PuTTY 0.83 on $computer..."

Invoke-Command -ComputerName $computer -ScriptBlock {

    $url  = "https://the.earth.li/~sgtatham/putty/latest/w32/putty-0.83-installer.msi"
    $path = "C:\Temp\putty-0.83-installer.msi"
    $installPath = "C:\Program Files\PuTTY\putty.exe"

    # Create C:\Temp if it does not exist
    if (-not (Test-Path "C:\Temp")) {
        New-Item -Path "C:\" -Name "Temp" -ItemType Directory | Out-Null
    }

    Write-Host "Downloading PuTTY installer..."
    try {
        Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: Failed to download PuTTY installer."
        exit 1
    }

    Write-Host "Running silent installation..."
    try {
        Start-Process "msiexec.exe" -ArgumentList "/i `"$path`" /qn /norestart" -Wait -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: PuTTY installer failed to run."
        exit 1
    }

    # Wait a moment for installation to finalize
    Start-Sleep -Seconds 5

    # Validate installation
    if (Test-Path $installPath) {
        Write-Host "SUCCESS: PuTTY 0.83 is installed at $installPath"
    }
    else {
        Write-Host "ERROR: PuTTY installation did not complete successfully."
        exit 1
    }
}

Write-Host "Process completed on $computer."
