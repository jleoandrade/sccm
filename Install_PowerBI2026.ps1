# Ask for the remote machine name
$computer = Read-Host "Enter the remote computer name"

Write-Host "Starting Power BI Desktop installation on $computer..."

Invoke-Command -ComputerName $computer -ScriptBlock {

    $url     = "https://download.microsoft.com/download/8/8/0/880bca75-79dd-466a-927d-1abf1f5454b0/PBIDesktopSetup_x64.exe"
    $path    = "C:\Temp\PBIDesktopSetup_x64.exe"
    $exePath = "C:\Program Files\Microsoft Power BI Desktop\bin\PBIDesktop.exe"

    # Ensure TLS 1.2+ (muito importante em servidores/Win antigos)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    } catch {
        # Se não suportar TLS 1.3, pelo menos TLS 1.2
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }

    # Create C:\Temp if needed
    if (-not (Test-Path "C:\Temp")) {
        New-Item -Path "C:\" -Name "Temp" -ItemType Directory | Out-Null
    }

    Write-Host "Downloading Power BI Desktop installer..."

    try {
        Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: Failed to download Power BI Desktop installer."
        Write-Host "Details: $($_.Exception.Message)"
        exit 1
    }

    Write-Host "Download completed. Running silent installation..."

    $arguments = "/quiet /norestart ACCEPT_EULA=1"

    try {
        $process = Start-Process $path -ArgumentList $arguments -PassThru -WindowStyle Hidden -ErrorAction Stop

        while (-not $process.HasExited) {
            Start-Sleep -Seconds 1
        }
    }
    catch {
        Write-Host "ERROR: Power BI Desktop installer failed to run."
        Write-Host "Details: $($_.Exception.Message)"
        exit 1
    }

    Start-Sleep -Seconds 3

    if (Test-Path $exePath) {
        Write-Host "SUCCESS: Power BI Desktop installed successfully!"
        Write-Host "Executable located at: $exePath"
    }
    else {
        Write-Host "ERROR: Power BI Desktop installation did not complete successfully."
        exit 1
    }
}

Write-Host "Process completed on $computer."
