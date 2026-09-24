<#
SCCM Version – Local Execution
- Detects Webex / Cisco Spark on the local machine
- Removes folders, uninstall keys, and Installer\UserData GUID
- Outputs a final status string for SCCM reporting
#>

$GUID = "D97C080B3E4B42454829EBBB6DB7A129"
$RemovedItems = @()
$FoundItems = @()

# ============================
# DETECTION
# ============================

# User profiles
$Profiles = Get-ChildItem "C:\Users" -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer }

foreach ($p in $Profiles) {
    $Paths = @(
        "$($p.FullName)\AppData\Local\Webex",
        "$($p.FullName)\AppData\LocalLow\Webex",
        "$($p.FullName)\AppData\Roaming\Webex",
        "$($p.FullName)\AppData\Local\Programs\Cisco Spark",
        "$($p.FullName)\AppData\Local\CiscoSparkLauncher"
    )
    foreach ($path in $Paths) {
        if (Test-Path $path) { $FoundItems += $path }
    }
}

# Program Files
$PFPaths = @(
    "C:\Program Files (x86)\Webex",
    "C:\Program Files (x86)\WebEx",
    "C:\Program Files\Webex",
    "C:\Program Files\WebEx",
    "C:\Program Files (x86)\Cisco Spark",
    "C:\Program Files\Cisco Spark"
)
foreach ($pf in $PFPaths) {
    if (Test-Path $pf) { $FoundItems += $pf }
}

# ProgramData
$PDItems = Get-ChildItem "C:\ProgramData" -ErrorAction SilentlyContinue |
           Where-Object { $_.PSIsContainer -and $_.Name -match "webex|spark" }
foreach ($item in $PDItems) {
    $FoundItems += $item.FullName
}

# Uninstall keys
$UninstallPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)
foreach ($up in $UninstallPaths) {
    $keys = Get-ChildItem $up -ErrorAction SilentlyContinue
    foreach ($k in $keys) {
        $props = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
        if ($props.DisplayName -match "webex|spark") {
            $FoundItems += $k.PSPath
        }
    }
}

# Installer\UserData (64-bit)
$Base = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData"
if (Test-Path $Base) {
    $SIDs = Get-ChildItem $Base -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer }
    foreach ($sid in $SIDs) {
        $CheckPath = "Registry::$($sid.Name)\Products\$GUID"
        if (Test-Path $CheckPath) {
            $FoundItems += $CheckPath
        }
    }
}

# ============================
# REMOVAL
# ============================

foreach ($item in $FoundItems) {
    try {
        if ($item -like "Registry::*") {
            Remove-Item $item -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Remove-Item $item -Recurse -Force -ErrorAction SilentlyContinue
        }
        $RemovedItems += $item
    }
    catch {}
}

# ============================
# SCCM OUTPUT
# ============================

if ($RemovedItems.Count -gt 0) {
    Write-Output "Webex/Spark Removed"
} elseif ($FoundItems.Count -gt 0) {
    Write-Output "Webex/Spark Detected but Removal Failed"
} else {
    Write-Output "Webex/Spark Not Found"
}
