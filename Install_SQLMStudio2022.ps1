# Ask for the remote machine name
$computer = Read-Host "Enter the remote computer name"

Write-Host "Downloading and installing SSMS on $computer..."

Invoke-Command -ComputerName $computer -ScriptBlock {
    $url = "https://aka.ms/ssmsfullsetup"
    $path = "C:\Temp\SSMS-Setup.exe"

    # Create C:\Temp if it does not exist
    if (-not (Test-Path "C:\Temp")) {
        New-Item -Path "C:\" -Name "Temp" -ItemType Directory | Out-Null
    }

    # Download SSMS installer
    Invoke-WebRequest -Uri $url -OutFile $path

    # Silent installation
    Start-Process $path -ArgumentList "/install /quiet /norestart" -Wait
}

Write-Host "SSMS installation completed on $computer."
