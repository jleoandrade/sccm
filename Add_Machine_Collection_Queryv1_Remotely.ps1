# ============================================================
#  SCCM - Manage Machines in Query-Based or Direct Collections
#  REMOTE VERSION (NO LOCAL CONSOLE REQUIRED)
# ============================================================

Write-Host "=== SCCM Collection Manager (Remote Mode) ===" -ForegroundColor Cyan

# ============================================================
#  CONNECT TO SCCM SERVER AND LOAD MODULE REMOTELY
# ============================================================

$SccmServer = "NJNWKSMS08V.ENTERPRISE.PSEG.COM"   # <-- CHANGE THIS

# Detect provider and site code remotely
$providerInfo = Get-WmiObject -ComputerName $SccmServer -Namespace "root\sms" -Class SMS_ProviderLocation | Select-Object -First 1
$Provider = $providerInfo.Machine
$Namespace = $providerInfo.NamespacePath
$SiteCode = ($Namespace -split "_")[-1]

Write-Host "Detected SMS Provider: $Provider" -ForegroundColor Cyan
Write-Host "Detected Site Code: $SiteCode" -ForegroundColor Cyan

# Load SCCM module from server
$CMModulePath = "\\$SccmServer\d$\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"

Import-Module $CMModulePath -ErrorAction Stop

# Create SCCM PSDrive
Set-Location "$SiteCode`:"

Write-Host "Connected to SCCM site: $SiteCode" -ForegroundColor Green

# ============================================================
#  COLLECTION SEARCH
# ============================================================

$SearchText = Read-Host "Enter part of the collection name"

$collections = Get-WmiObject -ComputerName $SccmServer -Namespace "root\sms\site_$SiteCode" -Class SMS_Collection |
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
#  GET RULES
# ============================================================

$queryRule = Get-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -ErrorAction SilentlyContinue
$directRules = Get-CMDeviceCollectionDirectMembershipRule -CollectionName $CollectionName -ErrorAction SilentlyContinue

# ============================================================
#  CHOOSE ACTION
# ============================================================

Write-Host "`nChoose an action:" -ForegroundColor Cyan
Write-Host "[1] Add machine"
Write-Host "[2] Remove machine(s)"
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
        Add-CMDeviceCollectionDirectMembershipRule -CollectionName $CollectionName -ResourceId $device.ResourceID
        Write-Host "`nMachine added via Direct Membership Rule." -ForegroundColor Green
    }

    Invoke-CMCollectionUpdate -Name $CollectionName

    Write-Host "`nTriggering Machine Policy Retrieval..." -ForegroundColor Cyan
    Invoke-CMClientAction -DeviceId $device.ResourceID -ActionType ClientNotificationRequestMachinePolicyNow
    Write-Host "Machine Policy Retrieval triggered!" -ForegroundColor Green
}

# ============================================================
#  REMOVE MULTIPLE MACHINES
# ============================================================

elseif ($action -eq "2") {

    $RemoveListRaw = Read-Host "Enter machine names separated by comma"
    $RemoveList = $RemoveListRaw.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

    Write-Host "`nMachines to remove:" -ForegroundColor Cyan
    $RemoveList | ForEach-Object { Write-Host " - $_" }

    # Remove from query rule
    if ($queryRule) {

        $machineList = [regex]::Matches($queryRule.QueryExpression, '"([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value }

        $newMachineList = $machineList | Where-Object { $RemoveList -notcontains $_ }

        $newQuery = 'select SMS_R_SYSTEM.ResourceID,SMS_R_SYSTEM.ResourceType,SMS_R_SYSTEM.Name,SMS_R_SYSTEM.SMSUniqueIdentifier,SMS_R_SYSTEM.ResourceDomainORWorkgroup,SMS_R_SYSTEM.Client from SMS_R_System where SMS_R_System.Name in ("' +
                    ($newMachineList -join '","') + '")'

        Remove-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -RuleName $queryRule.RuleName -Force
        Add-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -RuleName $queryRule.RuleName -QueryExpression $newQuery

        Write-Host "`nMachines removed from Query Rule." -ForegroundColor Green
    }

    # Remove from direct membership
    foreach ($comp in $RemoveList) {

        $device = Get-CMDevice -Name $comp -ErrorAction SilentlyContinue
        if ($device) {

            $rule = $directRules | Where-Object { $_.ResourceID -eq $device.ResourceID }

            if ($rule) {
                Remove-CMDeviceCollectionDirectMembershipRule -CollectionName $CollectionName -ResourceId $device.ResourceID -Force
                Write-Host "Removed from Direct Rule: $comp" -ForegroundColor Green
            }
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
