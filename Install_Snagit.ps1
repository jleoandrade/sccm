# Ask for the remote machine name
$computer = Read-Host "Enter the remote computer name"

Write-Host "Installing Snagit on $computer..."

Invoke-Command -ComputerName $computer -ScriptBlock {

    # URL oficial do instalador EXE (Snagit 2024)
    $url  = "https://download.techsmith.com/snagit/releases/2420/snagit.exe"
    $path = "C:\Temp\SnagitSetup.exe"
    $installPath = "C:\Program Files\TechSmith\Snagit 2024\Snagit32.exe"

    # Criar C:\Temp se não existir
    if (-not (Test-Path "C:\Temp")) {
        New-Item -Path "C:\" -Name "Temp" -ItemType Directory | Out-Null
    }

    Write-Host "Downloading Snagit installer..."
    try {
        Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: Failed to download Snagit installer."
        exit 1
    }

    Write-Host "Running silent installation..."
    try {
        Start-Process $path -ArgumentList "/quiet /norestart" -Wait -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: Snagit installer failed to run."
        exit 1
    }

    # Aguardar finalização
    Start-Sleep -Seconds 5

    # Validar instalação
    if (Test-Path $installPath) {
        Write-Host "SUCCESS: Snagit is installed at $installPath"
    }
    else {
        Write-Host "ERROR: Snagit installation did not complete successfully."
        exit 1
    }
}

Write-Host "Process completed on $computer."
