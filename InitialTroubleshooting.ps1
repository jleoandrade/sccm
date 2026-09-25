[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
    [string]$ComputerName
)

Clear-Host
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "   STARTING INITIAL TROUBLESHOOTING: $ComputerName" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# STEP 1: DNS Divergence Verification (Executed Locally)
# -----------------------------------------------------------------------------
Write-Host "`n[1/5] Checking DNS Consistency..." -ForegroundColor Cyan
$DnsDivergente = $false
$IpResolvido = $null

try {
    $dnsA = [System.Net.Dns]::GetHostEntry($ComputerName)
    $IpResolvido = $dnsA.AddressList | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1 -ExpandProperty IPAddressToString
    
    if (-not $IpResolvido) { $IpResolvido = $dnsA.AddressList.IPAddressToString }
    Write-Host "  > [OK] Hostname resolved to IP: $IpResolvido" -ForegroundColor Green

    try {
        $dnsPTR = [System.Net.Dns]::GetHostEntry($IpResolvido)
        $nomeReversoCompleto = $dnsPTR.HostName
        $nomeReversoCurto = $nomeReversoCompleto.Split('.')

        if ($nomeReversoCurto.ToLower() -eq $ComputerName.ToLower()) {
            Write-Host "  > [OK] DNS Consistent! Reverse points to: $nomeReversoCompleto" -ForegroundColor Green
        } else {
            Write-Host "  > [WARNING] Divergence! IP $IpResolvido points to '$nomeReversoCompleto'." -ForegroundColor Red
            $DnsDivergente = $true
        }
    } catch {
        Write-Host "  > [WARNING] No PTR (reverse) record exists for IP $IpResolvido." -ForegroundColor DarkYellow
    }
} catch {
    Write-Host "  > [CRITICAL ERROR] Could not resolve Hostname '$ComputerName' in DNS." -ForegroundColor Red
    exit
}

# -----------------------------------------------------------------------------
# STEP 2: Actual PSRemoting Authentication Test (Prevents false positives)
# -----------------------------------------------------------------------------
Write-Host "`n[2/5] Validating if PSRemoting is Active/Available..." -ForegroundColor Cyan
$UsarWinRM = $false

if ($DnsDivergente) {
    Write-Host "  > [BLOCKED] WinRM inaccessible due to identity/DNS divergence detected in Step 1." -ForegroundColor Yellow
} else {
    $TestWSMan = Test-WSMan -ComputerName $ComputerName -ErrorAction SilentlyContinue
    if ($TestWSMan) {
        Write-Host "  > [OK] WinRM responding and authenticated on the network." -ForegroundColor Green
        $UsarWinRM = $true
    } else {
        Write-Host "  > [WARNING] WinRM/PSRemoting disabled or not responding on default port." -ForegroundColor Yellow
    }
}

# -----------------------------------------------------------------------------
# STEP 3: Trust Relationship Diagnostics via PsExec (Secure Channel Validation)
# -----------------------------------------------------------------------------
Write-Host "`n[3/5] Verifying Trust Relationship..." -ForegroundColor Cyan

$ScriptFolder = Split-Path -Parent $MyInvocation.MyCommand.Path
$PsExecPath = Join-Path $ScriptFolder "psexec.exe"

if (-not (Test-Path $PsExecPath)) {
    if (Get-Command "psexec" -ErrorAction SilentlyContinue) {
        $PsExecPath = (Get-Command "psexec").Source
    } else {
        Write-Host "  > [CRITICAL ERROR] 'psexec.exe' file not found at: $ScriptFolder" -ForegroundColor Red
        exit
    }
}

$OutputArray = & $PsExecPath \\$ComputerName -accepteula hostname 2>&1
$CleanOutput = ($OutputArray | Out-String).ToLower().Trim()





# Helper function to list skipped steps in yellow on screen
function Proibir-Coleta {
    Write-Host "`n[SKIPPED] [4/5] System Information Collection..." -ForegroundColor Yellow
    Write-Host "[SKIPPED] [5/5] Analyzing Pending Reboot Status..." -ForegroundColor Yellow
    Write-Host "  > Reason: Remote WMI/WinRM queries are impossible while Trust is broken." -ForegroundColor Yellow
    Write-Host "`n====================================================" -ForegroundColor Cyan
}

if ($CleanOutput -match "trust relationship" -or 
    $CleanOutput -match "primary domain failed" -or 
    ($CleanOutput -match "couldn't access" -and $CleanOutput -match "handle is invalid")) {
    
    Write-Host "  > [CRITICAL ERROR] FAILURE CONFIRMED! (Trust Relationship Broken)" -ForegroundColor Red
    Write-Host "    Evidence: Domain rejected machine token (Invalid handle / Loss of trust)." -ForegroundColor DarkRed
    Proibir-Coleta
    exit
}
elseif ($CleanOutput -match "logon failure" -or $CleanOutput -match "1326") {
    Write-Host "  > [CRITICAL ERROR] PROBABLE FAILURE! (Secure Channel Authentication Error)." -ForegroundColor Red
    Proibir-Coleta
    exit
}
elseif ($CleanOutput -match "network path not found" -or $CleanOutput -match "rpc server is unavailable") {
    Write-Host "  > [WARNING] Inconclusive. SMB ports (445) blocked by firewall on the remote machine." -ForegroundColor Yellow
}
else {
    Write-Host "  > [OK] Secure Channel and trust relationship validated successfully!" -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# STEP 4: Data Collection with Secure Fallback (WinRM -> DCOM)
# -----------------------------------------------------------------------------
Write-Host "`n[4/5] Collecting System Information..." -ForegroundColor Cyan

$SucessoColeta = $false
$Resultado = $null

# ATTEMPT A: Using secure PSRemoting
if ($UsarWinRM) {
    try {
        Write-Host "  > Attempting connection via WinRM Session..." -ForegroundColor Gray
        $Resultado = Invoke-Command -ComputerName $ComputerName -ErrorAction Stop -ScriptBlock {
            $LastBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
            
            # HD Space Collection (Drive C:)
            $DriveC = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
            $HDTotal = $DriveC.Size
            $HDLivre = $DriveC.FreeSpace

            $WUKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired")
            $WU = $null -ne $WUKey; if($WUKey){$WUKey.Close()}
            $CBSKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending")
            $CBS = $null -ne $CBSKey; if($CBSKey){$CBSKey.Close()}
            try { $SccmCim = Invoke-CimMethod -Namespace root\ccm\ClientSDK -ClassName CCM_ClientUtilities -MethodName DetermineIfRebootPending -ErrorAction SilentlyContinue; $SCCM = [bool]$SccmCim.RebootPending } catch { $SCCM = $false }
            
            return [PSCustomObject]@{ LastBoot = $LastBoot; WU = $WU; CBS = $CBS; SCCM = $SCCM; HDTotal = $HDTotal; HDLivre = $HDLivre; Metodo = "WinRM" }
        }
        $SucessoColeta = $true
    } catch {}
}

# ATTEMPT B: Fallback to DCOM/RPC
if (-not $SucessoColeta) {
    Write-Host "  > [INFO] Starting fallback attempt via DCOM/RPC..." -ForegroundColor Yellow
    try {
        $CimOption = New-CimSessionOption -Protocol Dcom
        $CimSession = New-CimSession -ComputerName $ComputerName -SessionOption $CimOption -ErrorAction Stop

        $OS = Get-CimInstance -CimSession $CimSession -ClassName Win32_OperatingSystem -ErrorAction Stop
        $HostReal = (Get-CimInstance -CimSession $CimSession -ClassName Win32_ComputerSystem).Name

        if ($HostReal.ToLower() -ne $ComputerName.ToLower()) {







            throw "Connection established with wrong machine ($HostReal) due to dirty DNS."
        }

        $LastBoot = $OS.LastBootUpTime
        
        # HD Space Collection via DCOM (Drive C:)
        $DriveC = Get-CimInstance -CimSession $CimSession -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        $HDTotal = $DriveC.Size
        $HDLivre = $DriveC.FreeSpace

        $HKLM = [uint32]2147483650
        
        $WUResult = Invoke-CimMethod -CimSession $CimSession -Namespace root\default -ClassName StdRegProv -MethodName EnumKey -Arguments @{hDefKey=$HKLM; sSubKeyName="SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"} -ErrorAction SilentlyContinue
        $WU = ($null -ne $WUResult.sNames)

        $CBSResult = Invoke-CimMethod -CimSession $CimSession -Namespace root\default -ClassName StdRegProv -MethodName EnumKey -Arguments @{hDefKey=$HKLM; sSubKeyName="SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"} -ErrorAction SilentlyContinue
        $CBS = ($null -ne $CBSResult.sNames)

        try {
            $SccmCim = Invoke-CimMethod -CimSession $CimSession -Namespace root\ccm\ClientSDK -ClassName CCM_ClientUtilities -MethodName DetermineIfRebootPending -ErrorAction SilentlyContinue
            $SCCM = [bool]$SccmCim.RebootPending
        } catch { $SCCM = $false }

        $Resultado = [PSCustomObject]@{ LastBoot = $LastBoot; WU = $WU; CBS = $CBS; SCCM = $SCCM; HDTotal = $HDTotal; HDLivre = $HDLivre; Metodo = "DCOM/RPC" }
        $SucessoColeta = $true
        Remove-CimSession $CimSession
    } catch {
        Write-Host "  > [CRITICAL ERROR] Complete communication failure with host '$ComputerName'." -ForegroundColor Red
        Write-Host "    Detailed message: $_" -ForegroundColor DarkRed
    }
}

# -----------------------------------------------------------------------------
# FINAL DIAGNOSTIC DISPLAY
# -----------------------------------------------------------------------------
if ($SucessoColeta) {
    $Uptime = New-TimeSpan -Start $Resultado.LastBoot -End (Get-Date)
    Write-Host "`n[5/5] Analyzing Pending Reboot & System Status:" -ForegroundColor Cyan
    Write-Host "    ------------------------------------------------" -ForegroundColor Gray
    Write-Host "    Method Used                  : $($Resultado.Metodo)" -ForegroundColor Gray
    Write-Host "    Last Boot                    : $($Resultado.LastBoot)" -ForegroundColor Gray
    Write-Host "    Uptime                       : $($Uptime.Days) days, $($Uptime.Hours) hours, $($Uptime.Minutes) minutes" -ForegroundColor Yellow
    
    # Storage Calculations
    if ($Resultado.HDTotal -gt 0) {
        $TotalGB = [math]::Round($Resultado.HDTotal / 1GB, 2)
        $LivreGB = [math]::Round($Resultado.HDLivre / 1GB, 2)
        $PctLivre = [math]::Round(($Resultado.HDLivre / $Resultado.HDTotal) * 100, 1)
        
        $CorHD = if ($PctLivre -lt 15.0) { "Yellow" } else { "Green" }
        Write-Host "    System Drive (C:)            : $LivreGB GB free of $TotalGB GB ($PctLivre% free)" -ForegroundColor $CorHD
    } else {
        Write-Host "    System Drive (C:)            : [ERROR] Failed to read disk metrics." -ForegroundColor Red
    }
    
    Write-Host "    ------------------------------------------------" -ForegroundColor Gray
    
    function Out-Status($Nome, $Valor){
        $Cor = if($Valor){"Yellow"}else{"Green"}
        Write-Host ("    {0,-28}: {1}" -f $Nome, $Valor) -ForegroundColor $Cor
    }

    Out-Status "Windows Update" $Resultado.WU
    Out-Status "Add/Remove Feature (CBS)" $Resultado.CBS
    Out-Status "Configuration Manager (SCCM)" $Resultado.SCCM

    Write-Host ""
    if($Resultado.WU -or $Resultado.CBS -or $Resultado.SCCM){
        Write-Host "FINAL RESULT: Pending reboot DETECTED." -ForegroundColor Yellow
    } else {
        Write-Host "FINAL RESULT: No pending reboot detected." -ForegroundColor Green
    }
}

Write-Host "`n====================================================" -ForegroundColor Cyan
Write-Host "FINISHED RUN FOR HOSTNAME: $ComputerName" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
