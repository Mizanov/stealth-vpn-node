#!/usr/bin/env bash
# ==============================================================================
# Incy-Bot & Sing-Box Automated Server Upgrade Script
# Safely upgrades production VPS to the latest hardened architecture:
# - Pre-flight backup creation & verification
# - Dedicated non-root user 'incy-bot' & privileged helper setup
# - Sudoers configuration with visudo syntax validation
# - Binary SRS ruleset download & magic bytes validation
# - Client templates and Sing-box permission configuration
# - Bot code update, venv sync, and systemd sandboxed service restart
# - Nginx privacy & timeout updates with 'nginx -t' pre-flight
# - Pinned Docker container update for Telegram Web Proxy
# - Automatic subscription migration for existing users
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

if [ "$EUID" -ne 0 ]; then
    error "This upgrade script must be run as root."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="/opt/incy-bot/.env"

echo ""
echo -e "${CYAN}${BOLD}═════════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}   🚀 Запуск обновления VPS: stealth-network-node (Hardened)         ${NC}"
echo -e "${CYAN}${BOLD}═════════════════════════════════════════════════════════════════════${NC}"
echo ""

# 1. Pre-flight Checks & Environment Loading
if [ ! -f "$ENV_FILE" ]; then
    error "Файл конфигурации $ENV_FILE не найден! Убедитесь, что система была ранее установлена."
    exit 1
fi

info "Считывание текущей конфигурации из $ENV_FILE..."
# shellcheck disable=SC1090
source "$ENV_FILE"

MAIN_DOMAIN="${MAIN_DOMAIN:-}"
SUBS_PATH="${SUBS_PATH:-}"
VLESS_PATH="${VLESS_PATH:-}"
TROJAN_PATH="${TROJAN_PATH:-}"
RULESET_PATH="${RULESET_PATH:-}"

if [ -z "$MAIN_DOMAIN" ] || [ -z "$SUBS_PATH" ]; then
    error "Не удалось прочитать MAIN_DOMAIN или SUBS_PATH из $ENV_FILE."
    exit 1
fi

# Detect ruleset path if missing from .env
if [ -z "$RULESET_PATH" ]; then
    RULESET_PATH=$(grep -B 1 -E 'alias /var/www/' /etc/nginx/nginx.conf 2>/dev/null | grep 'location' | cut -d'/' -f2 || echo "")
    if [ -n "$RULESET_PATH" ]; then
        echo "RULESET_PATH=$RULESET_PATH" >> "$ENV_FILE"
    else
        RULESET_PATH="ruleset"
    fi
fi

WWW_DIR="/var/www/$SUBS_PATH"
RULESET_DIR="/var/www/$RULESET_PATH"

ok "Конфигурация подтверждена: Домен $MAIN_DOMAIN, подписки /$SUBS_PATH"

# 2. Automated Pre-Upgrade Snapshot Backup
info "Создание резервной копии перед обновлением..."
if [ -f "$SCRIPT_DIR/scripts/backup.sh" ]; then
    bash "$SCRIPT_DIR/scripts/backup.sh"
    ok "Резервная копия создана и верифицирована."
else
    warn "Скрипт scripts/backup.sh не найден, выполняется базовое архивирование..."
    mkdir -p /root/backups
    tar -czf "/root/backups/pre_upgrade_$(date +%s).tar.gz" /etc/sing-box /opt/incy-bot /etc/nginx/nginx.conf 2>/dev/null || true
fi

# 3. Create Dedicated Non-Root System User 'incy-bot'
if ! id -u incy-bot &>/dev/null; then
    info "Создание системного пользователя 'incy-bot'..."
    useradd -r -s /usr/sbin/nologin -d /opt/incy-bot -M incy-bot
    ok "Пользователь 'incy-bot' создан."
fi

# 4. Install Privileged Root Control Helper
info "Установка привилегированного хелпера /usr/local/bin/singbox-control..."
cp "$SCRIPT_DIR/scripts/singbox-control.sh" /usr/local/bin/singbox-control
chown root:root /usr/local/bin/singbox-control
chmod 755 /usr/local/bin/singbox-control
ok "Хелпер /usr/local/bin/singbox-control установлен."

# 5. Install & Validate Sudoers Rules
info "Обновление правил sudoers (/etc/sudoers.d/incy-bot)..."
cp "$SCRIPT_DIR/config/sudoers/incy-bot.sudoers" /etc/sudoers.d/incy-bot
chmod 440 /etc/sudoers.d/incy-bot
if command -v visudo >/dev/null 2>&1; then
    if ! visudo -cf /etc/sudoers.d/incy-bot >/dev/null; then
        error "Синтаксическая ошибка в sudoers! Откат изменений."
        rm -f /etc/sudoers.d/incy-bot
        exit 1
    fi
fi
ok "Правила sudoers валидированы и применены."

# 6. Update Sing-Box & Subscriptions Permissions
info "Настройка прав доступа к файлам Sing-Box и директории подписок..."
mkdir -p /etc/sing-box "$WWW_DIR" "$RULESET_DIR"
chown root:incy-bot /etc/sing-box
chmod 775 /etc/sing-box
chown sing-box:incy-bot /etc/sing-box/config.json 2>/dev/null || chown root:incy-bot /etc/sing-box/config.json 2>/dev/null || true
chmod 660 /etc/sing-box/config.json 2>/dev/null || true

chown -R incy-bot:www-data "$WWW_DIR"
chmod 770 "$WWW_DIR"
ok "Права на конфигурацию и директорию подписок настроены."

# 7. Update Binary SRS Rulesets
info "Загрузка и валидация бинарных правил маршрутизации Sing-Box (.srs)..."
if [ -f "$SCRIPT_DIR/scripts/download-rulesets.sh" ]; then
    bash "$SCRIPT_DIR/scripts/download-rulesets.sh" "$RULESET_DIR"
    chown -R www-data:www-data "$RULESET_DIR"
    chmod -R 755 "$RULESET_DIR"
    ok "Бинарные правила SRS успешно обновлены и проверены."
fi

# 7.5 Setup & Upgrade Xray-Core (VLESS REALITY & XHTTP Dual-Transport)
info "Настройка Xray-Core для высокоскоростного REALITY и потокового XHTTP..."
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) XRAY_ARCH="64" ;;
    aarch64|arm64) XRAY_ARCH="arm64-v8a" ;;
    *) XRAY_ARCH="64" ;;
esac

if [ ! -x /usr/local/bin/xray ]; then
    info "Установка бинарного файла Xray-core..."
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y unzip curl >/dev/null 2>&1 || true
    XRAY_TMP=$(mktemp -d)
    curl -sSL "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip" -o "$XRAY_TMP/xray.zip" || \
    curl -sSL "https://github.com/XTLS/Xray-core/releases/download/v24.11.30/Xray-linux-${XRAY_ARCH}.zip" -o "$XRAY_TMP/xray.zip"
    unzip -q -o "$XRAY_TMP/xray.zip" xray -d /usr/local/bin/
    chmod 755 /usr/local/bin/xray
    rm -rf "$XRAY_TMP"
    ok "Xray-core установлен в /usr/local/bin/xray."
fi

# Generate or load REALITY keys
if [ -z "${REALITY_PUBLIC_KEY:-}" ] || [ -z "${REALITY_PRIVATE_KEY:-}" ]; then
    info "Генерация ключей Xray REALITY (x25519)..."
    KEYS=$(/usr/local/bin/xray x25519 2>/dev/null || true)
    REALITY_PRIVATE_KEY=$(echo "$KEYS" | awk '/Private/ {print $NF}' || echo "")
    REALITY_PUBLIC_KEY=$(echo "$KEYS" | awk '/Public/ {print $NF}' || echo "")
    REALITY_SHORT_ID=$(openssl rand -hex 8)
    REALITY_PORT="${REALITY_PORT:-8443}"
    XHTTP_PORT="${XHTTP_PORT:-8444}"
    HY2_PORT="${HY2_PORT:-443}"
    HY2_OBFS_PASSWORD="${HY2_OBFS_PASSWORD:-sal_sec_84729472}"
    REALITY_DEST="${REALITY_DEST:-127.0.0.1:443}"
    REALITY_SNI="${REALITY_SNI:-$MAIN_DOMAIN}"
    XHTTP_PATH="${XHTTP_PATH:-xhttp}"

    {
        echo "REALITY_PORT=$REALITY_PORT"
        echo "XHTTP_PORT=$XHTTP_PORT"
        echo "HY2_PORT=$HY2_PORT"
        echo "HY2_OBFS_PASSWORD=$HY2_OBFS_PASSWORD"
        echo "REALITY_DEST=$REALITY_DEST"
        echo "REALITY_SNI=$REALITY_SNI"
        echo "XHTTP_PATH=$XHTTP_PATH"
        echo "REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY"
        echo "REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY"
        echo "REALITY_SHORT_ID=$REALITY_SHORT_ID"
    } >> "$ENV_FILE"
    ok "Ключи REALITY сгенерированы и сохранены в $ENV_FILE."
fi

# Ensure HY2_PORT and HY2_OBFS_PASSWORD are present in .env
if ! grep -q "^HY2_PORT=" "$ENV_FILE"; then
    echo "HY2_PORT=${HY2_PORT:-443}" >> "$ENV_FILE"
fi
if ! grep -q "^HY2_OBFS_PASSWORD=" "$ENV_FILE"; then
    echo "HY2_OBFS_PASSWORD=${HY2_OBFS_PASSWORD:-sal_sec_84729472}" >> "$ENV_FILE"
fi
# Clean up obsolete MASQUE_PORT from .env
sed -i.bak '/^MASQUE_PORT=/d' "$ENV_FILE" 2>/dev/null || true
rm -f "$ENV_FILE.bak"

HY2_PORT="${HY2_PORT:-443}"
HY2_OBFS_PASSWORD="${HY2_OBFS_PASSWORD:-sal_sec_84729472}"

# Ensure Sing-Box has Hysteria 2 inbound configured
if [ -f /etc/sing-box/config.json ]; then
    python3 -c "
import os, sys, json
sys.path.insert(0, '$SCRIPT_DIR/bot')
from config_manager import ensure_singbox_hy2_config

try:
    with open('/etc/sing-box/config.json', 'r') as f:
        sb = json.load(f)
    sb = ensure_singbox_hy2_config(
        sb,
        domain='$MAIN_DOMAIN',
        hy2_port=${HY2_PORT:-443},
        hy2_obfs_password='${HY2_OBFS_PASSWORD:-sal_sec_84729472}'
    )
    with open('/etc/sing-box/config.json', 'w') as f:
        json.dump(sb, f, indent=2)
except Exception as e:
    print('Sing-box Hy2 config update warning:', e)
" || true
fi

mkdir -p /etc/xray
if [ ! -f /etc/xray/config.json ]; then
    info "Генерация базового файла конфигурации /etc/xray/config.json..."
    sed -e "s|{{REALITY_PORT}}|${REALITY_PORT:-8443}|g" \
        -e "s|{{XHTTP_PORT}}|${XHTTP_PORT:-8444}|g" \
        -e "s|{{DOMAIN}}|$MAIN_DOMAIN|g" \
        -e "s|{{REALITY_DEST}}|${REALITY_DEST:-127.0.0.1:443}|g" \
        -e "s|{{REALITY_SNI}}|${REALITY_SNI:-$MAIN_DOMAIN}|g" \
        -e "s|{{XHTTP_PATH}}|${XHTTP_PATH:-xhttp}|g" \
        -e "s|{{REALITY_PRIVATE_KEY}}|$REALITY_PRIVATE_KEY|g" \
        -e "s|{{REALITY_SHORT_ID}}|$REALITY_SHORT_ID|g" \
        "$SCRIPT_DIR/config/xray/config.json.template" > /etc/xray/config.json
fi

# Synchronize existing Sing-Box users into Xray & ensure stats API configuration
if [ -f /etc/sing-box/config.json ] && [ -f /etc/xray/config.json ]; then
    python3 -c "
import os, sys, json
sys.path.insert(0, '$SCRIPT_DIR/bot')
from xray_manager import ensure_xray_stats_config, remove_xray_masque_config

try:
    with open('/etc/sing-box/config.json', 'r') as f:
        sb = json.load(f)
    with open('/etc/xray/config.json', 'r') as f:
        xr = json.load(f)

    # 1. Ensure Stats API & Policy configuration
    xr = ensure_xray_stats_config(xr)

    # 2. Remove legacy MASQUE Inbound configuration
    xr = remove_xray_masque_config(xr)

    # 3. Sync users
    vless_users = {}
    for ib in sb.get('inbounds', []):
        tag = ib.get('tag', '')
        if ib.get('type') == 'vless' or tag == 'vless-in':
            for u in ib.get('users', []):
                if u.get('name') and u.get('uuid'):
                    vless_users[u['name']] = u['uuid']

    for ib in xr.get('inbounds', []):
        tag = ib.get('tag', '')
        clients = ib.setdefault('settings', {}).setdefault('clients', [])
        for uname, uuid in vless_users.items():
            if not any(c.get('email') == uname or c.get('id') == uuid for c in clients):
                if tag == 'vless-reality-vision-in':
                    clients.append({'id': uuid, 'flow': 'xtls-rprx-vision', 'email': uname})
                elif tag == 'vless-reality-xhttp-in':
                    clients.append({'id': uuid, 'email': uname})

    with open('/etc/xray/config.json', 'w') as f:
        json.dump(xr, f, indent=2)
except Exception as e:
    print('Sync warning:', e)
" || true
fi

# Setup Xray permissions
chown -R root:incy-bot /etc/xray
chmod 775 /etc/xray
chmod 660 /etc/xray/config.json 2>/dev/null || true

# Install & restart Xray service
cp "$SCRIPT_DIR/config/xray/xray.service" /etc/systemd/system/xray.service
systemctl daemon-reload
systemctl enable xray.service >/dev/null 2>&1 || true
systemctl restart xray.service

# Configure UFW rules for REALITY and Hysteria 2 ports
if command -v ufw >/dev/null 2>&1; then
    ufw allow "${REALITY_PORT:-8443}/tcp" comment 'Xray REALITY Vision' >/dev/null 2>&1 || true
    ufw allow "${XHTTP_PORT:-8444}/tcp" comment 'Xray REALITY XHTTP' >/dev/null 2>&1 || true
    ufw delete allow 8445/tcp >/dev/null 2>&1 || true
    ufw delete allow 8445/udp >/dev/null 2>&1 || true
    ufw allow "${HY2_PORT:-443}/udp" comment 'Hysteria 2 UDP' >/dev/null 2>&1 || true
fi
ok "Служба Xray-Core настроена и запущена."

# 8. Update Client Templates
info "Обновление шаблонов профилей клиентов..."
SERVER_IP="${SERVER_IP:-$(curl -s4 --max-time 3 https://api.ipify.org || curl -s4 --max-time 3 https://ifconfig.me || getent hosts "$MAIN_DOMAIN" | awk '{print $1}' | head -n1 || echo "127.0.0.1")}"

sed -e "s|{{DOMAIN}}|$MAIN_DOMAIN|g" \
    -e "s|{{SUBS_PATH}}|$SUBS_PATH|g" \
    -e "s|{{RULESET_PATH}}|$RULESET_PATH|g" \
    -e "s|{{SERVER_IP}}|$SERVER_IP|g" \
    -e "s|{{VLESS_PATH}}|$VLESS_PATH|g" \
    -e "s|{{REALITY_SNI}}|${REALITY_SNI:-$MAIN_DOMAIN}|g" \
    -e "s|{{REALITY_PUBLIC_KEY}}|${REALITY_PUBLIC_KEY:-}|g" \
    -e "s|{{REALITY_SHORT_ID}}|${REALITY_SHORT_ID:-}|g" \
    -e "s|8443|${REALITY_PORT:-8443}|g" \
    "$SCRIPT_DIR/config/templates/template-vless.json" > /opt/incy-bot/template-vless.json

sed -e "s|{{DOMAIN}}|$MAIN_DOMAIN|g" \
    -e "s|{{SUBS_PATH}}|$SUBS_PATH|g" \
    -e "s|{{RULESET_PATH}}|$RULESET_PATH|g" \
    -e "s|{{SERVER_IP}}|$SERVER_IP|g" \
    -e "s|{{TROJAN_PATH}}|$TROJAN_PATH|g" \
    "$SCRIPT_DIR/config/templates/template-trj.json" > /opt/incy-bot/template-trj.json

sed -e "s|{{DOMAIN}}|$MAIN_DOMAIN|g" \
    -e "s|{{HY2_PORT}}|${HY2_PORT:-443}|g" \
    -e "s|{{HY2_OBFS_PASSWORD}}|${HY2_OBFS_PASSWORD:-sal_sec_84729472}|g" \
    "$SCRIPT_DIR/config/templates/template-hy2.json" > /opt/incy-bot/template-hy2.json
rm -f /opt/incy-bot/template-masque.json

chown incy-bot:incy-bot /opt/incy-bot/template-*.json
chmod 644 /opt/incy-bot/template-*.json
ok "Шаблоны клиентов обновлены с учётом OR-маршрутизации, REALITY и Hysteria 2."

# 9. Update Bot Code & Python Dependencies
info "Обновление кода Telegram-бота..."
cp "$SCRIPT_DIR/bot/bot.py" \
   "$SCRIPT_DIR/bot/auth.py" \
   "$SCRIPT_DIR/bot/config_manager.py" \
   "$SCRIPT_DIR/bot/subscription_manager.py" \
   "$SCRIPT_DIR/bot/requests_manager.py" \
   "$SCRIPT_DIR/bot/xray_manager.py" \
   "$SCRIPT_DIR/bot/stats_manager.py" \
   /opt/incy-bot/

if [ -f /opt/incy-bot/venv/bin/pip ]; then
    info "Проверка и установка зависимостей Python..."
    /opt/incy-bot/venv/bin/pip install --upgrade pip >/dev/null 2>&1 || true
    /opt/incy-bot/venv/bin/pip install -r "$SCRIPT_DIR/bot/requirements.txt" >/dev/null 2>&1 || true
fi

# Ensure subscriptions.json registry exists
if [ ! -f /opt/incy-bot/subscriptions.json ]; then
    echo "{}" > /opt/incy-bot/subscriptions.json
fi

chown -R incy-bot:incy-bot /opt/incy-bot
chown root:incy-bot /opt/incy-bot/.env
chmod 640 /opt/incy-bot/.env
chmod 600 /opt/incy-bot/subscriptions.json

# 10. Update Systemd Unit & Restart Bot
info "Обновление сервиса systemd incy-bot..."
cp "$SCRIPT_DIR/bot/incy-bot.service" /etc/systemd/system/incy-bot.service
systemctl daemon-reload
systemctl restart incy-bot.service
sleep 2

if ! systemctl is-active --quiet incy-bot.service; then
    error "Сервис incy-bot не запустился! Проверьте: journalctl -u incy-bot -n 30"
    exit 1
fi
ok "Сервис incy-bot успешно перезапущен с изоляцией прав."

# 11. Update Nginx Configuration
info "Проверка и обновление настроек Nginx..."
if [ -f "$SCRIPT_DIR/config/nginx/nginx.conf.template" ]; then
    sed -e "s|{{DOMAIN}}|$MAIN_DOMAIN|g" \
        -e "s|{{SUBS_PATH}}|$SUBS_PATH|g" \
        -e "s|{{RULESET_PATH}}|$RULESET_PATH|g" \
        -e "s|{{TROJAN_PATH}}|$TROJAN_PATH|g" \
        -e "s|{{VLESS_PATH}}|$VLESS_PATH|g" \
        "$SCRIPT_DIR/config/nginx/nginx.conf.template" > /etc/nginx/nginx.conf.new

    if nginx -t -c /etc/nginx/nginx.conf.new >/dev/null 2>&1; then
        mv /etc/nginx/nginx.conf.new /etc/nginx/nginx.conf
        systemctl reload nginx
        ok "Конфигурация Nginx обновлена (privacy_audit, persistent ws timeouts, so_keepalive)."
    else
        warn "Сгенерированный файл Nginx не прошёл проверку синтаксиса, рабочий конфиг оставлен без изменений."
        rm -f /etc/nginx/nginx.conf.new
    fi
fi

# 12. Decommission Legacy Telegram Web Proxy Container if present
if command -v docker >/dev/null 2>&1; then
    if docker ps -a --format '{{.Names}}' | grep -q "^tgweb-proxy$"; then
        info "Остановка и удаление устаревшего контейнера tgweb-proxy (выделен в stealth-proxy-cascade)..."
        docker stop tgweb-proxy >/dev/null 2>&1 || true
        docker rm tgweb-proxy >/dev/null 2>&1 || true
        docker volume rm tgweb-data >/dev/null 2>&1 || true
        ok "Устаревший tgweb-proxy удалён, ресурсы памяти и порт 8080 освобождены."
    fi
fi

# 13. Update Automated Backup Utility
info "Обновление утилиты резервного копирования /usr/local/bin/backup-vps..."
if [ -f "$SCRIPT_DIR/scripts/backup.sh" ]; then
    cp "$SCRIPT_DIR/scripts/backup.sh" /usr/local/bin/backup-vps
    chown root:root /usr/local/bin/backup-vps
    chmod 700 /usr/local/bin/backup-vps
    ok "Утилита /usr/local/bin/backup-vps обновлена (Path Traversal protection, verify, restore)."
fi

# 14. Verify Sing-Box Health
info "Проверка состояния ядра Sing-Box..."
if /usr/local/bin/singbox-control check /etc/sing-box/config.json >/dev/null 2>&1; then
    /usr/local/bin/singbox-control reload >/dev/null 2>&1 || true
    ok "Sing-Box проверен и активен."
else
    warn "Предупреждение: Проверьте конфигурацию Sing-Box: sing-box check -c /etc/sing-box/config.json"
fi

echo ""
echo -e "${GREEN}${BOLD}═════════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}    🎉 Обновление сервера успешно завершено!                         ${NC}"
echo -e "${GREEN}${BOLD}═════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Статус сервисов:"
echo "  • Telegram Bot (incy-bot): $(systemctl is-active incy-bot.service)"
echo "  • Sing-Box Core:           $(systemctl is-active sing-box.service)"
echo "  • Xray Core (REALITY):     $(systemctl is-active xray.service 2>/dev/null || echo 'inactive')"
echo "  • Nginx Web Server:        $(systemctl is-active nginx.service)"
echo ""
echo "Логи автоматической миграции пользователей:"
journalctl -u incy-bot -n 15 --no-pager | grep -iE '(migrat|token|start)' || true
echo ""
