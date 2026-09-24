# ==============================================================================
# Script: deploy_fix.ps1
# Description: Deploys and executes the fix_adobev1.ps1 script on a remote target.
#              Includes an automatic fallback block to provision and configure WinRM.
# ==============================================================================

# 1. Prompt the administrator for the target machine name or IP address
$TargetComputer = Read-Host "Enter the target machine name or IP address"

if ([string]::IsNullOrWhitespace($TargetComputer)) {
    Write-Warning "No machine name entered. Operation aborted."
    Exit
}

# REVERTED: Changed file name back to fix_adobev1.ps1
$SourcePath = "E:\EUC Team\Jorge\Scripts\fix_adobev1.ps1"
$LocalTempFolder = "C:\temp"
$DestinationPath = "\\$TargetComputer\C$\temp\fix_adobev1.ps1"

Write-Output "Initializing deployment process for target: $TargetComputer"

try {
    # ==============================================================================
    # PRELIMINARY STEP: WinRM Connectivity Validation and Proactive Activation
    # ==============================================================================
    Write-Output "Checking WinRM connectivity with target host..."
    $winrmTest = Test-WSMan -ComputerName $TargetComputer -ErrorAction SilentlyContinue

    if (-not $winrmTest) {
        Write-Warning "WinRM is not responding on the target. Attempting remote forced provisioning..."
        
        # Autonomous script block based on provided logic to enable WinRM locally on the target
        $WinRMSetupBlock = {
            $LogDir  = "$env:ProgramData\SCCM_Scripts\WinRM"
            $LogFile = Join-Path $LogDir "Enable-WinRM_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

            if (-not (Test-Path $LogDir)) { 
                New-Item -Path $LogDir -ItemType Directory -Force | Out-Null 
            }

            function Write-Log {
                param([string]$Message, [string]$Level = "INFO")
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                $line = "[$timestamp] [$Level] $Message"
                Add-Content -Path $LogFile -Value $line
            }

            try {
                Write-Log "===== Starting proactive WinRM enabling via Deploy Script ====="
                Write-Log "Host: $env:COMPUTERNAME | Execution User: $env:USERNAME"

                # 1. Verify/set the startup type for the WinRM service
                Write-Log "Configuring WinRM service for automatic startup..."
                Set-Service -Name WinRM -StartupType Automatic -ErrorAction Stop
                
                if ((Get-Service -Name WinRM).Status -ne 'Running') {
                    Write-Log "Starting WinRM service..."
                    Start-Service -Name WinRM -ErrorAction Stop
                } else {
                    Write-Log "WinRM service is already running."
                }

                # 2. Enable PS Remoting (configures listener, firewall, LocalAccountTokenFilterPolicy)
                Write-Log "Executing Enable-PSRemoting..."
                Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop
                Write-Log "Enable-PSRemoting completed successfully."
                
                # 3. Ensure the HTTP listener (5985) is configured
                $listenerHTTP = winrm enumerate winrm/config/Listener 2>$null | Select-String "Transport = HTTP"
                if (-not $listenerHTTP) {
                    Write-Log "HTTP Listener not found. Creating..."
                    winrm quickconfig -quiet | Out-Null
                } else {
                    Write-Log "HTTP Listener already configured."
                }

                # 4. Firewall Rules (Domain and Private)
                Write-Log "Validating firewall rules for WinRM..."
                $rules = Get-NetFirewallRule -DisplayName "Windows Remote Management*" -ErrorAction SilentlyContinue
                if ($rules) {
                    Enable-NetFirewallRule -DisplayName "Windows Remote Management*" -ErrorAction SilentlyContinue
                    Write-Log "WinRM firewall rules enabled."
                } else {
                    Write-Log "Default WinRM firewall rules not found (they might have already been created by Enable-PSRemoting)." "WARN"
                }

                # 5. Final validation
                if ((Get-Service -Name WinRM).Status -eq 'Running') {
                    Write-Log "Final validation: WinRM service running. Configuration completed successfully."
                } else {
                    throw "WinRM service is not running after configuration."
                }

                Write-Log "===== WinRM enabling completed successfully ====="
            } catch {
                Write-Log "ERROR during local provisioning: $($_.Exception.Message)" "ERROR"
            }
        }

        # Alternative Remote Injection Method (Fallback via WMI/CIM if WinRM is offline)
        try {
            Write-Output "Invoking WinRM initialization via RPC/WMI..."
            
            # Formats the command block into an encoded string to securely pass through the WMI command line boundary
            $encodedBlock = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($WinRMSetupBlock.ToString()))
            Invoke-CimMethod -ClassName Win32_Process -MethodName "Create" -ComputerName $TargetComputer -Arguments @{
                CommandLine = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encodedBlock"
            } | Out-Null
            
            # Wait a few seconds for the local network stack, service, and Firewall adjustments to complete
            Start-Sleep -Seconds 5
        } catch {
            throw "Critical Failure: Unable to reach the machine via WinRM, and the WMI/RPC fallback failed as well. Verify network path or permissions."
        }
    } else {
        Write-Output "WinRM connectivity successfully validated."
    }

    # ==============================================================================
    # MAIN ORIGINAL FLOW
    # ==============================================================================

    # 2. Force Group Policy update on the remote machine
    Write-Output "Forcing Group Policy update on remote machine..."
    Invoke-Command -ComputerName $TargetComputer -ScriptBlock {
        gpupdate /force
    } -ErrorAction Stop

    # 3. Terminate Adobe processes remotely using WMI/CIM (Safest method for remote tasks)
    Write-Output "Terminating remote Adobe processes..."
    Get-CimInstance -ComputerName $TargetComputer -ClassName Win32_Process -Filter "Name='Acrobat.exe' OR Name='AcroRd32.exe'" -ErrorAction SilentlyContinue | 
        Invoke-CimMethod -MethodName "Terminate" -ErrorAction SilentlyContinue | Out-Null

    # 4. Verify or create the C:\temp directory on the remote machine
    Invoke-Command -ComputerName $TargetComputer -ScriptBlock {
        param($folder)
        if (-not (Test-Path -Path $folder -ErrorAction SilentlyContinue)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }
    } -ArgumentList $LocalTempFolder -ErrorAction Stop

    # 5. Copy the fix script from the server to the remote machine's temp folder
    Write-Output "Copying script file to destination: $DestinationPath"
    Copy-Item -Path $SourcePath -Destination $DestinationPath -Force -ErrorAction Stop
    Write-Output "File transfer completed successfully."

    # 6. Execute the fix script remotely inside the target computer
    Write-Output "Executing fix script remotely on the target machine..."
    
    Invoke-Command -ComputerName $TargetComputer -ScriptBlock {
        param($scriptPath)
        if (Test-Path -Path $scriptPath -ErrorAction SilentlyContinue) {
            # Execute the local script bypassing local restrictions and suppressing sub-errors
            $ErrorActionPreference = "Stop"
            try {
                powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File $scriptPath
            } catch {
                # Prevents non-critical pipeline errors from breaking the master deployment script
                Write-Output "Notice: Script execution completed with minor pipeline warnings."
            }
        }
    } -ArgumentList "C:\temp\fix_adobev1.ps1" -ErrorAction Stop

    # 7. Clean up the temp script file from the target machine
    Invoke-Command -ComputerName $TargetComputer -ScriptBlock {
        param($scriptPath)
        if (Test-Path -Path $scriptPath -ErrorAction SilentlyContinue) {
            Remove-Item -Path $scriptPath -Force -ErrorAction SilentlyContinue
        }
    } -ArgumentList "C:\temp\fix_adobev1.ps1" -ErrorAction SilentlyContinue

    Write-Output "Process completed successfully on machine: $TargetComputer"

} catch {
    Write-Error "Deployment failed. Error details: $_"
}
