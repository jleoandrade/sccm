# Ensure the Excel module is safely installed without crashing the console
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    Install-Module -Name ImportExcel -Force -Scope CurrentUser -ErrorAction SilentlyContinue
}

# 1. SCCM Connection details
$SiteServer   = "NJNWKSMS08V" # Your SCCM Site Server Name
$SiteCode     = "A03"                      
$Namespace    = "root\sms\site_$SiteCode"
$CollectionID = "A03002EA"

# 2. Query central database for HotFix details
Write-Host "Fetching HotFix data from SCCM..." -ForegroundColor Cyan
$QueryHF = "SELECT ResourceID, HotFixID, InstalledBy, InstalledOn FROM SMS_G_System_QUICK_FIX_ENGINEERING WHERE HotFixID = 'KB5093998' OR HotFixID = 'KB5094126'"
$HotFixes = Get-CimInstance -ComputerName $SiteServer -Namespace $Namespace -Query $QueryHF -ErrorAction Stop

# 3. Fetch machines belonging to the specific collection "All Desktop and MDT Clients"
Write-Host "Fetching fleet machines from Collection ID $CollectionID..." -ForegroundColor Cyan
$QueryColl = "SELECT ResourceID, Name FROM SMS_CM_RES_COLL_$CollectionID"
$CollectionMembers = Get-CimInstance -ComputerName $SiteServer -Namespace $Namespace -Query $QueryColl -ErrorAction Stop

# Memory lookup hashtable for ultra-fast processing (Prevents server slowness)
$CollectionLookup = @{}
foreach ($Member in $CollectionMembers) {
    $CollectionLookup[$Member.ResourceID] = $Member.Name
}

# 4. Filter, clean fields, and dynamically translate service accounts
$Report = $HotFixes | ForEach-Object {
    if ($CollectionLookup.ContainsKey($_.ResourceID)) {
        
        # Naming logic: Translate explicit naming architectures cleanly matching your screenshot
        $Installer = $_.InstalledBy
        if ([string]::IsNullOrWhiteSpace($Installer)) { 
            $Installer = "(blank)" 
        } elseif ($Installer -like "ENTERPRISE\ServiceHLASMSWKS*") { 
            $Installer = "ENTERPRISE\ServiceHLASMSWKSx ( Manual Installation )" 
        } elseif ($Installer -eq "NT AUTHORITY\SYSTEM") {
            $Installer = "NT AUTHORITY\SYSTEM ( SCCM )"
        }

        [PSCustomObject]@{
            MachineName = $CollectionLookup[$_.ResourceID]
            HotFixId    = $_.HotFixID
            InstalledBy = $Installer
            InstalledOn = $_.InstalledOn
        }
    }
}

# 5. Consolidated collection fleet metrics calculations (Ensures data integrity)
$TotalCollectionFleet = $CollectionMembers.Count
$UniqueInstalled      = ($Report.MachineName | Select-Object -Unique).Count
$MissingInstallations = $TotalCollectionFleet - $UniqueInstalled
$ComplianceRate       = if ($TotalCollectionFleet -gt 0) { [Math]::Round(($UniqueInstalled / $TotalCollectionFleet) * 100, 2) } else { 0 }

# Exact 4-line summary block layout from your screenshot
$FleetSummary = @(
    [PSCustomObject]@{ Metric = "Total Machines";                 Value = $TotalCollectionFleet }
    [PSCustomObject]@{ Metric = "Total Patched Machines";         Value = $UniqueInstalled }
    [PSCustomObject]@{ Metric = "Machines Missing Installations"; Value = $MissingInstallations }
    [PSCustomObject]@{ Metric = "compliance rate";                Value = "$ComplianceRate%" }
)

# 6. Define output file path using Date and Time
$TimeStamp  = Get-Date -Format "yyyy-MM-dd_HHmm"
$OutputPath = "C:\Temp\Collection_Report_SCCM_Installations_$TimeStamp.xlsx"

if (-not (Test-Path "C:\Temp")) { New-Item -ItemType Directory -Path "C:\Temp" | Out-Null }

Write-Host "Generating production-safe Excel sheets..." -ForegroundColor Cyan

# --- STEP A: Create base sheet 'Machine_List' with filtered raw data
$Report | Export-Excel -Path $OutputPath -WorksheetName 'Machine_List' -ClearSheet

# --- STEP B: Place the 4-line metrics block on 'Summary Total' starting at Column D (Column 4)
# Added -TableStyle 'Medium2' and -AutoSize to make it visually match the blue Pivot Table style
$FleetSummary | Export-Excel -Path $OutputPath `
                             -WorksheetName 'Summary Total' `
                             -NoHeader:$false `
                             -StartColumn 4 `
                             -TableStyle 'Medium2' `
                             -AutoSize `
                             -ClearSheet

# --- STEP C: Insert summarized Pivot Table directly into 'Summary Total' tab
$Report | Export-Excel -Path $OutputPath `
                       -WorksheetName 'Machine_List' `
                       -PivotTableName 'Summary Total' `
                       -PivotRows @('InstalledBy', 'HotFixId') `
                       -PivotData @{ 'MachineName' = 'Count' }

# --- STEP D: Create sheet 'Summary Detailed' containing detailed Pivot Table (Asset Tags + Timestamps)
$Report | Export-Excel -Path $OutputPath `
                       -WorksheetName 'Machine_List' `
                       -PivotTableName 'Summary Detailed' `
                       -PivotRows @('InstalledBy', 'HotFixId', 'MachineName', 'InstalledOn') `
                       -PivotData @{ 'MachineName' = 'Count' } `
                       -Show

Write-Host "`n[SUCCESS] Production-safe Excel Workbook successfully generated with matching styles!" -ForegroundColor Green
Write-Host "File Output Path: $OutputPath" -ForegroundColor Green
