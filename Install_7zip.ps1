# Ask for the remote machine name
$computer = Read-Host "Enter the remote computer name"

Write-Host "Downloading and installing 7-Zip on $computer..."

Invoke-Command -ComputerName $computer -ScriptBlock {
    $url = "https://www.7-zip.org/a/7z2408-x64.exe"
    $path = "C:\Temp\7zip.exe"

    # Create C:\Temp if it does not exist
    if (-not (Test-Path "C:\Temp")) {
        New-Item -Path "C:\" -Name "Temp" -ItemType Directory | Out-Null
    }

    # Download 7-Zip installer
    Invoke-WebRequest -Uri $url -OutFile $path

    # Silent installation
    Start-Process $path -ArgumentList "/S" -Wait
}

Write-Host "7-Zip installation completed on $computer."
