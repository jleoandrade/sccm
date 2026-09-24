# Convert error codes (-2145844844) to hexidecimal (0x7fe6fe6c)

 
$Number = "-2146498174"
$FromNumber = [System.Convert]::ToString($Number,16)

 

if ($FromNumber.Length -eq 8){
    $Hex = "0x" + $FromNumber
}

 

if ($FromNumber.Length -eq 16){
    $Hex = $FromNumber.Substring(8,8)
    $Dec = $FromNumber.Substring(0,8)
    $Hex = "0x" + $Hex
    $Dec = "0x" + $Dec
}
$Hex 