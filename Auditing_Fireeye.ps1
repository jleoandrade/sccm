$computerName = Read-Host "Digite o nome da máquina alvo"

Write-Host "`n[INICIANDO AUDITORIA NO COMPUTADOR: $computerName]" -ForegroundColor Cyan

Invoke-Command -ComputerName $computerName -ScriptBlock {
    function Test-Check {
        param([string]$Name, [bool]$Condition, [string]$IfTrue, [string]$IfFalse)
        if ($Condition) {
            Write-Host " -> $Name: $IfTrue" -ForegroundColor Red
        } else {
            Write-Host " -> $Name: $IfFalse" -ForegroundColor Green
        }
    }

    # 1. CHECAGEM DE DIRETÓRIOS E ARQUIVOS
    Write-Host "`n[1/5] Verificando Diretórios no Disco:" -ForegroundColor Yellow
    Test-Check "Pasta Program Files (x86)" (Test-Path "C:\Program Files (x86)\FireEye") "AINDA EXISTE" "Removida/Não existe"
    Test-Check "Pasta ProgramData" (Test-Path "C:\ProgramData\FireEye") "AINDA EXISTE" "Removida/Não existe"

    # 2. CHECAGEM DE PROCESSOS ATIVOS
    Write-Host "`n[2/5] Verificando Processos em Execução:" -ForegroundColor Yellow
    $processos = Get-Process | Where-Object { $_.Name -match "xagt|fe_ad_collector|masvc" }
    if ($processos) {
        foreach ($p in $processos) {
            Write-Host " -> Processo Ativo Encontrado: $($p.Name) (PID: $($p.Id))" -ForegroundColor Red
        }
    } else {
        Write-Host " -> Nenhum processo do FireEye/Trellix rodando no momento." -ForegroundColor Green
    }

    # 3. CHECAGEM DE SERVIÇOS DO WINDOWS
    Write-Host "`n[3/5] Verificando Serviços do Windows:" -ForegroundColor Yellow
    $servicos = Get-Service | Where-Object { $_.Name -match "xagt|FE_Agent|UACProtect|masvc" }
    if ($servicos) {
        foreach ($s in $servicos) {
            Write-Host " -> Serviço Detectado: $($s.Name) [Status: $($s.Status)]" -ForegroundColor Red
        }
    } else {
        Write-Host " -> Nenhum serviço relacionado encontrado." -ForegroundColor Green
    }

    # 4. CHECAGEM DE DRIVERS DE KERNEL
    Write-Host "`n[4/5] Verificando Drivers de Filtro de Sistema (Kernel):" -ForegroundColor Yellow
    $drivers = Get-CimInstance Win32_SystemDriver | Where-Object { $_.Name -match "fe_sysmon|UACProtect" }
    if ($drivers) {
        foreach ($d in $drivers) {
            Write-Host " -> Driver Ativo no Kernel: $($d.Name) [Estado: $($d.State)]" -ForegroundColor Red
        }
    } else {
        Write-Host " -> Nenhum driver de kernel persistente foi detectado." -ForegroundColor Green
    }

    # 5. CHECAGEM DO REGISTRO (CHAVES DE DESINSTALAÇÃO / CMPIVOT)
    Write-Host "`n[5/5] Verificando Registro do Windows (Painel de Controle):" -ForegroundColor Yellow
    
    $regXagt = Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\xagt"
    Test-Check "Chave do Serviço Core (xagt)" $regXagt "AINDA EXISTE" "Removida/Não existe"

    $uninstall64 = Get-ChildItem "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "FireEye" -or (Get-ItemProperty $_.PSPath).DisplayName -match "FireEye|Trellix" }
    $uninstall32 = Get-ChildItem "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "FireEye" -or (Get-ItemProperty $_.PSPath).DisplayName -match "FireEye|Trellix" }

    if ($uninstall64 -or $uninstall32) {
        Write-Host " -> AVISO: O software ainda possui chaves de instalação no Registro. (Motivo do CMPivot acusar instalado)." -ForegroundColor Red
        if ($uninstall64) { Write-Host "    Localizado em: HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall" -ForegroundColor Gray }
        if ($uninstall32) { Write-Host "    Localizado em: HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall" -ForegroundColor Gray }
    } else {
        Write-Host " -> Nenhuma entrada de desinstalação encontrada. Limpo para o CMPivot." -ForegroundColor Green
    }
}
Write-Host "`n[AUDITORIA CONCLUÍDA]" -ForegroundColor Cyan
