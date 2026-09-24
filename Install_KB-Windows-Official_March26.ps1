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

    # Map version -> KBs and links
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
                    Id  = "KB5078883"
                    Url = "https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/cc3b3a63-4780-408f-a0a9-ae941d7f0c95/public/windows11.0-kb5078883-x64_ad6670dbea0da64763fd15b25ac1d6dcd966fdca.msu"
                }
            )
        }
        "24H2" {
            Write-Host "Windows 11 24H2 detected." -ForegroundColor Green
            $kbList = @(
                [PSCustomObject]@{
                    Id  = "KB5079473"
                    Url = "https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/db81d709-c552-47ed-a3b9-ba77dfff9972/public/windows11.0-kb5079473-x64_651d0cdb7665e03bb80b4c198784b255081032d2.msu"
                },
                [PSCustomObject]@{
                    Id  = "KB5043080"
                    Url = "https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/d8b7f92b-bd35-4b4c-96e5-46ce984b31e0/public/windows11.0-kb5043080-x64_953449672073f8fb99badb4cc6d5d7849b9c83e8.msu"
                }
            )
        }
        "25H2" {
            Write-Host "Windows 11 25H2 detected." -ForegroundColor Green
            $kbList = @(
                [PSCustomObject]@{
                    Id  = "KB5079473"
                    Url = "https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/db81d709-c552-47ed-a3b9-ba77dfff9972/public/windows11.0-kb5079473-x64_651d0cdb7665e03bb80b4c198784b255081032d2.msu"
                },
                [PSCustomObject]@{
                    Id  = "KB5043080"
                    Url = "https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/d8b7f92b-bd35-4b4c-96e5-46ce984b31e0/public/windows11.0-kb5043080-x64_953449672073f8fb99badb4cc6d5d7849b9c83e8.msu"
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

    # SCCM triggers – critical environment: force inventory and policy
    $triggers = @(
        "{00000000-0000-0000-0000-000000000003}", # Machine Policy Retrieval & Evaluation Cycle
        "{00000000-0000-0000-0000-000a000000113}", # Hardware Inventory
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
