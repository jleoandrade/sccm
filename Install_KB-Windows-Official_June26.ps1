<#
    Script: Remote KB Installer + SCCM Sync (Windows 11 23H2 / 24H2 / 25H2)
    Scenario: critical environment – goal is to ensure the KB installs without errors.
#>

Write-Host "=== Remote Windows 11 KB Installer (23H2 / 24H2 / 25H2) ===" -ForegroundColor Cyan

# Ask for the computer name
$ComputerName = Read-Host "Enter the computer name"

if (-not (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet)) {
    Write-Host "Machine unreachable. Aborting." -ForegroundColor Red
    return
}

Write-Host "Machine reachable. Starting remote procedure..." -ForegroundColor Green

Invoke-Command -ComputerName $ComputerName -ScriptBlock {

    Write-Host "=== Collecting Windows information ===" -ForegroundColor Cyan

    $cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    $displayVersion = $cv.DisplayVersion
    $releaseId      = $cv.ReleaseId
    $build          = $cv.CurrentBuild
    $ubr            = $cv.UBR

    Write-Host "Detected version:" -ForegroundColor Yellow
    Write-Host "  DisplayVersion : $displayVersion" -ForegroundColor Yellow
    Write-Host "  ReleaseId      : $releaseId"      -ForegroundColor Yellow
    Write-Host "  Build          : $build.$ubr"     -ForegroundColor Yellow

    # Map version -> KBs and links (April 2026 Security CUs ONLY)
    $kbList = @()
    $remoteFolder = "C:\temp"
    if (-not (Test-Path $remoteFolder)) {
        New-Item -Path $remoteFolder -ItemType Directory | Out-Null
    }

    switch ($displayVersion) {

        "23H2" {
            Write-Host "Windows 11 23H2 detected." -ForegroundColor Green
            $kbList = @(
                [PSCustomObject]@{
                    Id  = "KB5093998"
                    Url = "https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/e1829e07-08c7-4300-a0dc-7b0f93c9d9ac/public/windows11.0-kb5093998-x64_86c3045c44c406377df40661d15a2d8354e4222c.msu"
                }
            )
        }

        "24H2" {
            Write-Host "Windows 11 24H2 detected." -ForegroundColor Green
            $kbList = @(
                [PSCustomObject]@{
                    Id  = "KB5094126"
                    Url = "https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/8ab7b9b4-fb40-4820-afb3-cbaf4cc0a701/public/windows11.0-kb5094126-x64_1b7fae967f9781d27e8ee3f848fba51b7cd62e88.msu"
                }
            )
        }

        "25H2" {
            Write-Host "Windows 11 25H2 detected." -ForegroundColor Green
            $kbList = @(
                [PSCustomObject]@{
                    Id  = "KB5094126"
                    Url = "https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/8ab7b9b4-fb40-4820-afb3-cbaf4cc0a701/public/windows11.0-kb5094126-x64_1b7fae967f9781d27e8ee3f848fba51b7cd62e88.msu"
                }
            )
        }

        Default {
            Write-Host "Windows version is not 23H2, 24H2, or 25H2. Aborting for safety." -ForegroundColor Red
            return
        }
    }

    # Function to check if KB is installed (DISM + Get-HotFix)
    function Test-KBInstalled {
        param([string]$KbId)

        Write-Host "Checking if $KbId is already installed..." -ForegroundColor Cyan

        $foundHotfix = Get-HotFix -Id $KbId -ErrorAction SilentlyContinue
        if ($foundHotfix) {
            Write-Host "$KbId found via Get-HotFix." -ForegroundColor Green
            return $true
        }

        $dism = dism /online /get-packages | Select-String $KbId -ErrorAction SilentlyContinue
        if ($dism) {
            Write-Host "$KbId found via DISM (Package_for_RollupFix/Update)." -ForegroundColor Green
            return $true
        }

        Write-Host "$KbId is not installed." -ForegroundColor Yellow
        return $false
    }

    # Robust installation function (WUSA -> fallback DISM)
    function Install-KB {
        param(
            [string]$KbId,
            [string]$Url
        )

        $msuPath = Join-Path $remoteFolder "$KbId.msu"

        Write-Host "=== Processing $KbId ===" -ForegroundColor Cyan

        if (Test-KBInstalled -KbId $KbId) {
            Write-Host "$KbId already installed. Skipping." -ForegroundColor Green
            return
        }

        Write-Host "Downloading $KbId..." -ForegroundColor Cyan
        try {
            Start-BitsTransfer -Source $Url -Destination $msuPath -ErrorAction Stop
        }
        catch {
            Write-Host "BITS failed. Trying WebClient..." -ForegroundColor Yellow
            try {
                $wc = New-Object System.Net.WebClient
                $wc.DownloadFile($Url, $msuPath)
            }
            catch {
                Write-Host "Download failed for $KbId. Aborting." -ForegroundColor Red
                throw
            }
        }

        # Validate minimum size (50 MB)
        $size = (Get-Item $msuPath).Length
        if ($size -lt 50000000) {
            Write-Host "$KbId.msu is too small ($([math]::Round($size/1MB,2)) MB). Possible corruption. Aborting." -ForegroundColor Red
            throw "Corrupted MSU."
        }

        Write-Host "$KbId downloaded successfully ($([math]::Round($size/1MB,2)) MB)." -ForegroundColor Green

        # First attempt: WUSA
        Write-Host "Installing $KbId via WUSA..." -ForegroundColor Cyan
        $wusaLog = Join-Path $remoteFolder "$KbId-wusa.log"
        Start-Process "wusa.exe" -ArgumentList "`"$msuPath`" /quiet /norestart /log:`"$wusaLog`"" -Wait

        Start-Sleep -Seconds 20

        if (Test-KBInstalled -KbId $KbId) {
            Write-Host "$KbId installed successfully via WUSA." -ForegroundColor Green
            return
        }

        Write-Host "$KbId not confirmed after WUSA. Trying DISM fallback..." -ForegroundColor Yellow

        # Second attempt: DISM /Add-Package
        $dismLog = Join-Path $remoteFolder "$KbId-dism.log"
        $dismCmd = "dism /online /add-package /packagepath:`"$msuPath`" /logpath:`"$dismLog`""
        Write-Host "Executing: $dismCmd" -ForegroundColor DarkCyan
        cmd.exe /c $dismCmd

        Start-Sleep -Seconds 30

        if (Test-KBInstalled -KbId $KbId) {
            Write-Host "$KbId installed successfully via DISM." -ForegroundColor Green
            return
        }

        Write-Host "CRITICAL FAILURE: $KbId was not installed via WUSA or DISM. Check logs in $remoteFolder." -ForegroundColor Red
        throw "KB installation failed."
    }

    Write-Host "=== Starting installation of KBs mapped to $displayVersion ===" -ForegroundColor Cyan

    foreach ($kb in $kbList) {
        Install-KB -KbId $kb.Id -Url $kb.Url
    }

    Write-Host "=== All KBs processed. Starting SCCM synchronization ===" -ForegroundColor Cyan

    # Invoke a full (resync) HWI report
    $Instance = Get-CimInstance -NameSpace ROOT\ccm\InvAgt -Query "SELECT * FROM InventoryActionStatus WHERE InventoryActionID='{00000000-0000-0000-0000-000000000001}'"
    $Instance | Remove-CimInstance
    Invoke-CimMethod -Namespace ROOT\ccm -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = "{00000000-0000-0000-0000-000000000001}"}
    Start-Sleep -Seconds 5
 
    # Check InventoryAgent log for ignored message
    $Log = "$env:SystemRoot\CCM\Logs\InventoryAgent.Log"
    $LogEntries = Select-String –Path $Log –SimpleMatch "{00000000-0000-0000-0000-000000000001}" | Select -Last 1
    If ($LogEntries -match "already in queue. Message ignored.")
    {
    # Clear the message queue
    # WARNING: This restarts the SMS Agent host service
    Stop-Service -Name CcmExec -Force
    Remove-Item -Path C:\Windows\CCM\ServiceData\Messaging\EndpointQueues\InventoryAgent -Recurse -Force -Confirm:$false
    Start-Service -Name CcmExec
 
    # Invoke a full (resync) HWI report
    Start-Sleep -Seconds 5
    $Instance = Get-CimInstance -NameSpace ROOT\ccm\InvAgt -Query "SELECT * FROM InventoryActionStatus WHERE InventoryActionID='{00000000-0000-0000-0000-000000000001}'"
    $Instance | Remove-CimInstance
    Invoke-CimMethod -Namespace ROOT\ccm -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = "{00000000-0000-0000-0000-000000000001}"}
}

    # SCCM triggers – critical environment: force inventory and policy 
    $triggers = @(
        "{00000000-0000-0000-0000-000000000003}", # Machine Policy Retrieval & Evaluation Cycle
        "{00000000-0000-0000-0000-000000000113}", # Hardware Inventory
        "{00000000-0000-0000-0000-000000000121}"  # Software Inventory
    )

    foreach ($t in $triggers) {
        Write-Host "Triggering SCCM action: $t" -ForegroundColor Cyan
        try {
            Invoke-WmiMethod -Namespace root\ccm -Class sms_client -Name TriggerSchedule -ArgumentList $t | Out-Null
        }
        catch {
            Write-Host "Failed to trigger $t. Check SCCM client." -ForegroundColor Yellow
        }
    }

    Write-Host "Waiting a few seconds for stabilization..." -ForegroundColor Cyan
    Start-Sleep -Seconds 20

    # Re-read build after installation
    $cv2 = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    $build2 = $cv2.CurrentBuild
    $ubr2   = $cv2.UBR

    Write-Host "Build after KB installation: $build2.$ubr2" -ForegroundColor Green
    Write-Host "Procedure completed on remote host." -ForegroundColor Green

} # end Invoke-Command

Write-Host "=== Process completed. Check SCCM in a few minutes to confirm OS Build and compliance. ===" -ForegroundColor Cyan
