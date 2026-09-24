Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- FUNÇÃO AUXILIAR PARA QUEBRA INTELIGENTE ANTES DE 3800 CARACTERES ---
function Quebrar-TextoInteligente {
    param ([string]$Texto)
    $maxCaracteres = 3800
    $blocosResultado = New-Object System.Collections.Generic.List[string]
    $posicaoAtual = 0
    $tamanhoTotal = $Texto.Length

    while ($posicaoAtual -lt $tamanhoTotal) {
        $caracteresRestantes = $tamanhoTotal - $posicaoAtual
        if ($caracteresRestantes -le $maxCaracteres) {
            $blocosResultado.Add($Texto.Substring($posicaoAtual))
            break
        } else {
            $trechoMaximo = $Texto.Substring($posicaoAtual, $maxCaracteres)
            $ultimaQuebra = $trechoMaximo.LastIndexOf("`n")
            if ($ultimaQuebra -gt 0) {
                $comprimentoCorte = $ultimaQuebra + 1
                $blocosResultado.Add($Texto.Substring($posicaoAtual, $comprimentoCorte))
                $posicaoAtual += $comprimentoCorte
            } else {
                $blocosResultado.Add($trechoMaximo)
                $posicaoAtual += $maxCaracteres
            }
        }
    }
    return $blocosResultado.ToArray()
}

# --- FUNÇÃO AUXILIAR PARA CAPTURAR TEXTO VIA NOTEPAD ---
function Obter-TextoDoNotepad {
    param ([string]$MensagemTitulo)
    $tempFile = Join-Path $env:TEMP "codigo_temporario_ia.txt"
    if (Test-Path $tempFile) { Remove-Item $tempFile -Force }

    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "$MensagemTitulo" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan

    New-Item -ItemType File -Path $tempFile -Force | Out-Null
    $notepadProcess = Start-Process notepad.exe -ArgumentList $tempFile -PassThru
    $notepadProcess.WaitForExit()

    $textoCapturado = ""
    if (Test-Path $tempFile) {
        $textoCapturado = Get-Content -Path $tempFile -Raw
        Remove-Item $tempFile -Force
    }
    return $textoCapturado
}

# --- FUNÇÃO AUXILIAR PARA DISPARAR COMANDO NO NAVEGADOR ---
function Executar-EnvioNoNavegador {
    param ([string]$texto, $processoAlvo)
    if ($script:interromper) { return }

    [System.Windows.Forms.Clipboard]::SetText($texto)
    
    [void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic')
    [Microsoft.VisualBasic.Interaction]::AppActivate($processoAlvo.Id)
    Start-Sleep -Milliseconds 400
    
    $wshell = New-Object -ComObject WScript.Shell
    $wshell.SendKeys("^v")
    Start-Sleep -Milliseconds 300
    $wshell.SendKeys("{ENTER}")
}

# ==========================================================
# 1. PERGUNTA INICIAL AO USUÁRIO (MENU DE SELEÇÃO DE MODO)
# ==========================================================
$tituloSelecao = "Escolha o Modo de Operação"
$mensagemSelecao = "O que você deseja fazer hoje?`n`n[Sim] - Análise Padrão (Apenas 1 Script)`n[Não] - Comparar Dois Scripts Diferentes"
$respostaMenu = [System.Windows.Forms.MessageBox]::Show($mensagemSelecao, $tituloSelecao, [System.Windows.Forms.MessageBoxButtons]::YesNoCancel, [System.Windows.Forms.MessageBoxIcon]::Question)

if ($respostaMenu -eq [System.Windows.Forms.DialogResult]::Cancel) {
    Write-Warning "Operação cancelada pelo usuário."
    exit
}

$script:modoComparacao = $respostaMenu -eq [System.Windows.Forms.DialogResult]::No
$script:blocosScript1 = @()
$script:blocosScript2 = @()
$script:processoConcluido = $false 
$script:interromper = $false
$script:automacaoIniciada = $false

# Variáveis de controle da Fila de Envios
$script:listaFilaEnvios = New-Object System.Collections.Generic.List[string]
$script:indiceFilaAtual = 0
$script:targetProcess = $null

# ==========================================================
# 2. CAPTURA E PROCESSAMENTO INDEPENDENTE DOS SCRIPTS
# ==========================================================
if ($script:modoComparacao) {
    $codigo1 = Obter-TextoDoNotepad -MensagemTitulo "ABRINDO O NOTEPAD PARA O **SCRIPT 1**... COLE, SALVE E FECHE."
    if ([string]::IsNullOrWhitespace($codigo1)) { Write-Error "Script 1 vazio. Abortando."; exit }
    $script:blocosScript1 = Quebrar-TextoInteligente -Texto $codigo1

    $codigo2 = Obter-TextoDoNotepad -MensagemTitulo "ABRINDO O NOTEPAD PARA O **SCRIPT 2**... COLE, SALVE E FECHE."
    if ([string]::IsNullOrWhitespace($codigo2)) { Write-Error "Script 2 vazio. Abortando."; exit }
    $script:blocosScript2 = Quebrar-TextoInteligente -Texto $codigo2

    $totalS1 = $script:blocosScript1.Count
    $totalS2 = $script:blocosScript2.Count
    $textoInstrucaoComparar = "Atenção: Irei te enviar DOIS scripts diferentes para comparação. O primeiro script foi dividido em exatamente $totalS1 blocks de texto e o segundo script foi dividido em exatamente $totalS2 blocks de texto. Não tome nenhuma ação, não faça análise e não tente corrigir nada ainda. Apenas responda 'Entendido, aguardando os blocks.' e aguarde eu terminar de enviar todos os blocks sequencialmente."
    
    $script:listaFilaEnvios.Add("STATUS:Enviando Instruções de Comparação (1/2)...")
    $script:listaFilaEnvios.Add($textoInstrucaoComparar)
    $script:listaFilaEnvios.Add("STATUS:Repetindo Instruções de Comparação (2/2)...")
    $script:listaFilaEnvios.Add($textoInstrucaoComparar)

    for ($i = 0; $i -lt $totalS1; $i++) {
        $numB = $i + 1
        $script:listaFilaEnvios.Add("STATUS:Injetando Script 1: Bloco $numB de $totalS1...")
        $script:listaFilaEnvios.Add("[SCRIPT 1 - PARTE $numB DE $totalS1]`r`n" + $script:blocosScript1[$i])
    }

    $script:listaFilaEnvios.Add("STATUS:Avisando IA sobre início do Script 2...")
    $script:listaFilaEnvios.Add("Terminei de enviar inteiramente o primeiro script. Agora irei começar a enviar o segundo script. Continue apenas armazenando e não tome nenhuma ação ainda.")

    for ($j = 0; $j -lt $totalS2; $j++) {
        $numB = $j + 1
        $script:listaFilaEnvios.Add("STATUS:Injetando Script 2: Bloco $numB de $totalS2...")
        $script:listaFilaEnvios.Add("[SCRIPT 2 - PARTE $numB DE $totalS2]`r`n" + $script:blocosScript2[$j])
    }

    $script:listaFilaEnvios.Add("STATUS:Enviando Alerta de Conclusão Final...")
    $script:listaFilaEnvios.Add("Terminei o envio do segundo script. Finalizei todos os envios de códigos. Por favor, continue aguardando instruções sobre o que analisar ou comparar.")

} else {
    $codigoUnico = Obter-TextoDoNotepad -MensagemTitulo "ABRINDO O NOTEPAD PARA O SCRIPT... COLE, SALVE E FECHE."
    if ([string]::IsNullOrWhitespace($codigoUnico)) { Write-Error "Código vazio. Abortando."; exit }
    $script:blocosScript1 = Quebrar-TextoInteligente -Texto $codigoUnico
    
    $totalS1 = $script:blocosScript1.Count
    $textoInstrucaoPadrao = "Atenção: Vou te enviar um código longo que foi dividido de forma limpa em exatamente $totalS1 blocks de texto. Não tome nenhuma ação, não faça análise e não tente corrigir nada ainda. Apenas responda 'Entendido, aguardando os blocks.' e aguarde eu terminar de enviar todos os blocks sequencialmente."

    $script:listaFilaEnvios.Add("STATUS:Enviando Instruções Iniciais (1/2)...")
    $script:listaFilaEnvios.Add($textoInstrucaoPadrao)
    $script:listaFilaEnvios.Add("STATUS:Repetindo Instruções Iniciais (2/2)...")
    $script:listaFilaEnvios.Add($textoInstrucaoPadrao)

    for ($i = 0; $i -lt $totalS1; $i++) {
        $numB = $i + 1
        $script:listaFilaEnvios.Add("STATUS:Injetando Bloco $numB de $totalS1 automaticamente...")
        $script:listaFilaEnvios.Add("[PARTE $numB DE $totalS1]`r`n" + $script:blocosScript1[$i])
    }
}

# ==========================================================
# 3. INTERFACE GRÁFICA DO PAINEL AUTOMÁTICO
# ==========================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "Automação Google IA"
$form.Size = New-Object System.Drawing.Size(420,240)
$form.StartPosition = "CenterScreen"
$form.TopMost = $true 

$label = New-Object System.Windows.Forms.Label
$label.Location = New-Object System.Drawing.Point(20,20)
$label.Size = New-Object System.Drawing.Size(370,30)
$label.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
$label.Text = "Clique abaixo para iniciar a rotina automática no navegador."
$form.Controls.Add($label)

$button = New-Object System.Windows.Forms.Button
$button.Location = New-Object System.Drawing.Point(20,60)
$button.Size = New-Object System.Drawing.Size(360,50)
$button.Font = New-Object System.Drawing.Font("Arial", 11, [System.Drawing.FontStyle]::Bold)
$button.Text = "INICIAR PROCESSO AUTOMÁTICO"
$button.BackColor = [System.Drawing.Color]::LightGreen
$form.Controls.Add($button)

$btnParar = New-Object System.Windows.Forms.Button
$btnParar.Location = New-Object System.Drawing.Point(20,120)
$btnParar.Size = New-Object System.Drawing.Size(360,40)
$btnParar.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
$btnParar.Text = "PARAR AUTOMAÇÃO"
$btnParar.BackColor = [System.Drawing.Color]::LightCoral
$btnParar.Enabled = $true 
$form.Controls.Add($btnParar)

# CONFIGURAÇÃO DO TIMER
$automationTimer = New-Object System.Windows.Forms.Timer
$automationTimer.Interval = 5000

# LÓGICA DO EVENTO DO TIMER
$automationTimer.Add_Tick({
    if ($script:interromper) {
        $automationTimer.Stop()
        return
    }

    if ($script:indiceFilaAtual -lt $script:listaFilaEnvios.Count) {
        $itemAtual = $script:listaFilaEnvios[$script:indiceFilaAtual]

        if ($itemAtual.StartsWith("STATUS:")) {
            $label.Text = $itemAtual.Substring(7)
            $script:indiceFilaAtual++
            if ($script:indiceFilaAtual -lt $script:listaFilaEnvios.Count) {
                $comandoTexto = $script:listaFilaEnvios[$script:indiceFilaAtual]
                Executar-EnvioNoNavegador -texto $comandoTexto -processoAlvo $script:targetProcess
                $script:indiceFilaAtual++
            }
        } else {
            Executar-EnvioNoNavegador -texto $itemAtual -processoAlvo $script:targetProcess
            $script:indiceFilaAtual++
        }
    } else {
        # SUCESSO: Desliga o timer e remove fisicamente o botão Parar da janela
        $automationTimer.Stop()
        $script:processoConcluido = $true
        $form.Controls.Remove($btnParar) # MODIFICADO: Remove o botão do formulário
        
        $label.Text = "Processo finalizado com sucesso!"
        $button.Text = "FECHAR PAINEL"
        $button.BackColor = [System.Drawing.Color]::DarkGray
        $button.Enabled = $true
    }
})

# LÓGICA DO BOTÃO PARAR / CANCELAR
$btnParar.Add_Click({
    if ($script:automacaoIniciada) {
        $script:interromper = $true
        $automationTimer.Stop()
        
        $label.Text = "Processo interrompido pelo usuário!"
        $form.Controls.Remove($btnParar) # MODIFICADO: Também remove ao interromper por consistência
        
        $button.Text = "FECHAR"
        $button.BackColor = [System.Drawing.Color]::DarkOrange
        $button.Enabled = $true
        $script:processoConcluido = $true
    } else {
        $form.Close()
    }
})

# LÓGICA DO BOTÃO PRINCIPAL
$button.Add_Click({
    if ($script:processoConcluido) {
        $form.Close()
        return
    }

    $script:targetProcess = Get-Process -Name chrome, msedge -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -ne "" } | Select-Object -First 1
    if (-not $script:targetProcess) {
        [System.Windows.Forms.MessageBox]::Show("Navegador ativo não encontrado!", "Erro de Foco", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    $script:automacaoIniciada = $true
    $button.Enabled = $false
    $button.BackColor = [System.Drawing.Color]::LightGray
    $script:interromper = $false
    $script:indiceFilaAtual = 0

    $automationTimer.Start()
})

$form.ShowDialog() | Out-Null
$automationTimer.Dispose()
[System.Windows.Forms.Clipboard]::Clear()
Write-Host "Processo concluído e painel fechado." -ForegroundColor Yellow
