# 1. Initial Configurations
$SiteCode = "A03" # Change to your Site Code
$ProviderMachineName = "NJNWKSMS08V" # Change to your Site Server FQDN
$CollectionNames = @('PC Type - Desktops - NBU', 'PC Type - Laptops - NBU', 'PC Type - Tablets - NBU')
a
# 2. Import SCCM Module and Connect to Site Drive
if (!(Get-Module -Name ConfigurationManager)) {
    $ModulePath = "$($Env:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1"
    Import-Module $ModulePath
}

# Ensure we are in the SCCM Site Drive
if ((Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue) -eq $null) {
    New-PSDrive -Name $SiteCode -PSProvider "CMSite" -Root $ProviderMachineName -Description "SCCM Site"
}
Set-Location "$($SiteCode):"

$FullReport = @()
$Summary = @()

# 3. Data Processing
foreach ($CollName in $CollectionNames) {
    Write-Host "Processing Collection: $CollName..." -ForegroundColor Cyan
    
    # Get members of the collection
    $Devices = Get-CMDevice -CollectionName $CollName
    
    # Determine Device Type based on Collection Name
    $Type = if($CollName -like "*Desktops*") { "Desktop" } elseif($CollName -like "*Laptops*") { "Laptop" } else { "Tablet" }
    
    # Summary Part (Mimicking SortOrder 0)
    $Summary += [PSCustomObject]@{
        'Collection Name'       = "--- SUMMARY ---"
        'Machine Name'          = ($Devices.Count)
        'Type'                  = $Type
        'Client'                = $null
        'Primary User(s)'       = $null
        'Current Logged on User'= $null
        'Site Code'             = $null
        'Client Activity'       = $null
    }

    # Detailed Part (Mimicking SortOrder 1)
    foreach ($Device in $Devices) {
        $FullReport += [PSCustomObject]@{
            'Collection Name'       = $CollName
            'Machine Name'          = $Device.Name
            'Type'                  = $Type
            'Client'                = if($Device.IsClient) { "Yes" } else { "No" }
            'Primary User(s)'       = $Device.PrimaryUser
            'Current Logged on User'= $Device.UserName
            'Site Code'             = $Device.SiteCode
            'Client Activity'       = if($Device.ClientActiveStatus -eq 1) { "Active" } else { "Inactive" }
        }
    }
}

# 4. Unify and Sort
# We place Summary objects first, then sorted details
$FinalOutput = $Summary + ($FullReport | Sort-Object 'Collection Name', 'Machine Name')

# 5. Output Results
$FinalOutput | Out-GridView -Title "NBU Inventory Report"

# Optional: Export to CSV
# $FinalOutput | Export-Csv -Path "C:\Temp\NBU_Inventory_Report.csv" -NoTypeInformation -Encoding UTF8
