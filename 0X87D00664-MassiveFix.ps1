# List of target machines
$machines = @(

"1585970A"
"1586145A"
"1584465A"
"1584458A"
"1584449A"
"1584267A"
"1584262A"
"1584178A"
"1584163A"
"1584161A"
"1584143A"
"1588625A"
"1584636A"
"1588060A"
"1588067A"
"1585622A"
"1588074A"
"1587935A"
"1588677A"
"1584841A"
"1588503A"
"1584671A"
"1586002A"
"1585770A"
"1584062A"
"1589454A"
"1582943A"
"1582856A"
"1587667A"
"1587225A"
"1589821A"
"1085048A"
"1590099A"
"1589542A"
"1589411A"
"1589391A"
"1588852A"
"1583832A"
"1582982A"
"1586563A"
"1586564A"
"1587713A"
"1589319A"



)

foreach ($computer in $machines) {
    Write-Host "----------------------------------------------------"
    Write-Host "Processing: $computer" -ForegroundColor Cyan

    # Check if the machine is reachable
    if (Test-Connection -ComputerName $computer -Count 1 -Quiet) {
        try {
            Invoke-Command -ComputerName $computer -ScriptBlock {
                Write-Host "Cleaning Windows Update and SCCM Cache..."
                
                # 1. Stop Services
                Stop-Service -Name "CcmExec" -Force
                Stop-Service -Name "wuauserv" -Force

                # 2. Clear SCCM Cache via COM Object
                try {
                    $UIResCtl = New-Object -ComObject "UIResource.UIResourceMgr"
                    $Cache = $UIResCtl.GetCacheInfo()
                    $Cache.GetCacheElements() | ForEach-Object { $Cache.DeleteCacheElement($_.CacheElementID) }
                } catch {
                    Write-Warning "Could not clear SCCM cache via COM. Moving to folder deletion."
                }

                # 3. Clear SoftwareDistribution folder
                $swDistPath = "C:\Windows\SoftwareDistribution"
                if (Test-Path $swDistPath) {
                    Remove-Item -Path "$swDistPath\*" -Recurse -Force -ErrorAction SilentlyContinue
                }

                # 4. Restart Services
                Start-Service -Name "wuauserv"
                Start-Service -Name "CcmExec"

                # 5. Trigger SCCM Cycles (Scan and Deployment Evaluation)
                Write-Host "Triggering SCCM Update Cycles..."
                $SCCMClient = Get-WmiObject -Namespace root\ccm -Class SMS_Client
                $SCCMClient.TriggerSchedule("{00000000-0000-0000-0000-000000000113}") | Out-Null # Software Update Scan
                $SCCMClient.TriggerSchedule("{00000000-0000-0000-0000-000000000108}") | Out-Null # Software Update Evaluation
                
                Write-Host "Task completed on $env:COMPUTERNAME" -ForegroundColor Green
            }
        } catch {
            Write-Error "Failed to execute on $computer. Error: $_"
        }
    } else {
        Write-Host "Machine $computer is OFFLINE. Skipping..." -ForegroundColor Yellow
    }
}
