# 1. Prompt for the remote machine name or IP address
$RemoteMachine = Read-Host -Prompt "Enter the remote machine name or IP address"

# 2. Code block that will be executed INSIDE the remote machine
$ScriptBlock = {
    Write-Host "--- Starting processes on remote machine ($env:COMPUTERNAME) ---" -ForegroundColor Cyan

    # Remote machine local path definitions
    # Official direct URL for the Logi Options+ offline installer for Windows
    $Url = "https://download01.logi.com/web/ftp/pub/techsupport/optionsplus/logioptionsplus_installer.exe"
    $DestinationDir = "C:\Temp"
    $InstallerPath = Join-Path $DestinationDir "logioptionsplus_installer_offline.exe"

    # Create the local temporary directory on the remote machine if it doesn't exist
    if (-not (Test-Path $DestinationDir)) {
        New-Item -ItemType Directory -Path $DestinationDir | Out-Null
    }

    # Download the file directly from the remote machine
    Write-Host "Downloading the offline installer directly on the remote machine..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $Url -OutFile $InstallerPath -UseBasicParsing
    Write-Host "Download completed locally." -ForegroundColor Green

    # Silent Installation based on official Logitech parameters
    Write-Host "Starting silent installation..." -ForegroundColor Cyan
    $Process = Start-Process -FilePath $InstallerPath -ArgumentList "--quiet", "--analytics no", "--sso no", "--update no" -PassThru -Wait

    # Buffer time for Logitech installer subprocesses to finish their tasks
    Write-Host "Waiting 30 seconds for services to finalize..." -ForegroundColor Yellow
    Start-Sleep -Seconds 30

    # Success confirmation by reading the remote Windows registry (both 64-bit and 32-bit paths)
    Write-Host "Verifying if the software was registered in Windows..." -ForegroundColor Cyan
    $UninstallRegPath64 = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    $UninstallRegPath32 = "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    
    $InstalledApp = Get-ItemProperty $UninstallRegPath64, $UninstallRegPath32 -ErrorAction SilentlyContinue | 
                    Where-Object { $_.DisplayName -like "*Logi Options+*" }

    if ($InstalledApp) {
        Write-Host "SUCCESS: '$($InstalledApp.DisplayName)' (Version: $($InstalledApp.DisplayVersion)) installed!" -ForegroundColor Green
    } else {
        # Alternative validation by checking the physical file path
        $DefaultPath = "C:\Program Files\LogiOptionsPlus\logioptionsplus.exe"
        if (Test-Path $DefaultPath) {
             Write-Host "SUCCESS: Executable found in the default destination directory!" -ForegroundColor Green
        } else {
             Write-Host "ERROR: Logi Options+ could not be validated on the remote machine." -ForegroundColor Red
        }
    }

    # Cleanup the temporary installer file on the remote machine
    if (Test-Path $InstallerPath) {
        Remove-Item -Path $InstallerPath -Force
        Write-Host "Temporary installation file removed from the remote machine." -ForegroundColor Gray
    }
}

# 3. Trigger the execution of the code block on the specified remote machine using current Windows credentials (SSO)
Write-Host "Connecting and sending commands to $RemoteMachine using current credentials..." -ForegroundColor Yellow
Invoke-Command -ComputerName $RemoteMachine -ScriptBlock $ScriptBlock
