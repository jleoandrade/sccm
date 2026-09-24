# ==============================================================================
# Script: manage_adobe_login.ps1
# Description: Interactive script to either enable or disable Adobe Acrobat 
#              sign-in, online services, and updaters locally or remotely.
# ==============================================================================

# 1. Ask the user for the target computer name or IP address
$ComputerName = Read-Host "Enter the remote computer name or IP address (Or press ENTER for Localhost)"

if ([string]::IsNullOrWhitespace($ComputerName)) {
    $ComputerName = "localhost"
}

# 2. Present the menu options to the administrator
Write-Host "`nChoose an action for Adobe Policies:" -ForegroundColor Yellow
Write-Host "1. ENABLE Adobe Login and Online Services" -ForegroundColor Green
Write-Host "2. DISABLE Adobe Login and Online Services" -ForegroundColor Red
$Choice = Read-Host "Enter your choice (1 or 2)"

if ($Choice -ne "1" -and $Choice -ne "2") {
    Write-Warning "Invalid selection. Operation aborted."
    Exit
}

# 3. Define the core operational logic based on the user's choice
$AdobePolicyBlock = {
    param($ActionChoice)

    # Ensure Registry structures exist before modifying them
    $Paths = @(
        "HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown",
        "HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown\cServices",
        "HKLM:\SOFTWARE\WOW6432Node\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown",
        "HKLM:\SOFTWARE\WOW6432Node\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown\cServices"
    )
    foreach ($Path in $Paths) { 
        if (-not (Test-Path -Path $Path -ErrorAction SilentlyContinue)) { 
            New-Item -Path $Path -Force | Out-Null 
        } 
    }

    if ($ActionChoice -eq "1") {
        # ACTION: ENABLE LOGIN AND SERVICES (Set restrictions to 0, Updater to 1)
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown\cServices" -Name "bUpdater" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown" -Name "bIsSCReducedModeEnforcedEx" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown" -Name "bSuppressSignOut" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown" -Name "bAcroSuppressUpsell" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

        Set-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown\cServices" -Name "bUpdater" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown" -Name "bIsSCReducedModeEnforcedEx" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        
        Write-Output "SUCCESS: Adobe login and online services have been ENABLED on the target registry."
    }
    else {
        # ACTION: DISABLE LOGIN AND SERVICES (Set restrictions to 1, Updater to 0)
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown\cServices" -Name "bUpdater" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown" -Name "bIsSCReducedModeEnforcedEx" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown" -Name "bSuppressSignOut" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown" -Name "bAcroSuppressUpsell" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

        Set-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown\cServices" -Name "bUpdater" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown" -Name "bIsSCReducedModeEnforcedEx" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        
        Write-Output "SUCCESS: Adobe login and online services have been DISABLED on the target registry."
    }
}

# 4. Execute the chosen configuration remotely using WinRM
Write-Host "`nConnecting to $ComputerName and processing request..." -ForegroundColor Cyan

try {
    Invoke-Command -ComputerName $ComputerName -ScriptBlock $AdobePolicyBlock -ArgumentList $Choice -ErrorAction Stop
    Write-Host "`n[COMPLETED] Deployment task finished successfully on machine: $ComputerName" -ForegroundColor Green
}
catch {
    Write-Error "Failed to execute policies on $ComputerName. Ensure WinRM is active and administrative rights are valid. Details: $_"
}
