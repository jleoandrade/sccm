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

# 3. Safe Query: Fetch only core identification data from the Collection view
Write-Host "Fetching fleet machines from Collection ID $CollectionID..." -ForegroundColor Cyan
$QueryColl = "SELECT ResourceID, Name FROM SMS_CM_RES_COLL_$CollectionID"
$CollectionMembers = Get-CimInstance -ComputerName $SiteServer -Namespace $Namespace -Query $QueryColl -ErrorAction Stop

# 3.2 Fetch Extended User Discovery attributes safely from the primary System class
Write-Host "Fetching user discovery relationships from system records..." -ForegroundColor Cyan
$QuerySys = "SELECT ResourceID, LastLogonUserDomain, LastLogonUserName FROM SMS_R_System"
$Systems = Get-CimInstance -ComputerName $SiteServer -Namespace $Namespace -Query $QuerySys -ErrorAction Stop

# Memory lookup hashtables for ultra-fast relational mapping
$CollectionLookup   = @{}
foreach ($Member in $CollectionMembers) {
    $CollectionLookup[$Member.ResourceID] = $Member.Name
}

$UserDomainLookup   = @{}
$UserNameLookup     = @{}
foreach ($Sys in $Systems) {
    if (-not [string]::IsNullOrWhiteSpace($Sys.LastLogonUserName)) {
        $UserDomainLookup[$Sys.ResourceID] = $Sys.LastLogonUserDomain
        $UserNameLookup[$Sys.ResourceID]   = $Sys.LastLogonUserName
    }
}

# 4. Filter, clean fields, and dynamically translate service accounts
$PatchedResourceIDs = @{}
$Report = $HotFixes | ForEach-Object {
    if ($CollectionLookup.ContainsKey($_.ResourceID)) {
        
        # Track which machines have at least one patch
        $PatchedResourceIDs[$_.ResourceID] = $true

        # Naming logic: Translate explicit naming architectures cleanly matching your screenshot
        $Installer = $_.InstalledBy
        if ([string]::IsNullOrWhiteSpace($Installer)) { 
            $Installer = "Built-in the Image" 
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

# --- IDENTIFY EXACT MISSING MACHINES WITH LOGGED USER DATA ---
$MissingMachinesList = foreach ($Member in $CollectionMembers) {
    if (-not $PatchedResourceIDs.ContainsKey($Member.ResourceID)) {
        
        $Domain   = if ($UserDomainLookup.ContainsKey($Member.ResourceID)) { $UserDomainLookup[$Member.ResourceID] } else { $null }
        $Username = if ($UserNameLookup.ContainsKey($Member.ResourceID)) { $UserNameLookup[$Member.ResourceID] } else { $null }
        
        # Format clean User field string (DOMAIN\Username) or placeholder if unassigned
        $AccountName = if (-not [string]::IsNullOrWhiteSpace($Username)) { "$Domain\$Username" } else { "No Logged User" }
        $CleanName   = if (-not [string]::IsNullOrWhiteSpace($Username)) { $Username } else { "Unknown" }
        $UserEmail   = if (-not [string]::IsNullOrWhiteSpace($Username)) { "$($Username.ToLower())@enterprise.com" } else { "N/A" }
        
        [PSCustomObject]@{
            MachineName = $Member.Name
            User        = $AccountName
            Name        = $CleanName
            Email       = $UserEmail
            Status      = "Missing Updates"
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
$OutputPath = "C:\Users\ServiceHLASMSWKS15\Desktop\Reports Month MS - Oficial\Manual Installation x SCCM\Collection_Report_SCCM_Installations_$TimeStamp.xlsx"

if (-not (Test-Path "C:\Users\ServiceHLASMSWKS15\Desktop\Reports Month MS - Oficial\Manual Installation x SCCM\")) { New-Item -ItemType Directory -Path "C:\Users\ServiceHLASMSWKS15\Desktop\Reports Month MS - Oficial\Manual Installation x SCCM\" | Out-Null }

Write-Host "Generating production-safe Excel sheets..." -ForegroundColor Cyan

# --- STEP A: Create base sheet 'Machine_List' with filtered raw data
$Report | Export-Excel -Path $OutputPath -WorksheetName 'Machine_List' -ClearSheet

# --- STEP B: Place the 4-line metrics block on 'Summary Total' starting at Column D (Column 4)
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
                       -PivotData @{ 'MachineName' = 'Count' }

# --- STEP E: Export the list of unpatched machines containing detailed User, Name, and Email attributes
$MissingMachinesList | Export-Excel -Path $OutputPath `
                                    -WorksheetName 'Missing_KBs' `
                                    -TableStyle 'Medium4' `
                                    -AutoSize `
                                    -Show

Write-Host "`n[SUCCESS] Production-safe Excel Workbook successfully generated with user contacts!" -ForegroundColor Green
Write-Host "File Output Path: $OutputPath" -ForegroundColor Green
