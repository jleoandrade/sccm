# --- CONFIGURATION ---
$SCCMServer   = "NJNWKSMS08V"
$SiteCode     = "A03"
$CollectionID = "A03002CF"
$LocalCSVPath = "C:\Temp\SCCM_Collection_Membersv3.csv"

# --- REMOTE EXECUTION ---
Write-Host "Fetching data remotely..." -ForegroundColor Cyan

$RemoteData = Invoke-Command -ComputerName $SCCMServer -ScriptBlock {
    param($SiteCode, $CollectionID)
    Import-Module (Join-Path $env:SMS_ADMIN_UI_PATH "\..\ConfigurationManager.psd1") -ErrorAction SilentlyContinue
    Set-Location "$($SiteCode):"
    
    # Querying Get-CMDevice directly with -CollectionId is extremely fast
    Get-CMDevice -CollectionId $CollectionID -Fast
} -ArgumentList $SiteCode, $CollectionID

# --- LOCAL CSV EXPORT ---
if ($RemoteData) {
    $RemoteData | Select-Object `
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
        @{Name="Pending restart";        Expression={if($_.IsClientRestartPending){"Yes"}else{"No"}}} | 
        Export-Csv -Path $LocalCSVPath -NoTypeInformation -Encoding UTF8 -Delimiter ";"

    Write-Host "Done! File saved to $LocalCSVPath" -ForegroundColor Green
}
