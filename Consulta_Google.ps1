Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- FUNÇÃO GERENCIADORA DE DELAY COM SUPORTE A PAUSA, ABORTO E CONTADOR ---
function Aguardar-ComControles {
    param (
        [int]$Segundos,
        [System.Windows.Forms.Label]$LabelTempo,
        [int]$TempoRestanteTotal,
        [System.Windows.Forms.Label]$StatusLabel
    )
    $tempoRestanteLocal = $TempoRestanteTotal
    for ($s = 0; $s -lt ($Segundos * 10); $s++) {
        # Mantém a janela respondendo e evita o congelamento do Windows Forms
        [System.Windows.Forms.Application]::DoEvents()
        
        # Gerenciamento de interrupção imediata
        if ($script:abortarProcesso) { return $tempoRestanteLocal }
        
        # Loop de pausa ativa
        while ($script:pausarProcesso) {
            [System.Windows.Forms.Application]::DoEvents()
            if ($script:abortarProcesso) { return $tempoRestanteLocal }
            Start-Sleep -Milliseconds 100
        }
        
        Start-Sleep -Milliseconds 100
        
        # Atualiza o contador regressivo na tela a cada 1 segundo real
        if (($s % 10) -eq 0 -and $s -gt 0) {
            $tempoRestanteLocal--
            $minutos = [Math]::Floor($tempoRestanteLocal / 60)
            $segundosRestantes = $tempoRestanteLocal % 60
            $LabelTempo.Text = "Tempo Estimado Restante: {0:D2}:{1:D2}" -f $minutos, $segundosRestantes
        }
    }
    return $tempoRestanteLocal
}

# ==========================================================
# 1. CRIAÇÃO DA JANELA PRINCIPAL DA GUI (DESIGN DO SEU CÓDIGO)
# ==========================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "Envio 100% Automático Otimizado - Consulta Google"
$form.Size = New-Object System.Drawing.Size(600, 550)
$form.StartPosition = "CenterScreen"
$form.TopMost = $true

# Ativa o sinal de abortar caso o usuário feche a janela no "X" vermelho
$form.Add_FormClosing({
    $script:abortarProcesso = $true
})

# Rótulo explicativo
$label = New-Object System.Windows.Forms.Label
$label.Text = "Cole o código ou texto completo abaixo:"
$label.Location = New-Object System.Drawing.Point(20, 15)
$label.Size = New-Object System.Drawing.Size(540, 20)
$form.Controls.Add($label)

# Caixa de texto multilinha (Onde você cola o código diretamente)
$textBox = New-Object System.Windows.Forms.TextBox
$textBox.Multiline = $true
$textBox.ScrollBars = "Vertical"
$textBox.Location = New-Object System.Drawing.Point(20, 40)
$textBox.Size = New-Object System.Drawing.Size(540, 260)
$form.Controls.Add($textBox)

# NOVO: Rótulo do Contador Regressivo de Tempo Estimado
$labelTempo = New-Object System.Windows.Forms.Label
$labelTempo.Text = "Tempo Estimado Restante: 00:00"
$labelTempo.Location = New-Object System.Drawing.Point(20, 310)
$labelTempo.Size = New-Object System.Drawing.Size(540, 20)
$labelTempo.Font = New-Object System.Drawing.Font("Arial", 9, [System.Drawing.FontStyle]::Italic)
$form.Controls.Add($labelTempo)
# Botão Iniciar Processo
$button = New-Object System.Windows.Forms.Button
$button.Text = "Iniciar Processo 100% Automático"
$button.Location = New-Object System.Drawing.Point(20, 335)
$button.Size = New-Object System.Drawing.Size(540, 40)
$button.BackColor = [System.Drawing.Color]::LightGreen
$button.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($button)

# NOVO: Botão de Pausa e Abortar Dinâmico
$btnPausa = New-Object System.Windows.Forms.Button
$btnPausa.Text = "PAUSAR / ABORTAR"
$btnPausa.Location = New-Object System.Drawing.Point(20, 385)
$btnPausa.Size = New-Object System.Drawing.Size(540, 35)
$btnPausa.BackColor = [System.Drawing.Color]::LightGoldenrodYellow
$btnPausa.Font = New-Object System.Drawing.Font("Arial", 9, [System.Drawing.FontStyle]::Bold)
$btnPausa.Enabled = $false
$form.Controls.Add($btnPausa)

# Rótulo de Status
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Status: Aguardando entrada..."
$statusLabel.Location = New-Object System.Drawing.Point(20, 435)
$statusLabel.Size = New-Object System.Drawing.Size(540, 20)
$statusLabel.ForeColor = [System.Drawing.Color]::Blue
$form.Controls.Add($statusLabel)

# Inicialização das variáveis de controle de fluxo de segundo plano
$script:processoConcluido = $false 
$script:abortarProcesso = $false 
$script:pausarProcesso = $false

# Lógica de clique do botão Pausar / Retomar
$btnPausa.Add_Click({
    if (-not $script:pausarProcesso) {
        $script:pausarProcesso = $true
        $btnPausa.Text = "RETOMAR PROCESSO"
        $btnPausa.BackColor = [System.Drawing.Color]::Orange
        $statusLabel.Text = "Status: Processo pausado pelo usuário."
    } else {
        $script:pausarProcesso = $false
        $btnPausa.Text = "PAUSAR PROCESSO"
        $btnPausa.BackColor = [System.Drawing.Color]::LightSalmon
    }
})
# Ação do Botão Principal
$button.Add_Click({
    $rawText = $textBox.Text

    if ([string]::IsNullOrWhitespace($rawText)) {
        [System.Windows.Forms.MessageBox]::Show("Por favor, cole o texto antes de continuar.", "Aviso")
        return
    }

    # Reseta os estados de controle para uma nova execução segura
    $script:abortarProcesso = $false
    $script:pausarProcesso = $false
    $script:processoConcluido = $false

    $button.Enabled = $false
    $button.BackColor = [System.Drawing.Color]::LightGray
    $btnPausa.Enabled = $true
    $btnPausa.Text = "PAUSAR PROCESSO"
    $btnPausa.BackColor = [System.Drawing.Color]::LightSalmon

    $statusLabel.Text = "Status: Processando texto e quebrando em blocos..."
    $statusLabel.ForeColor = [System.Drawing.Color]::Blue
    $form.Refresh()

    # 1. Tratamento e normalização robusta de texto
    $utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes($rawText)
    $cleanText = [System.Text.Encoding]::UTF8.GetString($utf8Bytes)

    # 2. Divisão automática em blocos estáveis de 3800 caracteres (Prevenção de quebra de limite)
    $maxChunkSize = 3800
    $blocos = @()
    for ($i = 0; $i -lt $cleanText.Length; $i += $maxChunkSize) {
        if (($i + $maxChunkSize) -gt $cleanText.Length) {
            $blocos += $cleanText.Substring($i)
        } else {
            $blocos += $cleanText.Substring($i, $maxChunkSize)
        }
    }

    # 3. Gerenciamento inteligente de Foco do Navegador
    $statusLabel.Text = "Status: Localizando navegador e abrindo aba..."
    $form.Refresh()
    
    $url = "https://google.com/ai"
    Start-Process $url
    
    # Busca um processo ativo de navegador para aplicar foco de digitação
    $targetProcess = Get-Process -Name chrome, msedge -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -ne "" } | Select-Object -First 1
    
    # 4. Cálculo Dinâmico Real do Tempo Restante (7s do aviso + 10s da resposta + 8s por bloco)
    $totalBlocos = $blocos.Count
    $script:tempoTotalSegundos = 7 + 10 + ($totalBlocos * 8)
    
    # Pausa inicial de abertura de aba controlada pelo gerenciador
    $script:tempoTotalSegundos = Aguardar-ComControles -Segundos 7 -LabelTempo $labelTempo -TempoRestanteTotal $script:tempoTotalSegundos -StatusLabel $statusLabel

    # Injeta foco nativo no navegador alvo antes do primeiro envio
    if ($targetProcess) {
        [void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic')
        try { [Microsoft.VisualBasic.Interaction]::AppActivate($targetProcess.Id) } catch {}
        Start-Sleep -Milliseconds 400
    }

    # 5. Envio do Aviso Inicial sem duplicidade
    if (-not $script:abortarProcesso) {
        $statusLabel.Text = "Status: Enviando mensagem de aviso inicial..."
        $form.Refresh()

        $avisoInicial = "Atenção: Vou te enviar um texto ou código longo que foi dividido de forma limpa automaticamente. Não tome nenhuma ação, não faça análise e não tente corrigir nada ainda. Apenas responda 'Entendido, aguardando os blocks.' e aguarde eu terminar de enviar todos os blocks sequencialmente."
        
        [System.Windows.Forms.Clipboard]::SetText($avisoInicial)
        [System.Windows.Forms.SendKeys]::SendWait("^v")
        Start-Sleep -Milliseconds 400
        [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")

        $statusLabel.Text = "Status: Aguardando resposta inicial da IA (10 segundos)..."
        $form.Refresh()
        $script:tempoTotalSegundos = Aguardar-ComControles -Segundos 10 -LabelTempo $labelTempo -TempoRestanteTotal $script:tempoTotalSegundos -StatusLabel $statusLabel
    }

    # 6. Loop de Envio dos Blocos por Clipboard (Garante 100% de leitura de caracteres especiais)
    $contador = 1
    foreach ($bloco in $blocos) {
        if ($script:abortarProcesso) { break }

        # Traz o foco de volta para o navegador em cada loop para evitar cliques perdidos fora
        if ($targetProcess) {
            try { [Microsoft.VisualBasic.Interaction]::AppActivate($targetProcess.Id) } catch {}
            Start-Sleep -Milliseconds 200
        }

        $statusLabel.Text = "Status: Enviando Bloco $contador de $totalBlocos..."
        $form.Refresh()

        # Aloca o bloco inteiro na memória para colar bruto e idêntico
        [System.Windows.Forms.Clipboard]::SetText($bloco)
        [System.Windows.Forms.SendKeys]::SendWait("^v")
        Start-Sleep -Milliseconds 400
        [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")

        if ($contador -lt $totalBlocos) {
            $statusLabel.Text = "Status: Bloco $contador enviado. Aguardando 15 segundos..."
            $form.Refresh()
            $script:tempoTotalSegundos = Aguardar-ComControles -Segundos 15 -LabelTempo $labelTempo -TempoRestanteTotal $script:tempoTotalSegundos -StatusLabel $statusLabel
        }
        $contador++
    }

    # Finalização do Estado e Mensagem Final
    $btnPausa.Enabled = $false
    if ($script:abortarProcesso) {
        $statusLabel.Text = "Status: Processo abortado ou cancelado!"
        $statusLabel.ForeColor = [System.Drawing.Color]::Red
        $labelTempo.Text = "Tempo Estimado Restante: --:--"
        $button.Text = "FECHAR"
        $button.BackColor = [System.Drawing.Color]::LightCoral
    } else {
        $script:processoConcluido = $true
        $statusLabel.Text = "Status: Concluído! Todos os blocos foram enviados com sucesso."
        $statusLabel.ForeColor = [System.Drawing.Color]::Green
        $labelTempo.Text = "Tempo Estimado Restante: 00:00"
        $button.Text = "FECHAR PAINEL"
        $button.BackColor = [System.Drawing.Color]::DarkGray
        [System.Windows.Forms.MessageBox]::Show("Todos os blocos de código foram enviados sequencialmente de forma automática!", "Sucesso")
    }
    $button.Enabled = $true
})

# Exibir a Interface Ativa
$form.ShowDialog() | Out-Null
[System.Windows.Forms.Clipboard]::Clear()