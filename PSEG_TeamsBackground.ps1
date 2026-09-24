# ============================================================
# Script: Deploy New Teams Backgrounds Remotely
# Purpose: Copy corporate backgrounds to the New Teams Client
# Author: (Your Name)
# ============================================================

# 1. Ask for the machine name
$Computer = Read-Host "Enter the target machine name"

# 2. Source and destination paths
$SourcePath = "\\claue1fsp0002\SoftwarePackages-CurrentBranch\Image SCCM\Applications\zzApplicationsInTaskSequence\Teams Backgrounds\PSEG New Teams client Backgrounds\NewTeamsBackgroundsQ22024"
$RemoteTemp = "\\$Computer\C$\Temp\NewTeamsBackgroundsQ22024"

# ============================================================
# Connectivity validation
# ============================================================
if (!(Test-Connection -ComputerName $Computer -Count 1 -Quiet)) {
    Write-Host "ERROR: Machine is not responding to ping." -ForegroundColor Red
    exit
}

if (!(Test-Path "\\$Computer\C$")) {
    Write-Host "ERROR: Access to C$ on the remote machine is denied." -ForegroundColor Red
    exit
}

Write-Host "Connectivity OK. Starting file transfer..." -ForegroundColor Cyan

# ============================================================
# Copy files to remote C:\Temp
# ============================================================
if (!(Test-Path $RemoteTemp)) {
    New-Item -ItemType Directory -Path $RemoteTemp -Force | Out-Null
}

Copy-Item -Path $SourcePath\* -Destination $RemoteTemp -Recurse -Force

Write-Host "Files copied to $RemoteTemp" -ForegroundColor Green

# ============================================================
# Remote execution: Install backgrounds into New Teams
# ============================================================
Invoke-Command -ComputerName $Computer -ScriptBlock {

    param($RemoteTemp)

    # Detect logged-in user
    $User = (whoami).Split('\')[1]

    # New Teams Client background upload folder
    $TeamsBGUploadPath = "C:\Users\$User\AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Backgrounds\Uploads"

    # Create folder if missing
    if (!(Test-Path $TeamsBGUploadPath)) {
        New-Item -ItemType Directory -Path $TeamsBGUploadPath -Force | Out-Null
    }

    # Copy backgrounds
    Copy-Item -Path "$RemoteTemp\*" -Destination $TeamsBGUploadPath -Recurse -Force

    # Registry tracking
    $RegPath = "HKCU:\SOFTWARE\PSEG\Packages\PSEGNewTeamsBG"
    if (-Not (Test-Path $RegPath)) {
        New-Item -Path $RegPath -Force | Out-Null
    }

    New-ItemProperty -Path $RegPath -Name "Application Name" -Value "New Teams PSEG Backgrounds" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $RegPath -Name "Application Version" -Value "1.0" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $RegPath -Name "Installed" -Value (Get-Date).ToString() -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $RegPath -Name "Installed By" -Value $env:USERNAME -PropertyType String -Force | Out-Null

    Write-Host "Backgrounds successfully installed for user $User" -ForegroundColor Green

} -ArgumentList $RemoteTemp

Write-Host "Process completed successfully." -ForegroundColor Green
