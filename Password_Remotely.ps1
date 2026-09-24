# ============================================================
#  SCCM LAPS Password Retriever (Auto-fix for A03 drive issue)
# ============================================================

# Always return to filesystem before doing anything
Set-Location Microsoft.PowerShell.Core\FileSystem::C:\

# SCCM Site Server name
$SCCMServer = "NJNWKSMS08V.ENTERPRISE.PSEG.COM"

# SCCM Site Code (fixed)
$SiteCode = "A03"

# Correct path to the SCCM PowerShell module on the server
$ConfigMgrModulePath = "\\$SCCMServer\d$\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"

Write-Host "Loading SCCM PowerShell module from server $SCCMServer..." -ForegroundColor Cyan

# Validate and import the SCCM module
if (Test-Path $ConfigMgrModulePath) {
    Import-Module $ConfigMgrModulePath -ErrorAction Stop
} else {
    Write-Host "ERROR: SCCM module not found at: $ConfigMgrModulePath" -ForegroundColor Red
    exit
}

# Create SCCM PSDrive if it does not exist
if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SCCMServer -ErrorAction Stop | Out-Null
}

# Connect to SCCM site
Set-Location "$SiteCode`:"

Write-Host "Connected to SCCM ($SCCMServer - Site $SiteCode)" -ForegroundColor Green

# ============================================================
#  REQUEST DEVICE NAME
# ============================================================

$deviceName = Read-Host "Enter the device name"

# ============================================================
#  RETRIEVE LAPS PASSWORD
# ============================================================

try {
    $result = Get-AdmPwdPassword -ComputerName $deviceName

    Write-Host "`nDevice:      $($result.ComputerName)" -ForegroundColor Cyan
    Write-Host "Password:    $($result.Password)" -ForegroundColor Yellow
    Write-Host "Expires on:  $($result.ExpirationTimestamp)" -ForegroundColor Gray

} catch {
    Write-Host "`nFailed to retrieve the password. Check the device name and your permissions." -ForegroundColor Red
}

Write-Host "`nPress Enter to exit..."
Read-Host
