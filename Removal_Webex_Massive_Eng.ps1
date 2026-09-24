<#
Bulk Webex/Spark Cleanup Script
- Hardcoded machine list
- Ping test
- Progress bar
- Detection + Removal
- CSV summary report
#>

# ============================
# MACHINE LIST (EDIT HERE)
# ============================
$Computers = @(
"1080886A"
"1080894A"
"1081162A"
"1565660A"
"1565765A"
"1565902A"
"1566607A"
"1566613A"
"1566794A"
"1566952A"
"1566974A"
"1567039A"
"1567162A"
"1567221A"
"1567227A"
"1567234A"
"1567260A"
"1567287A"
"1567296A"
"1567372A"
"1567393A"
"1581374A"
"1581532A"
"1581580A"
"1581628A"
"1581634A"
"1581759A"
"1581761A"
"1581779A"
"1581784A"
"1581794A"
"1581819A"
"1581833A"
"1581851A"
"1582087A"
"1582096A"
"1582304A"
"1582630A"
"1582887A"
"1583078A"
"1583085A"
"1583133A"
"1583155A"
"1583220A"
"1583230A"
"1583233A"
"1583234A"
"1583316A"
"1583424A"
"1583541A"
"1583617A"
"1583634A"
"1583651A"
"1583660A"
"1583680A"
"1583689A"
"1583701A"
"1583790A"
"1583817A"
"1583936A"
"1583972A"
"1584007A"
"1584013A"
"1584055A"
"1584094A"
"1584100A"
"1584121A"
"1584172A"
"1584218A"
"1584408A"
"1584422A"
"1584576A"
"1584589A"
"1584812A"
"1584837A"
"1584848A"
"1584851A"
"1584948A"
"1584949A"
"1584965A"
"1585203A"
"1585318A"
"1585360A"
"1585531A"
"1585768A"
"1585976A"
"1585986A"
"1585987A"
"1586186A"
"1586318A"
"1586358A"
"1586626A"
"1586696A"
"1587198A"
"6052037A"
"6053394A")

# ============================
# CONFIGURATION
# ============================
$GUID = "D97C080B3E4B42454829EBBB6DB7A129"

$RootLog = "$env:USERPROFILE\Desktop\Bulk_Webex_Spark_Logs"
if (!(Test-Path $RootLog)) { New-Item -ItemType Directory -Path $RootLog | Out-Null }

$CSVReport = "$RootLog\Summary.csv"

# Create CSV header
"Asset,Status,MachineIsOn" | Out-File $CSVReport

# ============================
# REMOTE SCRIPTS (DETECTION + REMOVAL)
# ============================
$DetectionScript = {
    param($GUID)

    $Results = @()

    # User folders
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
            if (Test-Path $path) { $Results += "FOUND FOLDER: $path" }
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
        if (Test-Path $pf) { $Results += "FOUND FOLDER: $pf" }
    }

    # ProgramData
    $PDItems = Get-ChildItem "C:\ProgramData" -ErrorAction SilentlyContinue |
               Where-Object { $_.PSIsContainer -and $_.Name -match "webex|spark" }
    foreach ($item in $PDItems) {
        $Results += "FOUND FOLDER: $($item.FullName)"
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
                $Results += "FOUND REG UNINSTALL: $($k.PSPath)"
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
                $Results += "FOUND GUID: $GUID in SID $($sid.PSChildName)"
            }
        }
    }

    return $Results
}

$RemovalScript = {
    param($GUID)

    $Removed = @()

    # User folders
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
            if (Test-Path $path) {
                Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
                $Removed += "REMOVED FOLDER: $path"
            }
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
        if (Test-Path $pf) {
            Remove-Item $pf -Recurse -Force -ErrorAction SilentlyContinue
            $Removed += "REMOVED FOLDER: $pf"
        }
    }

    # ProgramData
    $PDItems = Get-ChildItem "C:\ProgramData" -ErrorAction SilentlyContinue |
               Where-Object { $_.PSIsContainer -and $_.Name -match "webex|spark" }
    foreach ($item in $PDItems) {
        Remove-Item $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
        $Removed += "REMOVED FOLDER: $($item.FullName)"
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
                Remove-Item $k.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                $Removed += "REMOVED REG UNINSTALL: $($k.PSPath)"
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
                Remove-Item $CheckPath -Recurse -Force -ErrorAction SilentlyContinue
                $Removed += "REMOVED GUID: $GUID in SID $($sid.PSChildName)"
            }
        }
    }

    return $Removed
}

# ============================
# MAIN BULK LOOP WITH PROGRESS BAR
# ============================
$Total = $Computers.Count
$Index = 0

foreach ($Computer in $Computers) {

    $Index++
    Write-Progress -Activity "Bulk Webex/Spark Cleanup" `
                   -Status "Processing $Computer ($Index of $Total)" `
                   -PercentComplete (($Index / $Total) * 100)

    # Ping test
    if (!(Test-Connection -ComputerName $Computer -Count 1 -Quiet)) {
        Add-Content $CSVReport "$Computer,Not Removed,Machine Offline"
        continue
    }

    # Detection
    $Detect = Invoke-Command -ComputerName $Computer -ScriptBlock $DetectionScript -ArgumentList $GUID

    # Removal
    $Remove = Invoke-Command -ComputerName $Computer -ScriptBlock $RemovalScript -ArgumentList $GUID

    # Determine status
    $Status = if ($Remove.Count -gt 0) { "Removed" } else { "Not Removed" }

    # Write CSV line
    Add-Content $CSVReport "$Computer,$Status,Machine Online"
}

Write-Output "`nBulk cleanup completed."
Write-Output "CSV report saved to: $CSVReport"
