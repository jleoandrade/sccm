# Ask for the remote machine name
$computer = Read-Host "Enter the remote computer name"

Write-Host "Installing Power Automate Desktop on $computer..."

Invoke-Command -ComputerName $computer -ScriptBlock {

    # Official Microsoft Power Automate Desktop installer (EXE)
    $url  = "https://go.microsoft.com/fwlink/?linkid=2102613"
    $path = "C:\Temp\Setup.Microsoft.PowerAutomate.exe"

    # Expected executable after installation
    $exePath = "C:\Program Files (x86)\Power Automate Desktop\PAD.Console.Host.exe"

    # Create C:\Temp if it does not exist
    if (-not (Test-Path "C:\Temp")) {
        New-Item -Path "C:\" -Name "Temp" -ItemType Directory | Out-Null
    }

    Write-Host "Downloading Power Automate Desktop installer..."
    try {
        Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: Failed to download Power Automate Desktop installer."
        exit 1
    }

    Write-Host "Running silent installation..."

    # Silent install with required parameters
    $arguments = "-Silent -Install -ACCEPTEULA -DONOTINSTALLMACHINERUNTIME"

    try {
        Start-Process $path -ArgumentList $arguments -Wait -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: Power Automate Desktop installer failed to run."
        exit 1
    }

    # Wait a moment for installation to finalize
    Start-Sleep -Seconds 5

    # Validate installation
    if (Test-Path $exePath) {
        Write-Host "SUCCESS: Power Automate Desktop installed successfully!"
        Write-Host "Executable found at: $exePath"
    }
    else {
        Write-Host "ERROR: Power Automate Desktop installation did not complete successfully."
        exit 1
    }
}

Write-Host "Process completed on $computer."
