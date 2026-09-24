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
# ASK FOR COMPUTER NAME
# ================================
$ComputerName = Read-Host "Enter the computer name"

Write-Host "`n=== Checking computer $ComputerName ===" -ForegroundColor Cyan

# ================================
# STEP 1 — CHECK BUILD REMOTELY
# ================================
$build = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
    $cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    return "$($cv.CurrentBuild).$($cv.UBR)"
}

Write-Host "Detected build: $build" -ForegroundColor Yellow

# ================================
# STEP 2 — CHECK IF KB IS INSTALLED
# ================================
$kbInstalled = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
    $kb = "KB5078883","KB5079473","KB5043080"
    foreach ($k in $kb) {
        if (Get-HotFix -Id $k -ErrorAction SilentlyContinue) { return $true }
        if (dism /online /get-packages | Select-String $k) { return $true }
    }
    return $false
}

if ($kbInstalled) {
    Write-Host "KB installed successfully." -ForegroundColor Green
} else {
    Write-Host "KB NOT installed. Aborting." -ForegroundColor Red
    return
}

# ================================
# STEP 3 — FORCE SCCM INVENTORY (REMOTE)
# ================================
Write-Host "`nForcing SCCM inventory..." -ForegroundColor Cyan

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

Start-Sleep -Seconds 20

# ================================
# STEP 4 — CHECK COLLECTION (LOCAL)
# ================================
$CollectionName = "All Desktop and MDT Clients - 30 day Communication Missing KB February 2026"

function Test-InCollection {
    param($ComputerName, $CollectionName)
    $dev = Get-CMDevice -Name $ComputerName -ErrorAction SilentlyContinue
    if (-not $dev) { return $false }
    $col = $dev | Get-CMCollectionMembership
    return ($col.CollectionName -contains $CollectionName)
}

Write-Host "`nChecking if the computer is still in the collection..." -ForegroundColor Cyan

$stillIn = Test-InCollection -ComputerName $ComputerName -CollectionName $CollectionName

if (-not $stillIn) {
    Write-Host "Computer has ALREADY left the collection." -ForegroundColor Green
    return
}

# ================================
# STEP 5 — LOOP UNTIL REMOVED FROM COLLECTION
# ================================
Write-Host "Computer is still in the collection. Reinforcing inventory..." -ForegroundColor Yellow

for ($i=1; $i -le 5; $i++) {

    Write-Host "Attempt $i/5..." -ForegroundColor Cyan

    Invoke-Command -ComputerName $ComputerName -ScriptBlock {
        Invoke-WmiMethod -Namespace root\ccm -Class sms_client -Name TriggerSchedule -ArgumentList "{00000000-0000-0000-0000-000000000113}"
        Invoke-WmiMethod -Namespace root\ccm -Class sms_client -Name TriggerSchedule -ArgumentList "{00000000-0000-0000-0000-000000000121}"
    }

    Start-Sleep -Seconds 30

    $stillIn = Test-InCollection -ComputerName $ComputerName -CollectionName $CollectionName

    if (-not $stillIn) {
        Write-Host "`nComputer successfully removed from the collection!" -ForegroundColor Green
        return
    }
}

Write-Host "`nThe computer is still in the collection after 5 attempts. Check the collection query." -ForegroundColor Red
