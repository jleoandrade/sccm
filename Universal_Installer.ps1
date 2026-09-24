Write-Host "==============================================="
Write-Host "        Remote Software Installer"
Write-Host "==============================================="
Write-Host ""
Write-Host "Select the software to install:"
Write-Host "1 - Visual Studio Code"
Write-Host "2 - SQL Server Management Studio (SSMS)"
Write-Host "3 - Enter a custom Winget package ID"
Write-Host ""

$choice = Read-Host "Enter the option number"
$computer = Read-Host "Enter the remote computer name"

switch ($choice) {

    "1" {
        $package = "Microsoft.VisualStudioCode"
        Write-Host "Installing Visual Studio Code on $computer..."
    }

    "2" {
        $package = "Microsoft.SQLServerManagementStudio"
        Write-Host "Installing SQL Server Management Studio on $computer..."
    }

    "3" {
        $package = Read-Host "Enter the Winget package ID (example: Google.Chrome)"
        Write-Host "Installing $package on $computer..."
    }

    default {
        Write-Host "Invalid option. Exiting."
        exit
    }
}

Invoke-Command -ComputerName $computer -ScriptBlock {
    param($pkg)

    Write-Host "Starting installation of package: $pkg"
    winget install --id $pkg --silent --accept-package-agreements --accept-source-agreements
} -ArgumentList $package

Write-Host ""
Write-Host "Installation completed or started, depending on the package."
Write-Host "==============================================="
