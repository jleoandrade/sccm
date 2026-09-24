# Ask for the remote machine name
$computer = Read-Host "Enter the remote computer name"

Write-Host "Installing WinSCP 6.3.1 on $computer..."

Invoke-Command -ComputerName $computer -ScriptBlock {

    $url  = "https://cdn.winscp.net/files/WinSCP-6.5.5-Setup.exe?secure=1Ol1E1oYotBTr16gzVwqYQ==,1774385696"
    $path = "C:\Temp\WinSCP-6.5.5-Setup.exe"
    $installPath = "C:\Program Files (x86)\WinSCP\WinSCP.exe"

    # Create C:\Temp if it does not exist
    if (-not (Test-Path "C:\Temp")) {
        New-Item -Path "C:\" -Name "Temp" -ItemType Directory | Out-Null
    }

    Write-Host "Downloading WinSCP installer..."
    try {
        Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: Failed to download WinSCP installer."
        exit 1
    }

    Write-Host "Running silent installation..."
    try {
        Start-Process $path -ArgumentList "/VERYSILENT /NORESTART" -Wait -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: WinSCP installer failed to run."
        exit 1
    }

    # Wait a moment for installation to finalize
    Start-Sleep -Seconds 5

    # Validate installation
    if (Test-Path $installPath) {
        Write-Host "SUCCESS: WinSCP 6.3.1 is installed at $installPath"
    }
    else {
        Write-Host "ERROR: WinSCP installation did not complete successfully."
        exit 1
    }
}

Write-Host "Process completed on $computer."
