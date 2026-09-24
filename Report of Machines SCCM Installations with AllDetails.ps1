# Garante a instalação do módulo de forma silenciosa e segura
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    Install-Module -Name ImportExcel -Force -Scope CurrentUser -ErrorAction SilentlyContinue
}

# 1. Detalhes de Conexão do SCCM
$SiteServer   = "NJNWKSMS08V" # Substitua pelo nome do seu servidor SCCM
$SiteCode     = "A03"                      
$Namespace    = "root\sms\site_$SiteCode"
$CollectionID = "A03002EA"

# 2. Query ao banco central buscando os HotFixes desejados
Write-Host "Fetching HotFix data from SCCM..." -ForegroundColor Cyan
$QueryHF = "SELECT ResourceID, HotFixID, InstalledBy, InstalledOn FROM SMS_G_System_QUICK_FIX_ENGINEERING WHERE HotFixID = 'KB5093998' OR HotFixID = 'KB5094126'"
$HotFixes = Get-CimInstance -ComputerName $SiteServer -Namespace $Namespace -Query $QueryHF -ErrorAction Stop

# 3. Busca a lista de máquinas pertencentes à Collection "All Desktop and MDT Clients"
Write-Host "Fetching fleet machines from Collection ID $CollectionID..." -ForegroundColor Cyan
$QueryColl = "SELECT ResourceID, Name FROM SMS_CM_RES_COLL_$CollectionID"
$CollectionMembers = Get-CimInstance -ComputerName $SiteServer -Namespace $Namespace -Query $QueryColl -ErrorAction Stop

# Cria uma tabela Hash em memória para resolução ultrarrápida (Evita lentidão no servidor)
$CollectionLookup = @{}
foreach ($Member in $CollectionMembers) {
    $CollectionLookup[$Member.ResourceID] = $Member.Name
}

# 4. Filtra, limpa os campos e renomeia as contas conforme solicitado
$Report = $HotFixes | ForEach-Object {
    if ($CollectionLookup.ContainsKey($_.ResourceID)) {
        
        # Lógica de renomear: Se começar com ServiceHLASMSWKS, vira "Manual Installation"
        $Installer = $_.InstalledBy
        if ([string]::IsNullOrWhiteSpace($Installer)) { 
            $Installer = "(blank)" 
        } elseif ($Installer -like "ServiceHLASMSWKS*") { 
            $Installer = "Manual Installation" 
        }

        [PSCustomObject]@{
            MachineName = $CollectionLookup[$_.ResourceID]
            HotFixId    = $_.HotFixID
            InstalledBy = $Installer
            InstalledOn = $_.InstalledOn
        }
    }
}

# 5. Cálculos métricos consolidados da Collection (Garante integridade dos dados)
$TotalCollectionFleet = $CollectionMembers.Count
$UniqueInstalled      = ($Report.MachineName | Select-Object -Unique).Count
$MissingInstallations = $TotalCollectionFleet - $UniqueInstalled
$ComplianceRate       = if ($TotalCollectionFleet -gt 0) { [Math]::Round(($UniqueInstalled / $TotalCollectionFleet) * 100, 2) } else { 0 }

# Bloco de texto solicitado para a aba Summary Total
$FleetSummary = @(
    [PSCustomObject]@{ Metric = "Total Machines";                 Value = $TotalCollectionFleet }
    [PSCustomObject]@{ Metric = "Total Patched Machines";         Value = $UniqueInstalled }
    [PSCustomObject]@{ Metric = "Machines Missing Installations"; Value = $MissingInstallations }
    [PSCustomObject]@{ Metric = "compliance rate";                Value = "$ComplianceRate%" }
)

# 6. Define o caminho do arquivo Excel de saída
$TimeStamp  = Get-Date -Format "yyyy-MM-dd_HHmm"
$OutputPath = "C:\Temp\Collection_Report_SCCM_Installations_$TimeStamp.xlsx"

if (-not (Test-Path "C:\Temp")) { New-Item -ItemType Directory -Path "C:\Temp" | Out-Null }

Write-Host "Generating production-safe Excel sheets..." -ForegroundColor Cyan

# --- PASSO A: Cria a aba base 'Machine_List' com os dados brutos filtrados
$Report | Export-Excel -Path $OutputPath -WorksheetName 'Machine_List' -ClearSheet

# --- PASSO B: Cria a aba 'Summary Total' contendo o bloco métrico textual nas colunas A e B
$FleetSummary | Export-Excel -Path $OutputPath -WorksheetName 'Summary Total' -NoHeader:$false

# --- PASSO C: Insere a Tabela Dinâmica resumida diretamente na aba 'Summary Total' sem parâmetros conflitantes
$Report | Export-Excel -Path $OutputPath `
                       -WorksheetName 'Machine_List' `
                       -PivotTableName 'Summary Total' `
                       -PivotRows @('InstalledBy', 'HotFixId') `
                       -PivotData @{ 'MachineName' = 'Count' }

# --- PASSO D: Cria a nova aba 'Summary Detailed' contendo a Tabela Dinâmica detalhada (Asset Tags + Timestamps)
$Report | Export-Excel -Path $OutputPath `
                       -WorksheetName 'Machine_List' `
                       -PivotTableName 'Summary Detailed' `
                       -PivotRows @('InstalledBy', 'HotFixId', 'MachineName', 'InstalledOn') `
                       -PivotData @{ 'MachineName' = 'Count' } `
                       -Show

Write-Host "`n[SUCCESS] Production-safe Excel Workbook successfully generated!" -ForegroundColor Green
Write-Host "File Output Path: $OutputPath" -ForegroundColor Green
