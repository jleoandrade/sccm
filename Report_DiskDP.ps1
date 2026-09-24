# --- CONFIGURAÇÕES ---
$SiteCode = "A03" # Substitua pelo seu Site Code
$ProviderMachineName = "NJNWKSMS08V.ENTERPRISE.PSEG.COM" # FQDN do seu servidor de site SCCM
$CaminhoCSV = "C:\Temp\Relatorio_DP_Discos.csv"

# 1. Conectar ao SCCM
Write-Host "Conectando ao SCCM..." -ForegroundColor Cyan
$ModulePath = "$($env:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1"
if (!(Get-Module -Name ConfigurationManager)) { Import-Module $ModulePath }
if (!(Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name $SiteCode -PSProvider "AdminUI.PS.Provider\CMSite" -Root $ProviderMachineName
}
Set-Location "$($SiteCode):"

# 2. Coletar DPs e 3. Processar Discos com Percentual
$DPs = Get-CMDistributionPoint | Select-Object -ExpandProperty NetworkOSPath
$Relatorio = @()

foreach ($DP in $DPs) {
    $ServerName = $DP.Replace("\\", "")
    Write-Host "Processando: $ServerName" -ForegroundColor Yellow

    try {
        $Discos = Get-CimInstance -ClassName Win32_LogicalDisk -ComputerName $ServerName -Filter "DriveType=3" -ErrorAction Stop

        foreach ($Disco in $Discos) {
            $Total = [math]::Round($Disco.Size / 1GB, 2)
            $Livre = [math]::Round($Disco.FreeSpace / 1GB, 2)
            # Cálculo do percentual formatado
            $PercentLivre = "{0:P2}" -f ($Disco.FreeSpace / $Disco.Size)

            $Relatorio += [PSCustomObject]@{
                Servidor       = $ServerName
                Drive          = $Disco.DeviceID
                Volume         = $Disco.VolumeName
                Total_GB       = $Total
                Consumido_GB   = [math]::Round($Total - $Livre, 2)
                Livre_GB       = $Livre
                Percent_Livre  = $PercentLivre # Exibe como 00,00%
            }
        }
    } catch {
        Write-Warning "Falha ao acessar $ServerName"
    }
}

# 4. Agrupar (Ordenar) e Gerar CSV
# Ordenamos por Servidor e depois por Drive para o CSV ficar agrupado logicamente
$Relatorio | Sort-Object Servidor, Drive | Export-Csv -Path $CaminhoCSV -NoTypeInformation -Encoding UTF8 -Delimiter ";"

Write-Host "Relatório agrupado gerado em: $CaminhoCSV" -ForegroundColor Green 