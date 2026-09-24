# ============================================================
#  CONNECT TO SCCM SERVER AND LOAD MODULE REMOTELY
# ============================================================

$SccmServer = "NJNWKSMS08V"   # <-- CHANGE THIS
$DeploymentName = "Desktop Deployment - Enterprise Production - Windows - 2026 - May"
$CollectionName = "All Desktop and MDT Clients"

# Detect provider and site code remotely
$providerInfo = Get-WmiObject -ComputerName $SccmServer -Namespace "root\sms" -Class SMS_ProviderLocation | Select-Object -First 1
$Provider = $providerInfo.Machine
$Namespace = $providerInfo.NamespacePath
$SiteCode = ($Namespace -split "_")[-1]

Write-Host "Detected SMS Provider: $Provider" -ForegroundColor Cyan
Write-Host "Detected Site Code: $SiteCode" -ForegroundColor Cyan

# Load SCCM module from server
$CMModulePath = "\\$SccmServer\d$\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"

if (Test-Path $CMModulePath) {
    Import-Module $CMModulePath -ErrorAction Stop
} else {
    Write-Error "Could not find ConfigurationManager.psd1 at $CMModulePath"
    exit
}

# Connect to SCCM Site Drive
Set-Location "$($SiteCode):" -ErrorAction Stop

# ============================================================
#  GET REAL-TIME METRICS DIRECTLY FROM WMI VIEW
# ============================================================
Write-Host "`nQuerying real-time database view summaries..." -ForegroundColor Cyan

# Querying the deployment view directly via WMI to bypass empty cmdlet properties
$WmiSiteNamespace = "root\sms\site_$SiteCode"
$SummaryQuery = "SELECT * FROM SMS_DeploymentSummary WHERE AssignmentID = '16785848'"
$DirectSummary = Get-WmiObject -ComputerName $SccmServer -Namespace $WmiSiteNamespace -Query $SummaryQuery | Select-Object -First 1

if (!$DirectSummary) {
    Write-Error "Could not retrieve direct WMI records for AssignmentID 16785848."
    Set-Location C:
    exit
}

Write-Host "`n=============================================" -ForegroundColor Yellow
Write-Host "         DEPLOYMENT STATUS SUMMARY            " -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host "Target Collection : $CollectionName"
Write-Host "Deployment ID     : 16785848"
Write-Host "---------------------------------------------"
Write-Host "Success           : $($DirectSummary.NumberSuccess)" -ForegroundColor Green
Write-Host "In Progress       : $($DirectSummary.NumberInProgress)" -ForegroundColor Yellow
Write-Host "Errors            : $($DirectSummary.NumberErrors)" -ForegroundColor Red
Write-Host "Unknown State     : $($DirectSummary.NumberUnknown)" -ForegroundColor Cyan
Write-Host "Total Targeted    : $($DirectSummary.NumberTotal)" -ForegroundColor White
Write-Host "=============================================`n" -ForegroundColor Yellow

# Return prompt location back to local drive
Set-Location C:
