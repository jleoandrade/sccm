# Defina sua lista de códigos aqui
$Numeros = @("-2133843966", "-2145844844", "-2147024891")

# Laço para processar em massa
foreach ($Number in $Numeros) {

    # Seu script original idêntico por dentro:
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
    
    # Exibe o resultado de cada um da lista
    [PSCustomObject]@{
        Decimal = $Number
        Hex     = $Hex
    }
}
