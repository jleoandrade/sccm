# ==============================================================================
# --- PART 1: CONFIGURATION OF DIRECTORIES, SERVERS, AND DATES ---
# ==============================================================================
$SCCMServer     = "NJNWKSMS08V"
$SiteCode       = "A03"
$CollectionID   = "A03002CF"
$CurrentDate    = Get-Date -Format "dd-MM-yyyy"
$LocalExcelPath = "C:\Temp\SCCM_Collection_Members_${CurrentDate}.xlsx"

# Final Target Patch Report Setup
$ReportDirectory = "\\Njnwksmp0001v\d$\Reports Month MS - Oficial\Aug x July - Comparison Report"
$DateToken       = Get-Date -Format "dd.MM.yy"
$DailyPatchFile  = Join-Path $ReportDirectory "Aug x Jul Workplace Daily Patch Report - ${DateToken}.xlsx"

# Remote Automation Network Report Setup (Source)
$SourceNetworkDir = "\\NJNWKSMS08V\d$\Automation\reports_sccm\exports"

# Targets TODAY's generated file stamp (e.g., Aug-4)
$TargetMonthName  = Get-Date -Format "MMM"
$TargetDayNumber  = (Get-Date).Day

# One continuous line matching explicitly the target generation string pattern
$SourceFilePattern = "Desktop Deployment - Enterprise Production - Windows - * - * - *Desktop and MDT Clients* - Completo - ${TargetMonthName}-${TargetDayNumber} - *.xlsx"
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

# Clean 'status' Worksheet (Preserve row 1 headers, clear everything below row 2)
$StatusWorksheet = $ExcelPackage.Workbook.Worksheets["status"]
if ($StatusWorksheet -and $StatusWorksheet.Dimension) {
    $MaxRowsStatus = $StatusWorksheet.Dimension.End.Row
    if ($MaxRowsStatus -ge 2) {
        $StatusWorksheet.DeleteRow(2, ($MaxRowsStatus - 1))
    }
}

# Completely purge data cells from 'error', 'in progress', and 'unknown' sheets
$TabsToClear = @("error", "in progress", "unknown")
foreach ($Tab in $TabsToClear) {
    $Worksheet = $ExcelPackage.Workbook.Worksheets[$Tab]
    if ($Worksheet -and $Worksheet.Dimension) {
        $MaxRows = $Worksheet.Dimension.End.Row
        $Worksheet.DeleteRow(1, $MaxRows)
    }
}

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
    
    if (-not (Test-Path -Path $ModulePath)) {
        Throw "SCCM PowerShell module not found at specified path: $ModulePath"
    }
    
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
        @{Name="Last online time";       Expression={if($_.CNLastOnlineTime){[DateTime]$_.CNLastOnlineTime | Get-Date -Format "M/d/yyyy H:mm"}else{""}}},
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

    $CleanData = $RemoteData | Select-Object * -ExcludeProperty PS* , RunspaceId
    $CleanData | Export-Excel -Path $LocalExcelPath -WorksheetName "SCCM Collection Members" -AutoSize -AutoFilter -ClearSheet
    Write-Host "Success! Local raw dataset backup written to: $LocalExcelPath" -ForegroundColor Green
    
    Write-Host "Injecting live dataset onto target 'status' worksheet..." -ForegroundColor Cyan
    if (Test-Path $DailyPatchFile) {
        
        $ExcelPackage = Open-ExcelPackage -Path $DailyPatchFile
        $StatusSheet  = $ExcelPackage.Workbook.Worksheets["status"]
        
        if ($StatusSheet -and $StatusSheet.Dimension) {
            $MaxCols = $StatusSheet.Dimension.End.Column
            $Headers = for ($col = 1; $col -le $MaxCols; $col++) { $StatusSheet.Cells[1, $col].Value }
            Close-ExcelPackage -ExcelPackage $ExcelPackage
            
            $AlignedData = $CleanData | Select-Object $Headers
            $AlignedData | Export-Excel -Path $DailyPatchFile -WorksheetName "status" -StartRow 2 -NoHeader
            Write-Host "Part 4 completed: Worksheet 'status' successfully populated." -ForegroundColor Green
        } else {
            Close-ExcelPackage -ExcelPackage $ExcelPackage
            $CleanData | Export-Excel -Path $DailyPatchFile -WorksheetName "status" -StartRow 2 -NoHeader
        }
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
    Write-Host "Validating and refreshing active network share connectivity..." -ForegroundColor Cyan
    
    if (-not (Test-Path -Path $SourceNetworkDir)) {
        Write-Warning "Network node locked or sleeping. Initializing direct pipeline wake-up..."
        cmd.exe /c "dir `"$SourceNetworkDir`"" > $null
    }

    Write-Host "Scanning network path to target the absolute newest automation report..." -ForegroundColor Cyan
    
    $ResolvedSourceFile = Get-ChildItem -Path $SourceNetworkDir -Filter $SourceFilePattern -ErrorAction SilentlyContinue | 
                          Sort-Object LastWriteTime -Descending | 
                          Select-Object -First 1

    if ($ResolvedSourceFile) {
        Write-Host "Target matched! Importing arrays from network node: $($ResolvedSourceFile.Name)" -ForegroundColor Green
        
        $TargetSheets = Get-ExcelSheetInfo -Path $DailyPatchFile
        $InProgTargetName = $TargetSheets.Name | Where-Object { $_ -match "^In\s?progress$" } | Select-Object -First 1
        if (-not $InProgTargetName) { $InProgTargetName = "In progress" }

        $ErrorData      = Import-Excel -Path $ResolvedSourceFile.FullName -WorksheetName "Error" -StartRow 3 -EndColumn 8
        $InProgressData = Import-Excel -Path $ResolvedSourceFile.FullName -WorksheetName "In progress" -StartRow 3 -EndColumn 7
        $UnknownData    = Import-Excel -Path $ResolvedSourceFile.FullName -WorksheetName "Unknown" -StartRow 3 -EndColumn 7

        if ($ErrorData) { $ErrorData | Export-Excel -Path $DailyPatchFile -WorksheetName "Error" -StartRow 1 -ClearSheet -AutoSize }
        if ($InProgressData) { $InProgressData | Export-Excel -Path $DailyPatchFile -WorksheetName $InProgTargetName -StartRow 1 -ClearSheet -AutoSize }
        if ($UnknownData) { $UnknownData | Export-Excel -Path $DailyPatchFile -WorksheetName "Unknown" -StartRow 1 -ClearSheet -AutoSize }

        $ExcelPackage = Open-ExcelPackage -Path $DailyPatchFile

        $TargetTabs = @("Error", $InProgTargetName, "Unknown")
        foreach ($TabName in $TargetTabs) {
            $SheetObject = $ExcelPackage.Workbook.Worksheets[$TabName]
            if ($SheetObject -and $SheetObject.Dimension) {
                Write-Host "Stripping duplicated row 1 layout template from: $TabName" -ForegroundColor Magenta
                $SheetObject.DeleteRow(1)
            }
        }

        # --- SAFE VLOOKUP FORMULA INJECTION ENGINE ---
        Write-Host "Deploying real-time VLOOKUP arrays onto the master 'status' tracking layer..." -ForegroundColor Cyan
        $StatusSheet = $ExcelPackage.Workbook.Worksheets["status"]
        
        if ($StatusSheet) {
            $StatusSheet.Cells["M1"].Value = "Error LookUp"
            $StatusSheet.Cells["N1"].Value = "In Progress LookUp"
            $StatusSheet.Cells["O1"].Value = "Unknown LookUp"

            $StartRow = 2
            $TotalRows = $CleanData.Count

            if ($TotalRows -gt 0) {
                $EndRow = $StartRow + ($TotalRows - 1)
                Write-Host "Writing VLOOKUP formulas to active evaluation layer..." -ForegroundColor Magenta
                
                # FIX: Utilizing the explicit .Formula property enables Excel engine compilation
                # Added the dynamic implicit intersection prefix (@) as requested
                for ($i = $StartRow; $i -le $EndRow; $i++) {
                    $StatusSheet.Cells["M$i"].Formula = "=VLOOKUP(@A:A,Error!A:G,7,0)"
                    $StatusSheet.Cells["N$i"].Formula = "=VLOOKUP(@A:A,'$InProgTargetName'!A:E,5,0)"
                    $StatusSheet.Cells["O$i"].Formula = "=VLOOKUP(@A:A,Unknown!A:E,5,0)"
                }
            }
        }

        Close-ExcelPackage -ExcelPackage $ExcelPackage
        Write-Host "Part 5 completed: Data links attached and formulas bound successfully!" -ForegroundColor Green
        Write-Host "AUTOMATION PROCESS FULLY EXECUTED AND CONCLUDED!" -ForegroundColor Green
    } else {
        Write-Error "CRITICAL: No matching network files found for pattern [ $SourceFilePattern ] inside: $SourceNetworkDir"
    }
}
