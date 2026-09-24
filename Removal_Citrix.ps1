# 1. Ask for the target machine name or IP
$computerName = Read-Host "Enter the target computer name or IP address"

if (-not (Test-Connection -ComputerName $computerName -Count 1 -Quiet)) {
    Write-Error "Could not ping the machine $computerName. Please check the connection."
    exit
}

# Define network paths (using the administrative share C$ of the target machine)
$sourcePath = "\\claue1fsp0002\SoftwarePackages-CurrentBranch\Citrix\Remove_tool"
$targetNetworkPath = "\\$computerName\C$\temp\remove_citrix_tool"

# 2. Create the folder and copy files from YOUR machine (prevents Double-Hop credential issues)
if (-not (Test-Path $targetNetworkPath)) {
    New-Item -ItemType Directory -Path $targetNetworkPath -Force | Out-Null
}

Write-Host "Copying removal tools directly to the target machine..." -ForegroundColor Cyan
Copy-Item -Path "$sourcePath\*" -Destination $targetNetworkPath -Recurse -Force

# Local path that the target machine will use internally
$targetLocalPath = "C:\temp\remove_citrix_tool"

# Remote execution block on the target computer
Invoke-Command -ComputerName $computerName -ScriptBlock {
    param($target)

    # FEATURE: Detect and Uninstall Microsoft Visual C++ 2015-2022 Redistributables
    Write-Host "`n--- Processing Microsoft Visual C++ 2015-2022 Uninstall ---" -ForegroundColor Yellow
    
    # Registry paths for 32-bit and 64-bit installed programs
    $regPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    # Filter strictly for the 2015-2022 redistributables
    $vcRedists = Get-ItemProperty $regPaths -ErrorAction SilentlyContinue | 
        Where-Object { $_.DisplayName -like "Microsoft Visual C++ 2015-2022 Redistributable*" }

    if ($vcRedists) {
        foreach ($redist in $vcRedists) {
            # Fixed: Changed color from "Orange" to "Yellow"
            Write-Host "[UNINSTALLING] $($redist.DisplayName)..." -ForegroundColor Yellow
            
            if ($redist.UninstallString -match "MsiExec.exe") {
                # Extract the Product Code GUID from the uninstall string
                $guid = ($redist.UninstallString -split " ") | Where-Object { $_ -like "{*}" }
                Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $guid /qn /norestart" -Wait -NoNewWindow
            } elseif ($redist.UninstallString) {
                # Fixed: Properly split the executable path from any built-in parameters to avoid "file not found"
                # This regex separates the true file path from trailing arguments
                if ($redist.UninstallString -match '^"(?<exe>[^"]+)"\s*(?<args>.*)$' -or $redist.UninstallString -match '^(?<exe>\S+)\s*(?<args>.*)$') {
                    $uninstallCmd = $Matches['exe']
                } else {
                    $uninstallCmd = $redist.UninstallString
                }

                # Standard arguments for executable VC++ installers to run silently
                $silentArgs = "/uninstall /quiet /norestart"
                
                Start-Process -FilePath $uninstallCmd -ArgumentList $silentArgs -Wait -NoNewWindow
            }
            Write-Host "[DONE] Finished uninstalling $($redist.DisplayName)" -ForegroundColor Green
        }
    } else {
        Write-Host "No Microsoft Visual C++ 2015-2022 Redistributables found to remove." -ForegroundColor DarkYellow
    }
    Write-Host "------------------------------------------------------------`n"

    # Forcefully kill all running Citrix processes and stop Citrix services
    Write-Host "Stopping Citrix processes and services to unlock files..." -ForegroundColor Cyan
    Get-Process -Name "*citrix*", "*receiver*" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Service -Name "*citrix*" -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
    
    # Brief pause to ensure processes have fully released their file handles
    Start-Sleep -Seconds 3

    # 3. Execute the cleanup utility locally
    $exePath = Join-Path $target "ReceiverCleanupUtility.exe"
    if (Test-Path $exePath) {
        Write-Host "Executing ReceiverCleanupUtility.exe..." -ForegroundColor Cyan
        Start-Process -FilePath $exePath -ArgumentList "/silent" -Wait -NoNewWindow
    } else {
        Write-Error "CRITICAL ERROR: Executable was not found at $exePath"
        exit
    }

    # Wait 5 seconds to ensure the utility completely finishes its tasks
    Start-Sleep -Seconds 5

    # 4. Deep cleanup of specified directories (Deletes entire matching folders and subfolders)
    Write-Host "Starting deep directory cleanup..." -ForegroundColor Cyan

    # 4a. Clear the content of C:\Windows\Temp
    if (Test-Path "C:\Windows\Temp") {
        Get-ChildItem -Path "C:\Windows\Temp" -Recurse -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 4b. Clear the content of C:\windows\ccmcache
    if (Test-Path "C:\Windows\ccmcache") {
        Get-ChildItem -Path "C:\Windows\ccmcache" -Recurse -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 4c. Delete entire Citrix folders in Program Files and Program Files (x86)
    $programPaths = @("C:\Program Files", "C:\Program Files (x86)")
    foreach ($path in $programPaths) {
        if (Test-Path $path) {
            Get-ChildItem -Path $path -Filter "*citrix*" -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # 4d. Delete entire Citrix folders in AppData for all user profiles
    if (Test-Path "C:\Users") {
        $userProfiles = Get-ChildItem -Path "C:\Users" -Directory
        foreach ($profile in $userProfiles) {
            if ($profile.Name -notmatch "Public|Default|All Users|NetworkService|LocalService") {
                
                $appDataPaths = @(
                    "$($profile.FullName)\AppData\Local",
                    "$($profile.FullName)\AppData\Roaming"
                )

                foreach ($appData in $appDataPaths) {
                    if (Test-Path $appData) {
                        Get-ChildItem -Path $appData -Filter "*citrix*" -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }

    Write-Host "Process completed successfully on the target machine!" -ForegroundColor Green

} -ArgumentList $targetLocalPath
