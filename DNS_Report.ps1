 ============================================================
#  1. DIRECTORY AND FILE SETUP
# ============================================================
$BaseDir = "E:\Temp\DNS_Report"
if (!(Test-Path $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir | Out-Null }

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$OutputFile = Join-Path -Path $BaseDir -ChildPath "DNS_Report_$Timestamp.csv"

# ============================================================
#  2. INPUT HOSTNAMES
# ============================================================
$Computers = @(

"1074464A"
"1074467A"
"1080117A"
"1080879A"
"1080889A"
"1081445A"
"1081791A"
"1081813A"
"1581303A"
"1582256A"
"1582487A"
"1582948A"
"1582962A"
"1582970A"
"1582973A"
"1582975A"
"1582995A"
"1583009A"
"1583011A"
"1583032A"
"1583062A"
"1583079A"
"1583104A"
"1583135A"
"1583193A"
"1583194A"
"1583322A"
"1583342A"
"1583396A"
"1583464A"
"1583470A"
"1583532A"
"1583581A"
"1583678A"
"1583722A"
"1583730A"
"1583732A"
"1583767A"
"1583791A"
"1583841A"
"1583849A"
"1583904A"
"1583940A"
"1583996A"
"1584027A"
"1584054A"
"1584117A"
"1584204A"
"1584205A"
"1584215A"
"1584239A"
"1584250A"
"1584289A"
"1584384A"
"1584434A"
"1584441A"
"1584457A"
"1584477A"
"1584496A"
"1584511A"
"1584512A"
"1584531A"
"1584532A"
"1584541A"
"1584542A"
"1584545A"
"1584554A"
"1584563A"
"1584599A"
"1584606A"
"1584619A"
"1584632A"
"1584663A"
"1584678A"
"1584745A"
"1584749A"
"1584821A"
"1584862A"
"1584916A"
"1584930A"
"1584954A"
"1584974A"
"1584991A"
"1585036A"
"1585113A"
"1585161A"
"1585166A"
"1585173A"
"1585228A"
"1585272A"
"1585296A"
"1585379A"
"1585408A"
"1585478A"
"1585482A"
"1585484A"
"1585556A"
"1585619A"
"1585641A"
"1585654A"
"1585673A"
"1585685A"
"1585739A"
"1585745A"
"1585747A"
"1585770A"
"1585809A"
"1585816A"
"1585847A"
"1585881A"
"1585884A"
"1585887A"
"1585907A"
"1585908A"
"1585911A"
"1585934A"
"1585938A"
"1585948A"
"1585957A"
"1585958A"
"1586032A"
"1586132A"
"1586139A"
"1586148A"
"1586174A"
"1586309A"
"1586375A"
"1586377A"
"1586428A"
"1586454A"
"1586524A"
"1586780A"
"1586781A"
"1586795A"
"1586814A"
"1586868A"
"1586887A"
"1586907A"
"1586997A"
"1587061A"
"1587082A"
"1587131A"
"1587132A"
"1587158A"
"1587165A"
"1587243A"
"1587387A"
"1587424A"
"1587534A"
"1587566A"
"1587666A"
"1587787A"
"1587822A"
"1587921A"
"1587991A"
"1588051A"
"1588053A"
"1588184A"
"1588256A"
"1588283A"
"1588292A"
"1588302A"
"1588385A"
"1588453A"
"1588460A"
"1588592A"
"1588633A"
"1588646A"
"1588682A"
"1588757A"
"1588773A"
"1588859A"
"1588887A"
"1588916A"
"1588923A"
"1588969A"
"1588975A"
"1589004A"
"1589013A"
"1589015A"
"1589028A"
"1589042A"
"1589091A"
"1589104A"
"1589107A"
"1589211A"
"1589227A"
"1589231A"
"1589270A"
"1589293A"
"1589370A"
"1589380A"
"1589419A"
"1589499A"
"1589572A"
"1589586A"
"1589600A"
"1589642A"
"1589710A"
"1589784A"
"1589797A"
"1589800A"
"1589983A"
"1590102A"
"1590103A"
"2JTTA81479"
"4556387A"
"5CTTA67434"
"5DTTA87908"
"5FTTA19546"
"6053361A"
"6DTTA38506"
"6DTTA39751"

)

$Results = foreach ($HostName in $Computers) {
    $ExecutionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Ping Status
    $Ping = Test-Connection -ComputerName $HostName -Count 1 -ErrorAction SilentlyContinue
    $PingStatus = if ($Ping) { "Success" } else { "Failed" }

    # Forward Lookup
    try {
        $ForwardAddr = [System.Net.Dns]::GetHostEntry($HostName)
        $ResolvedName = $ForwardAddr.HostName
        $IP = $ForwardAddr.AddressList.IPAddressToString
    } catch {
        $ResolvedName = "Not Found"
        $IP = "N/A"
    }

    # Reverse Lookup
    try {
        $ReverseName = if ($IP -ne "N/A") { ([System.Net.Dns]::GetHostEntry($IP)).HostName } else { "N/A" }
    } catch {
        $ReverseName = "Not Found"
    }

    # DNS Issue Logic
    $DNSIssue = if ($ResolvedName -eq $ReverseName -and $ResolvedName -ne "Not Found") { "No" } else { "Yes" }

    [PSCustomObject]@{
        ExecutionTime         = $ExecutionTime
        Hostname              = $HostName
        PingStatus            = $PingStatus
        ResolvedName          = $ResolvedName
        IP                    = $IP
        "Resolved Name Reverse" = $ReverseName
        "DNS Issue"           = $DNSIssue
    }
}

# ============================================================
#  3. EXPORT DETAILED DATA TO CSV
# ============================================================
$Results | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8 -Delimiter ","

# ============================================================
#  4. APPEND SUMMARY REPORT TO THE SAME FILE
# ============================================================
$TotalComputers = $Results.Count
$TotalDNSErrors = ($Results | Where-Object { $_."DNS Issue" -eq "Yes" }).Count
$OverallStatus  = if ($TotalDNSErrors -gt 0) { "Attention Required" } else { "Healthy Environment" }

# Add blank lines as a separator for visual clearance
Add-Content -Path $OutputFile -Value "`r`n`r`n"

# Add Summary Header and Data Rows
Add-Content -Path $OutputFile -Value "SUMMARY REPORT"
Add-Content -Path $OutputFile -Value "Report Date,Total Computers,Total DNS Issues,Overall Status"
Add-Content -Path $OutputFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$TotalComputers,$TotalDNSErrors,$OverallStatus"

# ============================================================
#  5. SHOW PATH ONLY
# ============================================================
Write-Host "File saved to: $OutputFile" -ForegroundColor Green
