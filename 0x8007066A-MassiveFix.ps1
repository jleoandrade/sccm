<# 
Mass Remediation Script for Error 0x8007066A
Runs your full remediation logic on multiple remote machines.
#>

# ============================
# MACHINE LIST (EDIT HERE)
# ============================
$machines = @(

"1586859A"

)

Write-Host "Máquinas selecionadas para remediação:"
$machines | ForEach-Object { Write-Host " - $_" }

# Optional parameters
$DotNetRepairTool = $null
$ForceRebootIfPending = $true

foreach ($machine in $machines) {

    Write-Host "`n====================================================="
    Write-Host "Iniciando remediação na máquina: $machine"
    Write-Host "====================================================="

    try {
        Invoke-Command -ComputerName $machine -ScriptBlock {

param($DotNetRepairTool, $ForceRebootIfPending)

# --- Logging setup ---
$LogFile = 'C:\Temp\result_0x8007066A.txt'
$LogDir  = Split-Path $LogFile -Parent
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
if (-not (Test-Path $LogFile)) { New-Item -ItemType File -Path $LogFile -Force | Out-Null }

function Write-Log {
  param([string]$Message, [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level='INFO')
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
  $line = "[$ts][$Level] $Message"
  Add-Content -Path $LogFile -Value $line
}

# --- Admin check ---
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltinRole] "Administrator")
if (-not $IsAdmin) {
  Write-Log "This script must be run as Administrator." 'ERROR'
  exit 1
}

Write-Log "==== Start remediation for 0x8007066A ===="

# --- Reboot pending detection ---
function Test-PendingReboot {
  $keys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations'
  )
  foreach ($k in $keys) { if (Test-Path $k) { return $true } }
  return $false
}

# --- Step 1: Reset Windows Update components ---
try {
  Write-Log "Stopping Windows Update services..."
  Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
  Stop-Service bits     -Force -ErrorAction SilentlyContinue
  Stop-Service cryptsvc -Force -ErrorAction SilentlyContinue

  $sd  = "$env:windir\SoftwareDistribution"
  $cr2 = "$env:windir\System32\catroot2"
  if (Test-Path $sd)  { $sdOld  = $sd  + ".old_{0:yyyyMMddHHmmss}" -f (Get-Date);  Rename-Item $sd  $sdOld  -ErrorAction SilentlyContinue; Write-Log "Renamed: $sd -> $sdOld" }
  if (Test-Path $cr2) { $cr2Old = $cr2 + ".old_{0:yyyyMMddHHmmss}" -f (Get-Date);  Rename-Item $cr2 $cr2Old -ErrorAction SilentlyContinue; Write-Log "Renamed: $cr2 -> $cr2Old" }

  Write-Log "Starting services..."
  Start-Service wuauserv -ErrorAction SilentlyContinue
  Start-Service bits     -ErrorAction SilentlyContinue
  Start-Service cryptsvc -ErrorAction SilentlyContinue
}
catch { Write-Log "Failed to reset Windows Update components: $($_.Exception.Message)" 'WARN' }

# --- Step 2: SFC ---
try {
  Write-Log "Running SFC /scannow..."
  $p = Start-Process -FileFilePath "sfc.exe" -ArgumentList "/scannow" -Wait -PassThru -WindowStyle Hidden
  Write-Log "SFC completed. ExitCode=$($p.ExitCode)"
}
catch { Write-Log "Error running SFC: $($_.Exception.Message)" 'WARN' }

# --- Step 3: DISM ---
try {
  Write-Log "Running DISM /RestoreHealth..."
  $dismArgs = "/Online /Cleanup-Image /RestoreHealth /NoRestart"
  $proc = Start-Process -FilePath "dism.exe" -ArgumentList $dismArgs -Wait -PassThru -WindowStyle Hidden
  Write-Log "DISM completed. ExitCode=$($proc.ExitCode)"
}
catch { Write-Log "Error running DISM: $($_.Exception.Message)" 'WARN' }

# --- Step 4: Optional .NET Repair ---
if ($DotNetRepairTool) {
  if (Test-Path $DotNetRepairTool) {
    try {
      Write-Log "Running .NET Repair Tool..."
      $netfxLog = Join-Path $env:TEMP "NetFxRepair_0x8007066A_$(Get-Date -Format yyyyMMddHHmmss).txt"
      $args = "/q /l `"$netfxLog`" /repair"
      $nf = Start-Process -FilePath $DotNetRepairTool -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
      Write-Log ".NET repair completed. ExitCode=$($nf.ExitCode)"
    }
    catch { Write-Log "Error running .NET Repair Tool: $($_.Exception.Message)" 'WARN' }
  } else {
    Write-Log ".NET Repair Tool not found at: $DotNetRepairTool" 'WARN'
  }
} else {
  Write-Log "DotNetRepairTool not provided. Skipping .NET repair."
}

# --- Step 5: Trigger SCCM cycles ---
try {
  Write-Log "Triggering SCCM client cycles..."
  $ns   = "root\ccm"
  $cls  = "SMS_Client"
  Invoke-WmiMethod -Namespace $ns -Class $cls -Name TriggerSchedule -ArgumentList "{00000000-0000-0000-0000-000000000021}" | Out-Null
  Invoke-WmiMethod -Namespace $ns -Class $cls -Name TriggerSchedule -ArgumentList "{00000000-0000-0000-0000-000000000113}" | Out-Null
  Invoke-WmiMethod -Namespace $ns -Class $cls -Name TriggerSchedule -ArgumentList "{00000000-0000-0000-0000-000000000108}" | Out-Null
  Write-Log "SCCM cycles triggered."
}
catch { Write-Log "Failed to trigger SCCM cycles: $($_.Exception.Message)" 'WARN' }

# --- Step 6: Reboot logic ---
$pending = Test-PendingReboot
if ($pending -and $ForceRebootIfPending) {
  Write-Log "Pending reboot detected. Returning 3010."
  Write-Log "==== End remediation (reboot pending) ===="
  exit 3010
}

Write-Log "==== End remediation (success) ===="
exit 0

} -ArgumentList $DotNetRepairTool, $ForceRebootIfPending

        Write-Host "Remediação concluída com sucesso em $machine"
    }
    catch {
      Write-Host ("Falha ao executar remediação em {0}: {1}" -f $machine, $_)
    }
}

Write-Host "`nExecução em massa concluída."
