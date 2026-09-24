Import-Module ActiveDirectory

$Computer = Read-Host "Enter the computer name"

Write-Host "`nChecking computer $Computer..." -ForegroundColor Cyan

# Logged-on user
try {
    $User = (Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $Computer).UserName
} catch {
    $User = $null
}

# Prepare AD fields
$AD_DisplayName = "Unavailable"
$AD_Email       = "Unavailable"

# If a user was found, try to query AD
if ($User) {
    try {
        # Extract only the username (DOMAIN\User → User)
        $Sam = $User.Split("\")[-1]

        $ADUser = Get-ADUser -Filter { SamAccountName -eq $Sam } -Properties mail, displayName

        if ($ADUser) {
            $AD_DisplayName = $ADUser.DisplayName
            $AD_Email       = $ADUser.Mail
        }
        else {
            $AD_DisplayName = "User not found in AD"
            $AD_Email       = "User not found in AD"
        }
    }
    catch {
        $AD_DisplayName = "Error querying AD"
        $AD_Email       = "Error querying AD"
    }
}
else {
    $User = "Error retrieving user"
}

# Reboot pending
try {
    $Pending = Invoke-Command -ComputerName $Computer -ScriptBlock {
        $Reboot = $false

        if (Test-Path "HKLM:\SOFTWARE\Microsoft\CCM\PendingReboot") { $Reboot = $true }
        if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { $Reboot = $true }
        if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $Reboot = $true }

        return $Reboot
    }
} catch {
    $Pending = "Error retrieving reboot status"
}

# Output
[PSCustomObject]@{
    Computer        = $Computer
    LoggedOnUser    = $User
    AD_DisplayName  = $AD_DisplayName
    AD_Email        = $AD_Email
    RebootPending   = $Pending
}
