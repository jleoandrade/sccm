# ================================
# AUTOMATICALLY DETECT PROVIDER AND SITE CODE
# ================================
$providerInfo = Get-WmiObject -Namespace "root\sms" -Class SMS_ProviderLocation | Select-Object -First 1
$Provider = $providerInfo.Machine
$Namespace = $providerInfo.NamespacePath
$SiteCode = ($Namespace -split "_")[-1]

Write-Host "Detected SMS Provider: $Provider" -ForegroundColor Cyan
Write-Host "Detected Site Code: $SiteCode" -ForegroundColor Cyan

# ================================
# LOAD SCCM MODULE (LOCAL)
# ================================
Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1"
Set-Location "$SiteCode`:"

# ================================
# TARGET COLLECTION
# ================================
$CollectionName = "All Desktop and MDT Clients - 30 day Communication Missing KB February 2026"

Write-Host "`nLoading devices from collection: $CollectionName" -ForegroundColor Cyan

$devices = Get-CMDevice -CollectionName $CollectionName

if (-not $devices) {
    Write-Host "No devices found in the collection." -ForegroundColor Yellow
    return
}

Write-Host "Found $($devices.Count) devices." -ForegroundColor Green

# ================================
# KB LIST
# ================================
$KBList = "KB5078883","KB5079473","KB5043080"

# ================================
# PROCESS EACH DEVICE
# ================================
foreach ($dev in $devices) {

    $ComputerName = $dev.Name
    Write-Host "`n=== Checking $ComputerName ===" -ForegroundColor Cyan

    # Test remote connectivity
    if (-not (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet)) {
        Write-Host "Machine unreachable. Skipping." -ForegroundColor Yellow
        continue
    }

    # Check KBs remotely
    $kbInstalled = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
        param($KBList)
        foreach ($k in $KBList) {
            if (Get-HotFix -Id $k -ErrorAction SilentlyContinue) { return $true }
            if (dism /online /get-packages | Select-String $k) { return $true }
        }
        return $false
    } -ArgumentList $KBList

    if ($kbInstalled) {

        Write-Host "KB found on $ComputerName → Forcing SCCM inventory..." -ForegroundColor Green

        # Force inventory
        Invoke-Command -ComputerName $ComputerName -ScriptBlock {
            $triggers = @(
                "{00000000-0000-0000-0000-000000000001}", # Machine Policy Refresh
                "{00000000-0000-0000-0000-000000000113}", # Hardware Inventory
                "{00000000-0000-0000-0000-000000000121}"  # Software Inventory
            )
            foreach ($t in $triggers) {
                try {
                    Invoke-WmiMethod -Namespace root\ccm -Class sms_client -Name TriggerSchedule -ArgumentList $t -ErrorAction Stop
                }
                catch {}
            }
        }

        Start-Sleep -Seconds 10

        Write-Host "Removing $ComputerName from collection..." -ForegroundColor Cyan

        # Remove from collection
        Remove-CMDeviceCollectionDirectMembershipRule `
            -CollectionName $CollectionName `
            -ResourceId $dev.ResourceID `
            -ErrorAction SilentlyContinue

        Write-Host "Removed successfully." -ForegroundColor Green
    }
    else {
        Write-Host "KB NOT installed → Machine stays in the collection." -ForegroundColor Yellow
    }
}

Write-Host "`nProcess completed." -ForegroundColor Cyan
