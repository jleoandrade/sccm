Invoke-Command -ComputerName 1583982A -ScriptBlock {
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Access Connectivity Engine\Engines\ACE" -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Access Connectivity Engine\Engines\ACE" -Name "BlockRemoteDatabaseAccess" -Value 1 -PropertyType DWord -Force
}
