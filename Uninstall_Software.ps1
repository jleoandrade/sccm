Write-Host "=== Remote Software Uninstallation ===" -ForegroundColor Cyan

# 1. Ask for the remote computer name
$Computer = Read-Host "Enter the name of the remote computer"

# Test connection
if (!(Test-Connection -ComputerName $Computer -Count 1 -Quiet)) {
    Write-Host "It was not possible to connect to the computer $Computer" -ForegroundColor Red
    exit
}

# 2. Ask for the software name (example: Zoom)
$SoftwareName = Read-Host "Enter the name (or part of the name) of the software to search for"

Write-Host "`nSearching for software '$SoftwareName' on computer $Computer..." -ForegroundColor Yellow

# Search for the software
$App = Get-WmiObject -Class Win32_Product -ComputerName $Computer |
       Where-Object { $_.Name -like "*$SoftwareName*" }

if (!$App) {
    Write-Host "No software found with that name." -ForegroundColor Red
    exit
}

Write-Host "`n=== Software Found ===" -ForegroundColor Green
$App | Select-Object Name, IdentifyingNumber | Format-Table -AutoSize

# 3. Ask for the Product ID to uninstall
$ProductID = Read-Host "`nEnter the Product ID shown above to uninstall"

# Confirm it exists
$Selected = $App | Where-Object { $_.IdentifyingNumber -eq $ProductID }

if (!$Selected) {
    Write-Host "The Product ID does not match the software found." -ForegroundColor Red
    exit
}

Write-Host "`nYou selected: $($Selected.Name)" -ForegroundColor Cyan

$Confirm = Read-Host "Do you really want to uninstall it? (Y/N)"

if ($Confirm -ne "Y") {
    Write-Host "Operation canceled." -ForegroundColor Yellow
    exit
}

# 4. Execute the uninstallation
Write-Host "`nStarting uninstallation..." -ForegroundColor Yellow

$Selected.Uninstall()

Write-Host "`nUninstallation completed." -ForegroundColor Green
