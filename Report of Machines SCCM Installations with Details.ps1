# Install Excel Module
Install-Module -Name ImportExcel -Force -Scope CurrentUser

# 1. SCCM Connection details
$SiteServer = "NJNWKSMS08V.ENTERPRISE.PSEG.COM" # Insert your site server name here
$SiteCode   = "A03"                      
$Namespace  = "root\sms\site_$SiteCode"

# 2. Query central database for HotFix details
Write-Host "Fetching HotFix data from SCCM..." -ForegroundColor Cyan
$QueryHF = "SELECT ResourceID, HotFixID, InstalledBy, InstalledOn FROM SMS_G_System_QUICK_FIX_ENGINEERING WHERE HotFixID = 'KB5093998' OR HotFixID = 'KB5094126'"
$HotFixes = Get-CimInstance -ComputerName $SiteServer -Namespace $Namespace -Query $QueryHF -ErrorAction Stop

# 3. Fetch Machine Names to resolve ResourceIDs efficiently
Write-Host "Resolving machine names..." -ForegroundColor Cyan
$QuerySys = "SELECT ResourceID, Name FROM SMS_R_System"
$Systems = Get-CimInstance -ComputerName $SiteServer -Namespace $Namespace -Query $QuerySys -ErrorAction Stop

# Create a fast lookup table (hashtable) matching ResourceID to Computer Name
$ComputerLookup = @{}
foreach ($Sys in $Systems) {
    $ComputerLookup[$Sys.ResourceID] = $Sys.Name
}

# 4. Clean up fields & map ResourceID to actual Machine Name
$Report = $HotFixes | ForEach-Object {
    $MachineName = if ($ComputerLookup.ContainsKey($_.ResourceID)) { $ComputerLookup[$_.ResourceID] } else { "Unknown ($($_.ResourceID))" }

    [PSCustomObject]@{
        MachineName = $MachineName
        HotFixId    = $_.HotFixID
        InstalledBy = if ([string]::IsNullOrWhiteSpace($_.InstalledBy)) { "(blank)" } else { $_.InstalledBy }
        InstalledOn = $_.InstalledOn
    }
}

# 5. Generate dynamic file path using Date and Time
$TimeStamp  = Get-Date -Format "yyyy-MM-dd_HHmm"
$OutputPath = "C:\Temp\Report_of_Machines_SCCM_Installations_$TimeStamp.xlsx"

if (-not (Test-Path "C:\Temp")) { New-Item -ItemType Directory -Path "C:\Temp" | Out-Null }

# 6. Export directly to Excel with an optimized Pivot Table
Write-Host "Generating Excel report..." -ForegroundColor Cyan
$Report | Export-Excel -Path $OutputPath `
                       -WorksheetName 'Machine_List' `
                       -PivotTableName 'Summary_By_Installer' `
                       -PivotRows @('InstalledBy', 'HotFixId', 'MachineName') `
                       -PivotData @{ 'MachineName' = 'Count' } `
                       -Show

Write-Host "`n[SUCCESS] Excel Workbook with resolved Machine Names generated at: $OutputPath" -ForegroundColor Green
