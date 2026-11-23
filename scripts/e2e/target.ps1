# Janela alvo do smoke test: uma caixa de texto que grava o que recebe em $Out, para o
# smoke.mjs conferir que o atalho/tecla do DeckOS chegou de verdade. Fecha sozinha em 2 min.
param([string]$Out, [string]$Title = 'DeckOS E2E Target')
Add-Type -AssemblyName System.Windows.Forms
$form = New-Object System.Windows.Forms.Form
$form.Text = $Title
$form.Width = 420; $form.Height = 160
$form.TopMost = $true
$box = New-Object System.Windows.Forms.TextBox
$box.Dock = 'Fill'; $box.Multiline = $true
$form.Controls.Add($box)
$box.Add_TextChanged({ Set-Content -LiteralPath $Out -Value ('text=' + $box.Text) -NoNewline })
$form.Add_Shown({ $form.Activate(); $box.Focus(); Set-Content -LiteralPath $Out -Value 'text=' -NoNewline })
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 120000
$timer.Add_Tick({ $form.Close() })
$timer.Start()
[void]$form.ShowDialog()
