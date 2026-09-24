# 1. Settings
$SiteCode = "A03" # Your Site Code
$ProviderMachine = "NJNWKSMS08V" # Your Site Server FQDN
$Collections = @(
    'PC Type - Desktops - Enterprise',
    'PC Type - Laptops - Enterprise',
    'PC Type - Tablets - Enterprise',
    'All MDT WorkStation Client Installed'
)

# 2. Module and Drive Setup
if (!(Get-Module -Name ConfigurationManager)) {
    Import-Module "$($Env:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1"
}
if (!(Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name $SiteCode -PSProvider "CMSite" -Root $ProviderMachine
}
Set-Location "$($SiteCode):"

$DetailedList = @()
$SummaryList = @()

# 3. Data Collection Logic
foreach ($CollName in $Collections) {
    Write-Host "Fetching data from: $CollName" -ForegroundColor Cyan
    $Devices = Get-CMDevice -CollectionName $CollName
    
    # Define Client Type mapping (same as SQL CASE)
    $ClientType = switch -Wildcard ($CollName) {
        "*Desktops*" { "Desktop" }
        "*Laptops*"  { "Laptop" }
        "*Tablets*"  { "Tablet" }
        "All MDT WorkStation Client Installed" { "MDT" }
        Default { "Other" }
    }

    # Summary Record (SortOrder 0 logic)
    $SummaryList += [PSCustomObject]@{
        'Collection Name'        = "--- SUMMARY ---"
        'Machine Name'           = ($Devices.Count).ToString()
        'Client Type'            = $ClientType
        'Client'                 = $null
        'Primary User(s)'        = $null
        'Current Logged on User' = $null
        'Site Code'              = $null
        'Client Activity'        = $null
    }

    # Detailed Records (SortOrder 1 logic)
    foreach ($Device in $Devices) {
        $DetailedList += [PSCustomObject]@{
            'Collection Name'        = $CollName
            'Machine Name'           = $Device.Name
            'Client Type'            = $ClientType
            'Client'                 = if($Device.IsClient) { "Yes" } else { "No" }
            'Primary User(s)'        = if($Device.PrimaryUser) { $Device.PrimaryUser } else { "No Primary User" }
            'Current Logged on User' = $Device.UserName
            'Site Code'              = $Device.SiteCode
            'Client Activity'        = if($Device.ClientActiveStatus -eq 1) { "Active" } else { "Inactive" }
        }
    }
}

# 4. Final Result (Summary first, then sorted details)
$FinalReport = $SummaryList + ($DetailedList | Sort-Object 'Collection Name', 'Machine Name')

# 5. Export/Display
$FinalReport | Out-GridView -Title "Enterprise & MDT Inventory Report"
# $FinalReport | Export-Csv -Path "C:\Reports\Inventory.csv" -NoTypeInformation
