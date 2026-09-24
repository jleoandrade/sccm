# Install Excel Module

Install-Module -Name ImportExcel -Force -Scope CurrentUser

# 1. SCCM Connection details
$SiteServer = "NJNWKSMS08V" 
$SiteCode   = "A03"                      
$Namespace  = "root\sms\site_$SiteCode"

# 2. Query central database
$Query = "SELECT HotFixID, InstalledBy, InstalledOn FROM SMS_G_System_QUICK_FIX_ENGINEERING WHERE HotFixID = 'KB5093998' OR HotFixID = 'KB5094126'"
$HotFixes = Get-CimInstance -ComputerName $SiteServer -Namespace $Namespace -Query $Query -ErrorAction Stop

# 3. Clean up fields & translate blanks exactly like your screenshot
$Report = $HotFixes | Group-Object HotFixID, InstalledBy, InstalledOn | ForEach-Object {
    [PSCustomObject]@{
        HotFixId    = $_.Values[0]
        InstalledBy = if ([string]::IsNullOrWhiteSpace($_.Values[1])) { "(blank)" } else { $_.Values[1] }
        InstalledOn = $_.Values[2]
        Count       = $_.Count
    }
}

# 4. Generate dynamic file path using Date and Time
$TimeStamp  = Get-Date -Format "yyyy-MM-dd_HHmm"
$OutputPath = "C:\Temp\Report_of_Machines_SCCM_Installations_$TimeStamp.xlsx"

if (-not (Test-Path "C:\Temp")) { New-Item -ItemType Directory -Path "C:\Temp" | Out-Null }

# 5. Export directly using clean, standard explicit parameters
$Report | Export-Excel -Path $OutputPath `
                       -WorksheetName 'Query_Data' `
                       -PivotTableName 'Summary' `
                       -PivotRows @('HotFixId', 'InstalledBy') `
                       -PivotData @{ 'Count' = 'Sum' } `
                       -Show

Write-Host "`n[SUCCESS] Excel Workbook with the Pivot Table summary generated at: $OutputPath" -ForegroundColor Green
