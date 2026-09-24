# ============================================================
#  SCCM - Manage Machines in Query-Based or Direct Collections
# ============================================================

Write-Host "=== SCCM Collection Manager ===" -ForegroundColor Cyan

# ============================================================
#  Ensure SCCM PowerShell Drive is Loaded
# ============================================================

# Load SCCM module if not loaded
if (-not (Get-Module ConfigurationManager)) {
    Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1"
}

# Detect site code automatically
$siteCode = (Get-PSDrive -PSProvider CMSite).Name

if (-not $siteCode) {
    Write-Host "ERROR: Could not detect SCCM site code. Exiting." -ForegroundColor Red
    exit
}

# Change to SCCM drive
Set-Location "$siteCode`:"

Write-Host "Connected to SCCM site: $siteCode" -ForegroundColor Green

# ============================================================
#  Collection Search
# ============================================================

$SearchText = Read-Host "Enter part of the collection name"

$collections = Get-WmiObject -Namespace "root\sms\site_$siteCode" -Class SMS_Collection |
    Where-Object { $_.Name -like "*$SearchText*" } |
    Select-Object Name

if (-not $collections) {
    Write-Host "No collections found matching '$SearchText'." -ForegroundColor Red
    return
}

Write-Host "`nCollections found:" -ForegroundColor Cyan

for ($i = 0; $i -lt $collections.Count; $i++) {
    Write-Host "[$i] $($collections[$i].Name)"
}

$index = Read-Host "`nEnter the number of the collection you want to use"

if ($index -notmatch '^\d+$' -or $index -ge $collections.Count) {
    Write-Host "Invalid selection." -ForegroundColor Red
    return
}

$CollectionName = $collections[$index].Name
Write-Host "`nSelected collection: $CollectionName" -ForegroundColor Green

# ============================================================
#  Get Rules
# ============================================================

$queryRule = Get-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -ErrorAction SilentlyContinue
$directRules = Get-CMDeviceCollectionDirectMembershipRule -CollectionName $CollectionName -ErrorAction SilentlyContinue

# ============================================================
#  Choose Action
# ============================================================

Write-Host "`nChoose an action:" -ForegroundColor Cyan
Write-Host "[1] Add machine"
Write-Host "[2] Remove machine"
$action = Read-Host "Enter option number"

# ============================================================
#  ADD MACHINE
# ============================================================

if ($action -eq "1") {

    $NewComputer = Read-Host "Enter the computer name to add"

    $device = Get-CMDevice -Name $NewComputer -ErrorAction SilentlyContinue
    if (-not $device) {
        Write-Host "Device not found in SCCM. Cannot add." -ForegroundColor Red
        return
    }

    # If collection has query rule → update query
    if ($queryRule) {

        $machineList = [regex]::Matches($queryRule.QueryExpression, '"([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value }

        if ($machineList -contains $NewComputer) {
            Write-Host "`nMachine already exists in the query." -ForegroundColor Yellow
        } else {
            $oldQuery = $queryRule.QueryExpression
            $replacement = ',"' + $NewComputer + '")'
            $newQuery = $oldQuery -replace '\)$', $replacement

            Remove-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -RuleName $queryRule.RuleName -Force
            Add-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -RuleName $queryRule.RuleName -QueryExpression $newQuery

            Write-Host "`nMachine added to Query Rule." -ForegroundColor Green
        }

    } else {
        # No query rule → add direct membership
        Add-CMDeviceCollectionDirectMembershipRule -CollectionName $CollectionName -ResourceId $device.ResourceID
        Write-Host "`nMachine added via Direct Membership Rule." -ForegroundColor Green
    }

    Invoke-CMCollectionUpdate -Name $CollectionName

    Write-Host "`nTriggering Machine Policy Retrieval..." -ForegroundColor Cyan
    Invoke-CMClientAction -DeviceId $device.ResourceID -ActionType ClientNotificationRequestMachinePolicyNow
    Write-Host "Machine Policy Retrieval triggered!" -ForegroundColor Green
}

# ============================================================
#  REMOVE MACHINE
# ============================================================

elseif ($action -eq "2") {

    $RemoveComputer = Read-Host "Enter the computer name to remove"

    $device = Get-CMDevice -Name $RemoveComputer -ErrorAction SilentlyContinue

    # Remove from query rule if exists
    if ($queryRule) {

        $machineList = [regex]::Matches($queryRule.QueryExpression, '"([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value }

        if ($machineList -contains $RemoveComputer) {

            $newMachineList = $machineList | Where-Object { $_ -ne $RemoveComputer }

            $newQuery = 'select SMS_R_SYSTEM.ResourceID,SMS_R_SYSTEM.ResourceType,SMS_R_SYSTEM.Name,SMS_R_SYSTEM.SMSUniqueIdentifier,SMS_R_SYSTEM.ResourceDomainORWorkgroup,SMS_R_SYSTEM.Client from SMS_R_System where SMS_R_System.Name in ("' +
                        ($newMachineList -join '","') + '")'

            Remove-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -RuleName $queryRule.RuleName -Force
            Add-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -RuleName $queryRule.RuleName -QueryExpression $newQuery

            Write-Host "`nMachine removed from Query Rule." -ForegroundColor Green
        }
    }

    # Remove from direct membership
    if ($device -and $directRules) {

        $rule = $directRules | Where-Object { $_.ResourceID -eq $device.ResourceID }

        if ($rule) {
            Remove-CMDeviceCollectionDirectMembershipRule -CollectionName $CollectionName -ResourceId $device.ResourceID -Force
            Write-Host "`nMachine removed from Direct Membership Rule." -ForegroundColor Green
        }
    }

    Invoke-CMCollectionUpdate -Name $CollectionName
    Write-Host "`nRemoval completed." -ForegroundColor Green
}

else {
    Write-Host "Invalid option." -ForegroundColor Red
    return
}

Write-Host "`nAll tasks completed." -ForegroundColor Green
