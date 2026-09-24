# --- CONFIGURAÇÕES DE CONEXÃO ---
$Server   = "NJNWKSMS08V"
$Database = "CM_A03"

# --- CONFIGURAÇÃO DO ARQUIVO DE SAÍDA ---
$TargetFolder = "C:\temp"
$Timestamp    = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$CsvPath      = Join-Path $TargetFolder "repot-all-enterprise($Timestamp).csv"

# Garante que o diretório C:\temp exista
if (-not (Test-Path $TargetFolder)) {
    New-Item -ItemType Directory -Path $TargetFolder -Force | Out-Null
}

# --- QUERY SQL COMPLETA (CORRIGIDA) ---
$SqlQuery = @"
/*
Combined query returning COMPLIANT devices only.
Compliant = devices that HAVE one or more of the KBs listed below.
*/

/* Collection Variables */
DECLARE @CollectionID NVARCHAR(8) = 'A0300E27'; -- All Enterprise MDTs and Workstation

/* Deployment Variable */
DECLARE @AssignmentID INT = 16785848;

/* Microsoft KB Variables */
DECLARE @KBs TABLE (KB NVARCHAR(20));
INSERT INTO @KBs (KB) VALUES
('KB5093998'), -- JUN
('KB5094126'); -- JUN

WITH Members AS (
    SELECT fcm.ResourceID
    FROM v_FullCollectionMembership AS fcm
    WHERE fcm.CollectionID = @CollectionID
),
KBList AS (
    SELECT UPPER(KB) AS KBLabel
    FROM @KBs
),
BaseData AS (
    SELECT
        m.ResourceID,
        rs.Name0 AS ComputerName,

        LOWER(
            COALESCE(
                CASE
                    WHEN cs.UserName0 IS NOT NULL AND cs.UserName0 <> '' THEN
                        CASE
                            WHEN CHARINDEX('\', cs.UserName0) > 0
                                THEN SUBSTRING(cs.UserName0, CHARINDEX('\', cs.UserName0) + 1, LEN(cs.UserName0))
                            WHEN CHARINDEX('@', cs.UserName0) > 0
                                THEN LEFT(cs.UserName0, CHARINDEX('@', cs.UserName0) - 1)
                            ELSE cs.UserName0
                        END
                    ELSE NULL
                END,
                CASE
                    WHEN rs.User_Name0 IS NOT NULL AND rs.User_Name0 <> '' THEN
                        CASE
                            WHEN CHARINDEX('\', rs.User_Name0) > 0
                                THEN SUBSTRING(rs.User_Name0, CHARINDEX('\', rs.User_Name0) + 1, LEN(rs.User_Name0))
                            WHEN CHARINDEX('@', rs.User_Name0) > 0
                                THEN LEFT(rs.User_Name0, CHARINDEX('@', rs.User_Name0) - 1)
                            ELSE rs.User_Name0
                        END
                    ELSE NULL
                END
            )
        ) AS UserId,

        CONVERT(date, ch.LastActiveTime) AS LastActivity
    FROM Members AS m
    JOIN v_R_System AS rs ON rs.ResourceID = m.ResourceID
    LEFT JOIN v_GS_COMPUTER_SYSTEM AS cs ON cs.ResourceID = m.ResourceID
    LEFT JOIN v_GS_OPERATING_SYSTEM AS os ON os.ResourceID = m.ResourceID
    LEFT JOIN v_CH_ClientSummary AS ch ON ch.ResourceID = m.ResourceID

    /* COMPLIANT FILTER — device has at least one matching KB */
    WHERE EXISTS (
        SELECT 1
        FROM v_GS_QUICK_FIX_ENGINEERING AS qfe
        JOIN KBList AS k ON UPPER(qfe.HotFixID0) = k.KBLabel
        WHERE qfe.ResourceID = m.ResourceID
    )
),
AssignmentData AS (
    SELECT
        cia.AssignmentID,
        cas.ResourceID,
        coll.Name AS Collection_Name,
        coll.CollectionID AS Collection_ID,
        sn.StateName AS Status_State,
        cas.LastEnforcementMessageTime AS Last_Modification,
        cas.LastEnforcementErrorCode AS Error_Code_ExitCode
    FROM v_CIAssignment cia
    JOIN v_Collection coll ON cia.CollectionID = coll.CollectionID
    JOIN v_CIAssignmentStatus cas ON cia.AssignmentID = cas.AssignmentID
    JOIN v_R_System sys ON cas.ResourceID = sys.ResourceID
    JOIN v_AssignmentState_Combined assc 
        ON cia.AssignmentID = assc.AssignmentID 
       AND cas.ResourceID = assc.ResourceID
    JOIN v_StateNames sn 
        ON assc.StateType = sn.TopicType 
       AND sn.StateID = ISNULL(assc.StateID, 0)
    WHERE cia.AssignmentID = @AssignmentID
)

SELECT 
    b.ComputerName,
    b.UserId,
    cdr.DeviceOSBuild AS FullOSBuild,
    b.LastActivity,
    adusr.Mail0 AS User_Email,
    a.Collection_Name,
    a.Collection_ID,
    a.Status_State,
    a.Last_Modification,
    a.Error_Code_ExitCode,

    CASE 
        WHEN a.Error_Code_ExitCode IS NULL THEN NULL
        ELSE '0x' +
             SUBSTRING(
                 master.dbo.fn_varbintohexstr(
                     CONVERT(VARBINARY(4),
                        ((a.Error_Code_ExitCode % 4294967296 + 4294967296) % 4294967296)
                     )
                 ),
                 3,
                 8
             )
    END AS Hex_Error_Code

FROM BaseData b
LEFT JOIN AssignmentData a
    ON b.ResourceID = a.ResourceID
LEFT JOIN v_R_User adusr
    ON LOWER(adusr.User_Name0) = b.UserId
LEFT JOIN v_CombinedDeviceResources cdr
    ON cdr.MachineID = b.ResourceID
ORDER BY a.Status_State, b.ComputerName;
"@

# --- EXECUÇÃO VIA DRIVER NATIVO DOTNET ---
try {
    Write-Host "Conectando e extraindo dados do banco via .NET..." -ForegroundColor Cyan
    
    $ConnectionString = "Server=$Server;Database=$Database;Integrated Security=True;"
    $Connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    $Command = New-Object System.Data.SqlClient.SqlCommand($SqlQuery, $Connection)
    $Command.CommandTimeout = 120 # 2 minutos de timeout para queries grandes
    
    $Adapter = New-Object System.Data.SqlClient.SqlDataAdapter($Command)
    $DataTable = New-Object System.Data.DataTable
    
    $Connection.Open()
    $Null = $Adapter.Fill($DataTable)
    $Connection.Close()

    if ($DataTable.Rows.Count -gt 0) {
        Write-Host "Exportando $($DataTable.Rows.Count) linhas para o CSV..." -ForegroundColor Cyan
        $DataTable | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Delimiter ","
        Write-Host "Arquivo gerado com sucesso em: $CsvPath" -ForegroundColor Green
    } else {
        Write-Host "A query rodou, mas retornou zero resultados." -ForegroundColor Yellow
    }
}
catch {
    Write-Error "Erro crítico na execução: $_"
    if ($Connection.State -eq "Open") { $Connection.Close() }
}

Read-Host "`nPressione Enter para fechar esta janela..."
