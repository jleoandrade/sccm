# Ask for the remote machine name
$computer = Read-Host "Enter the remote computer name"

Write-Host "Installing Amazon Corretto JRE 8 (x64) on $computer..."

Invoke-Command -ComputerName $computer -ScriptBlock {

    # Official Amazon Corretto JRE 8 (x64) MSI
    $url  = "https://corretto.aws/downloads/latest/amazon-corretto-8-x64-windows-jre.msi"
    $path = "C:\Temp\corretto8-jre-x64.msi"
    $installPath = "C:\Program Files\Amazon Corretto\jdk1.8.0_*\jre\bin\java.exe"

    # Create C:\Temp if it does not exist
    if (-not (Test-Path "C:\Temp")) {
        New-Item -Path "C:\" -Name "Temp" -ItemType Directory | Out-Null
    }

    Write-Host "Downloading Amazon Corretto JRE installer..."
    try {
        Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: Failed to download Amazon Corretto JRE installer."
        exit 1
    }

    Write-Host "Running silent installation..."
    try {
        Start-Process "msiexec.exe" -ArgumentList "/i `"$path`" /qn /norestart" -Wait -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: Amazon Corretto JRE installer failed to run."
        exit 1
    }

    # Wait a moment for installation to finalize
    Start-Sleep -Seconds 5

    # Validate installation (wildcard because version folder changes)
    $java = Get-ChildItem "C:\Program Files\Amazon Corretto" -Recurse -Filter "java.exe" -ErrorAction SilentlyContinue

    if ($java) {
        Write-Host "SUCCESS: Amazon Corretto JRE 8 (x64) is installed at $($java.FullName)"
    }
    else {
        Write-Host "ERROR: Amazon Corretto JRE installation did not complete successfully."
        exit 1
    }
}

Write-Host "Process completed on $computer."
