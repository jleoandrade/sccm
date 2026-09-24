# 1. Connection Settings and File Path
$ServerName   = "NJNWKSMS08V"
$DatabaseName = "CM_A03" 
$ExcelPath    = "C:\Temp\Report_Day06.11.26.xlsx"
$CompliantText = "Compliant"

# 2. Kill Open Excel Locks & Create Directories
$TargetFileName = Split-Path $ExcelPath -Leaf
$OpenExcelProcesses = Get-Process excel -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like "*$TargetFileName*" }
if ($OpenExcelProcesses) {
    Write-Host "Found open instances of $TargetFileName. Closing them to release file lock..." -ForegroundColor Yellow
    $OpenExcelProcesses | Stop-Process -Force
    Start-Sleep -Seconds 1 
}

# Ensure the directory exists
$TargetDir = Split-Path $ExcelPath -Parent
if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}

# Delete the old file completely if it exists to ensure a clean write
if (Test-Path $ExcelPath) {
    Remove-Item $ExcelPath -Force -ErrorAction SilentlyContinue
}

# 3. Prerequisites Check
if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
    Write-Host "SqlServer module missing. Attempting to install..." -ForegroundColor Yellow
    try {
        Install-Module -Name SqlServer -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Import-Module SqlServer -ErrorAction Stop
    } catch {
        Write-Warning "Could not install SqlServer module. Falling back to native .NET SQL Client..."
    }
}

# 4. Your Complete SQL Query
$SqlQuery = "
DECLARE @CollectionID NVARCHAR(8) = 'A03002CF';
DECLARE @AssignmentID INT = 16785848;

DECLARE @KBs TABLE (KB NVARCHAR(20));
INSERT INTO @KBs (KB) VALUES ('KB5087420'), ('KB5089549');

WITH Members AS (
    SELECT fcm.ResourceID FROM v_FullCollectionMembership AS fcm WHERE fcm.CollectionID = @CollectionID
),
KBList AS (
    SELECT UPPER(KB) AS KBLabel FROM @KBs
),
BaseData AS (
    SELECT
        m.ResourceID,
        rs.Name0 AS ComputerName,
        rs.Resource_Domain_OR_Workgr0 AS DomainName,
        LOWER(COALESCE(
            CASE WHEN cs.UserName0 IS NOT NULL AND cs.UserName0 <> '' THEN
                CASE WHEN CHARINDEX('\', cs.UserName0) > 0 THEN SUBSTRING(cs.UserName0, CHARINDEX('\', cs.UserName0) + 1, LEN(cs.UserName0))
                     WHEN CHARINDEX('@', cs.UserName0) > 0 THEN LEFT(cs.UserName0, CHARINDEX('@', cs.UserName0) - 1)
                     ELSE cs.UserName0 END
            ELSE NULL END,
            CASE WHEN rs.User_Name0 IS NOT NULL AND rs.User_Name0 <> '' THEN
                CASE WHEN CHARINDEX('\', rs.User_Name0) > 0 THEN SUBSTRING(rs.User_Name0, CHARINDEX('\', rs.User_Name0) + 1, LEN(rs.User_Name0))
                     WHEN CHARINDEX('@', rs.User_Name0) > 0 THEN LEFT(rs.User_Name0, CHARINDEX('@', rs.User_Name0) - 1)
                     ELSE rs.User_Name0 END
            ELSE NULL END
        )) AS UserId,
        os.Version0 AS FullOSBuild,
        CONVERT(date, ch.LastActiveTime) AS LastActivity
    FROM Members AS m
    JOIN v_R_System AS rs ON rs.ResourceID = m.ResourceID
    LEFT JOIN v_GS_COMPUTER_SYSTEM AS cs ON cs.ResourceID = m.ResourceID
    LEFT JOIN v_GS_OPERATING_SYSTEM AS os ON os.ResourceID = m.ResourceID
    LEFT JOIN v_CH_ClientSummary AS ch ON ch.ResourceID = m.ResourceID
    WHERE NOT EXISTS (
        SELECT 1 FROM v_GS_QUICK_FIX_ENGINEERING AS qfe JOIN KBList AS k ON UPPER(qfe.HotFixID0) = k.KBLabel WHERE qfe.ResourceID = m.ResourceID
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
    JOIN v_AssignmentState_Combined assc ON cia.AssignmentID = assc.AssignmentID AND cas.ResourceID = assc.ResourceID
    JOIN v_StateNames sn ON assc.StateType = sn.TopicType AND sn.StateID = ISNULL(assc.StateID, 0)
    WHERE cia.AssignmentID = @AssignmentID
)
SELECT 
    b.ComputerName,
    b.DomainName,
    b.UserId,
    b.FullOSBuild,
    b.LastActivity,
    adusr.Mail0 AS User_Email,
    a.Collection_Name,
    a.Collection_ID,
    a.Status_State,
    a.Last_Modification,
    a.Error_Code_ExitCode,
    CASE WHEN a.Error_Code_ExitCode IS NULL THEN NULL
         ELSE '0x' + SUBSTRING(master.dbo.fn_varbintohexstr(CONVERT(VARBINARY(4), ((a.Error_Code_ExitCode & 0xFFFFFFFF)))), 3, 8) END AS Hex_Error_Code
FROM BaseData b
LEFT JOIN AssignmentData a ON b.ResourceID = a.ResourceID
LEFT JOIN v_R_User adusr ON LOWER(adusr.User_Name0) = b.UserId
ORDER BY b.ComputerName, a.Status_State;
"

# 5. Execute Query and Uniform Data Structure
if (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue) {
    $RawData = Invoke-Sqlcmd -ServerInstance $ServerName -Database $DatabaseName -Query $SqlQuery -QueryTimeout 0 -TrustServerCertificate
    $GeneralData = @($RawData | ForEach-Object { [PSCustomObject]$_ })
} else {
    $ConnectionString = "Server=$ServerName;Database=$DatabaseName;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;"
    $Connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    $Command = New-Object System.Data.SqlClient.SqlCommand($SqlQuery, $Connection)
    $Command.CommandTimeout = 0
    $Adapter = New-Object System.Data.SqlClient.SqlDataAdapter($Command)
    $DataTable = New-Object System.Data.DataTable
    $Adapter.Fill($DataTable) | Out-Null
    
    $GeneralData = @()
    foreach ($Row in $DataTable.Rows) {
        $Obj = [Ordered] @{}
        foreach ($Column in $DataTable.Columns) { $Obj[$Column.ColumnName] = $Row[$Column.ColumnName] }
        $GeneralData += [PSCustomObject]$Obj
    }
}

# 6. Result Verification
if ($null -eq $GeneralData -or $GeneralData.Count -eq 0) {
    Write-Warning "The query successfully connected but returned 0 records."
    exit
}

# 7. Separate data by target domains
$NbuData        = @($GeneralData | Where-Object { $_.DomainName -ieq "ENTNBU" })
$EnterpriseData = @($GeneralData | Where-Object { $_.DomainName -ieq "ENTERPRISE" })

# Helper Function to Apply Formatting and Expression-Based Entire Row Highlighting
function Export-AndFormatSheet ($Data, $Path, $SheetName) {
    # 1. Export standard data array 
    $Excel = $Data | Export-Excel -Path $Path -WorksheetName $SheetName -PassThru -AutoSize

    # 2. Bind worksheet metadata context 
    $Worksheet = $Excel.Workbook.Worksheets[$SheetName]
    $TotalRows = $Data.Count + 1

    # 3. Dynamic Entire Row Highlight Formula (Status_State is column I / 9th column)
    # The '$I' anchor locks evaluation horizontally, allowing the style engine to flood color across the row.
    $TargetFormula = "=`$I2=`"$CompliantText`""

    Add-ConditionalFormatting -Worksheet $Worksheet -Range "A2:L$TotalRows" -RuleType Expression -ConditionValue $TargetFormula -ForegroundColor "Black" -BackgroundColor "LightGreen"

    # 4. Save file payload stream cleanly
    Close-ExcelPackage -ExcelPackage $Excel
}

# 8. Output and Format worksheets 
Write-Host "Writing structured tables and applying color filters to Excel..." -ForegroundColor Cyan

# Tab 1: General
Export-AndFormatSheet -Data $GeneralData -Path $ExcelPath -SheetName "General"

# Tab 2: NBU
if ($NbuData.Count -gt 0) {
    Export-AndFormatSheet -Data $NbuData -Path $ExcelPath -SheetName "NBU"
} else {
    Write-Host "No data found matching domain 'ENTNBU'. Tab was not created." -Workspace Yellow
}

# Tab 3: ENTERPRISE
if ($EnterpriseData.Count -gt 0) {
    Export-AndFormatSheet -Data $EnterpriseData -Path $ExcelPath -SheetName "ENTERPRISE"
} else {
    Write-Host "No data found for domain: ENTERPRISE. Tab was not created." -ForegroundColor Yellow
}

Write-Host "Excel workbook successfully built with compliant highlighting at: $ExcelPath" -ForegroundColor Green
