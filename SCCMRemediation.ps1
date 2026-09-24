# Coleta os dados de input e define como variáveis globais da sessão
$Global:Computer = Read-Host "Enter target computer name"
$Global:Servidor = Read-Host "Enter SCCM Server name or FQDN (e.g., sccm01.domain.local)"
$TargetComputer = $Global:Computer

Write-Host ""
Write-Host "============================================="
Write-Host "BLOQUE 1: VALIDAÇÃO INICIAL COM MÁQUINA: $Global:Computer"
Write-Host "============================================="

# Validação Inicial de Conectividade ICMP
Write-Host "[LOCAL] Testing network connectivity..."
if (-not (Test-Connection -ComputerName $Global:Computer -Count 2 -Quiet)) {
    Write-Host "[LOCAL] ERROR: Machine not reachable via ICMP. Verify network connection." -ForegroundColor Red
    exit
}

# Validação e Ativação Proativa do WinRM
Write-Output "Checking WinRM connectivity with target host..."
$winrmTest = Test-WSMan -ComputerName $TargetComputer -ErrorAction SilentlyContinue

if (-not $winrmTest) {
    Write-Warning "WinRM is not responding on the target. Attempting remote forced provisioning..."
    
    $WinRMSetupBlock = {
        $LogDir  = "$env:ProgramData\SCCM_Scripts\WinRM"
        $LogFile = Join-Path $LogDir "Enable-WinRM_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

        if (-not (Test-Path $LogDir)) { 
            New-Item -Path $LogDir -ItemType Directory -Force | Out-Null 
        }

        function Write-Log {
            param([string]$Message, [string]$Level = "INFO")
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $line = "[$timestamp] [$Level] $Message"
            Add-Content -Path $LogFile -Value $line
        }

        try {
            Write-Log "===== Starting proactive WinRM enabling via Deploy Script ====="
            Set-Service -Name WinRM -StartupType Automatic -ErrorAction Stop
            if ((Get-Service -Name WinRM).Status -ne 'Running') {
                Start-Service -Name WinRM -ErrorAction Stop
            }
            Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop
            $listenerHTTP = winrm enumerate winrm/config/Listener 2>$null | Select-String "Transport = HTTP"
            if (-not $listenerHTTP) { winrm quickconfig -quiet | Out-Null }
            Enable-NetFirewallRule -DisplayName "Windows Remote Management*" -ErrorAction SilentlyContinue
            Write-Log "===== WinRM enabling completed successfully ====="
        } catch {
            Write-Log "ERROR during local provisioning: $($_.Exception.Message)" "ERROR"
        }
    }

    try {
        Write-Output "Invoking WinRM initialization via RPC/WMI..."
        $encodedBlock = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($WinRMSetupBlock.ToString()))
        Invoke-CimMethod -ClassName Win32_Process -MethodName "Create" -ComputerName $TargetComputer -Arguments @{
            CommandLine = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encodedBlock"
        } | Out-Null
        
        Write-Output "WMI payload delivered. Waiting 10 seconds for the service stack to provision..."
        Start-Sleep -Seconds 10
    } catch {
        Write-Host "Critical Failure: Unable to reach the machine via WinRM, and the WMI/RPC fallback failed as well." -ForegroundColor Red
        exit
    }
} else { Write-Output "WinRM connectivity successfully validated." }

# Criando a PSSession persistente
try {
    $Global:Session = New-PSSession -ComputerName $Global:Computer -ErrorAction Stop
    Write-Host "[LOCAL] PSSession estável estabelecida. Canal de comunicação aberto." -ForegroundColor Green
}
catch {
    Write-Host "[LOCAL] ERROR CRÍTICO: Não foi possível criar canal persistente WinRM. Erro: $($_.Exception.Message)" -ForegroundColor Red
    exit
}
Write-Host ">>> PARTE 1 FINALIZADA COM SUCESSO" -ForegroundColor Green
if (-not $Global:Session) { Write-Host "Erro: Execute o Bloco 1 primeiro para abrir a sessão." -ForegroundColor Red; exit }

Write-Host ""
Write-Host "============================================="
Write-Host "BLOCO 2: EXECUTANDO LIMPEZA REMOTA"
Write-Host "============================================="

try {
    $Result = Invoke-Command -Session $Global:Session -ScriptBlock {
        $Output = [ordered]@{
            Computer = $env:COMPUTERNAME
            Success = $false
            SoftwareDistributionRecreated = $false
            WindowsUpdateHealthy = $false
            Error = $null
        }

        function Fast-Delete($path) {
            if (Test-Path $path) { cmd.exe /c "rmdir /s /q `"$path`"" 2>$null }
        }

        Fast-Delete "C:\Windows\Temp"; New-Item -ItemType Directory -Path "C:\Windows\Temp" -Force | Out-Null
        Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $tempPath = "$($_.FullName)\AppData\Local\Temp"
            Fast-Delete $tempPath; New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
        }
        Fast-Delete $env:TEMP; New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
        Fast-Delete "C:\Windows\Prefetch"; New-Item -ItemType Directory -Path "C:\Windows\Prefetch" -Force | Out-Null
        Remove-Item -Path "C:\Windows\WindowsUpdate.log" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "C:\Windows\SoftwareDistribution\ReportingEvents.log" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "C:\Windows\Logs\CBS\*.log" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "C:\Windows\Logs\CBS\*.cab" -Force -ErrorAction SilentlyContinue

        $TmpPaths = @("C:\Windows\Temp", "C:\ProgramData\Temp", "C:\Windows\CCM\Temp", "C:\Windows\CCMCache")
        Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $TmpPaths += "$($_.FullName)\AppData\Local\Temp" }
        foreach ($path in $TmpPaths) {
            if (Test-Path $path) { Get-ChildItem -Path $path -Recurse -Force -Include *.tmp -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
        }

        Stop-Service spooler -Force -ErrorAction SilentlyContinue
        Fast-Delete "C:\Windows\System32\spool\PRINTERS"; New-Item -ItemType Directory -Path "C:\Windows\System32\spool\PRINTERS" -Force | Out-Null
        Start-Service spooler -ErrorAction SilentlyContinue

        Fast-Delete "C:\Windows\ccmcache"
        Fast-Delete "C:\Windows\CCM\Temp"
        Fast-Delete "C:\Windows\CCM\Cache"
        Remove-Item "C:\Windows\CCM\*.tmp" -Force -ErrorAction SilentlyContinue
        Remove-Item "C:\Windows\CCM\Logs\*.log" -Force -ErrorAction SilentlyContinue
        Remove-Item "C:\Windows\CCMSetup\*.log" -Force -ErrorAction SilentlyContinue
        Fast-Delete "C:\ProgramData\Microsoft\Windows\WER\ReportQueue"
        Fast-Delete "C:\ProgramData\Microsoft\Windows\WER\ReportArchive"
        Fast-Delete "C:\ProgramData\Microsoft\Windows\WER\Temp"

        Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
        Stop-Service bits -Force -ErrorAction SilentlyContinue
        Stop-Service cryptsvc -Force -ErrorAction SilentlyContinue
        Stop-Service msiserver -Force -ErrorAction SilentlyContinue
        Fast-Delete "$env:windir\SoftwareDistribution"
        Fast-Delete "$env:windir\System32\catroot2"
        Start-Service wuauserv -ErrorAction SilentlyContinue
        Start-Service bits -ErrorAction SilentlyContinue
        Start-Service cryptsvc -ErrorAction SilentlyContinue
        Start-Service msiserver -ErrorAction SilentlyContinue

        Start-Sleep -Seconds 3
        Dism.exe /Online /Cleanup-Image /StartComponentCleanup | Out-Null

        if (Test-Path "$env:windir\SoftwareDistribution") { $Output.SoftwareDistributionRecreated = $true }
        try {
            $Session = New-Object -ComObject Microsoft.Update.Session
            $Searcher = $Session.CreateUpdateSearcher()
            $Searcher.Search("IsInstalled=0") | Out-Null
            $Output.WindowsUpdateHealthy = $true
        } catch { $Output.WindowsUpdateHealthy = $false }

        $Output.Success = $true
        return $Output
    }
    $Result | Format-List
    Write-Host ">>> PARTE 2 FINALIZADA COM SUCESSO" -ForegroundColor Green
}
catch {
    Write-Host "[$Global:Computer] ERRO CRÍTICO NA PARTE 2: $($_.Exception.Message)" -ForegroundColor Red
    exit
}
if (-not $Global:Session) { Write-Host "Erro: Execute o Bloco 1 primeiro para abrir a sessão." -ForegroundColor Red; exit }

Write-Host ""
Write-Host "============================================="
Write-Host "BLOCO 3: DESINSTALAÇÃO DO SCCM"
Write-Host "============================================="

try {
    Invoke-Command -Session $Global:Session -ScriptBlock {
        if (Test-Path "C:\Windows\ccmsetup\ccmsetup.exe") {
            Write-Host "[$env:COMPUTERNAME] Executando ccmsetup.exe /uninstall..." -ForegroundColor Cyan
            Start-Process -FilePath "C:\Windows\ccmsetup\ccmsetup.exe" -ArgumentList "/uninstall" -Wait -NoNewWindow
            
            Write-Host "[$env:COMPUTERNAME] Aguardando a remoção do serviço CcmExec do sistema..." -ForegroundColor Yellow
            $timeout = 0; $serviceExists = $true
            while ($serviceExists -and $timeout -lt 24) {
                if (-not (Get-Service -Name "ccmexec" -ErrorAction SilentlyContinue)) { $serviceExists = $false } 
                else { Start-Sleep -Seconds 5; $timeout++ }
            }
            if (-not $serviceExists) { Write-Host "[$env:COMPUTERNAME] Sucesso: Cliente antigo desinstalado." -ForegroundColor Green }
            else { Write-Host "[$env:COMPUTERNAME] Aviso: Timeout esgotado, ccmexec ainda ativo." -ForegroundColor Yellow }
        } else { Write-Host "[$env:COMPUTERNAME] ccmsetup.exe local não localizado. Nada a desinstalar." -ForegroundColor Gray }
    } -ErrorAction Stop
    Write-Host ">>> PARTE 3 FINALIZADA COM SUCESSO" -ForegroundColor Green
}
catch {
    Write-Host "[$Global:Computer] ERRO CRÍTICO NA PARTE 3: $($_.Exception.Message)" -ForegroundColor Red
    exit
}
if (-not $Global:Session) { Write-Host "Erro: Execute o Bloco 1 primeiro para abrir a sessão." -ForegroundColor Red; exit }
if (-not $Global:Servidor) { $Global:Servidor = Read-Host "Enter SCCM Server name or FQDN" }

# ATENÇÃO: Altere apenas o valor abaixo ("S01") para o seu código de site real do SCCM
# para que o script localize a pasta de distribuição padrão da rede
$SiteCodeDoServidor = "S01" 

Write-Host ""
Write-Host "============================================="
Write-Host "BLOCO 4: INICIALIZAÇÃO DA NOVA INSTALAÇÃO (FIXED)"
Write-Host "============================================="

try {
    # Mapeia o caminho UNC de origem do servidor SCCM
    $SourceNetworkPath = "\\$Global:Servidor\SMS_$SiteCodeDoServidor\Client"

    $InstallResult = Invoke-Command -Session $Global:Session -ScriptBlock {
        param($SccmServer, $SourcePath)
        
        $LocalSetupDir = "C:\Windows\ccmsetup"
        $LocalExe = "C:\Windows\ccmsetup\ccmsetup.exe"
        $CCMArgs = "/mp:$SccmServer SMSSITECODE=AUTO FSP:$SccmServer"
        
        # Correção automatizada de diretório ausente
        if (-not (Test-Path $LocalSetupDir)) {
            New-Item -Path $LocalSetupDir -ItemType Directory -Force | Out-Null
        }

        # Busca e copia o executável de instalação diretamente do compartilhamento do Servidor
        if (-not (Test-Path $LocalExe)) {
            Write-Host "[$env:COMPUTERNAME] Buscando ccmsetup.exe na rede em $SourcePath..." -ForegroundColor Yellow
            if (Test-Path "$SourcePath\ccmsetup.exe") {
                Copy-Item -Path "$SourcePath\ccmsetup.exe" -Destination $LocalExe -Force -ErrorAction SilentlyContinue
                Write-Host "[$env:COMPUTERNAME] Cópia concluída com sucesso." -ForegroundColor Green
            } else {
                return "ERR_SOURCE_NOT_FOUND"
            }
        }

        # Execução segura
        if (Test-Path $LocalExe) {
            Remove-Item -Path "C:\Windows\ccmsetup\Logs\ccmsetup.log" -Force -ErrorAction SilentlyContinue
            Write-Host "[$env:COMPUTERNAME] Disparando instalador atrelado ao servidor: $SccmServer" -ForegroundColor Cyan
            Start-Process -FilePath $LocalExe -ArgumentList $CCMArgs -NoNewWindow
            return "SUCCESS"
        } else {
            return "ERR_EXE_MISSING"
        }
    } -ArgumentList $Global:Servidor, $SourceNetworkPath -ErrorAction Stop

    # Validação estruturada de retornos do bloco remoto
    if ($InstallResult -eq "ERR_SOURCE_NOT_FOUND") {
        Write-Host "[$Global:Computer] ERRO CRÍTICO: Não foi possível acessar o compartilhamento em '$SourceNetworkPath'. Verifique o SiteCode ou permissões." -ForegroundColor Red
        exit
    }
    elseif ($InstallResult -eq "ERR_EXE_MISSING" -or $InstallResult -ne "SUCCESS") {
        Write-Host "[$Global:Computer] ERRO CRÍTICO: Falha ao provisionar ccmsetup.exe localmente na máquina remota. Abortado." -ForegroundColor Red
        exit
    }

    Write-Host ">>> PARTE 4 FINALIZADA COM SUCESSO" -ForegroundColor Green
}
catch {
    Write-Host "[$Global:Computer] ERRO CRÍTICO NA PARTE 4: $($_.Exception.Message)" -ForegroundColor Red
    exit
}
if (-not $Global:Computer) { $Global:Computer = Read-Host "Enter target computer name" }

Write-Host ""
Write-Host "============================================="
Write-Host "BLOCO 5: MONITORAMENTO EM TEMPO REAL"
Write-Host "============================================="
Write-Host "[$Global:Computer] Aguardando o instalador gerar o arquivo ccmsetup.log..." -ForegroundColor Yellow

$LogPath = "\\$Global:Computer\c$\Windows\ccmsetup\Logs\ccmsetup.log"
$logTimeout = 0
Start-Sleep -Seconds 4

while (-not (Test-Path $LogPath) -and ($logTimeout -lt 15)) {
    Start-Sleep -Seconds 5
    $logTimeout++
}

if (Test-Path $LogPath) {
    Write-Host "[$Global:Computer] Conexão com log estabelecida. Transmitindo linhas:" -ForegroundColor Gray
    $Reader = New-Object System.IO.StreamReader([System.IO.File]::Open($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite))
    $Monitoring = $true

    while ($Monitoring) {
        $Line = $Reader.ReadLine()
        if ($Line -ne $null) {
            Write-Host "[$Global:Computer LOG] $Line"
            if ($Line -match "CcmSetup is exiting with return code 0") {
                Write-Host ""
                Write-Host "[$Global:Computer] SUCESSO EXTRAORDINÁRIO: SCCM instalado e integrado ao Site Code via AUTO (Código 0)!" -ForegroundColor Green
                $Monitoring = $false
            }
            elseif ($Line -match "CcmSetup is exiting with return code") {
                Write-Host ""
                Write-Host "[$Global:Computer] ERRO INTERNO: O ccmsetup reportou uma falha de código no log." -ForegroundColor Red
                $Monitoring = $false
            }
        } else {
            Start-Sleep -Seconds 1
            if ($Global:Session) {
                $ProcessCheck = Invoke-Command -Session $Global:Session -ScriptBlock { Get-Process -Name "ccmsetup" -ErrorAction SilentlyContinue }
                if (-not $ProcessCheck -and $Monitoring) {
                    if ($Reader.EndOfStream) {
                        Write-Host ""
                        Write-Host "[$Global:Computer] AVISO: O processo ccmsetup fechou sem capturar a string padrão de encerramento de sucesso." -ForegroundColor Yellow
                        $Monitoring = $false
                    }
                }
            }
        }
    }
    $Reader.Close()
    Write-Host ">>> PARTE 5 FINALIZADA COM SUCESSO" -ForegroundColor Green
} else { Write-Host "[$Global:Computer] ERRO: Arquivo de log não localizado dentro do tempo limite de espera." -ForegroundColor Red }

if ($Global:Session) { Remove-PSSession -Session $Global:Session -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "============================================="
Write-Host "PROCESSO TOTAL FINALIZADO"
Write-Host "============================================="
