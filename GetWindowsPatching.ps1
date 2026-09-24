    <#
.SYNOPSIS
Counts compliant and non-compliant devices (presence of specified KBs) in SCCM collections,
calculates per-collection compliance percentages, and outputs friendly collection labels with a timestamp.

.DESCRIPTION
For each CollectionID:
- CompliantDeviceCount: devices that HAVE at least one of the KBs
- NonCompliantDeviceCount: devices that DO NOT HAVE any of the KBs
- TotalDevices
- CompliancePercent (rounded to 2 decimals)
- GeneratedAt (timestamp in Eastern Time, 12-hour AM/PM)

Includes an overall summary row. Uses DISTINCT ResourceID to avoid duplication.

.PARAMETER SqlServer
SQL Server instance hosting the ConfigMgr DB (e.g., "SCCM-SQL01" or "SCCM-SQL01\INST1").

.PARAMETER Database
ConfigMgr database name (e.g., "CM_ABC").

.PARAMETER KBs
KBs considered compliant (presence of any in this list => compliant).

.PARAMETER CollectionIDs
Collection IDs to evaluate. Defaults to A0300E27 and A0300E28.

.PARAMETER CollectionLabelMap
Hashtable mapping CollectionID -> Friendly Label.

.PARAMETER TimeZoneId
Windows time zone ID to use for the timestamp. Default: "Eastern Standard Time" (handles DST automatically).

.PARAMETER TimestampFormat
.NET datetime format string. Default: "MM/dd/yyyy hh:mm tt 'EST'" (12-hour with AM/PM and EST label).

.PARAMETER UseDynamicEasternAbbreviation
Switch to show the correct seasonal abbreviation ("EST" in winter, "EDT" in summer). Only applies if TimeZoneId is "Eastern Standard Time".
#>

[CmdletBinding()]
param(
    #[Parameter(Mandatory = $true)]
    [string]$SqlServer = "NJNWKSMS08V",

    #[Parameter(Mandatory = $true)]
    [string]$Database = "CM_A03",

    [string[]]$KBs = @('KB5099414', 'KB5101650', 'KB5120240', 'KB5121003'),

    [string[]]$CollectionIDs = @('A0300E27', 'A0300E28'),

    [hashtable]$CollectionLabelMap = @{
        'A0300E27' = 'ENTERPRISE'
        'A0300E28' = 'NBU'
    },

    [string]$TimeZoneId = 'Eastern Standard Time',
    [string]$TimestampFormat = "MM/dd/yyyy hh:mm tt 'EST'",
    [switch]$UseDynamicEasternAbbreviation
)

function Invoke-ConfigMgrSql {
    param(
        [string]$Server,
        [string]$Db,
        [string]$Query
    )

    # Prefer Invoke-Sqlcmd if available; fall back to SqlClient
    $useInvokeSqlcmd = $false
    try {
        if (-not (Get-Module -ListAvailable -Name SqlServer)) {
            Import-Module SqlServer -ErrorAction Stop | Out-Null
        }
        $useInvokeSqlcmd = $true
    } catch {
        $useInvokeSqlcmd = $false
    }

    if ($useInvokeSqlcmd) {
        try {
            return Invoke-Sqlcmd -ServerInstance $Server -Database $Db -Query $Query -ErrorAction Stop
        } catch {
            throw "Invoke-Sqlcmd failed. Error: $($_.Exception.Message)"
        }
    } else {
        $connectionString = "Server=$Server;Database=$Db;Integrated Security=True;TrustServerCertificate=True;"
        $conn = New-Object System.Data.SqlClient.SqlConnection $connectionString
        try {
            $conn.Open()
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = $Query
            $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
            $dt = New-Object System.Data.DataTable
            [void]$adapter.Fill($dt)
            return $dt
        } catch {
            throw "SqlClient failed. Error: $($_.Exception.Message)"
        } finally {
            if ($conn.State -ne 'Closed') { $conn.Close() }
        }
    }
}

function Get-ComplianceCountsForCollection {
    param(
        [string]$Server,
        [string]$Db,
        [string]$CollectionId,
        [string[]]$KbList
    )

    # Build the inline VALUES list for KBs
    $kbValues = ($KbList | ForEach-Object { "('$($_)')" }) -join ",`n"

    $tsql = @"
WITH Members AS (
    SELECT fcm.ResourceID
    FROM v_FullCollectionMembership AS fcm
    WHERE fcm.CollectionID = '$CollectionId'
),
DistinctMembers AS (
    SELECT DISTINCT ResourceID
    FROM Members
),
KBList AS (
    SELECT UPPER(KB) AS KBLabel
    FROM (VALUES
$kbValues
    ) AS KBs(KB)
),
KBInstalled AS (
    SELECT DISTINCT qfe.ResourceID
    FROM v_GS_QUICK_FIX_ENGINEERING AS qfe
    JOIN KBList AS k ON UPPER(qfe.HotFixID0) = k.KBLabel
),
CompliantMembers AS (
    SELECT DISTINCT dm.ResourceID
    FROM DistinctMembers dm
    INNER JOIN KBInstalled ki ON ki.ResourceID = dm.ResourceID
)
SELECT
    (SELECT COUNT(*) FROM DistinctMembers) AS TotalDevices,
    (SELECT COUNT(*) FROM CompliantMembers) AS CompliantDeviceCount,
    (SELECT COUNT(*) FROM DistinctMembers) - (SELECT COUNT(*) FROM CompliantMembers) AS NonCompliantDeviceCount;
"@

    $result = Invoke-ConfigMgrSql -Server $Server -Db $Db -Query $tsql

    # Normalize output whether DataTable or PSObject
    if ($result -is [System.Data.DataTable]) {
        if ($result.Rows.Count -eq 0) {
            return [pscustomobject]@{ TotalDevices = 0; CompliantDeviceCount = 0; NonCompliantDeviceCount = 0 }
        }
        return [pscustomobject]@{
            TotalDevices            = [int]$result.Rows[0]["TotalDevices"]
            CompliantDeviceCount    = [int]$result.Rows[0]["CompliantDeviceCount"]
            NonCompliantDeviceCount = [int]$result.Rows[0]["NonCompliantDeviceCount"]
        }
    } else {
        $row = ($result | Select-Object -First 1)
        if (-not $row) {
            return [pscustomobject]@{ TotalDevices = 0; CompliantDeviceCount = 0; NonCompliantDeviceCount = 0 }
        }
        return [pscustomobject]@{
            TotalDevices            = [int]$row.TotalDevices
            CompliantDeviceCount    = [int]$row.CompliantDeviceCount
            NonCompliantDeviceCount = [int]$row.NonCompliantDeviceCount
        }
    }
}

# ---------- Timestamp (EST, non-military time) ----------
$now = Get-Date
try {
    $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
} catch {
    throw "Time zone '$TimeZoneId' not found on this system. Try 'Eastern Standard Time'."
}
$etNow = [System.TimeZoneInfo]::ConvertTime($now, $tz)

# Dynamic EST/EDT abbreviation if requested and using Eastern Time
if ($UseDynamicEasternAbbreviation -and $TimeZoneId -eq 'Eastern Standard Time') {
    $abbr = if ($tz.IsDaylightSavingTime($etNow)) { 'EDT' } else { 'EST' }
    $timestamp = ($etNow.ToString('MM/dd/yyyy hh:mm tt') + " $abbr")
} else {
    # Default: show literal EST suffix and 12-hour AM/PM format
    $timestamp = $etNow.ToString($TimestampFormat)  # e.g., "MM/dd/yyyy hh:mm tt 'EST'"
}

# Get counts for each collection
$results = foreach ($cid in $CollectionIDs) {
    try {
        $counts = Get-ComplianceCountsForCollection -Server $SqlServer -Db $Database -CollectionId $cid -KbList $KBs
        $label = if ($CollectionLabelMap.ContainsKey($cid)) { $CollectionLabelMap[$cid] } else { $cid }
        [pscustomobject]@{
            CollectionID            = $cid
            CollectionLabel         = $label
            TotalDevices            = $counts.TotalDevices
            CompliantDeviceCount    = $counts.CompliantDeviceCount
            NonCompliantDeviceCount = $counts.NonCompliantDeviceCount
            GeneratedAt             = $timestamp
        }
    } catch {
        Write-Warning "Failed to get counts for collection '$cid': $($_.Exception.Message)"
        $label = if ($CollectionLabelMap.ContainsKey($cid)) { $CollectionLabelMap[$cid] } else { $cid }
        [pscustomobject]@{
            CollectionID            = $cid
            CollectionLabel         = $label
            TotalDevices            = 0
            CompliantDeviceCount    = 0
            NonCompliantDeviceCount = 0
            GeneratedAt             = $timestamp
        }
    }
}

# Calculate compliance percentages per collection
$resultsWithPct = foreach ($r in $results) {
    $total = [int]$r.TotalDevices
    $pct   = 0
    if ($total -gt 0) {
        $pct = [System.Math]::Round( ($r.CompliantDeviceCount / [double]$total) * 100, 2 )
    }

    [pscustomobject]@{
        CollectionID            = $r.CollectionID
        CollectionLabel         = $r.CollectionLabel
        CompliantDeviceCount    = $r.CompliantDeviceCount
        NonCompliantDeviceCount = $r.NonCompliantDeviceCount
        TotalDevices            = $total
        CompliancePercent       = $pct
        GeneratedAt             = $r.GeneratedAt
    }
}

# Overall summary across all provided collections
$overallCompliant    = ($results | Measure-Object -Property CompliantDeviceCount -Sum).Sum
$overallNonCompliant = ($results | Measure-Object -Property NonCompliantDeviceCount -Sum).Sum
$overallTotal        = $overallCompliant + $overallNonCompliant

$overallPct = 0
if ($overallTotal -gt 0) {
    $overallPct = [System.Math]::Round( ($overallCompliant / [double]$overallTotal) * 100, 2 )
}

$overall = [pscustomobject]@{
    CollectionID            = 'ALL'
    CollectionLabel         = 'ALL'
    CompliantDeviceCount    = $overallCompliant
    NonCompliantDeviceCount = $overallNonCompliant
    TotalDevices            = $overallTotal
    CompliancePercent       = $overallPct
    GeneratedAt             = $timestamp
}

# Header with timestamp
Write-Host ("Report generated at (Eastern): {0}" -f $timestamp) -ForegroundColor Cyan

# Pretty output (percent shown with % sign) using friendly labels
$final = $resultsWithPct + $overall
$final | Format-Table @{Label='Collection'; Expression = { $_.CollectionLabel } },
                      CompliantDeviceCount,
                      NonCompliantDeviceCount,
                      TotalDevices,
                      @{Label='CompliancePercent'; Expression = { "{0:N2}%" -f $_.CompliancePercent } },
                      @{Label='GeneratedAt'; Expression = { $_.GeneratedAt } } -AutoSize

# Also return objects for pipeline/automation
return $final
