# --- Profile Removal Script ---

# 1. Ask for the computer name
$ComputerName = Read-Host "Enter the target Computer Name or IP address"
if (-not (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet)) {
    Write-Error "Could not connect to $ComputerName. Machine is offline."
    Exit
}
Write-Host "`nConnecting to $ComputerName..." -ForegroundColor Cyan

# 2. Fetch user profiles and calculate last login time
$Profiles = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
    Get-CimInstance -ClassName Win32_UserProfile | Where-Object { $_.Special -eq $false } | ForEach-Object {
        [PSCustomObject]@{
            Username  = $_.LocalPath.Split('\')[-1]
            LastLogin = $_.LastUseTime
            SID       = $_.SID
        }
    }
}

if ($null -eq $Profiles -or $Profiles.Count -eq 0) {
    Write-Host "No local user profiles found on $ComputerName." -ForegroundColor Yellow
    Exit
}

# 3. List profiles with index numbers
Write-Host "`nAvailable user profiles on ${ComputerName}:" -ForegroundColor Green
for ($i = 0; $i -lt $Profiles.Count; $i++) {
    Write-Host "[$i] User: $($Profiles[$i].Username) | Last Login: $($Profiles[$i].LastLogin)"
}

# 4. Ask the administrator which profiles to delete
Write-Host "`nInstructions: Enter the numbers you want to delete separated by commas (e.g., 0,2,3)." -ForegroundColor Yellow
$Selection = Read-Host "Enter profile numbers to DELETE"

if ([string]::IsNullOrWhiteSpace($Selection)) {
    Write-Host "No profiles selected. Exiting safely." -ForegroundColor Cyan
    Exit
}

# Process selections cleanly
$TargetIndexes = $Selection.Split(',') | ForEach-Object { $_.Trim() }

foreach ($Index in $TargetIndexes) {
    # Strictly validate if the input is a number and within array bounds
    if ($Index -match '^\d+$' -and [int]$Index -lt $Profiles.Count) {
        $ProfileToDelete = $Profiles[[int]$Index]
        Write-Host "`nAttempting to delete profile: $($ProfileToDelete.Username)..." -ForegroundColor Yellow

        # 5. Execute deletion on remote machine
        try {
            Invoke-Command -ComputerName $ComputerName -ErrorAction Stop -ScriptBlock {
                param($Sid)
                $UserObj = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID = '$Sid'"
                if ($null -ne $UserObj) {
                    Remove-CimInstance -InputObject $UserObj -ErrorAction Stop
                } else {
                    throw "Profile SID not found on remote machine."
                }
            } -ArgumentList $ProfileToDelete.SID

            Write-Host "Success: Profile $($ProfileToDelete.Username) deleted successfully." -ForegroundColor Green
        }
        catch {
            Write-Host "Error: Failed to delete profile $($ProfileToDelete.Username). Details: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "Invalid selection: '$Index' is not a valid profile number." -ForegroundColor Red
    }
}

Write-Host "`nProcess finished." -ForegroundColor Cyan
