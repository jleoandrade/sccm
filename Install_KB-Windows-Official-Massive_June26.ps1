<#
    Script: Remote KB Installer + SCCM Sync (Windows 11 23H2 / 24H2 / 25H2)
    Mode: Multi-machine execution (sequential, skip on error)
#>

Write-Host "=== Remote Windows 11 KB Installer (Multi-Machine Mode) ===" -ForegroundColor Cyan

# ================================
# MACHINE LIST (EDIT HERE)
# ================================
$Machines = @(

"1588760A"
"1080259A"
"1080881A"
"1588321A"
"1082221A"
"5FTTA16732"
"1583720A"
"1081563A"
"1585727A"
"1586245A"
"1584117A"
"1587963A"
"1589359A"
"1085029A"
"1567023A"
"1585209A"
"1584957A"
"1587994A"
"1588061A"
"1567325A"
"1080285A"
"1080292A"
"1584300A"
"1584703A"
"1586979A"
"1585142A"
"3HTTA82972"
"1585101A"
"1584520A"
"1586774A"
"1584764A"

)
# ================================

if ($Machines.Count -eq 0) {
    Write-Host "No machines defined in the list. Aborting." -ForegroundColor Red
    return
}

Write-Host "`nProcessing $($Machines.Count) machine(s)..." -ForegroundColor Cyan

foreach ($ComputerName in $Machines) {

    Write-Host "`n===============================" -ForegroundColor DarkCyan
    Write-Host "Processing: $ComputerName" -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor DarkCyan

    # Connectivity check
    if (-not (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet)) {
        Write-Host "Machine $ComputerName unreachable. Skipping." -ForegroundColor Red
        continue
    }

    Write-Host "Machine reachable. Attempting remote execution..." -ForegroundColor Green

    try {
        Invoke-Command -ComputerName $ComputerName -ErrorAction Stop -ScriptBlock {

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
                    Write-Host "Unsupported Windows version. Aborting for safety." -ForegroundColor Red
                    return
                }
            }

            # Function to check if KB is installed
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
                    Write-Host "$KbId found via DISM." -ForegroundColor Green
                    return $true
                }

                Write-Host "$KbId is not installed." -ForegroundColor Yellow
                return $false
            }

            # KB installation function
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
                    Write-Host "$KbId.msu is too small. Possible corruption. Aborting." -ForegroundColor Red
                    throw "Corrupted MSU."
                }

                Write-Host "$KbId downloaded successfully." -ForegroundColor Green

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

                Write-Host "CRITICAL FAILURE: $KbId was not installed." -ForegroundColor Red
                throw "KB installation failed."
            }

            Write-Host "=== Starting installation of KBs mapped to $displayVersion ===" -ForegroundColor Cyan

            foreach ($kb in $kbList) {
                Install-KB -KbId $kb.Id -Url $kb.Url
            }

            Write-Host "=== All KBs processed. Starting SCCM synchronization ===" -ForegroundColor Cyan

            # SCCM triggers
            $triggers = @(
                "{00000000-0000-0000-0000-000000000003}", # Machine Policy Retrieval
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

        } # end ScriptBlock

    }
    catch {
        Write-Host "ERROR on ${ComputerName}: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Skipping to next machine..." -ForegroundColor Yellow
        continue
    }

} # end foreach machine

Write-Host "`n=== Multi-machine KB installation completed. Check SCCM for compliance. ===" -ForegroundColor Cyan
