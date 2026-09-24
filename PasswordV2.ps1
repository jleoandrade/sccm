do {
    Clear-Host
    Write-Host "=== LAPS Password Retrieval ===" -ForegroundColor Cyan

    # Prompt for device name
    $deviceName = Read-Host "Enter the device name (or type 'exit' to quit)"

    # Exit condition
    if ($deviceName -eq "exit") {
        break
    }

    # Attempt to retrieve password
    try {
        $result = Get-AdmPwdPassword -ComputerName $deviceName
        Write-Host "`nDevice:      $($result.ComputerName)" -ForegroundColor Cyan
        Write-Host "Password:    $($result.Password)" -ForegroundColor Yellow
        Write-Host "Expires on:  $($result.ExpirationTimestamp)" -ForegroundColor Gray
    } catch {
        Write-Host "`nError retrieving password. Make sure the device name is correct and you have permission." -ForegroundColor Red
    }

    # Pause before next loop
    Write-Host "`nPress Enter to continue..."
    Read-Host

} while ($true)

Write-Host "`nScript ended. Goodbye!" -ForegroundColor Green
