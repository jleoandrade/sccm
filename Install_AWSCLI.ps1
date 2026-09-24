Write-Host "=== AWS CLI Remote Installer ===" -ForegroundColor Cyan

# Ask for machine name
$ComputerName = Read-Host "Enter the computer name"

# AWS CLI download URL
$awsInstaller = "https://awscli.amazonaws.com/AWSCLIV2.msi"

# Remote paths
$remoteFolder = "C:\temp"
$remoteFile = "$remoteFolder\AWSCLIV2.msi"
$remoteLog = "$remoteFolder\aws_install.log"

Write-Host "`nConnecting to $ComputerName..." -ForegroundColor Cyan

# Test connection
if (-not (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet)) {
    Write-Host "Machine not reachable." -ForegroundColor Red
    return
}

Write-Host "Machine reachable. Preparing installation..." -ForegroundColor Green

Invoke-Command -ComputerName $ComputerName -ScriptBlock {
    param($awsInstaller, $remoteFolder, $remoteFile, $remoteLog)

    # Ensure temp folder exists
    if (-not (Test-Path $remoteFolder)) {
        New-Item -Path $remoteFolder -ItemType Directory | Out-Null
    }

    Write-Host "Downloading AWS CLI installer..." -ForegroundColor Cyan

    try {
        Invoke-WebRequest -Uri $awsInstaller -OutFile $remoteFile -UseBasicParsing
    }
    catch {
        Write-Host "Download failed. Check proxy/firewall." -ForegroundColor Red
        return
    }

    # Validate file size
    $size = (Get-Item $remoteFile).Length
    if ($size -lt 50000000) {  # 50 MB mínimo
        Write-Host "Downloaded file is too small. Likely corrupted." -ForegroundColor Red
        return
    }

    Write-Host "Installer downloaded successfully ($([math]::Round($size/1MB,2)) MB)" -ForegroundColor Green

    Write-Host "Installing AWS CLI..." -ForegroundColor Cyan
    Start-Process "msiexec.exe" -ArgumentList "/i `"$remoteFile`" /qn /L*v `"$remoteLog`"" -Wait

    Write-Host "Checking installation..." -ForegroundColor Cyan
    $version = aws --version 2>$null

    if ($version) {
        Write-Host "AWS CLI installed successfully!" -ForegroundColor Green
        Write-Host "Version: $version"
    } else {
        Write-Host "Installation failed. Check log at $remoteLog" -ForegroundColor Red
    }

} -ArgumentList $awsInstaller, $remoteFolder, $remoteFile, $remoteLog

Write-Host "`nProcess completed." -ForegroundColor Green
