# Permite execução temporária de scripts no escopo atual
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# Lista de GUIDs dos produtos a serem removidos
$guids = @(
    "{3E532AF4-B9B1-4DE0-9511-7ACEB14C8D6D}",
    "{ECC23FD6-535B-43CB-894B-F47FA605EBB3}",
    "{98D7AA09-44E1-4469-AB34-BFDC9A6890DD}",
    "{83C9183A-A0F9-4E57-ACEC-4282F1028D25}"
)

foreach ($guid in $guids) {
    Write-Host "Attempting to uninstall product with GUID: $guid" -ForegroundColor Cyan
    $uninstall = Start-Process "msiexec.exe" -ArgumentList "/x $guid /quiet /norestart" -Wait -PassThru

    Start-Sleep -Seconds 5

    # Verifica se ainda está instalado
    $check = Get-WmiObject -Class Win32_Product | Where-Object { $_.IdentifyingNumber -eq $guid }

    if ($check) {
        Write-Host "? Still installed: $($check.Name)" -ForegroundColor Red
    } else {
        Write-Host "? Successfully removed: $guid" -ForegroundColor Green
    }
}
