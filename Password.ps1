# Solicita o nome do computador
$deviceName = Read-Host "Digite o nome do dispositivo"

# Executa o comando para obter a senha LAPS
try {
    $result = Get-AdmPwdPassword -ComputerName $deviceName
    Write-Host "`nDispositivo: $($result.ComputerName)" -ForegroundColor Cyan
    Write-Host "Senha:       $($result.Password)" -ForegroundColor Yellow
    Write-Host "Expira em:   $($result.ExpirationTimestamp)" -ForegroundColor Gray
} catch {
    Write-Host "`nErro ao obter a senha. Verifique se o nome do dispositivo está correto e se você tem permissão." -ForegroundColor Red
}

# Pausa compatível com qualquer ambiente
Write-Host "`nPressione Enter para sair..."
Read-Host
