Write-Host "=======================================================================" -ForegroundColor Cyan
Write-Host "   Script de Correção Global (Remoto via PowerShell)                  " -ForegroundColor Cyan
Write-Host "   Alvos: Windows Update, Delivery Optimization e SCCM               " -ForegroundColor Cyan
Write-Host "=======================================================================" -ForegroundColor Cyan

# 1. Solicita a lista de máquinas ao usuário
$InputComputers = Read-Host "Digite o nome das máquinas separadas por vírgula (ex: comp1, comp2)"

if ([string]::IsNullOrWhiteSpace($InputComputers)) {
    Write-Warning "Nenhuma máquina inserida. Encerrando o script."
    Exit
}

# Divide a entrada em uma lista, limpa espaços extras e remove valores vazios
$TargetComputers = $InputComputers -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

# Bloco de script com a lógica que será executada dentro das máquinas remotas
$ScriptBlock = {
    $Hostname = hostname
    $ErrorActionPreference = "SilentlyContinue"

    # -------------------------------------------------------------------------
    # PARTE 1: Parar os Serviços Necessários
    # -------------------------------------------------------------------------
    Write-Host "[$Hostname] === Parando serviços de atualização e gerenciamento... ===" -ForegroundColor Yellow
    Stop-Service -Name "DoSvc" -Force                    # Delivery Optimization
    Stop-Service -Name "wuauserv" -Force                 # Windows Update
    Stop-Service -Name "bits" -Force                     # Background Intelligent Transfer Service
    Stop-Service -Name "ccmexec" -Force                  # SCCM Agent

    # -------------------------------------------------------------------------
    # PARTE 2: Limpeza do Delivery Optimization (DO)
    # -------------------------------------------------------------------------
    Write-Host "[$Hostname] Removendo registro de política DeliveryOptimization..." -ForegroundColor White
    $RegPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"
    if (Test-Path $RegPath) {
        Remove-Item -Path $RegPath -Recurse -Force
    }

    Write-Host "[$Hostname] Limpando pasta GroupPolicy..." -ForegroundColor White
    $GpoPath1 = "$env:SystemRoot\System32\GroupPolicy"
    if (Test-Path $GpoPath1) {
        Remove-Item -Path $GpoPath1 -Recurse -Force
    }

    Write-Host "[$Hostname] Limpando pasta GroupPolicyUsers..." -ForegroundColor White
    $GpoPath2 = "$env:SystemRoot\System32\GroupPolicyUsers"
    if (Test-Path $GpoPath2) {
        Remove-Item -Path $GpoPath2 -Recurse -Force
    }

    Write-Host "[$Hostname] Limpando cache local do Delivery Optimization..." -ForegroundColor White
    $DoCachePath = "$env:SystemDrive\ProgramData\Microsoft\Network\Downloader"
    if (Test-Path $DoCachePath) {
        Remove-Item -Path "$DoCachePath\*" -Recurse -Force
    }

    # -------------------------------------------------------------------------
    # PARTE 3: Limpeza do Windows Update & Pastas de Cache
    # -------------------------------------------------------------------------
    Write-Host "[$Hostname] Limpando as pastas de cache local do Windows Update..." -ForegroundColor White
    
    $SoftwareDistPath = "$env:windir\SoftwareDistribution"
    if (Test-Path $SoftwareDistPath) {
        Remove-Item -Path $SoftwareDistPath -Recurse -Force
    }

    $Catroot2Path = "$env:windir\System32\catroot2"
    if (Test-Path $Catroot2Path) {
        Remove-Item -Path $Catroot2Path -Recurse -Force
    }

    # -------------------------------------------------------------------------
    # PARTE 4: Reiniciar os Serviços
    # -------------------------------------------------------------------------
    Write-Host "[$Hostname] === Reiniciando os serviços... ===" -ForegroundColor Yellow
    Start-Service -Name "DoSvc"
    Start-Service -Name "wuauserv"
    Start-Service -Name "bits"
    Start-Service -Name "ccmexec"

    # Aguarda alguns segundos para a estabilização do agente SCCM
    Write-Host "[$Hostname] Aguardando 5 segundos para estabilização do agente SCCM..." -ForegroundColor Gray
    Start-Sleep -Seconds 5

    # -------------------------------------------------------------------------
    # PARTE 5: Forçar Atualizações de Políticas e Patches
    # -------------------------------------------------------------------------
    Write-Host "[$Hostname] === Forçando atualização de GPO (gpupdate) ===" -ForegroundColor Yellow
    gpupdate /force /wait:0 *> $null

    Write-Host "[$Hostname] Forçando novo ciclo de avaliação de patches no SCCM..." -ForegroundColor Green
    Invoke-WMIMethod -Namespace "root\ccm\invcomp" -Class "CCM_SoftwareUpdatesManager" -Name "InstallUpdates" -ArgumentList $null
}

# -----------------------------------------------------------------------------
# EXECUÇÃO PRINCIPAL (Loop através das máquinas informadas)
# -----------------------------------------------------------------------------
foreach ($Computer in $TargetComputers) {
    Write-Host ""
    Write-Host "=======================================================================" -ForegroundColor Magenta
    Write-Host " INICIANDO EXECUÇÃO NA MÁQUINA: $Computer" -ForegroundColor Magenta
    Write-Host "=======================================================================" -ForegroundColor Magenta

    # Testa se a máquina responde ao ping antes de tentar conectar via WinRM
    if (Test-Connection -ComputerName $Computer -Count 1 -Quiet) {
        # Executa o bloco de comandos remotamente
        Invoke-Command -ComputerName $Computer -ScriptBlock $ScriptBlock
        
        Write-Host ""
        Write-Host "=======================================================================" -ForegroundColor Cyan
        Write-Host " Execução Remota Concluída com Sucesso em: $Computer" -ForegroundColor Cyan
        Write-Host "=======================================================================" -ForegroundColor Cyan
    } else {
        Write-Warning "A máquina $Computer está OFFLINE ou inacessível no momento."
    }
    
    Write-Host ""
    Write-Host "Fim da execução para: $Computer" -ForegroundColor Gray
}

Write-Host ""
Write-Host "=======================================================================" -ForegroundColor Cyan
Write-Host " Tarefa Concluída em todas as Máquinas Informadas!                     " -ForegroundColor Cyan
Write-Host "=======================================================================" -ForegroundColor Cyan
