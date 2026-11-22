# Envia o projeto do seu PC para a VPS e roda a instalação (ou atualização).
# Uso:  powershell -ExecutionPolicy Bypass -File deploy\enviar.ps1 -Ip 123.45.67.89
# O banco de dados, as fotos e o .env NUNCA são enviados (os da VPS ficam intactos).
param(
  [Parameter(Mandatory = $true)][string]$Ip,
  [string]$Usuario = 'root'
)

$raiz = Split-Path -Parent $PSScriptRoot
$pai = Split-Path -Parent $raiz
$nome = Split-Path -Leaf $raiz
$pacote = Join-Path $env:TEMP 'saas-lojas.tgz'
$destino = "$Usuario@$Ip"

Write-Host "`n==> Empacotando $raiz" -ForegroundColor Magenta
if (Test-Path $pacote) { Remove-Item $pacote -Force }
tar -czf $pacote --exclude="$nome/data" --exclude="$nome/.env" --exclude="$nome/node_modules" -C $pai $nome
if ($LASTEXITCODE -ne 0) { Write-Host 'Falha ao empacotar.' -ForegroundColor Red; exit 1 }
Write-Host ("    pacote: {0:N0} KB" -f ((Get-Item $pacote).Length / 1KB))

Write-Host "`n==> Enviando para $destino (digite a senha da VPS se pedir)" -ForegroundColor Magenta
scp $pacote "${destino}:/tmp/saas-lojas.tgz"
if ($LASTEXITCODE -ne 0) { Write-Host 'Falha ao enviar. Confira o IP, o usuário e a senha da VPS.' -ForegroundColor Red; exit 1 }

Write-Host "`n==> Instalando na VPS" -ForegroundColor Magenta
$remoto = "mkdir -p /opt && tar -xzf /tmp/saas-lojas.tgz -C /opt && rm -f /tmp/saas-lojas.tgz && " +
          "sed -i 's/\r$//' /opt/$nome/deploy/instalar.sh && bash /opt/$nome/deploy/instalar.sh"
ssh -t $destino $remoto
if ($LASTEXITCODE -ne 0) { Write-Host "`nA instalação parou com erro (veja a mensagem acima)." -ForegroundColor Red; exit 1 }
