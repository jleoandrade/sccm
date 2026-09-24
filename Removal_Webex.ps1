<#
Script completo:
- Detecta Webex / Cisco Spark em máquina remota
- Lista tudo (pastas + registro + GUID em Installer\UserData)
- Pergunta se remove
- Remove tudo com segurança

Usa registro 64 bits para localizar o GUID D97C080B3E4B42454829EBBB6DB7A129
#>

# ============================
# PERGUNTA A MÁQUINA
# ============================
$Computer = Read-Host "Digite o nome ou IP da máquina remota"

# ============================
# TESTE DE CONECTIVIDADE
# ============================
if (!(Test-Connection -ComputerName $Computer -Count 2 -Quiet)) {
    Write-Output "A máquina não está acessível."
    exit
}

# ============================
# LOGS LOCAIS
# ============================
$LogPath = "$env:USERPROFILE\Desktop\Logs_Webex_Spark"
if (!(Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath | Out-Null }

$LogCheck  = "$LogPath\Check_$Computer.txt"
$LogRemove = "$LogPath\Removed_$Computer.txt"

# ============================
# SCRIPT REMOTO – DETECÇÃO
# ============================
$CheckScript = {

    $GUID = "D97C080B3E4B42454829EBBB6DB7A129"
    $Results = @()

    $Results += "=== DETECÇÃO DE PASTAS ==="

    # Perfis de usuário
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
    $Results += "=== DETECÇÃO DE REGISTRO – UNINSTALL ==="

    # Registro – Uninstall
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
    $Results += "=== DETECÇÃO DE REGISTRO – INSTALLER\\UserData (GUID) ==="

    # Registro 64 bits – Installer\UserData
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
            $Results += "Nenhum SID com o GUID $GUID encontrado em Installer\UserData (64 bits)."
        }
    } else {
        $Results += "Installer\UserData (64 bits) não existe nesta máquina."
    }

    if ($Results.Count -eq 0) {
        $Results += "Nenhum item Webex / Cisco Spark encontrado."
    }

    return $Results
}

# EXECUTA DETECÇÃO
$CheckResult = Invoke-Command -ComputerName $Computer -ScriptBlock $CheckScript
$CheckResult | Out-File $LogCheck -Encoding UTF8

Write-Output "=== ITENS ENCONTRADOS ==="
$CheckResult
Write-Output "`nLog salvo em: $LogCheck"

# CONFIRMAÇÃO
$Confirm = Read-Host "Deseja REMOVER TODOS os itens acima? (S/N)"

if ($Confirm -ne "S") {
    Write-Output "Operação cancelada."
    exit
}

# ============================
# SCRIPT REMOTO – REMOÇÃO
# ============================
$RemoveScript = {

    $GUID = "D97C080B3E4B42454829EBBB6DB7A129"
    $Removed = @()

    $Removed += "=== REMOÇÃO DE PASTAS ==="

    # Perfis de usuário
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
    $Removed += "=== REMOÇÃO DE REGISTRO – UNINSTALL ==="

    # Registro – Uninstall
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
    $Removed += "=== REMOÇÃO DE REGISTRO – INSTALLER\\UserData (GUID) ==="

    # Registro 64 bits – Installer\UserData
    $Base = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData"

    if (Test-Path $Base) {

        $SIDs = Get-ChildItem $Base -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer }

        foreach ($sid in $SIDs) {

            $CheckPath = "Registry::$($sid.Name)\Products\$GUID"

            if (Test-Path $CheckPath) {
                Remove-Item $CheckPath -Recurse -Force -ErrorAction SilentlyContinue
                $Removed += "REMOVED GUID: $GUID em SID $($sid.PSChildName)"
            }
        }
    } else {
        $Removed += "Installer\UserData (64 bits) não existe nesta máquina."
    }

    if ($Removed.Count -eq 0) {
        $Removed += "Nada foi removido."
    }

    return $Removed
}

# EXECUTA REMOÇÃO
$RemoveResult = Invoke-Command -ComputerName $Computer -ScriptBlock $RemoveScript
$RemoveResult | Out-File $LogRemove -Encoding UTF8

Write-Output "=== ITENS REMOVIDOS ==="
$RemoveResult
Write-Output "`nLog salvo em: $LogRemove"
