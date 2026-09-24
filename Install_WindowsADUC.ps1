# Ask for the target machine
$Computer = Read-Host "Enter the computer name where you want to install ADUC"

# Test connectivity
if (-not (Test-Connection -ComputerName $Computer -Count 1 -Quiet)) {
    Write-Host "Machine is unreachable." -ForegroundColor Red
    return
}

Invoke-Command -ComputerName $Computer -ScriptBlock {

    Write-Host "=== Installing Active Directory Users and Computers (ADUC) ===" -ForegroundColor Cyan

    # Check OS version (RSAT only works on Pro/Enterprise/Education)
    $edition = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").EditionID
    Write-Host "Windows Edition: $edition"

    if ($edition -eq "Core") {
        Write-Host "ERROR: RSAT cannot be installed on Windows Home edition." -ForegroundColor Red
        return
    }

    # Check if RSAT AD Tools are already installed
    $capability = Get-WindowsCapability -Online | Where-Object { $_.Name -like "Rsat.ActiveDirectory.DS-LDS.Tools*" }

    Write-Host "Current RSAT AD Capability State: $($capability.State)"

    try {
        Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0 -ErrorAction Stop
        Write-Host "ADUC installation completed." -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: Failed to install ADUC." -ForegroundColor Red
        Write-Host "----- DEBUG INFORMATION -----" -ForegroundColor Yellow
        Write-Host "Exception Message: $($_.Exception.Message)"
        Write-Host "Exception Type: $($_.Exception.GetType().FullName)"
        Write-Host "HResult: $([System.String]::Format('0x{0:X8}', $_.Exception.HResult))"
        if ($_.Exception.InnerException) {
            Write-Host "Inner Exception: $($_.Exception.InnerException.Message)"
        }
        Write-Host "-----------------------------"
        return
    }

    Write-Host "Validating installation..." -ForegroundColor Cyan

    # Validation: check if dsa.msc exists
    $aducPath = "C:\Windows\System32\dsa.msc"

    if (Test-Path $aducPath) {
        Write-Host "ADUC is installed successfully." -ForegroundColor Green
        Write-Host "Executable found at: $aducPath"
    }
    else {
        Write-Host "ADUC installation failed. dsa.msc not found." -ForegroundColor Red
    }

    Write-Host "=== Validation complete ===" -ForegroundColor Cyan
}

Write-Host "`nProcess completed on machine $Computer." -ForegroundColor Green
