#!/usr/bin/env bash
# ==============================================================================
# Multi-Transport Stealth Network Node & Telegram Bot - Automated Installer
# Target OS: Ubuntu 22.04/24.04, Debian 12 (x86_64)
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} "; }
ok()    { echo -e "${GREEN}[OK]${NC} "; }
warn()  { echo -e "${YELLOW}[WARN]${NC} "; }
error() { echo -e "${RED}[ERROR]${NC} "; exit 1; }

# 1. Root & OS Check
if [ "$EUID" -ne 0 ]; then
    error "Please run this script as root (use: sudo -i)"
fi

if ! grep -q -E "noble|jammy|bookworm|trixie" /etc/os-release; then
    warn "This script is optimized for Ubuntu 22.04/24.04 and Debian 12."
fi

echo -e "${CYAN}${BOLD}"
echo "╔═════════════════════════════════════════════════════════════════════╗"
echo "║        Multi-Transport Stealth Network Node Installer               ║"
echo "╚═════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 2. Configuration & Inputs
if [ -f "$SCRIPT_DIR/.env" ]; then
    info "Loading settings from .env file..."
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

prompt_var() {
    local var_name="$1"
    local prompt_text="$2"
    local default_val="${3:-}"
    local current_val="${!var_name:-}"

    # Strict validation of variable identifier name
    if [[ ! "$var_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        error "Invalid variable name: $var_name"
        return 1
    fi

    if [ -z "$current_val" ]; then
        if [ -n "$default_val" ]; then
            read -r -p "$prompt_text [$default_val]: " input
            printf -v "$var_name" '%s' "${input:-$default_val}"
        else
            while [ -z "${!var_name:-}" ]; do
                read -r -p "$prompt_text: " input
                printf -v "$var_name" '%s' "$input"
            done
        fi
    fi
}

prompt_var MAIN_DOMAIN "Enter your Main Domain (e.g., node.domain.com or domain.duckdns.org)"
prompt_var ACME_EMAIL "Enter your Email for Let's Encrypt certificates" "admin@$MAIN_DOMAIN"
prompt_var TELEGRAM_BOT_TOKEN "Enter your Telegram Bot Token from @BotFather"
prompt_var TELEGRAM_ADMIN_IDS "Enter your Telegram User ID (numeric, from @userinfobot)"

# Auto-generate secure random paths if not supplied
SUBS_PATH="${SUBS_PATH:-$(openssl rand -hex 16)}"
VLESS_PATH="${VLESS_PATH:-$(openssl rand -hex 16)}"
TROJAN_PATH="${TROJAN_PATH:-$(openssl rand -hex 16)}"
RULESET_PATH="${RULESET_PATH:-$(openssl rand -hex 16)}"
FIRST_USER_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)"
FIRST_USER_PASS="$(openssl rand -hex 8)"
FIRST_USER_NAME="user_admin"

info "Detected Configuration:"
echo "  • Main Domain: $MAIN_DOMAIN"
echo "  • Email: $ACME_EMAIL"
echo "  • Telegram Bot: Configured"
echo "  • Admin ID: $TELEGRAM_ADMIN_IDS"
echo ""

# 3. Swap Setup
info "Setting up Swap..."
if [ -f "$SCRIPT_DIR/scripts/setup-swap.sh" ]; then
    bash "$SCRIPT_DIR/scripts/setup-swap.sh" 2
fi

# 4. System Packages
info "Updating repositories and installing base packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget jq git certbot ufw fail2ban python3-systemd unattended-upgrades openssl sed python3-venv python3-pip unzip

# 5. Disable IPv6 & Enable BBR
info "Disabling IPv6 by default to prevent DNS/IP leaks and dual-stack issues..."
cat << 'EOF' > /etc/sysctl.d/99-disable-ipv6.conf
# Disable IPv6 system-wide (Prevents IP/DNS leaks, dual-stack routing & Let's Encrypt AAAA mismatch)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1 || true

if [ -f /etc/default/ufw ]; then
    sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw 2>/dev/null || true
fi

info "Enabling TCP BBR..."
if ! grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf /etc/sysctl.d/* 2>/dev/null; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.d/99-bbr.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-bbr.conf
    sysctl --system >/dev/null 2>&1 || true
fi

# 6. Issue SSL Certificates
info "Issuing SSL certificates with Let's Encrypt..."
mkdir -p /etc/nginx
systemctl stop nginx >/dev/null 2>&1 || true

certbot certonly --standalone --preferred-challenges http --agree-tos \
    --email "$ACME_EMAIL" -d "$MAIN_DOMAIN" \
    --no-eff-email --non-interactive --keep-until-expiring

# Configure zero-downtime renewal via webroot and automatic Nginx reload hook
mkdir -p /var/www/site/.well-known/acme-challenge
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat << 'EOF' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
#!/bin/bash
systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

RENEWAL_CONF="/etc/letsencrypt/renewal/${MAIN_DOMAIN}.conf"
if [ -f "$RENEWAL_CONF" ]; then
    sed -i 's/^authenticator = standalone/authenticator = webroot/' "$RENEWAL_CONF"
    if ! grep -q "webroot_path" "$RENEWAL_CONF"; then
        sed -i "/\[renewalparams\]/a webroot_path = /var/www/site," "$RENEWAL_CONF"
        cat << EOF >> "$RENEWAL_CONF"
[[webroot_map]]
${MAIN_DOMAIN} = /var/www/site
EOF
    fi
fi

ok "SSL certificates obtained successfully."

# Diffie-Hellman parameters
if [ ! -f /etc/nginx/dhparam.pem ]; then
    info "Generating 2048-bit DH parameters (this may take 20s)..."
    openssl dhparam -out /etc/nginx/dhparam.pem 2048
fi

# 7. Install Sing-Box & Nginx Official Packages
info "Installing Sing-Box and Nginx official packages..."
os_codename=$(grep "VERSION_CODENAME=" /etc/os-release | cut -d "=" -f 2)
os_id=$(grep -E "^ID=" /etc/os-release | cut -d "=" -f 2 | tr -d '"')

# Sing-Box repo
mkdir -p /etc/apt/keyrings
curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc && chmod a+r /etc/apt/keyrings/sagernet.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/sagernet.asc] https://deb.sagernet.org/ * *" | tee /etc/apt/sources.list.d/sagernet.list > /dev/null

# Nginx repo
curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /etc/apt/keyrings/nginx-archive-keyring.gpg 2>/dev/null || true
echo "deb [signed-by=/etc/apt/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/${os_id} ${os_codename} nginx" | tee /etc/apt/sources.list.d/nginx.list > /dev/null

apt-get update -y
apt-get install -y sing-box nginx

# 8. Setup Decoy Site, Rulesets & Directories
WWW_DIR="/var/www/$SUBS_PATH"
RULESET_DIR="/var/www/$RULESET_PATH"
mkdir -p "$WWW_DIR" "$RULESET_DIR" /var/www/site /opt/incy-bot

info "Deploying decoy stealth portfolio website..."
if [ -d "$SCRIPT_DIR/site" ]; then
    cp -r "$SCRIPT_DIR/site/"* /var/www/site/
    sed -i "s|{{MAIN_DOMAIN}}|$MAIN_DOMAIN|g" /var/www/site/*.html /var/www/site/*.xml /var/www/site/robots.txt /var/www/site/.well-known/* 2>/dev/null || true
fi
chown -R www-data:www-data /var/www/site

info "Downloading and validating routing rulesets..."
if [ -f "$SCRIPT_DIR/scripts/download-rulesets.sh" ]; then
    bash "$SCRIPT_DIR/scripts/download-rulesets.sh" "$RULESET_DIR"
else
    error "FATAL: scripts/download-rulesets.sh not found! Aborting."
fi

# 9. Configure Sing-Box
info "Deploying Sing-Box configuration..."
SERVER_IP=$(curl -s4 https://api.ipify.org || curl -s4 https://ifconfig.me || echo "127.0.0.1")
HY2_PORT=443
HY2_OBFS_PASSWORD="sal_$(openssl rand -hex 8)"

sed -e "s|{{MAIN_DOMAIN}}|$MAIN_DOMAIN|g" \
    -e "s|{{DOMAIN}}|$MAIN_DOMAIN|g" \
    -e "s|{{SUBS_PATH}}|$SUBS_PATH|g" \
    -e "s|{{RULESET_PATH}}|$RULESET_PATH|g" \
    -e "s|{{TROJAN_PATH}}|$TROJAN_PATH|g" \
    -e "s|{{VLESS_PATH}}|$VLESS_PATH|g" \
    -e "s|{{HY2_PORT}}|$HY2_PORT|g" \
    -e "s|{{HY2_OBFS_PASSWORD}}|$HY2_OBFS_PASSWORD|g" \
    "$SCRIPT_DIR/config/sing-box/config.json.template" > /etc/sing-box/config.json

# Inject initial user
jq ".inbounds[] |= if .tag == \"vless-in\" then .users = [{\"name\": \"$FIRST_USER_NAME\", \"uuid\": \"$FIRST_USER_UUID\"}] elif .tag == \"trojan-in\" then .users = [{\"name\": \"$FIRST_USER_NAME\", \"password\": \"$FIRST_USER_PASS\"}] elif .tag == \"hy2-in\" then .users = [{\"name\": \"$FIRST_USER_NAME\", \"password\": \"$FIRST_USER_PASS\"}] else . end" /etc/sing-box/config.json > /tmp/sb_cfg.json
mv /tmp/sb_cfg.json /etc/sing-box/config.json

# Verify presence of all mandatory rulesets before starting Sing-Box
for req_rs in geoip-ru.srs geosite-category-gov-ru.srs geosite-category-ads-all.srs geosite-openai.srs geosite-anthropic.srs geosite-xai.srs; do
    if [ ! -f "$RULESET_DIR/$req_rs" ]; then
        error "FATAL: Mandatory ruleset '$RULESET_DIR/$req_rs' is missing! Sing-Box cannot start. Aborting."
    fi
done

# Perform pre-flight configuration validation
if command -v sing-box >/dev/null 2>&1; then
    info "Verifying Sing-Box configuration validity..."
    if ! sing-box check -c /etc/sing-box/config.json; then
        error "FATAL: Sing-Box pre-flight check failed! Aborting."
    fi
fi

systemctl daemon-reload
systemctl enable --now sing-box
systemctl restart sing-box

# 10. Configure Nginx
info "Deploying Nginx configuration..."
sed -e "s|{{DOMAIN}}|$MAIN_DOMAIN|g" \
    -e "s|{{SUBS_PATH}}|$SUBS_PATH|g" \
    -e "s|{{RULESET_PATH}}|$RULESET_PATH|g" \
    -e "s|{{TROJAN_PATH}}|$TROJAN_PATH|g" \
    -e "s|{{VLESS_PATH}}|$VLESS_PATH|g" \
    "$SCRIPT_DIR/config/nginx/nginx.conf.template" > /etc/nginx/nginx.conf

nginx -t
systemctl enable --now nginx
systemctl restart nginx

# 11. Setup Xray-Core (VLESS REALITY Vision & XHTTP)
info "Setting up Xray-Core for high-speed REALITY & streaming XHTTP..."
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) XRAY_ARCH="64" ;;
    aarch64|arm64) XRAY_ARCH="arm64-v8a" ;;
    *) XRAY_ARCH="64" ;;
esac

if [ ! -x /usr/local/bin/xray ]; then
    info "Installing Xray binary..."
    XRAY_TMP=$(mktemp -d)
    curl -sSL "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip" -o "$XRAY_TMP/xray.zip" || \
    curl -sSL "https://github.com/XTLS/Xray-core/releases/download/v24.11.30/Xray-linux-${XRAY_ARCH}.zip" -o "$XRAY_TMP/xray.zip"
    unzip -q -o "$XRAY_TMP/xray.zip" xray -d /usr/local/bin/
    chmod 755 /usr/local/bin/xray
    rm -rf "$XRAY_TMP"
    ok "Xray-core binary installed."
fi

# Generate REALITY keys
KEYS=$(/usr/local/bin/xray x25519 2>/dev/null || true)
REALITY_PRIVATE_KEY=$(echo "$KEYS" | awk '/Private/ {print $NF}' || echo "")
REALITY_PUBLIC_KEY=$(echo "$KEYS" | awk '/Public/ {print $NF}' || echo "")
REALITY_SHORT_ID=$(openssl rand -hex 8)
REALITY_PORT=8443
XHTTP_PORT=8444
REALITY_DEST="127.0.0.1:443"
REALITY_SNI="$MAIN_DOMAIN"
XHTTP_PATH="xhttp"

mkdir -p /etc/xray
sed -e "s|{{REALITY_PORT}}|$REALITY_PORT|g" \
    -e "s|{{XHTTP_PORT}}|$XHTTP_PORT|g" \
    -e "s|{{DOMAIN}}|$MAIN_DOMAIN|g" \
    -e "s|{{REALITY_DEST}}|$REALITY_DEST|g" \
    -e "s|{{REALITY_SNI}}|$REALITY_SNI|g" \
    -e "s|{{XHTTP_PATH}}|$XHTTP_PATH|g" \
    -e "s|{{REALITY_PRIVATE_KEY}}|$REALITY_PRIVATE_KEY|g" \
    -e "s|{{REALITY_SHORT_ID}}|$REALITY_SHORT_ID|g" \
    "$SCRIPT_DIR/config/xray/config.json.template" > /etc/xray/config.json

# Add initial user to Xray config
python3 -c "
import json
try:
    with open('/etc/xray/config.json', 'r') as f:
        cfg = json.load(f)
    for ib in cfg.get('inbounds', []):
        if ib.get('tag') == 'vless-reality-vision-in':
            clients = ib.setdefault('settings', {}).setdefault('clients', [])
            clients.append({'id': '$FIRST_USER_UUID', 'flow': 'xtls-rprx-vision', 'email': '$FIRST_USER_NAME'})
        elif ib.get('tag') == 'vless-reality-xhttp-in':
            clients = ib.setdefault('settings', {}).setdefault('clients', [])
            clients.append({'id': '$FIRST_USER_UUID', 'email': '$FIRST_USER_NAME'})
    with open('/etc/xray/config.json', 'w') as f:
        json.dump(cfg, f, indent=2)
except Exception as e:
    print('Warning: could not add initial user to Xray:', e)
"

# Install Xray systemd service
cp "$SCRIPT_DIR/config/xray/xray.service" /etc/systemd/system/xray.service
systemctl daemon-reload
systemctl enable --now xray.service
systemctl restart xray.service

# 12. Setup Privileged Helper, Permissions & Telegram Bot
info "Setting up Telegram Bot and restricted privileges..."

# Create dedicated non-root system user for incy-bot if not present
if ! id -u incy-bot &>/dev/null; then
    info "Creating dedicated system user 'incy-bot'..."
    useradd -r -s /usr/sbin/nologin -d /opt/incy-bot -M incy-bot
fi

# Install root-owned privileged helper
info "Installing privileged control helper /usr/local/bin/singbox-control..."
cp "$SCRIPT_DIR/scripts/singbox-control.sh" /usr/local/bin/singbox-control
chown root:root /usr/local/bin/singbox-control
chmod 755 /usr/local/bin/singbox-control

# Configure restricted sudoers permissions with visudo validation
info "Configuring restricted sudoers permissions for incy-bot..."
mkdir -p /etc/sudoers.d
cp "$SCRIPT_DIR/config/sudoers/incy-bot.sudoers" /etc/sudoers.d/incy-bot
chmod 440 /etc/sudoers.d/incy-bot
if ! visudo -cf /etc/sudoers.d/incy-bot; then
    error "FATAL: Sudoers syntax validation failed for /etc/sudoers.d/incy-bot! Aborting."
fi

sed -e "s|{{DOMAIN}}|$MAIN_DOMAIN|g" \
    -e "s|{{SUBS_PATH}}|$SUBS_PATH|g" \
    -e "s|{{RULESET_PATH}}|$RULESET_PATH|g" \
    -e "s|{{SERVER_IP}}|$SERVER_IP|g" \
    -e "s|{{TROJAN_PATH}}|$TROJAN_PATH|g" \
    -e "s|{{VLESS_PATH}}|$VLESS_PATH|g" \
    -e "s|{{REALITY_SNI}}|$REALITY_SNI|g" \
    -e "s|{{REALITY_PUBLIC_KEY}}|$REALITY_PUBLIC_KEY|g" \
    -e "s|{{REALITY_SHORT_ID}}|$REALITY_SHORT_ID|g" \
    -e "s|8443|$REALITY_PORT|g" \
    "$SCRIPT_DIR/config/templates/template-vless.json" > /opt/incy-bot/template-vless.json

sed -e "s|{{DOMAIN}}|$MAIN_DOMAIN|g" \
    -e "s|{{SUBS_PATH}}|$SUBS_PATH|g" \
    -e "s|{{RULESET_PATH}}|$RULESET_PATH|g" \
    -e "s|{{SERVER_IP}}|$SERVER_IP|g" \
    -e "s|{{TROJAN_PATH}}|$TROJAN_PATH|g" \
    -e "s|{{VLESS_PATH}}|$VLESS_PATH|g" \
    "$SCRIPT_DIR/config/templates/template-trj.json" > /opt/incy-bot/template-trj.json

sed -e "s|{{DOMAIN}}|$MAIN_DOMAIN|g" \
    -e "s|{{HY2_PORT}}|$HY2_PORT|g" \
    -e "s|{{HY2_OBFS_PASSWORD}}|$HY2_OBFS_PASSWORD|g" \
    "$SCRIPT_DIR/config/templates/template-hy2.json" > /opt/incy-bot/template-hy2.json

# Bot files & Venv
cp "$SCRIPT_DIR/bot/bot.py" \
   "$SCRIPT_DIR/bot/auth.py" \
   "$SCRIPT_DIR/bot/config_manager.py" \
   "$SCRIPT_DIR/bot/subscription_manager.py" \
   "$SCRIPT_DIR/bot/requests_manager.py" \
   "$SCRIPT_DIR/bot/xray_manager.py" \
   "$SCRIPT_DIR/bot/stats_manager.py" \
   /opt/incy-bot/
python3 -m venv /opt/incy-bot/venv
/opt/incy-bot/venv/bin/pip install --upgrade pip >/dev/null
/opt/incy-bot/venv/bin/pip install -r "$SCRIPT_DIR/bot/requirements.txt" >/dev/null

printf "TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ADMIN_IDS=%s\nMAIN_DOMAIN=%s\nSUBS_PATH=%s\nVLESS_PATH=%s\nTROJAN_PATH=%s\nREALITY_PORT=%s\nXHTTP_PORT=%s\nHY2_PORT=%s\nHY2_OBFS_PASSWORD=%s\nREALITY_DEST=%s\nREALITY_SNI=%s\nXHTTP_PATH=%s\nREALITY_PRIVATE_KEY=%s\nREALITY_PUBLIC_KEY=%s\nREALITY_SHORT_ID=%s\n" \
    "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_ADMIN_IDS" "$MAIN_DOMAIN" "$SUBS_PATH" "$VLESS_PATH" "$TROJAN_PATH" \
    "$REALITY_PORT" "$XHTTP_PORT" "$HY2_PORT" "$HY2_OBFS_PASSWORD" "$REALITY_DEST" "$REALITY_SNI" "$XHTTP_PATH" "$REALITY_PRIVATE_KEY" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID" > /opt/incy-bot/.env

# Permissions: incy-bot ownership and restricted read for .env
chown -R incy-bot:incy-bot /opt/incy-bot
chown root:incy-bot /opt/incy-bot/.env
chmod 640 /opt/incy-bot/.env

# Subscriptions dir ownership
chown -R incy-bot:www-data "$WWW_DIR"
chmod 770 "$WWW_DIR"

# Sing-box & Xray directory & config permissions for transactional atomic updates by incy-bot
mkdir -p /etc/sing-box /etc/xray
chown root:incy-bot /etc/sing-box /etc/xray
chmod 775 /etc/sing-box /etc/xray
chown sing-box:incy-bot /etc/sing-box/config.json 2>/dev/null || chown root:incy-bot /etc/sing-box/config.json 2>/dev/null || true
chmod 660 /etc/sing-box/config.json 2>/dev/null || true
chown root:incy-bot /etc/xray/config.json 2>/dev/null || true
chmod 660 /etc/xray/config.json 2>/dev/null || true

# Generate initial user cryptographically secure subscription token & files
FIRST_USER_TOKEN=$(openssl rand -hex 16)
VLESS_REALITY_LINK="vless://${FIRST_USER_UUID}@${MAIN_DOMAIN}:${REALITY_PORT}?security=reality&encryption=none&pbk=${REALITY_PUBLIC_KEY}&headerType=none&fp=chrome&spx=%2F&type=tcp&flow=xtls-rprx-vision&sni=${REALITY_SNI}&sid=${REALITY_SHORT_ID}#⚡ [XTLS] VLESS-Reality-Vision"
VLESS_XHTTP_LINK="vless://${FIRST_USER_UUID}@${MAIN_DOMAIN}:${XHTTP_PORT}?security=reality&encryption=none&pbk=${REALITY_PUBLIC_KEY}&headerType=none&fp=chrome&type=xhttp&path=%2F${XHTTP_PATH}&sni=${REALITY_SNI}&sid=${REALITY_SHORT_ID}#🛡️ [XHTTP] VLESS-Reality"
HY2_LINK="hysteria2://${FIRST_USER_PASS}@${MAIN_DOMAIN}:${HY2_PORT}/?sni=${MAIN_DOMAIN}&obfs=salamander&obfs-password=${HY2_OBFS_PASSWORD}#🚀 [Hy2] Hysteria 2 - Salamander"
VLESS_WS_LINK="vless://${FIRST_USER_UUID}@${MAIN_DOMAIN}:443?security=tls&encryption=none&type=ws&path=%2F${VLESS_PATH}#🌐 [WS] VLESS (over TLS)"
TROJAN_WS_LINK="trojan://${FIRST_USER_PASS}@${MAIN_DOMAIN}:443?security=tls&type=ws&path=%2F${TROJAN_PATH}#🔒 [WS] Trojan (over TLS)"

echo -e "${VLESS_REALITY_LINK}\n${VLESS_XHTTP_LINK}\n${HY2_LINK}\n${VLESS_WS_LINK}\n${TROJAN_WS_LINK}\n" | base64 | tr -d '\n' > "$WWW_DIR/${FIRST_USER_TOKEN}.txt"
chmod 644 "$WWW_DIR/${FIRST_USER_TOKEN}.txt"

sed -e "s|{{DOMAIN}}|$MAIN_DOMAIN|g" \
    -e "s|{{HY2_PORT}}|$HY2_PORT|g" \
    -e "s|{{USER_NAME}}|$FIRST_USER_NAME|g" \
    -e "s|{{USER_PASS}}|$FIRST_USER_PASS|g" \
    -e "s|\${hy2pass}|$FIRST_USER_PASS|g" \
    -e "s|\${trjpass}|$FIRST_USER_PASS|g" \
    -e "s|{{HY2_OBFS_PASSWORD}}|$HY2_OBFS_PASSWORD|g" \
    "$SCRIPT_DIR/config/templates/template-hy2.json" > "$WWW_DIR/${FIRST_USER_TOKEN}-hy2.json"
chmod 644 "$WWW_DIR/${FIRST_USER_TOKEN}-hy2.json"
chown -R incy-bot:www-data "$WWW_DIR"
chmod 770 "$WWW_DIR"

cat <<EOF > /opt/incy-bot/subscriptions.json
{
  "${FIRST_USER_NAME}": {
    "token": "${FIRST_USER_TOKEN}",
    "vless_uuid": "${FIRST_USER_UUID}",
    "trojan_pass": "${FIRST_USER_PASS}",
    "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }
}
EOF
chown incy-bot:incy-bot /opt/incy-bot/subscriptions.json
chmod 600 /opt/incy-bot/subscriptions.json

# Systemd service deployment & verification (after initial registry creation)
cp "$SCRIPT_DIR/bot/incy-bot.service" /etc/systemd/system/incy-bot.service
if command -v systemd-analyze >/dev/null 2>&1; then
    info "Verifying systemd unit security configuration..."
    systemd-analyze verify /etc/systemd/system/incy-bot.service 2>&1 || true
fi

systemctl daemon-reload
systemctl enable --now incy-bot.service
systemctl restart incy-bot.service

# 13. Multi-Layer Security Hardening & Automated Backups
info "Applying multi-layer security hardening (Firewall, Fail2ban, SSH, Kernel)..."
if [ -f "$SCRIPT_DIR/scripts/setup-security.sh" ]; then
    bash "$SCRIPT_DIR/scripts/setup-security.sh"
elif [ -f "$SCRIPT_DIR/scripts/setup-firewall.sh" ]; then
    bash "$SCRIPT_DIR/scripts/setup-firewall.sh" >/dev/null 2>&1
fi

info "Configuring automated daily backup..."
if [ -f "$SCRIPT_DIR/scripts/backup.sh" ]; then
    cp "$SCRIPT_DIR/scripts/backup.sh" /usr/local/bin/backup-vps
    chown root:root /usr/local/bin/backup-vps
    chmod 700 /usr/local/bin/backup-vps
    (crontab -l 2>/dev/null | grep -v 'backup-vps' || true; echo "0 3 * * * /usr/local/bin/backup-vps >/dev/null 2>&1") | crontab -
fi

# 14. Output Final Summary
sleep 2

echo ""
echo -e "${GREEN}${BOLD}═════════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}        🚀 Установка успешно завершена! Всё настроено и работает!   ${NC}"
echo -e "${GREEN}${BOLD}═════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "📱 ${BOLD}Telegram-бот управления:${NC}"
echo "   Откройте вашего бота в Telegram и отправьте /start"
echo ""
echo -e "📦 ${BOLD}Ключи для клиентов (Incy / Happ / V2Ray / Shadowrocket / NekoBox):${NC}"
echo "   • Пользователь:       ${FIRST_USER_NAME}"
echo "   • Универсал.подписка: https://${MAIN_DOMAIN}/${SUBS_PATH}/${FIRST_USER_TOKEN}.txt"
echo "   • Основной REALITY:   ${VLESS_REALITY_LINK}"
echo "   • Резервный XHTTP:    ${VLESS_XHTTP_LINK}"
echo "   • Скоростной Hy2:     ${HY2_LINK}"
echo ""
echo -e "🔒 ${BOLD}Статус безопасности (Многоуровневая защита):${NC}"
echo "   • SSL Сертификаты: Автоматическое продление через Certbot (Webroot, 0ms downtime)"
echo "   • Стелс-режим Nginx: Сброс соединений по IP без ответа (HTTP 444, Anti-Scanner)"
echo "   • Защита от брутфорса: Fail2ban + UFW (блокировка на 24ч при 5 попытках)"
echo "   • SSH Защита: Вход по паролю ОТКЛЮЧЕН (только ed25519/RSA ключи)"
echo "   • Ядро Linux: SYN cookies, защита от IP-спуфинга, TCP BBR"
echo "   • Фаервол: UFW активен (порты 22, 80, 443, 8443, 8444; все сервисы на 127.0.0.1)"
echo "   • Автообновления: unattended-upgrades для патчей безопасности"
echo "   • Резервное копирование: Автоматический снапшот конфигураций ежедневно в 03:00"
echo ""
