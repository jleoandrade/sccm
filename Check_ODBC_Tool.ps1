# ============================================
# REMOTE ODBC CHECK TOOL
# ============================================

Write-Host "=== REMOTE ODBC CHECK TOOL ===" -ForegroundColor Cyan

$remoteMachine = Read-Host "Enter the remote machine name"

Invoke-Command -ComputerName $remoteMachine -ScriptBlock {

    Write-Host "=== Checking ODBC Configuration on Remote Machine ===" -ForegroundColor Cyan

    function Show-List {
        param([string]$Title, [array]$Items)

        Write-Host "`n$Title" -ForegroundColor Cyan
        if ($Items -and $Items.Count -gt 0) {
            foreach ($i in $Items) {
                Write-Host " - $($i.PSChildName)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "   No entries found." -ForegroundColor Green
        }
    }

    # -------------------------------
    # 1. SYSTEM DSN (64-bit)
    # -------------------------------
    $sys64 = @()
    if (Test-Path "HKLM:\SOFTWARE\ODBC\ODBC.INI") {
        $sys64 = Get-ChildItem "HKLM:\SOFTWARE\ODBC\ODBC.INI" | Where-Object { $_.PSChildName -ne "ODBC Data Sources" }
    }
    Show-List "System DSN (64-bit)" $sys64

    # -------------------------------
    # 2. SYSTEM DSN (32-bit)
    # -------------------------------
    $sys32 = @()
    if (Test-Path "HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBC.INI") {
        $sys32 = Get-ChildItem "HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBC.INI" | Where-Object { $_.PSChildName -ne "ODBC Data Sources" }
    }
    Show-List "System DSN (32-bit)" $sys32

    # -------------------------------
    # 3. USER DSN
    # -------------------------------
    $userDsn = @()
    if (Test-Path "HKCU:\Software\ODBC\ODBC.INI") {
        $userDsn = Get-ChildItem "HKCU:\Software\ODBC\ODBC.INI" | Where-Object { $_.PSChildName -ne "ODBC Data Sources" }
    }
    Show-List "User DSN" $userDsn

    # -------------------------------
    # 4. ODBC DRIVERS INSTALLED
    # -------------------------------
    Write-Host "`nODBC Drivers Installed (64-bit)" -ForegroundColor Cyan
    if (Test-Path "HKLM:\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers") {
        Get-ItemProperty "HKLM:\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers" |
            Select-Object -Property * |
            Format-List
    } else {
        Write-Host "   No drivers found." -ForegroundColor Green
    }

    Write-Host "`nODBC Drivers Installed (32-bit)" -ForegroundColor Cyan
    if (Test-Path "HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBCINST.INI\ODBC Drivers") {
        Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBCINST.INI\ODBC Drivers" |
            Select-Object -Property * |
            Format-List
    } else {
        Write-Host "   No drivers found." -ForegroundColor Green
    }

    Write-Host "`n=== ODBC CHECK COMPLETED ===" -ForegroundColor Cyan
}

Write-Host "`nODBC check finished on $remoteMachine." -ForegroundColor Green
