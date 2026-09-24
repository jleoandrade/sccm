# --- PROCESS ARCHITECTURE FORCE RE-RUN ---
# Forces the script to run as 64-bit if executed from a 32-bit (SysWOW64) window
if ($env:Processor_Architecture -eq "x86") {
    & "$env:windir\sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File $MyInvocation.MyCommand.Path -ExecutionPolicy Bypass
    exit
}

# --- USER CONFIGURATION ---
$SCCMServer   = "NJNWKSMS08V"
$SiteCode     = "A03"
$CollectionID = "A03002CF"
# Adds the current date in YYYY-MM-DD format to the file name
$CurrentDate  = Get-Date -Format "yyyy-MM-dd"
$LocalCSVPath = "C:\Temp\MissingKB_${CurrentDate}.csv"

# Ensures the C:\Temp directory exists before exporting
if (-not (Test-Path "C:\Temp")) {
    New-Item -ItemType Directory -Path "C:\Temp" -Force | Out-Null
}

# --- REMOTE EXECUTION ---
Write-Host "Connecting to server $SCCMServer and extracting data via 64-bit environment..." -ForegroundColor Cyan

$RemoteData = Invoke-Command -ComputerName $SCCMServer -ScriptBlock {
    param($SiteCode, $CollectionID)
    
    $WarningPreference = "SilentlyContinue"
    
    # Direct path to the module on the server's local D: drive
    $ModulePath = "D:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"
    Import-Module $ModulePath -ErrorAction SilentlyContinue
    
    # Navigate to the SCCM site drive to initialize the provider context
    Set-Location "$($SiteCode):"
    
    # Retrieve base devices belonging to the requested collection
    $Devices = Get-CMDevice -CollectionId $CollectionID
    if (-not $Devices) { return $null }

    # Array to compile combined attributes
    $ReportCollection = @()

    foreach ($Device in $Devices) {
        # Instantly fetch the real hardware inventory OS Version string (includes sub-build mappings)
        $OSInfo = Get-CMDeviceVariable -DeviceName $Device.Name | Where-Object { $_.Name -eq "OSVersion" }
        
        # Alternative native WMI mapping block to secure full Build revisions safely
        $WqlQuery = "SELECT Version FROM SMS_G_System_OPERATING_SYSTEM WHERE ResourceID = '$($Device.ResourceID)'"
        $LiveOS = Invoke-CMWmiQuery -Query $WqlQuery | Select-Object -First 1

        $ReportCollection += [PSCustomObject]@{
            Device                 = $Device.Name
            ClientType             = $Device.ClientType
            IsClient               = $Device.IsClient
            LastLogonUser          = $Device.LastLogonUser
            SiteCode               = $Device.SiteCode
            IsActive               = $Device.IsActive
            ADSiteName             = $Device.ADSiteName
            CNIsOnline             = $Device.CNIsOnline
            Domain                 = $Device.Domain
            CNLastOnlineTime       = $Device.CNLastOnlineTime
            OSBuild                = if ($LiveOS.Version) { $LiveOS.Version } else { $Device.OSVersion }
            IsClientRestartPending = $Device.IsClientRestartPending
        }
    }
    
    return $ReportCollection
} -ArgumentList $SiteCode, $CollectionID

# --- LOCAL CSV EXPORT ---
if ($RemoteData) {
    Write-Host "Processing received data layers..." -ForegroundColor Cyan
    
    # Formats and exports data with your precise English headers
    $RemoteData | Select-Object `
        @{Name="Device";                 Expression={$_.Device}},
        @{Name="Client type";            Expression={if($_.ClientType -eq 1){"Computer"}else{"Other"}}},
        @{Name="Client";                 Expression={if($_.IsClient){"Yes"}else{"No"}}},
        @{Name="Current logged on user"; Expression={$_.LastLogonUser}},
        @{Name="Site code";              Expression={$_.SiteCode}},
        @{Name="Client activity";        Expression={if($_.IsActive){"Active"}else{"Inactive"}}},
        @{Name="AD Site";                Expression={$_.ADSiteName}},
        @{Name="Device status";          Expression={if($_.CNIsOnline){"Online"}else{"Offline"}}},
        @{Name="Domain";                 Expression={$_.Domain}},
        @{Name="Last online time";       Expression={if($_.CNLastOnlineTime){$_.CNLastOnlineTime.ToString("M/d/yyyy H:mm")}else{""}}},
        @{Name="Operating System Build"; Expression={$_.OSBuild}}, 
        @{Name="Pending restart";        Expression={if($_.IsClientRestartPending){"Yes"}else{"No"}}} | 
        Export-Csv -Path $LocalCSVPath -NoTypeInformation -Encoding UTF8 -Delimiter ";"

    Write-Host "Success! File saved cleanly to: $LocalCSVPath" -ForegroundColor Green
} else {
    Write-Warning "No data was returned from the remote server."
}
