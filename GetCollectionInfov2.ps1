# --- USER CONFIGURATION ---
$SCCMServer   = "NJNWKSMS08v"
$SiteCode     = "A03"
$CollectionID = "A03002CF"
$CurrentDate  = Get-Date -Format "dd-MM-yyyy"
# Saved with .xlsx extension to natively support AutoFit column widths
$LocalExcelPath = "C:\Temp\SCCM_Collection_Members_${CurrentDate}.xlsx"

# --- PREREQUISITE CHECK ---
# Installs the ImportExcel module locally only if it is missing (does not require Admin rights)
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    Write-Host "Installing required Excel module locally..." -ForegroundColor Yellow
    Install-Module -Name ImportExcel -Scope CurrentUser -Force
}

# --- REMOTE EXECUTION ---
Write-Host "Connecting to server $SCCMServer and extracting data..." -ForegroundColor Cyan

$RemoteData = Invoke-Command -ComputerName $SCCMServer -ScriptBlock {
    param($SiteCode, $CollectionID)
    
    # Suppress lazy property warnings and quiet the console
    $global:CMPSSuppressFastNotUsedCheck = $true
    $WarningPreference = "SilentlyContinue"
    
    # Direct path to the module on the server's local D: drive
    $ModulePath = "D:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"
    Import-Module $ModulePath -ErrorAction SilentlyContinue
    
    # Navigate to the SCCM site drive
    Set-Location "${SiteCode}:"
    
    # Ultra-fast device retrieval filtered directly by Collection ID
    $Devices = Get-CMDevice -CollectionId $CollectionID -Fast
    
    # Process and format data on the server to prevent property loss during network transfer
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

# --- LOCAL EXCEL EXPORT ---
if ($RemoteData) {
    Write-Host "Processing received data..." -ForegroundColor Cyan
    
    # Automatically create the local folder if it does not exist
    $LocalFolder = Split-Path $LocalExcelPath
    if (-not (Test-Path $LocalFolder)) {
        New-Null = New-Item -ItemType Directory -Path $LocalFolder -Force
    }

    # REMOVE METADATA: Discards implicit remote session variables (PSComputerName, RunspaceId)
    $CleanData = $RemoteData | Select-Object * -ExcludeProperty PS* , RunspaceId

    # Exports directly to XLSX applying absolute AutoFit (-AutoSize) and header dropdown targets (-AutoFilter)
    $CleanData | Export-Excel -Path $LocalExcelPath -WorksheetName "SCCM Collection Members" -AutoSize -AutoFilter -ClearSheet

    Write-Host "Success! Excel file with AutoFit saved to: $LocalExcelPath" -ForegroundColor Green
} else {
    Write-Warning "No data was returned from the remote server."
}
