# ============================================
# ORACLE CLIENT IMPROVED CLEANUP - REMOTE
# ============================================

Write-Host "=== ORACLE REMOTE CLEANUP TOOL (IMPROVED) ===" -ForegroundColor Cyan

$remoteMachine = Read-Host "Enter the remote machine name"

Invoke-Command -ComputerName $remoteMachine -ScriptBlock {

    Write-Host "=== Starting Improved Oracle Cleanup ===" -ForegroundColor Cyan

    function Safe-RemoveItem {
        param([string]$Path, [switch]$Recurse)
        if (Test-Path $Path) {
            try {
                if ($Recurse) {
                    Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
                } else {
                    Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
                }
                Write-Host "Deleted: $Path" -ForegroundColor Yellow
            } catch {
                Write-Host "FAILED to delete: $Path" -ForegroundColor Red
            }
        }
    }

    # ---------------------------------------------------------
    # 1. REMOVE ORACLE SERVICES (FORÇADO)
    # ---------------------------------------------------------
    Write-Host "`n[1] Removing Oracle services..." -ForegroundColor Cyan

    $oracleServices = Get-Service | Where-Object { $_.Name -like "Oracle*" }

    foreach ($svc in $oracleServices) {
        Write-Host "Stopping service: $($svc.Name)" -ForegroundColor Yellow
        Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue

        Write-Host "Deleting service: $($svc.Name)" -ForegroundColor Yellow
        sc.exe delete $svc.Name | Out-Null
    }

    # ---------------------------------------------------------
    # 2. REMOVE ORACLE REGISTRY KEYS (INCLUINDO WOW6432Node)
    # ---------------------------------------------------------
    Write-Host "`n[2] Removing Oracle registry keys..." -ForegroundColor Cyan

    $regKeys = @(
        "HKLM:\SOFTWARE\WOW6432Node\Oracle",
        "HKLM:\SOFTWARE\Oracle"
    )

    foreach ($key in $regKeys) {
        Safe-RemoveItem -Path $key -Recurse
    }

    # Remove service registry keys
    $svcReg = "HKLM:\SYSTEM\CurrentControlSet\Services"
    Get-ChildItem $svcReg | Where-Object { $_.Name -match "Oracle" } |
        ForEach-Object {
            Write-Host "Removing service registry key: $($_.Name)" -ForegroundColor Yellow
            Safe-RemoveItem -Path $_.PSPath -Recurse
        }

    # ---------------------------------------------------------
    # 3. REMOVE ORACLE FOLDERS (INCLUINDO INVENTORY)
    # ---------------------------------------------------------
    Write-Host "`n[3] Removing Oracle folders..." -ForegroundColor Cyan

    $folders = @(
        "C:\Program Files (x86)\Oracle",
        "C:\Program Files (x86)\Oracle\Inventory",
        "C:\Program Files\Oracle",
        "C:\Oracle",
        "C:\app",
        "C:\Programs\Oracle"
    )

    foreach ($folder in $folders) {
        Safe-RemoveItem -Path $folder -Recurse
    }

    # ---------------------------------------------------------
    # 4. REMOVE ORACLE INVENTORY (FORÇADO)
    # ---------------------------------------------------------
    Write-Host "`n[4] Removing Oracle Inventory..." -ForegroundColor Cyan

    $inventoryPaths = @(
        "C:\Program Files (x86)\Oracle\Inventory",
        "C:\Program Files\Oracle\Inventory"
    )

    foreach ($inv in $inventoryPaths) {
        Safe-RemoveItem -Path $inv -Recurse
    }

    # ---------------------------------------------------------
    # 5. REMOVE ODBC DRIVERS (REVERIFICAR)
    # ---------------------------------------------------------
    Write-Host "`n[5] Removing Oracle ODBC Drivers..." -ForegroundColor Cyan

    $driverKeys = @(
        "HKLM:\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers",
        "HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBCINST.INI\ODBC Drivers"
    )

    foreach ($key in $driverKeys) {
        if (Test-Path $key) {
            $props = Get-ItemProperty -Path $key
            $props.PSObject.Properties |
                Where-Object { $_.Name -match "Oracle" } |
                ForEach-Object {
                    Write-Host "Removing ODBC driver value: $($_.Name)" -ForegroundColor Yellow
                    Remove-ItemProperty -Path $key -Name $_.Name -ErrorAction SilentlyContinue
                }
        }
    }

    # ---------------------------------------------------------
    # 6. REMOVE ORACLE SERVICE DLLs (GARANTE REMOÇÃO)
    # ---------------------------------------------------------
    Write-Host "`n[6] Removing Oracle DLLs..." -ForegroundColor Cyan

    $dllPatterns = @("oci.dll","oraociei*.dll","oraons.dll","sqora32.dll","sqora64.dll","oraclient*.dll","ora*.dll")
    $dllFolders = @("C:\Windows\System32","C:\Windows\SysWOW64")

    foreach ($folder in $dllFolders) {
        foreach ($pattern in $dllPatterns) {
            Get-ChildItem -Path $folder -Filter $pattern -ErrorAction SilentlyContinue |
                ForEach-Object { Safe-RemoveItem -Path $_.FullName }
        }
    }

    Write-Host "`n=== IMPROVED ORACLE CLEANUP COMPLETED ===" -ForegroundColor Green
}

Write-Host "`nCleanup finished on $remoteMachine." -ForegroundColor Green
