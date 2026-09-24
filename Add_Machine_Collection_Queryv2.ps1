# ============================================================
#  SCCM - Fast Machine Collection Manager (PART 1 OF 3)
# ============================================================

# Ensure SCCM PowerShell Module is Loaded
if (-not (Get-Module ConfigurationManager)) {
    $AdminUIPath = "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1"
    if (Test-Path $AdminUIPath) {
        Import-Module $AdminUIPath
    } else {
        Write-Host "ERROR: SCCM Console Module not found on this system." -ForegroundColor Red
        Exit
    }
}

# Auto-detect SCCM Site Code
$siteCode = (Get-PSDrive -PSProvider CMSite -ErrorAction SilentlyContinue).Name
if (-not $siteCode) {
    Write-Host "ERROR: Could not detect SCCM Site Code. Exiting." -ForegroundColor Red
    Exit
}

# Switch context to the SCCM PSDrive
Set-Location "$siteCode`:"

do {
    Clear-Host
    Write-Host "=== SCCM Collection Manager ===" -ForegroundColor Cyan
    Write-Host " [1] ADD Machines to Collections"
    Write-Host " [2] REMOVE Machines from Collections"
    Write-Host " [3] Exit"
    $mainMode = Read-Host "`nSelect an option (1-3)"

    if ($mainMode -eq "3") { break }
    if ($mainMode -notmatch '^[1-2]$') { 
        Write-Host "Invalid option. Please try again." -ForegroundColor Red
        Start-Sleep -Seconds 2
        continue 
    }

    $isAddMode = $mainMode -eq "1"
    $modeText = if ($isAddMode) { "ADD TO" } else { "REMOVE FROM" }

    do {
        Clear-Host
        Write-Host "=== SCCM Collection Manager [$($modeText -replace ' TO| FROM','')] ===" -ForegroundColor Cyan
        Write-Host "Connected to SCCM site: $siteCode" -ForegroundColor Green

        # Fast WMI/CIM Collection Search Filter
        $SearchText = Read-Host "`nEnter part of the collection name to $modeText"
        if ([string]::IsNullOrWhiteSpace($SearchText)) { continue }

        $collections = Get-CimInstance -Namespace "root\sms\site_$siteCode" -ClassName SMS_Collection -Filter "Name like '%$SearchText%'" | 
            Select-Object Name, CollectionID

        if (-not $collections) {
            Write-Host "No collections found matching '$SearchText'." -ForegroundColor Red
            $restartChoice = Read-Host "`nTry again? (Y/N)"
            if ($restartChoice -eq "Y" -or $restartChoice -eq "y") { $loopBack = $true; continue } else { $loopBack = $false; break }
        }

        # Display Found Collections
        Write-Host "`nCollections found:" -ForegroundColor Cyan
        Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Gray
        $collectionsCount = @($collections).Count
        for ($i = 0; $i -lt $collectionsCount; $i++) {
            $colName = @($collections)[$i].Name
            "{0,-6} | {1,-65}" -f "[$i]", $colName
        }
        Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Gray

        $indexInput = Read-Host "`nEnter the index numbers separated by commas (e.g.: 0,2,3)"
        if ($indexInput -notmatch '^(\d+)(,\d+)*$') {
            Write-Host "Invalid format selection." -ForegroundColor Red
            $restartChoice = Read-Host "`nTry again? (Y/N)"
            if ($restartChoice -eq "Y" -or $restartChoice -eq "y") { $loopBack = $true; continue } else { $loopBack = $false; break }
        }

        $selectedIndices = $indexInput.Split(',') | ForEach-Object { [int]$_.Trim() }
        $targetCollections = @()
        foreach ($idx in $selectedIndices) {
            if ($idx -lt $collectionsCount) { $targetCollections += @($collections)[$idx] }
        }

        if ($targetCollections.Count -eq 0) {
            Write-Host "No valid selections were made." -ForegroundColor Red
            $restartChoice = Read-Host "`nTry again? (Y/N)"
            if ($restartChoice -eq "Y" -or $restartChoice -eq "y") { $loopBack = $true; continue } else { $loopBack = $false; break }
        }

        # Gather Machine Names
        $ComputersInput = Read-Host "`nEnter computer names separated by commas (e.g.: PC01,PC02)"
        $InputComputers = $ComputersInput.Split(',') | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ -ne "" }

        if (-not $InputComputers) {
            Write-Host "No computer names provided." -ForegroundColor Red
            $restartChoice = Read-Host "`nTry again? (Y/N)"
            if ($restartChoice -eq "Y" -or $restartChoice -eq "y") { $loopBack = $true; continue } else { $loopBack = $false; break }
        }
        # ----------------------------------------------------
        # EXECUTION: ADD MODE (PART 2 OF 3)
        # ----------------------------------------------------
        if ($isAddMode) {
            $validDevices = @()
            foreach ($comp in $InputComputers) {
                $device = Get-CMDevice -Name $comp -ErrorAction SilentlyContinue
                if ($device) { $validDevices += $device } else { Write-Host "Warning: Device '$comp' not found in SCCM database. Skipping." -ForegroundColor Yellow }
            }

            if ($validDevices.Count -eq 0) {
                Write-Host "No valid devices found to add." -ForegroundColor Red
            } else {
                foreach ($Collection in $targetCollections) {
                    $CollectionName = $Collection.Name
                    Write-Host "`nProcessing additions for: $CollectionName..." -ForegroundColor Cyan

                    $queryRule = Get-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -ErrorAction SilentlyContinue | Select-Object -First 1

                    if ($queryRule) {
                        $machineList = [regex]::Matches($queryRule.QueryExpression, '"([^"]+)"') | ForEach-Object { $_.Groups.Value.ToUpper() }
                        $newQuery = $queryRule.QueryExpression
                        $queryUpdated = $false

                        foreach ($dev in $validDevices) {
                            if ($machineList -contains $dev.Name.ToUpper()) {
                                Write-Host "Machine '$($dev.Name)' already exists in this Query Rule." -ForegroundColor Yellow
                            } else {
                                # Safe injection targeting the closing parenthesis of the WQL IN clause
                                $replacement = ',"' + $dev.Name + '")'
                                $newQuery = $newQuery -replace '\)$', $replacement
                                $queryUpdated = $true
                            }
                        }

                        if ($queryUpdated) {
                            Remove-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -RuleName $queryRule.RuleName -Force
                            Add-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -RuleName $queryRule.RuleName -QueryExpression $newQuery
                            Write-Host "Query Rule updated successfully." -ForegroundColor Green
                        }
                    } else {
                        Write-Host "No Query Rule found. Falling back to Direct Rules..." -ForegroundColor Yellow
                        foreach ($dev in $validDevices) {
                            Add-CMDeviceCollectionDirectMembershipRule -CollectionName $CollectionName -Resource $dev -Force
                            Write-Host "Added '$($dev.Name)' via Direct Rule." -ForegroundColor Green
                        }
                    }
                    
                    # Force membership update on the collection
                    Invoke-CMDeviceCollectionUpdate -Name $CollectionName
                }

                # Trigger Client Machine Policy Retrieval Cycle for faster software delivery
                Write-Host "`nTriggering immediate Machine Policy Evaluation on targets..." -ForegroundColor Cyan
                foreach ($dev in $validDevices) {
                    $computerName = $dev.Name
                    if (Test-Connection -ComputerName $computerName -Count 1 -Quiet) {
                        Write-Host "Sending policy trigger to online machine: $computerName" -ForegroundColor Gray
                        Invoke-CimMethod -Namespace "root\ccm" -ClassName "SMS_Client" -MethodName "TriggerSchedule" -Arguments @{ sScheduleID = "{00000000-0000-0000-0000-0000-000000000021}" } -ComputerName $computerName -ErrorAction SilentlyContinue | Out-Null
                        Write-Host "Policy Retrieval triggered on '$computerName'." -ForegroundColor Green
                    } else {
                        Write-Host "Machine '$computerName' appears to be offline. Policy trigger skipped." -ForegroundColor Yellow
                    }
                }
            }
        }
        # ----------------------------------------------------
        # EXECUTION: REMOVE MODE (PART 3 OF 3)
        # ----------------------------------------------------
        else {
            foreach ($Collection in $targetCollections) {
                $CollectionName = $Collection.Name
                Write-Host "`nProcessing removals for: $CollectionName..." -ForegroundColor Cyan

                $queryRule = Get-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -ErrorAction SilentlyContinue | Select-Object -First 1
                $directRules = Get-CMDeviceCollectionDirectMembershipRule -CollectionName $CollectionName -ErrorAction SilentlyContinue

                if ($queryRule) {
                    # Extract active machine names out of the query safe and sound
                    $machineList = [regex]::Matches($queryRule.QueryExpression, '"([^"]+)"') | ForEach-Object { $_.Groups.Value.ToUpper() }
                    $updatedMachineList = $machineList | Where-Object { $_ -notin $InputComputers }

                    if ($machineList.Count -ne $updatedMachineList.Count) {
                        # Rebuild compliance WQL structure strictly using double quotes
                        $formattedMachines = $updatedMachineList | ForEach-Object { "`"$_`"" }
                        $joinedMachines = $formattedMachines -join ','
                        
                        # Precision regex target: Only replaces inside the IN list scope
                        $newQuery = $queryRule.QueryExpression -replace '\bin\s*\([^)]+\)', "IN ($joinedMachines)"

                        Remove-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -RuleName $queryRule.RuleName -Force
                        Add-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -RuleName $queryRule.RuleName -QueryExpression $newQuery
                        Write-Host "Matching target machines removed from Query Rule." -ForegroundColor Green
                    }
                }

                if ($directRules) {
                    foreach ($target in $InputComputers) {
                        $matchedDirectRule = $directRules | Where-Object { $_.ResourceName.ToUpper() -eq $target }
                        if ($matchedDirectRule) {
                            Remove-CMDeviceCollectionDirectMembershipRule -CollectionName $CollectionName -ResourceName $target -Force
                            Write-Host "Removed Direct Rule for machine: $target" -ForegroundColor Green
                        }
                    }
                }
                
                # Force membership update on the collection
                Invoke-CMDeviceCollectionUpdate -Name $CollectionName
            }
        }

        # Sub-Menu Navigation Flow Control
        Write-Host "`n========================================================" -ForegroundColor Cyan
        Write-Host "Task complete. What would you like to do next?" -ForegroundColor Cyan
        Write-Host " [1] Search again in current mode"
        Write-Host " [2] Return to Main Menu"
        $subChoice = Read-Host "Enter option number"
        
        $loopBack = ($subChoice -eq "1")

    } while ($loopBack)

} while ($true)

Write-Host "`nExiting tool. Goodbye!" -ForegroundColor Green
