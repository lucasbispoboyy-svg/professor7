#!/usr/bin/env bash
# Instala/atualiza o painel numa VPS Ubuntu/Debian.
# Na primeira vez pergunta domínio, login do dono e o certificado do Cloudflare.
# Nas próximas (atualizações) só reinicia com o código novo.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$APP_DIR/.env"
CERT=/etc/caddy/origin.pem
KEY=/etc/caddy/origin.key
APP_NOME=lojas

passo() { echo -e "\n\033[1;35m==> $*\033[0m"; }
ok()    { echo -e "\033[1;32m    ✔ $*\033[0m"; }
erro()  { echo -e "\033[1;31m    ✖ $*\033[0m" >&2; exit 1; }

[[ $EUID -eq 0 ]] || erro "Rode como root (ou com sudo)."
command -v apt-get >/dev/null || erro "Este script é para Ubuntu ou Debian."

set_env() {
  local k=$1 v=$2
  touch "$ENV_FILE"
  grep -v "^$k=" "$ENV_FILE" > "$ENV_FILE.tmp" || true
  mv "$ENV_FILE.tmp" "$ENV_FILE"
  printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"
}
get_env() { grep "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }

ler_pem() {
  local destino=$1 linha
  : > "$destino"
  while IFS= read -r linha; do
    linha=${linha%$'\r'}
    printf '%s\n' "$linha" >> "$destino"
    [[ "$linha" == -----END* ]] && break
  done
}

# ------------------------------------------------------------------ 1. dados
passo "Configuração"
DOMINIO=$(get_env BASE_DOMAIN)
if [[ -n "$DOMINIO" && "$DOMINIO" != "localhost" ]]; then
  ok "Já configurado para $DOMINIO (atualização)"
else
  read -rp "    Seu domínio (ex.: minhaslojas.com.br): " DOMINIO
  DOMINIO=$(echo "$DOMINIO" | tr 'A-Z' 'a-z' | sed -E 's#^https?://##; s#^www\.##; s#/.*$##; s/[[:space:]]//g')
  [[ "$DOMINIO" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || erro "Domínio inválido: $DOMINIO"
  read -rp "    E-mail de login do dono: " EMAIL
  [[ "$EMAIL" == *@*.* ]] || erro "E-mail inválido."
  while true; do
    read -rsp "    Senha do dono (mínimo 8 caracteres): " S1; echo
    read -rsp "    Repita a senha: " S2; echo
    [[ ${#S1} -ge 8 && "$S1" == "$S2" ]] && break
    echo "    As senhas não conferem ou são curtas. Tente de novo."
  done
  set_env ADMIN_EMAIL "$EMAIL"
  set_env ADMIN_PASSWORD "$S1"
  set_env BASE_DOMAIN "$DOMINIO"
  set_env PUBLIC_PROTO https
  set_env PUBLIC_PORT ""
  set_env TRUST_PROXY 1
  set_env PORT 3000
  chmod 600 "$ENV_FILE"
  ok "Configuração salva em $ENV_FILE"
fi

# ------------------------------------------------------------------ 2. programas
passo "Instalando programas (pode levar alguns minutos)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg debian-keyring debian-archive-keyring apt-transport-https sqlite3 ufw openssl >/dev/null

NODE_MAJOR=$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || echo 0)
if [[ "${NODE_MAJOR:-0}" -lt 22 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
ok "Node.js $(node -v)"

if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null
fi
ok "Caddy $(caddy version | cut -d' ' -f1)"

command -v pm2 >/dev/null || npm install -g pm2 --silent >/dev/null
ok "PM2 $(pm2 -v)"

# ------------------------------------------------------------------ 3. certificado
passo "Certificado HTTPS do Cloudflare"
if [[ -s "$CERT" && -s "$KEY" ]]; then
  ok "Certificado já instalado"
else
  cat <<EOF
    No Cloudflare: SSL/TLS → Origin Server → Create Certificate
    (deixe "$DOMINIO" e "*.$DOMINIO" na lista e validade de 15 anos).

    Cole abaixo o ORIGIN CERTIFICATE inteiro e aperte Enter
    (termina com -----END CERTIFICATE-----):
EOF
  ler_pem "$CERT"
  echo "    Agora cole a PRIVATE KEY inteira (termina com -----END PRIVATE KEY-----):"
  ler_pem "$KEY"
  openssl x509 -noout -in "$CERT" 2>/dev/null || { rm -f "$CERT" "$KEY"; erro "Certificado inválido. Rode o script de novo e cole o texto completo."; }
  openssl pkey -noout -in "$KEY" 2>/dev/null || { rm -f "$CERT" "$KEY"; erro "Chave inválida. Rode o script de novo e cole o texto completo."; }
  ok "Certificado salvo"
fi
chown root:caddy "$CERT" "$KEY"
chmod 640 "$CERT" "$KEY"

# ------------------------------------------------------------------ 4. caddy
passo "Configurando o Caddy (HTTPS)"
cat > /etc/caddy/Caddyfile <<EOF
$DOMINIO, *.$DOMINIO {
    tls $CERT $KEY
    encode gzip
    request_body {
        max_size 400MB
    }
    reverse_proxy localhost:3000
}
EOF
caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 || erro "Configuração do Caddy inválida."
systemctl enable caddy >/dev/null 2>&1
systemctl restart caddy
ok "Caddy rodando"

# ------------------------------------------------------------------ 5. app
passo "Iniciando o painel"
cd "$APP_DIR"
mkdir -p data
if pm2 describe "$APP_NOME" >/dev/null 2>&1; then
  pm2 restart "$APP_NOME" --update-env >/dev/null
else
  pm2 start server.js --name "$APP_NOME" --cwd "$APP_DIR" --node-args="--disable-warning=ExperimentalWarning" >/dev/null
fi
pm2 save >/dev/null
pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || true
sleep 2
CODIGO=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/ || echo 000)
[[ "$CODIGO" == "200" ]] || { pm2 logs "$APP_NOME" --lines 30 --nostream; erro "O painel não respondeu (HTTP $CODIGO). Veja o log acima."; }
ok "Painel respondendo"

# ------------------------------------------------------------------ 6. firewall
passo "Firewall"
SSH_PORTA=$(echo "${SSH_CONNECTION:-x x x 22}" | awk '{print $4}')
ufw allow "${SSH_PORTA:-22}"/tcp >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null
ok "Liberadas as portas ${SSH_PORTA:-22} (SSH), 80 e 443"

# ------------------------------------------------------------------ 7. backup diário
passo "Backup diário"
mkdir -p /opt/backups
cat > /etc/cron.daily/backup-lojas <<EOF
#!/bin/sh
D=\$(date +%F)
sqlite3 "$APP_DIR/data/saas.db" ".backup '/opt/backups/saas-\$D.db'"
tar -czf "/opt/backups/arquivos-\$D.tgz" -C "$APP_DIR" data/uploads data/comprovantes .env 2>/dev/null
find /opt/backups -type f -mtime +14 -delete
EOF
chmod +x /etc/cron.daily/backup-lojas
ok "Cópia diária em /opt/backups (guarda 14 dias)"

# ------------------------------------------------------------------ fim
echo -e "\n\033[1;32mTudo pronto!\033[0m"
echo "  Painel:  https://$DOMINIO"
echo "  Lojas:   https://NOMEDALOJA.$DOMINIO"
echo "  Login:   $(get_env ADMIN_EMAIL) (senha que você digitou)"
echo
echo "  Confira no Cloudflare: DNS com registros A para @ e * apontando para este servidor"
echo "  (nuvem laranja ligada) e SSL/TLS no modo Full (strict)."
