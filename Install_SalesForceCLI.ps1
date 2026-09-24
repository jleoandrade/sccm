# Ask for the target machine
$Computer = Read-Host "Enter the computer name where you want to install Salesforce CLI"

# Test connectivity
if (-not (Test-Connection -ComputerName $Computer -Count 1 -Quiet)) {
    Write-Host "Machine is unreachable." -ForegroundColor Red
    return
}

Invoke-Command -ComputerName $Computer -ScriptBlock {

    Write-Host "=== Installing Salesforce CLI ===" -ForegroundColor Cyan

    # Official download URL
    $Url = "https://developer.salesforce.com/media/salesforce-cli/sf/channels/stable/sf-x64.exe"
    $InstallerPath = "C:\Temp\sf-x64.exe"

    # Ensure Temp folder exists
    if (-not (Test-Path "C:\Temp")) {
        New-Item -Path "C:\Temp" -ItemType Directory | Out-Null
    }

    # Download installer
    Write-Host "Downloading installer..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $Url -OutFile $InstallerPath

    # Silent installation
    Write-Host "Running installer..." -ForegroundColor Cyan
    Start-Process $InstallerPath -ArgumentList "/S" -Wait

    # Possible installation paths
    $possiblePaths = @(
        "$env:LOCALAPPDATA\sf\bin\sf.exe",
        "$env:LOCALAPPDATA\sf\bin\sf.cmd",
        "C:\Program Files\sf\bin\sf.exe",
        "C:\Program Files\sf\bin\sf.cmd"
    )

    # Detect installation
    $sfPath = $possiblePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $sfPath) {
        Write-Host "ERROR: Salesforce CLI was not found after installation." -ForegroundColor Red
        return
    }

    Write-Host "Salesforce CLI found at: $sfPath" -ForegroundColor Green

    # Extract folder path
    $sfFolder = Split-Path $sfPath -Parent

    Write-Host "Updating PATH..." -ForegroundColor Cyan

    # Update PATH for all shells (CMD + PowerShell)
    setx PATH "$([Environment]::GetEnvironmentVariable('Path','Machine'));$sfFolder" /M | Out-Null

    Write-Host "PATH updated successfully." -ForegroundColor Green

    # Reload PATH in current PowerShell session
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine")

    # Validate CLI
    Write-Host "Validating Salesforce CLI..." -ForegroundColor Cyan

    try {
        $version = & $sfPath --version
        Write-Host "Salesforce CLI version detected:" -ForegroundColor Green
        Write-Host "  $version"
    }
    catch {
        Write-Host "ERROR: Salesforce CLI exists but failed to execute." -ForegroundColor Red
    }

    Write-Host "=== Installation and validation complete ===" -ForegroundColor Cyan
}

Write-Host "`nProcess completed on machine $Computer." -ForegroundColor Green
