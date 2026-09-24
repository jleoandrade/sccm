$ComputerName = "1074134A" # Substitua pelo nome ou IP

Invoke-Command -ComputerName $ComputerName -ScriptBlock {
    $r = @{
        WindowsUpdate = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
        ComponentServicing = Test-Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
        FileRename = $null -ne (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    }
    
    [PSCustomObject]@{
        ComputerName  = $env:COMPUTERNAME
        PendingReboot = $r.Values -contains $true
        Details       = $r
    }
}
