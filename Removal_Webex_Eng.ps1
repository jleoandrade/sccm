<#
Complete script:
- Detects Webex / Cisco Spark on a remote machine
- Lists everything (folders + registry + GUID in Installer\UserData)
- Asks for confirmation before removal
- Removes everything safely

Uses 64‑bit registry to locate GUID 063553425DBD6CF50A39BEE465565EDC
#>

# ============================
# ASK FOR REMOTE MACHINE
# ============================
$Computer = Read-Host "Enter the remote machine name or IP"

# ============================
# CONNECTIVITY TEST
# ============================
if (!(Test-Connection -ComputerName $Computer -Count 2 -Quiet)) {
    Write-Output "The machine is not reachable."
    exit
}

# ============================
# LOCAL LOGS
# ============================
$LogPath = "$env:USERPROFILE\Desktop\Logs_Webex_Spark"
if (!(Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath | Out-Null }

$LogCheck  = "$LogPath\Check_$Computer.txt"
$LogRemove = "$LogPath\Removed_$Computer.txt"

# ============================
# REMOTE SCRIPT – DETECTION
# ============================
$CheckScript = {

    $GUID = "063553425DBD6CF50A39BEE465565EDC"
    $Results = @()

    $Results += "=== FOLDER DETECTION ==="

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
            if (Test-Path $path) {
                $Results += "FOUND FOLDER: $path"
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
            $Results += "FOUND FOLDER: $pf"
        }
    }

    # ProgramData
    $PDItems = Get-ChildItem "C:\ProgramData" -ErrorAction SilentlyContinue |
               Where-Object { $_.PSIsContainer -and $_.Name -match "webex|spark" }

    foreach ($item in $PDItems) {
        $Results += "FOUND FOLDER: $($item.FullName)"
    }

    $Results += ""
    $Results += "=== REGISTRY DETECTION – UNINSTALL ==="

    # Registry – Uninstall
    $UninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    foreach ($up in $UninstallPaths) {
        $keys = Get-ChildItem $up -ErrorAction SilentlyContinue
        foreach ($k in $keys) {
            $props = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if ($props.DisplayName -match "webex|spark") {
                $Results += "FOUND REG UNINSTALL: $($k.PSPath) - $($props.DisplayName)"
            }
        }
    }

    $Results += ""
    $Results += "=== REGISTRY DETECTION – INSTALLER\\UserData (GUID) ==="

    # 64‑bit Registry – Installer\UserData
    $Base = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData"

    if (Test-Path $Base) {

        $SIDs = Get-ChildItem $Base -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer }

        $FoundGUID = $false

        foreach ($sid in $SIDs) {

            $CheckPath = "Registry::$($sid.Name)\Products\$GUID"

            if (Test-Path $CheckPath) {

                $FoundGUID = $true
                $Results += "FOUND GUID: $GUID"
                $Results += "  SID: $($sid.PSChildName)"
                $Results += "  PATH: $CheckPath"

                $InstallProps = "$CheckPath\InstallProperties"
                if (Test-Path $InstallProps) {
                    $props = Get-ItemProperty $InstallProps -ErrorAction SilentlyContinue
                    $Results += "  DisplayName: $($props.DisplayName)"
                    $Results += "  ProductName: $($props.ProductName)"
                    $Results += "  Publisher:   $($props.Publisher)"
                }

                $Results += ""
            }
        }

        if (-not $FoundGUID) {
            $Results += "No SID contains GUID $GUID in Installer\UserData (64‑bit)."
        }
    } else {
        $Results += "Installer\UserData (64‑bit) does not exist on this machine."
    }

    if ($Results.Count -eq 0) {
        $Results += "No Webex / Cisco Spark items found."
    }

    return $Results
}

# RUN DETECTION
$CheckResult = Invoke-Command -ComputerName $Computer -ScriptBlock $CheckScript
$CheckResult | Out-File $LogCheck -Encoding UTF8

Write-Output "=== ITEMS FOUND ==="
$CheckResult
Write-Output "`nLog saved to: $LogCheck"

# CONFIRMATION
$Confirm = Read-Host "Do you want to REMOVE ALL items above? (Y/N)"

if ($Confirm -ne "Y") {
    Write-Output "Operation cancelled."
    exit
}

# ============================
# REMOTE SCRIPT – REMOVAL
# ============================
$RemoveScript = {

    $GUID = "063553425DBD6CF50A39BEE465565EDC"
    $Removed = @()

    $Removed += "=== FOLDER REMOVAL ==="

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

    $Removed += ""
    $Removed += "=== REGISTRY REMOVAL – UNINSTALL ==="

    # Registry – Uninstall
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

    $Removed += ""
    $Removed += "=== REGISTRY REMOVAL – INSTALLER\\UserData (GUID) ==="

    # 64‑bit Registry – Installer\UserData
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
    } else {
        $Removed += "Installer\UserData (64‑bit) does not exist on this machine."
    }

    if ($Removed.Count -eq 0) {
        $Removed += "Nothing was removed."
    }

    return $Removed
}

# RUN REMOVAL
$RemoveResult = Invoke-Command -ComputerName $Computer -ScriptBlock $RemoveScript
$RemoveResult | Out-File $LogRemove -Encoding UTF8

Write-Output "=== ITEMS REMOVED ==="
$RemoveResult
Write-Output "`nLog saved to: $LogRemove"
