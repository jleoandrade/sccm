# ================================
# CONFIGURATION — DEFINE SCCM SERVER
# ================================
$SccmServer = "NJNWKSMS08V.ENTERPRISE.PSEG.COM"

# ================================
# DETECT PROVIDER AND SITE CODE REMOTELY
# ================================
$providerInfo = Get-WmiObject -ComputerName $SccmServer -Namespace "root\sms" -Class SMS_ProviderLocation | Select-Object -First 1
$Provider = $providerInfo.Machine
$Namespace = $providerInfo.NamespacePath
$SiteCode = ($Namespace -split "_")[-1]

Write-Host "Detected SMS Provider: $Provider" -ForegroundColor Cyan
Write-Host "Detected Site Code: $SiteCode" -ForegroundColor Cyan

# ================================
# LOAD SCCM MODULE REMOTELY
# ================================
$CMModulePath = "\\$SccmServer\d$\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"
Import-Module $CMModulePath -ErrorAction Stop
Set-Location "$SiteCode`:"

# ================================
# TARGET COLLECTION
# ================================
$CollectionName = "All Desktop and MDT Clients - Missing KB June 2026"
Write-Host "`nLoading devices from collection: $CollectionName" -ForegroundColor Cyan

$devices = Get-CMDevice -CollectionName $CollectionName

if (-not $devices) {
    Write-Host "No devices found in the collection." -ForegroundColor Yellow
    return
}

Write-Host "Found $($devices.Count) devices." -ForegroundColor Green

# ================================
# KB LIST
# ================================
$KBList = "KB5079473", "KB5078883", "KB5083769", "KB5082052", "KB5089549", "KB5087420", "KB5094126", "KB5093998"

# ================================
# PROCESS EACH DEVICE
# ================================
foreach ($dev in $devices) {

    $ComputerName = $dev.Name
    Write-Host "`n=== Checking $ComputerName ===" -ForegroundColor Cyan

    # Test remote connectivity
    if (-not (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet)) {
        Write-Host "Machine unreachable. Skipping." -ForegroundColor Yellow
        continue
    }

    # Check KBs remotely
    $kbInstalled = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
        param($KBList)
        foreach ($k in $KBList) {
            if (Get-HotFix -Id $k -ErrorAction SilentlyContinue) { return $true }
            if (dism /online /get-packages | Select-String $k) { return $true }
        }
        return $false
    } -ArgumentList (,$KBList)

    if ($kbInstalled) {

        Write-Host "KB found on $ComputerName → Forcing Full SCCM Hardware Inventory Resync..." -ForegroundColor Green

        # Force advanced hardware inventory resync remotely
        Invoke-Command -ComputerName $ComputerName -ScriptBlock {
            $HwiGUID = "{00000000-0000-0000-0000-000000000001}"
            
            # 1. Triga a atualização de políticas básicas da máquina primeiro
            try {
                Invoke-CimMethod -Namespace ROOT\ccm -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = "{00000000-0000-0000-0000-000000000001}" } -ErrorAction SilentlyContinue
                Invoke-CimMethod -Namespace ROOT\ccm -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = "{00000000-0000-0000-0000-000000000121}" } -ErrorAction SilentlyContinue
            } catch {}

            # 2. Deleta o status atual do HWI para forçar um relatório completo (Resync)
            $Instance = Get-CimInstance -Namespace ROOT\ccm\InvAgt -Query "SELECT * FROM InventoryActionStatus WHERE InventoryActionID='$HwiGUID'" -ErrorAction SilentlyContinue
            if ($Instance) { $Instance | Remove-CimInstance -ErrorAction SilentlyContinue }
            
            # 3. Dispara o agendamento do Inventário de Hardware
            Invoke-CimMethod -Namespace ROOT\ccm -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = $HwiGUID } -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
            
            # 4. Verifica no Log local se o comando foi ignorado por fila cheia
            $Log = "$env:SystemRoot\CCM\Logs\InventoryAgent.log"
            if (Test-Path $Log) {
                $LogEntries = Select-String -Path $Log -SimpleMatch $HwiGUID -ErrorAction SilentlyContinue | Select-Object -Last 1
                if ($LogEntries -and ($LogEntries.Line -match "already in queue. Message ignored.")) {
                    
                    # Limpa a fila travada reiniciando o serviço CcmExec
                    Stop-Service -Name CcmExec -Force -ErrorAction SilentlyContinue
                    $QueuePath = "$env:SystemRoot\CCM\ServiceData\Messaging\EndpointQueues\InventoryAgent"
                    if (Test-Path $QueuePath) { Remove-Item -Path $QueuePath -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue }
                    Start-Service -Name CcmExec -ErrorAction SilentlyContinue
                    
                    # Aguarda o serviço estabilizar e força o resync novamente
                    Start-Sleep -Seconds 10
                    $Instance = Get-CimInstance -Namespace ROOT\ccm\InvAgt -Query "SELECT * FROM InventoryActionStatus WHERE InventoryActionID='$HwiGUID'" -ErrorAction SilentlyContinue
                    if ($Instance) { $Instance | Remove-CimInstance -ErrorAction SilentlyContinue }
                    Invoke-CimMethod -Namespace ROOT\ccm -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = $HwiGUID } -ErrorAction SilentlyContinue
                }
            }
        }

        # Pausa no servidor SCCM para permitir o processamento inicial da máquina remota
        Start-Sleep -Seconds 5

        Write-Host "Removing $ComputerName from collection..." -ForegroundColor Cyan

        # Remove do escopo da Collection do SCCM
        Remove-CMDeviceCollectionDirectMembershipRule `
            -CollectionName $CollectionName `
            -ResourceId $dev.ResourceID `
            -Force `
            -ErrorAction SilentlyContinue

        Write-Host "Removed successfully." -ForegroundColor Green
    }
    else {
        Write-Host "KB NOT installed → Machine remains in the collection." -ForegroundColor Yellow
    }
}

Write-Host "`nProcess completed." -ForegroundColor Cyan
