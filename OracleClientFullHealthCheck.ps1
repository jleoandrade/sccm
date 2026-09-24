#=====================================================================
# Oracle Client Full Health Check
# =====================================================================

# Ask for machine name
$ComputerName = Read-Host "Digite o nome da máquina para verificar Oracle Client"

$LocalLog = "C:\Temp\oracle_healthcheck_$ComputerName.log"
$Results = @()

$RemoteResults = Invoke-Command -ComputerName $ComputerName -ScriptBlock {

    $Output = @()
    $Output += "Oracle Client Full Health Check - $(Get-Date)"

    $OracleHome = "C:\Programs\Oracle\product\19.0.0\client_1"
    $Bin = Join-Path $OracleHome "bin"

    function Check-File($Path, $Name) {
        if (Test-Path $Path) {
            return "$Name OK: $Path"
        } else {
            return "$Name MISSING: $Path"
        }
    }

    # ---------------------------------------------------------
    # 1. Oracle Home
    # ---------------------------------------------------------
    if (Test-Path $OracleHome) {
        $Output += "Oracle Home exists: $OracleHome"
    } else {
        $Output += "Oracle Home NOT found."
    }

    # ---------------------------------------------------------
    # 2. Registry
    # ---------------------------------------------------------
    $Reg32 = "HKLM:\SOFTWARE\WOW6432Node\ORACLE"
    $Reg64 = "HKLM:\SOFTWARE\ORACLE"

    if ((Test-Path $Reg32) -or (Test-Path $Reg64)) {
        $Output += "Oracle registry entries detected."
    } else {
        $Output += "Oracle registry entries NOT found."
    }

    # ---------------------------------------------------------
    # 3. PATH
    # ---------------------------------------------------------
    $PathCheck = $env:PATH -split ";" | Select-String "client_1"
    if ($PathCheck) {
        $Output += "Oracle PATH entry detected."
    } else {
        $Output += "Oracle PATH entry NOT found."
    }

    # ---------------------------------------------------------
    # 4. Services
    # ---------------------------------------------------------
    $OracleServices = Get-Service | Where-Object { $_.Name -like "Oracle*" }
    if ($OracleServices) {
        $Output += "Oracle services detected:"
        $OracleServices | ForEach-Object { $Output += " - $($_.Name) ($($_.Status))" }
    } else {
        $Output += "No Oracle services detected."
    }

    # ---------------------------------------------------------
    # 5. Component Checks (Based on RSP)
    # ---------------------------------------------------------

    # SQL*Plus
    $Output += Check-File "$Bin\sqlplus.exe" "SQL*Plus"

    # OCI
    $Output += Check-File "$Bin\oci.dll" "OCI"

    # ODBC
    $Output += Check-File "$Bin\sqora32.dll" "Oracle ODBC Driver"

    # OLEDB
    $Output += Check-File "$Bin\OraOLEDB19.dll" "Oracle OLEDB Provider"

    # ODP.NET
    $Output += Check-File "$OracleHome\odp.net\bin\4\Oracle.DataAccess.dll" "ODP.NET"

    # JDBC
    $Output += Check-File "$OracleHome\jdbc\lib\ojdbc8.jar" "JDBC Driver"

    # ASP.NET Providers
    $Output += Check-File "$OracleHome\asp.net\bin" "ASP.NET Providers"

    # Network Client
    $Output += Check-File "$OracleHome\network\admin\tnsnames.ora" "tnsnames.ora"
    $Output += Check-File "$OracleHome\network\admin\sqlnet.ora" "sqlnet.ora"

    # DataPump Utilities
    $Output += Check-File "$Bin\expdp.exe" "DataPump Export"
    $Output += Check-File "$Bin\impdp.exe" "DataPump Import"

    return $Output
}

# Save log locally
$RemoteResults | Out-File $LocalLog

Write-Host ""
Write-Host "Health Check concluído para a máquina: $ComputerName"
Write-Host "Log salvo em: $LocalLog"
Write-Host ""
