# 1. Pergunta o nome da máquina
$ComputerName = Read-Host "Digite o nome da máquina (ou pressione Enter para Localhost)"
if ([string]::IsNullOrWhiteSpace($ComputerName)) { $ComputerName = "localhost" }

Write-Host "`nConectando a [$ComputerName] e buscando entradas ODBC via WinRM..." -ForegroundColor Cyan

# Bloco de código que será executado diretamente na máquina remota
$ScriptBlock = {
    $OdbcPaths = @(
        @{ Path = "HKLM:\Software\ODBC\ODBC.INI\ODBC Data Sources"; Arch = "64-bit"; Type = "System DSN" },
        @{ Path = "HKLM:\Software\Wow6432Node\ODBC\ODBC.INI\ODBC Data Sources"; Arch = "32-bit"; Type = "System DSN" },
        @{ Path = "HKCU:\Software\ODBC\ODBC.INI\ODBC Data Sources"; Arch = "64-bit"; Type = "User DSN" }
    )

    $ResultadosLocal = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($Item in $OdbcPaths) {
        if (Test-Path $Item.Path) {
            $Drivers = Get-ItemProperty -Path $Item.Path
            $Properties = $Drivers.PSObject.Properties | Where-Object { $_.Name -notmatch "PSPath|PSParentPath|PSChildName|PSDrive|PSProvider" }

            foreach ($Prop in $Properties) {
                $DsnName = $Prop.Name
                $DriverName = $Prop.Value
                
                # Entra na subchave do DSN para buscar o usuário
                $DsnPath = Join-Path ($Item.Path) $DsnName
                $User = "Não especificado"
                
                if (Test-Path $DsnPath) {
                    $DsnDetails = Get-ItemProperty -Path $DsnPath -ErrorAction SilentlyContinue
                    if ($DsnDetails.UID) { $User = $DsnDetails.UID }
                    elseif ($DsnDetails.LastUser) { $User = $DsnDetails.LastUser }
                }

                $ResultadosLocal.Add([PSCustomObject]@{
                    "Nome do DSN" = $DsnName
                    "Tipo"        = $Item.Type
                    "Arquitetura" = $Item.Arch
                    "Usuário"     = $User
                    "Driver"      = $DriverName
                })
            }
        }
    }
    return $ResultadosLocal
}

try {
    # Executa localmente ou envia o comando para a máquina remota
    if ($ComputerName -eq "localhost" -or $ComputerName -eq $env:COMPUTERNAME) {
        $Resultados = Invoke-Command -ScriptBlock $ScriptBlock
    } else {
        $Resultados = Invoke-Command -ComputerName $ComputerName -ScriptBlock $ScriptBlock -ErrorAction Stop
    }

    # 2 e 3. Exibe a lista final formatada
    if ($Resultados) {
        Write-Host "`nEntradas ODBC encontradas em [$ComputerName]:" -ForegroundColor Green
        $Resultados | Select-Object "Nome do DSN", "Tipo", "Arquitetura", "Usuário", "Driver" | Format-Table -AutoSize
    } else {
        Write-Host "`nNenhuma entrada ODBC encontrada." -ForegroundColor Yellow
    }
} catch {
    Write-Error "Erro ao conectar via WinRM na máquina [$ComputerName]: $_"
    Write-Host "`n[DICA] Se o erro persistir, certifique-se de que o PowerShell Remoto (WinRM) está ativo na máquina alvo executando o comando 'Enable-PSRemoting' nela." -ForegroundColor Yellow
}
