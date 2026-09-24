<#
.SYNOPSIS
    Exporta o inventário de todas as Applications do MECM/SCCM
    (Software Library > Application Management > Applications):
    nome, Deployment Type, tecnologia, Content Location,
    Installation Program e Uninstall Program.

.DESCRIPTION
    Script SOMENTE LEITURA: não altera nada no site.
    Gera uma linha por Deployment Type (uma Application pode ter vários).

.EXAMPLE
    .\Export-CMApplicationInventory.ps1 -SiteCode ABC
    .\Export-CMApplicationInventory.ps1 -SiteCode ABC -OutputPath C:\Temp\apps.csv -TestContent

.NOTES
    - Rodar em Windows PowerShell 5.1 numa máquina com o console do MECM instalado.
    - A conta precisa de pelo menos permissão de leitura (Read) nas Applications (RBAC).
#>

param(
    [Parameter(Mandatory)]
    [string]$SiteCode,                                                    # Código do site, ex.: ABC

    [string]$OutputPath = "$env:USERPROFILE\Desktop\CM_Applications.csv", # Caminho ABSOLUTO do CSV de saída

    [switch]$TestContent                                                  # Se informado, testa se a pasta de origem existe
)

# 1. Monta o caminho do módulo a partir da variável que o instalador do console cria
#    (SMS_ADMIN_UI_PATH aponta para ...\AdminConsole\bin\i386; o .psd1 fica em ...\AdminConsole\bin)
$modulePath = Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1'

# 2. Carrega o módulo; se falhar (console não instalado), para o script aqui
Import-Module $modulePath -ErrorAction Stop

# 3. Guarda a pasta atual para voltar a ela no final
$originalLocation = Get-Location

# 4. Entra no "drive" do site (ex.: ABC:) - os cmdlets do CM só funcionam dentro dele
Set-Location "$($SiteCode):" -ErrorAction Stop

try {
    # 5. Busca todas as Applications (revisão mais recente), incluindo o XML com os Deployment Types.
    #    NÃO usar -Fast aqui: o -Fast omite justamente o SDMPackageXML de que precisamos.
    $apps = Get-CMApplication
    Write-Host "Applications encontradas: $($apps.Count)" -ForegroundColor Cyan

    # 6. Percorre cada Application e acumula as linhas do relatório em $result
    $result = foreach ($app in $apps) {

        # 7. Converte o XML (SDMPackageXML) num objeto navegável, com a classe do próprio SDK do CM
        $sdm = [Microsoft.ConfigurationManagement.ApplicationManagement.Serialization.SccmSerializer]::DeserializeFromString($app.SDMPackageXML, $true)

        # 8. Application sem Deployment Type: registra mesmo assim, para aparecer na revisão
        if ($sdm.DeploymentTypes.Count -eq 0) {
            [pscustomobject]@{
                ApplicationName  = $app.LocalizedDisplayName
                SoftwareVersion  = $app.SoftwareVersion
                DeploymentType   = '(nenhum Deployment Type)'
                Technology       = $null
                ContentLocation  = $null
                InstallProgram   = $null
                UninstallProgram = $null
                ContentExists    = $null
            }
            continue
        }

        # 9. Uma linha por Deployment Type
        foreach ($dt in $sdm.DeploymentTypes) {

            # 10. Content Location: primeira origem de conteúdo do instalador (o caminho UNC da aba Content)
            $location = ($dt.Installer.Contents | Select-Object -First 1).Location

            # 11. Opcional: testa se a pasta existe. O prefixo FileSystem:: é obrigatório porque
            #     estamos dentro do drive do CM (ABC:), e não do provider de arquivos
            $exists = $null
            if ($TestContent -and $location) {
                $exists = Test-Path -LiteralPath "FileSystem::$location"
            }

            # 12. Monta a linha. Em tipos como App-V ou pacotes .appx, os comandos vêm vazios - isso é esperado
            [pscustomobject]@{
                ApplicationName  = $app.LocalizedDisplayName
                SoftwareVersion  = $app.SoftwareVersion
                DeploymentType   = $dt.Title
                Technology       = $dt.Technology              # MSI, Script, AppV5X, Deeplink, etc.
                ContentLocation  = $location
                InstallProgram   = $dt.Installer.InstallCommandLine
                UninstallProgram = $dt.Installer.UninstallCommandLine
                ContentExists    = $exists
            }
        }
    }
}
finally {
    # 13. Volta para a pasta original SEMPRE, mesmo se der erro no meio
    Set-Location $originalLocation
}

# 14. Exporta o CSV já fora do drive do CM. Delimitador ';' para abrir direto no Excel em pt-BR
$result | Sort-Object ApplicationName, DeploymentType |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 -Delimiter ';'

Write-Host "Linhas exportadas: $(@($result).Count) -> $OutputPath" -ForegroundColor Green
