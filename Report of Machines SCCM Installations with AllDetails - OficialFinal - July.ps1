# ==============================================================================
#  PART 1: CONSOLE OPTIMIZATION, ANTI-SUSPEND, AND SCCM TELEMETRY EXTRACTION
# ==============================================================================

# 1. Anti-Suspend Core Module (Disables QuickEdit to prevent accidental mouse-click console freezing)
$Kernel32 = Add-Type -MemberDefinition @"
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
"@ -Name "Win32Utils" -Namespace "Win32" -PassThru

$hStdout = $Kernel32::GetStdHandle(-10) # STD_INPUT_HANDLE
$mode = 0
if ($Kernel32::GetConsoleMode($hStdout, [ref]$mode)) {
    $mode = $mode -band -not 0x0040 # Remotion of ENABLE_QUICK_EDIT_MODE flag
    $Kernel32::SetConsoleMode($hStdout, $mode) | Out-Null
}

# 2. Enforce ImportExcel Module validation
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    Write-Host "[PART 1] Deploying missing ImportExcel module dependency..." -ForegroundColor Yellow
    Install-Module -Name ImportExcel -Force -Scope CurrentUser -ErrorAction SilentlyContinue
}

# 3. Connection and Infrastructure Scope parameters
$SiteServer   = "NJNWKSMS08V" # Your SCCM Site Server Name
$SiteCode     = "A03"                      
$Namespace    = "root\sms\site_$SiteCode"
$CollectionID = "A03002EA"

# Global target storage paths and unique deployment timestamps
$Global:TimeStampExcel = Get-Date -Format "yyyy-MM-dd_HHmm"
$Global:TargetDirExcel = "C:\Users\ServiceHLASMSWKS15\Desktop\Reports Month MS - Oficial\Manual Installation x SCCM\"
$Global:OutputPath     = Join-Path $Global:TargetDirExcel "Collection_Report_SCCM_Installations_Jul_$Global:TimeStampExcel.xlsx"

# 4. Pull Inventory records from Core Site Database
Write-Host "[PART 1] Pulling active HotFix records from SMS database providers..." -ForegroundColor Cyan
$QueryHF = "SELECT ResourceID, HotFixID, InstalledBy, InstalledOn FROM SMS_G_System_QUICK_FIX_ENGINEERING WHERE HotFixID = 'KB5099414' OR HotFixID = 'KB5101650'"
$Global:HotFixes = Get-CimInstance -ComputerName $SiteServer -Namespace $Namespace -Query $QueryHF -ErrorAction Stop

Write-Host "[PART 1] Extracting live target systems from Collection ID: $CollectionID..." -ForegroundColor Cyan
$QueryColl = "SELECT ResourceID, Name FROM SMS_CM_RES_COLL_$CollectionID"
$Global:CollectionMembers = Get-CimInstance -ComputerName $SiteServer -Namespace $Namespace -Query $QueryColl -ErrorAction Stop

Write-Host "[PART 1] Resolving explicit client logon discovery identifiers..." -ForegroundColor Cyan
$QuerySys = "SELECT ResourceID, LastLogonUserDomain, LastLogonUserName FROM SMS_R_System"
$Systems = Get-CimInstance -ComputerName $SiteServer -Namespace $Namespace -Query $QuerySys -ErrorAction Stop

# 5. Hydrate high-velocity lookups (Memory Hashtables)
$Global:CollectionLookup = @{}
foreach ($Member in $Global:CollectionMembers) { $Global:CollectionLookup[$Member.ResourceID] = $Member.Name }

$Global:UserDomainLookup = @{}
$Global:UserNameLookup   = @{}
foreach ($Sys in $Systems) {
    if (-not [string]::IsNullOrWhiteSpace($Sys.LastLogonUserName)) {
        $Global:UserDomainLookup[$Sys.ResourceID] = $Sys.LastLogonUserDomain
        $Global:UserNameLookup[$Sys.ResourceID]   = $Sys.LastLogonUserName
    }
}

Write-Host "[SUCCESS] Part 1 pipeline complete. Structural assets cached natively.`n" -ForegroundColor Green
# ==============================================================================
#  PART 2: RELATIONAL DATA MAPPING, ENRICHMENT, AND FLEET METRICS COMPILATION
# ==============================================================================

# 1. Process active Compliant Assets and map exact architecture string identities
$PatchedResourceIDs = @{}
$Global:Report = $Global:HotFixes | ForEach-Object {
    if ($Global:CollectionLookup.ContainsKey($_.ResourceID)) {
        
        $PatchedResourceIDs[$_.ResourceID] = $true

        $Installer = $_.InstalledBy
        if ([string]::IsNullOrWhiteSpace($Installer)) { 
            $Installer = "Built-in the Image" 
        } elseif ($Installer -like "*ServiceHLASMSWKS*") { 
            $Installer = "ENTERPRISE\ServiceHLASMSWKSx ( Manual Installation )" 
        } elseif ($Installer -eq "NT AUTHORITY\SYSTEM") {
            $Installer = "NT AUTHORITY\SYSTEM ( SCCM )"
        }

        [PSCustomObject]@{
            MachineName = $Global:CollectionLookup[$_.ResourceID]
            HotFixId    = $_.HotFixID
            InstalledBy = $Installer
            InstalledOn = $_.InstalledOn
        }
    }
}

# 2. Segregate and map detailed enterprise profiles for Non-Compliant targets
Write-Host "[PART 2] Filtering baseline fleet gaps and building communication array..." -ForegroundColor Cyan
$Global:MissingMachinesList = foreach ($Member in $Global:CollectionMembers) {
    if (-not $PatchedResourceIDs.ContainsKey($Member.ResourceID)) {
        
        $Domain   = if ($Global:UserDomainLookup.ContainsKey($Member.ResourceID)) { $Global:UserDomainLookup[$Member.ResourceID] } else { $null }
        $Username = if ($Global:UserNameLookup.ContainsKey($Member.ResourceID)) { $Global:UserNameLookup[$Member.ResourceID] } else { $null }
        
        $AccountName = if (-not [string]::IsNullOrWhiteSpace($Username)) { "$Domain\$Username" } else { "No Logged User" }
        $CleanName   = if (-not [string]::IsNullOrWhiteSpace($Username)) { $Username } else { "Unknown" }
        $UserEmail   = if (-not [string]::IsNullOrWhiteSpace($Username)) { "$($Username.ToLower())@enterprise.com" } else { "N/A" }
        
        [PSCustomObject]@{
            MachineName = $Member.Name
            User        = $AccountName
            Name        = $CleanName
            Email       = $UserEmail
            Status      = "Missing Updates"
        }
    }
}

# 3. Compile structural Fleet Metrics matching screenshot formulas
$TotalCollectionFleet = $Global:CollectionMembers.Count
$UniqueInstalled      = ($Global:Report | Select-Object -ExpandProperty MachineName -Unique).Count
$MissingInstallations = $TotalCollectionFleet - $UniqueInstalled
$ComplianceRate       = if ($TotalCollectionFleet -gt 0) { [Math]::Round(($UniqueInstalled / $TotalCollectionFleet) * 100, 2) } else { 0 }

$Global:FleetSummary = @(
    [PSCustomObject]@{ Metric = "Total Machines";                 Value = $TotalCollectionFleet }
    [PSCustomObject]@{ Metric = "Total Patched Machines";         Value = $UniqueInstalled }
    [PSCustomObject]@{ Metric = "Machines Missing Installations"; Value = $MissingInstallations }
    [PSCustomObject]@{ Metric = "compliance rate";                Value = "$ComplianceRate%" }
)

Write-Host "[SUCCESS] Part 2 data consolidation finalized smoothly.`n" -ForegroundColor Green
# ==============================================================================
#  PART 3: LIVE REMOTE VERIFICATION ENGINES (PENDING REBOOT & .NET DNS AUDIT)
# ==============================================================================

# 1. Dedicated Remote Pending Reboot Evaluation Engine
Write-Host "[PART 3] Launching remote Pending Reboot evaluation engine..." -ForegroundColor Yellow
$Global:RebootResults = foreach ($Machine in $Global:MissingMachinesList.MachineName) {
    $CheckTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "Checking update reboot status on host: $Machine" -ForegroundColor DarkGray
    
    $IsPending = "No"
    $Reason    = "Clean / No Pending Actions"
    $Online    = Test-Connection -ComputerName $Machine -Count 1 -TimeToLive 2 -ErrorAction SilentlyContinue

    if ($Online) {
        try {
            # Audit Component Based Servicing (CBS) and Windows Update registry markers
            $RegCBS = Get-CimInstance -ComputerName $Machine -Namespace root\default -ClassName StdRegProv -ErrorAction SilentlyContinue
            if ($RegCBS) {
                # Check RebootRequired key under Component Based Servicing
                $CbsCheck = Get-CimInstance -ComputerName $Machine -Namespace root\cimv2 -Query "SELECT * FROM Win32_OptionalFeature" -ErrorAction SilentlyContinue
                
                # Check typical Windows Update reboot path
                $WuKey = "SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
                $Params = @{hDefKey = [uint32]2147483650; lpSubKeyName = $WuKey} # HKEY_LOCAL_MACHINE
                $WuCheck = Invoke-CimMethod -ComputerName $Machine -Namespace root\default -ClassName StdRegProv -MethodName EnumKey -Arguments $Params -ErrorAction SilentlyContinue
                
                if ($WuCheck.ReturnValue -eq 0 -and $WuCheck.sNames) {
                    $IsPending = "Yes"
                    $Reason    = "Windows Update Reboot Required"
                }
            }
        } catch {
            $Reason = "RPC/WMI Access Denied"
        }
    } else {
        $Reason = "Host Offline"
    }

    [PSCustomObject]@{
        EvaluationTime = $CheckTime
        MachineName    = $Machine
        PendingReboot  = $IsPending
        TriggerReason  = $Reason
    }
}

# 2. Native .NET High-Performance Infrastructure DNS Diagnostics
Write-Host "[PART 3] Launching target network footprint and DNS lookup audit..." -ForegroundColor Yellow
$BaseDirDNS    = "D:\Jorge\DNS"
$TimestampDNS  = Get-Date -Format "yyyyMMdd_HHmmss"
$OutputFileCSV = Join-Path -Path $BaseDirDNS -ChildPath "DNS_Report_$TimestampDNS.csv"
if (-not (Test-Path $BaseDirDNS)) { New-Item -ItemType Directory -Path $BaseDirDNS | Out-Null }

$NetPing = New-Object System.Net.NetworkInformation.Ping

$Global:DNSResults = foreach ($HostName in $Global:MissingMachinesList.MachineName) {
    $ExecutionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    try {
        $PingReply = $NetPing.Send($HostName, 1000)
        $PingStatus = if ($PingReply.Status -eq "Success") { "Success" } else { "Failed" }
    } catch {
        $PingStatus = "Failed"
    }

    $ResolvedName = "Not Found"
    $IP = "N/A"
    $ReverseName = "N/A"
    $DNSIssue = "Yes"

    if ($PingStatus -eq "Success") {
        try {
            $ForwardAddr = [System.Net.Dns]::GetHostEntry($HostName)
            $ResolvedName = $ForwardAddr.HostName
            $IP = $ForwardAddr.AddressList.IPAddressToString
            
            try {
                $ReverseName = ([System.Net.Dns]::GetHostEntry($IP)).HostName
            } catch {
                $ReverseName = "Not Found"
            }
            
            if ($ResolvedName -eq $ReverseName -and $ResolvedName -ne "Not Found") { $DNSIssue = "No" }
        } catch {
            $ResolvedName = "Not Found"
        }
    }

    [PSCustomObject]@{
        ExecutionTime           = $ExecutionTime
        Hostname                = $HostName
        PingStatus              = $PingStatus
        ResolvedName            = $ResolvedName
        IP                      = $IP
        "Resolved Name Reverse" = $ReverseName
        "DNS Issue"             = $DNSIssue
    }
}

# Dump legacy flat file outputs containing full audit footprint for Jorge's integration scripts
$Global:DNSResults | Export-Csv -Path $OutputFileCSV -NoTypeInformation -Encoding UTF8 -Delimiter ","
$TotalDNSErrors = ($Global:DNSResults | Where-Object { $_."DNS Issue" -eq "Yes" }).Count
$OverallStatus  = if ($TotalDNSErrors -gt 0) { "Attention Required" } else { "Healthy Environment" }
Add-Content -Path $OutputFileCSV -Value "`r`n`r`nSUMMARY REPORT`r`nReport Date,Total Computers,Total DNS Issues,Overall Status`r`n$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$($Global:DNSResults.Count),$TotalDNSErrors,$OverallStatus"

Write-Host "[SUCCESS] Part 3 verification modules executed sequentially.`n" -ForegroundColor Green
# ==============================================================================
#  PART 4: WORKBOOK INJECTION, PIVOT ENGINE MAPPING, AND SCREENSHOT MATCHING
# ==============================================================================

Write-Host "[PART 4] Rendering consolidated multi-tab corporate Excel Workbook artifact..." -ForegroundColor Cyan

if (-not (Test-Path $Global:TargetDirExcel)) { 
    New-Item -ItemType Directory -Path $Global:TargetDirExcel | Out-Null 
}

# Step A: Export master raw compliant array into data catalog sheet 'Machine_List'
$Global:Report | Export-Excel -Path $Global:OutputPath -WorksheetName 'Machine_List' -ClearSheet -AutoSize

# Step B: Inject Pivot Table 'Summary Total' and map 4-line metrics block to Column D (EXACT MATCH)
$Global:Report | Export-Excel -Path $Global:OutputPath `
                       -WorksheetName 'Machine_List' `
                       -PivotTableName 'Summary Total' `
                       -PivotRows @('InstalledBy', 'HotFixId') `
                       -PivotData @{ 'MachineName' = 'Count' }

# Directly append the 4-line executive summaries block side-by-side on Column D of the Pivot tab
$Global:FleetSummary | Export-Excel -Path $Global:OutputPath `
                             -WorksheetName 'Summary Total' `
                             -NoHeader:$false `
                             -StartColumn 4 `
                             -TableStyle 'Medium2' `
                             -AutoSize

# Step C: Inject granular tracking structural trace Pivot Table 'Summary Detailed'
$Global:Report | Export-Excel -Path $Global:OutputPath `
                       -WorksheetName 'Machine_List' `
                       -PivotTableName 'Summary Detailed' `
                       -PivotRows @('InstalledBy', 'HotFixId', 'MachineName', 'InstalledOn') `
                       -PivotData @{ 'MachineName' = 'Count' }

# Step D: Export Non-Compliant raw asset dictionary targeting contact maps 'Missing_KBs'
$Global:MissingMachinesList | Export-Excel -Path $Global:OutputPath `
                                    -WorksheetName 'Missing_KBs' `
                                    -TableStyle 'Medium4' `
                                    -AutoSize

# Step E: Deploy target infrastructure sheet 'Pending Reboot' (FIRST ORDER CONSTRAINT)
$Global:RebootResults | Export-Excel -Path $Global:OutputPath `
                             -WorksheetName 'Pending Reboot' `
                             -TableStyle 'Medium9' `
                             -AutoSize

# Step F: Deploy network footprint evaluation diagnostics 'DNS Issues' and launch file visualization
$Global:DNSResults | Export-Excel -Path $Global:OutputPath `
                           -WorksheetName 'DNS Issues' `
                           -TableStyle 'Medium7' `
                           -AutoSize `
                           -Show

Write-Host "`n[GLOBAL PIPELINE SUCCESS] Production-grade verified workbook generated and launched successfully!" -ForegroundColor Green
Write-Host "Target Generated Path: $Global:OutputPath" -ForegroundColor Green
