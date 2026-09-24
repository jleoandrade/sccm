# --- CONFIGURAÇÕES DO SCRIPT ---
$ComputerName = "1585207A" #MACHINE NAME
$LocalMsuPath = "\\Njnwksms08v\Automation\KBs\23h2\*.msu"             # Pasta local de origem
$RemoteFolder = "C:\temp\kb\23h2"         # Pasta destino na máquina remota

# --- RESOLUÇÃO DO ARQUIVO LOCAL ---
$MsuFile = Get-Item -Path $LocalMsuPath -ErrorAction Stop
$FileName = $MsuFile.Name

# Extrai o ID do KB do nome do arquivo (ex: "Windows11.0-KB5012345-x64.msu" -> "KB5012345")
if ($FileName -match "KB\d+") {
    $KbId = $Matches[0]
} else {
    $KbId = "KB-Instalacao"
}

# --- COPIA DO ARQUIVO ---
Write-Host "Criando pasta remota e copiando arquivo..." -ForegroundColor Cyan
$RemoteSharePath = "\\$ComputerName\c$\temp\kb\23h2"

if (-not (Test-Path $RemoteSharePath)) {
    New-Item -ItemType Directory -Path $RemoteSharePath -Force | Out-Null
}

Copy-Item -Path $MsuFile.FullName -Destination $RemoteSharePath -Force
Write-Host "Arquivo copiado com sucesso para o destino." -ForegroundColor Green

# --- EXECUÇÃO REMOTA ---
Write-Host "Iniciando sessão remota em $ComputerName..." -ForegroundColor Cyan

Invoke-Command -ComputerName $ComputerName -ScriptBlock {
    param($FileName, $KbId, $RemoteFolder)

    $msuPath = Join-Path $RemoteFolder $FileName

    # Função interna para validar se o KB já consta no sistema
    function Test-KBInstalled ($KbId) {
        $search = Get-HotFix -Id $KbId -ErrorAction SilentlyContinue
        return ($null -ne $search)
    }

    # Verifica se já está instalado antes de começar
    if (Test-KBInstalled -KbId $KbId) {
        Write-Host "$KbId já está instalado nesta máquina." -ForegroundColor Green
        return
    }

    # Método 1: Tentativa com WUSA
    Write-Host "Installing $KbId via WUSA..." -ForegroundColor Cyan
    $wusaLog = Join-Path $RemoteFolder "$KbId-wusa.log"
    
    # Executa o WUSA silenciosamente sem reiniciar
    $process = Start-Process "wusa.exe" -ArgumentList "`"$msuPath`" /quiet /norestart /log:`"$wusaLog`"" -Wait -PassThru
    
    Start-Sleep -Seconds 20

    if (Test-KBInstalled -KbId $KbId) {
        Write-Host "$KbId installed successfully via WUSA." -ForegroundColor Green
        return
    }

    Write-Host "$KbId not confirmed after WUSA. Trying DISM fallback..." -ForegroundColor Yellow

    # Método 2: Fallback com DISM /Add-Package
    $dismLog = Join-Path $RemoteFolder "$KbId-dism.log"
    $dismCmd = "dism /online /add-package /packagepath:`"$msuPath`" /logpath:`"$dismLog`" /norestart"
    
    Write-Host "Executing: $dismCmd" -ForegroundColor DarkCyan
    # Executa via cmd.exe conforme sua estrutura original
    cmd.exe /c $dismCmd

    Start-Sleep -Seconds 30

    # Validação final pós-DISM
    if (Test-KBInstalled -KbId $KbId) {
        Write-Host "$KbId installed successfully via DISM." -ForegroundColor Green
    } else {
        Write-Warning "Falha ao confirmar a instalacao de $KbId. Verifique os logs em $RemoteFolder"
    }

} -ArgumentList $FileName, $KbId, $RemoteFolder
