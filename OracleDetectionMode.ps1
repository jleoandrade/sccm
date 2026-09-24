<#
.SYNOPSIS
    SCCM Detection Method script for the Oracle Uninstall Application.

.DESCRIPTION
    This script is used as a "Script" Detection Method in an SCCM Application
    Deployment Type. Detection logic is INVERTED compared to a normal install:
    - If Oracle is NOT present (already uninstalled) -> write output and exit 0
      (SCCM considers the application "installed", i.e. compliant, and will
      NOT run the uninstall action again).
    - If Oracle IS still present -> produce no output and exit 0
      (SCCM considers the application "not installed" and will run the
      uninstall Deployment Type).
#>

$knownBinPaths = @(
    "C:\Programs\Oracle\12.2.0.1_32bit\bin\",
    "C:\Programs\Oracle\12.2.0.1_64bit\bin\",
    "C:\Programs\Oracle\Ora11g\bin\",
    "C:\Programs\Oracle\11.2.0.4_32bit\bin\",
    "C:\Programs\Oracle\product\12.2.0\client_1\bin\",
    "C:\Programs\Oracle\Ora11g_32\bin\",
    "C:\Programs\Oracle\ora11g_64bit\bin\",
    "C:\Programs\Oracle\product\11.2.0\client_1\bin\",
    "C:\Programs\Oracle\product\11.2.0\client_2\bin\",
    "C:\Programs\Oracle\12.2.01_64bit\bin\"
)

$oracleFound = $false

# Checks known installation folders
foreach ($binPath in $knownBinPaths) {
    if (Test-Path $binPath) {
        $oracleFound = $true
        break
    }
}

# Extra safety check: sweeps the whole C:\Programs\Oracle folder
if (-not $oracleFound -and (Test-Path "C:\Programs\Oracle")) {
    $anyDeinstall = Get-ChildItem -Path "C:\Programs\Oracle" -Filter "deinstall.bat" -Recurse -ErrorAction SilentlyContinue
    if ($anyDeinstall) {
        $oracleFound = $true
    }
}

# Extra safety check: ORACLE_HOME registry key
if (-not $oracleFound) {
    $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
    $oracleHomeValue = (Get-ItemProperty -Path $registryPath -Name "ORACLE_HOME" -ErrorAction SilentlyContinue).ORACLE_HOME
    if ($oracleHomeValue) {
        $oracleFound = $true
    }
}

if (-not $oracleFound) {
    # Oracle is not present - already uninstalled - report as "installed" for SCCM
    Write-Output "OracleAlreadyUninstalled"
}

# If Oracle is still present, the script produces no output on purpose,
# which tells SCCM the Deployment Type is "not detected" / not compliant.
Exit 0