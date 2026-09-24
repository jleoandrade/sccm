# Solicita o nome da máquina alvo
$computerName = Read-Host "Digite o nome da máquina alvo"

Write-Host "Iniciando o processo na máquina: $computerName" -ForegroundColor Cyan

# Executa o bloco de comandos remotamente na máquina especificada
Invoke-Command -ComputerName $computerName -ScriptBlock {
    # 1. Reseta permissões e remove a pasta FireEye em Program Files (x86)
    Write-Host "Removendo arquivos de Program Files (x86)..." -ForegroundColor Yellow
    icacls "C:\Program Files (x86)\FireEye" /reset /t /c /q | Out-Null
    rd /s /q "C:\Program Files (x86)\FireEye"

    # 2. Reseta permissões e remove a pasta FireEye em ProgramData
    Write-Host "Removendo arquivos de ProgramData..." -ForegroundColor Yellow
    icacls "C:\ProgramData\FireEye" /reset /t /c /q | Out-Null
    rd /s /q "C:\ProgramData\FireEye"

    # 3. Deleta a chave de registro do serviço xagt
    Write-Host "Removendo a chave de registro xagt..." -ForegroundColor Yellow
    reg delete "HKLM\SYSTEM\CurrentControlSet\Services\xagt" /f | Out-Null

    # 4. Verificação final da existência da chave de registro
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\xagt"
    Write-Host "`n[VERIFICAÇÃO FINAL]" -ForegroundColor Cyan
    
    if (Test-Path $regPath) {
        Write-Host "AVISO: A chave HKLM\SYSTEM\CurrentControlSet\Services\xagt AINDA EXISTE." -ForegroundColor Red
    } else {
        Write-Host "SUCESSO: A chave HKLM\SYSTEM\CurrentControlSet\Services\xagt foi removida ou não existe." -ForegroundColor Green
    }
}
