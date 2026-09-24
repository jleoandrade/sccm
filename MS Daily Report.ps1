# ==============================================================================
# --- PART 1: CONFIGURATION OF DIRECTORIES, SERVERS, AND DATES ---
# ==============================================================================
$SCCMServer     = "NJNWKSMS08V"
$SiteCode       = "A03"
$CollectionID   = "A03002CF"
$CurrentDate    = Get-Date -Format "dd-MM-yyyy"
$LocalExcelPath = "C:\Temp\SCCM_Collection_Members_${CurrentDate}.xlsx"

# Final Target Patch Report Setup
$ReportDirectory = "C:\Users\ServiceHLASMSWKS15\Desktop\Reports Month MS - Oficial\July x June - Comparison Report"
$DateToken       = Get-Date -Format "dd.MM.yy"
$DailyPatchFile  = Join-Path $ReportDirectory "July x June Workplace Daily Patch Report - ${DateToken}.xlsx"

# Remote Automation Network Report Setup (Source)
$SourceNetworkDir = "\\NJNWKSMS08V\D$\Automation\reports_sccm\"
$SourceDateToken  = Get-Date -Format "yyyy - MM"

# Search pattern targeting the network automation file
$SourceFilePattern = "Desktop Deployment - Enterprise Production - Windows - ${SourceDateToken} - All Desktop Clients (PCs) - Completo - *.xlsx"
$FullSourcePattern  = Join-Path $SourceNetworkDir $SourceFilePattern

# --- PREREQUISITE CHECK ---
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    Write-Host "Installing required Excel module locally..." -ForegroundColor Yellow
    Install-Module -Name ImportExcel -Scope CurrentUser -Force
}
Import-Module ImportExcel
Write-Host "Part 1 completed: Environment and configuration variables loaded." -ForegroundColor Green
# ==============================================================================
# --- PART 2: FILE LOCATION, REPLICATION, AND INITIAL WORKBOOK CLEANSING ---
# ==============================================================================
$LastFile = Get-ChildItem -Path $ReportDirectory -Filter "*.xlsx" | 
            Sort-Object LastWriteTime | 
            Select-Object -Last 1

if (-not $LastFile) {
    Throw "No Excel files found in the report directory to replicate."
}

Write-Host "Replicating latest file '${LastFile.Name}' to the new daily instance..." -ForegroundColor Cyan
Copy-Item -Path $LastFile.FullName -Destination $DailyPatchFile -Force

Write-Host "Opening target workbook stream to clear legacy content..." -ForegroundColor Yellow
$ExcelPackage = Open-ExcelPackage -Path $DailyPatchFile

# Clean 'Status' Worksheet (Preserve row 1 headers, clear from A2:O2 downwards)
$StatusWorksheet = $ExcelPackage.Workbook.Worksheets["status"]
if ($StatusWorksheet) {
    $MaxRowsStatus = $StatusWorksheet.Dimension.End.Row
    $MaxColsStatus = $StatusWorksheet.Dimension.End.Column
    
    if ($MaxRowsStatus -ge 2) {
        $LimitCol = [Math]::Max($MaxColsStatus, 15)
        for ($row = 2; $row -le $MaxRowsStatus; $row++) {
            for ($col = 1; $col -le $LimitCol; $col++) {
                $StatusWorksheet.Cells[$row, $col].Value = $null
            }
        }
    }
}

# Completely purge data cells from 'error', 'in progress', and 'unknown' sheets
$TabsToClear = @("error", "in progress", "unknown")
foreach ($Tab in $TabsToClear) {
    $Worksheet = $ExcelPackage.Workbook.Worksheets[$Tab]
    if ($Worksheet) {
        $MaxRows = $Worksheet.Dimension.End.Row
        $MaxCols = $Worksheet.Dimension.End.Column
        
        if ($MaxRows -and $MaxCols) {
            for ($row = 1; $row -le $MaxRows; $row++) {
                for ($col = 1; $col -le $MaxCols; $col++) {
                    $Worksheet.Cells[$row, $col].Value = $null
                }
            }
        }
    }
}

# Save and release file locks to avoid intermitent Export-Excel sharing violations
Close-ExcelPackage -ExcelPackage $ExcelPackage
Write-Host "Part 2 completed: Daily patch report created and staging areas cleared." -ForegroundColor Green
# ==============================================================================
# --- PART 3: REMOTE INVOCATION AND SCCM COLLECTION DATA GATHERING ---
# ==============================================================================
Write-Host "Connecting to server $SCCMServer to fetch live inventory dataset..." -ForegroundColor Cyan

$RemoteData = Invoke-Command -ComputerName $SCCMServer -ScriptBlock {
    param($SiteCode, $CollectionID)
    
    $global:CMPSSuppressFastNotUsedCheck = $true
    $WarningPreference = "SilentlyContinue"
    
    $ModulePath = "D:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"
    Import-Module $ModulePath -ErrorAction SilentlyContinue
    
    Set-Location "${SiteCode}:"
    
    $Devices = Get-CMDevice -CollectionId $CollectionID -Fast
    
    $Devices | Select-Object `
        @{Name="Device";                 Expression={$_.Name}},
        @{Name="Client type";            Expression={if($_.ClientType -eq 1){"Computer"}else{"Other"}}},
        @{Name="Client";                 Expression={if($_.IsClient){"Yes"}else{"No"}}},
        @{Name="Current logged on user"; Expression={$_.LastLogonUser}},
        @{Name="Site code";              Expression={$_.SiteCode}},
        @{Name="Client activity";        Expression={if($_.IsActive){"Active"}else{"Inactive"}}},
        @{Name="AD Site";                Expression={$_.ADSiteName}},
        @{Name="Device status";          Expression={if($_.CNIsOnline){"Online"}else{"Offline"}}},
        @{Name="Domain";                 Expression={$_.Domain}},
        @{Name="Last online time";       Expression={if($_.CNLastOnlineTime){$_.CNLastOnlineTime.ToString("M/d/yyyy H:mm")}else{""}}},
        @{Name="OS build number";        Expression={$_.ClientVersion}},
        @{Name="Pending restart";        Expression={if($_.IsClientRestartPending){"Yes"}else{"No"}}}
} -ArgumentList $SiteCode, $CollectionID

Write-Host "Part 3 completed: SCCM remote collection data extraction finished." -ForegroundColor Green
# ==============================================================================
# --- PART 4: LOCAL EXTRACTION BACKUP AND STATUS SHEET POPULATION ---
# ==============================================================================
if ($RemoteData) {
    Write-Host "Filtering out session wrapper metadata from the remote payload..." -ForegroundColor Cyan
    
    $LocalFolder = Split-Path $LocalExcelPath
    if (-not (Test-Path $LocalFolder)) {
        New-Item -ItemType Directory -Path $LocalFolder -Force | Out-Null
    }

    # Eliminate default PowerShell remote execution metadata tracking fields
    $CleanData = $RemoteData | Select-Object * -ExcludeProperty PS* , RunspaceId

    # Export a raw snapshot copy to local C:\Temp staging root
    $CleanData | Export-Excel -Path $LocalExcelPath -WorksheetName "SCCM Collection Members" -AutoSize -AutoFilter -ClearSheet
    Write-Host "Success! Local raw dataset backup written to: $LocalExcelPath" -ForegroundColor Green

    # Inject cleaned dataset arrays directly onto row 2 of the daily target report
    Write-Host "Injecting live dataset onto target 'Status' worksheet..." -ForegroundColor Cyan
    if (Test-Path $DailyPatchFile) {
        $CleanData | Export-Excel -Path $DailyPatchFile -WorksheetName "Status" -StartRow 2 -NoHeader -AutoSize
        Write-Host "Part 4 completed: Worksheet 'Status' successfully populated." -ForegroundColor Green
    } else {
        Write-Warning "Target file reference dead-end: $DailyPatchFile"
    }
} else {
    Write-Warning "Zero arrays returned from the remote infrastructure endpoint. Aborting data injection."
}
# ==============================================================================
# --- PART 5: NETWORK SCANNING, METADATA STRIPPING, AND DYNAMIC VLOOKUP ---
# ==============================================================================
if ($RemoteData) { 
    Write-Host "Scanning network path to target the absolute newest automation report..." -ForegroundColor Cyan
    
    $ResolvedSourceFile = Get-ChildItem -Path $FullSourcePattern -ErrorAction SilentlyContinue | 
                          Sort-Object LastWriteTime -Descending | 
                          Select-Object -First 1

    if ($ResolvedSourceFile) {
        Write-Host "Target matched! Importing arrays from network node: $($ResolvedSourceFile.Name)" -ForegroundColor Green
        
        # Address variation handling for "In progress" sheet casing or padding
        $TargetSheets = Get-ExcelSheetInfo -Path $DailyPatchFile
        $InProgTargetName = $TargetSheets.Name | Where-Object { $_ -match "^In\s?progress$" } | Select-Object -First 1
        if (-not $InProgTargetName) { $InProgTargetName = "In progress" }

        # Pull matrices from network automation source file skipping initial padding
        $ErrorData      = Import-Excel -Path $ResolvedSourceFile.FullName -WorksheetName "Error" -StartRow 3 -EndColumn 8
        $InProgressData = Import-Excel -Path $ResolvedSourceFile.FullName -WorksheetName "In progress" -StartRow 3 -EndColumn 7
        $UnknownData    = Import-Excel -Path $ResolvedSourceFile.FullName -WorksheetName "Unknown" -StartRow 3 -EndColumn 7

        # Overwrite internal data blocks inside our clean target daily workbook instance
        if ($ErrorData) { $ErrorData | Export-Excel -Path $DailyPatchFile -WorksheetName "Error" -StartRow 1 -ClearSheet -AutoSize }
        if ($InProgressData) { $InProgressData | Export-Excel -Path $DailyPatchFile -WorksheetName $InProgTargetName -StartRow 1 -ClearSheet -AutoSize }
        if ($UnknownData) { $UnknownData | Export-Excel -Path $DailyPatchFile -WorksheetName "Unknown" -StartRow 1 -ClearSheet -AutoSize }

        # Establish direct COM-like open streaming session to perform physical row drops
        $ExcelPackage = Open-ExcelPackage -Path $DailyPatchFile

        $TargetTabs = @("Error", $InProgTargetName, "Unknown")
        foreach ($TabName in $TargetTabs) {
            $SheetObject = $ExcelPackage.Workbook.Worksheets[$TabName]
            if ($SheetObject) {
                Write-Host "Stripping duplicated row 1 layout template from: $TabName" -ForegroundColor Magenta
                $SheetObject.DeleteRow(1)
            }
        }

        # --- DYNAMIC VLOOKUP FORMULA INJECTION ENGINE ---
        Write-Host "Deploying real-time VLOOKUP arrays onto the master 'Status' tracking layer..." -ForegroundColor Cyan
        $StatusSheet = $ExcelPackage.Workbook.Worksheets["Status"]
        
        if ($StatusSheet) {
            # Build operational metadata labels on tracking columns M, N, and O
            $StatusSheet.Cells["M1"].Value = "Error LookUp"
            $StatusSheet.Cells["N1"].Value = "In Progress LookUp"
            $StatusSheet.Cells["O1"].Value = "Unknown LookUp"

            # Compute formula range scope matches based on Part 4 inventory volume count
            $StartRow = 2
            $EndRow   = $StartRow + ($CleanData.Count - 1)

            if ($CleanData.Count -gt 0) {
                Write-Host "Writing VLOOKUP strings dynamically from row $StartRow to row $EndRow..." -ForegroundColor Magenta
                for ($i = $StartRow; $i -le $EndRow; $i++) {
                    $StatusSheet.Cells["M$i"].Formula = "=VLOOKUP(A$i,Error!A:G,7,0)"
                    $StatusSheet.Cells["N$i"].Formula = "=VLOOKUP(A$i,'$InProgTargetName'!A:E,5,0)"
                    $StatusSheet.Cells["O$i"].Formula = "=VLOOKUP(A$i,Unknown!A:E,5,0)"
                }
            }
        }

        # Save updates and flush active Excel file streaming cache handle
        Close-ExcelPackage -ExcelPackage $ExcelPackage
        Write-Host "Part 5 completed: Data links attached and formulas bound successfully!" -ForegroundColor Green
        Write-Host "AUTOMATION PROCESS FULLY EXECUTED CONCLUDED!" -ForegroundColor Green
    } else {
        Write-Warning "No matching network files found within the targeted node: $SourceNetworkDir"
    }
}
