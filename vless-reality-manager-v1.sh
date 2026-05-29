#!/usr/bin/env bash
# VLESS REALITY Manager v1
# Ubuntu/Debian, Xray-core, VLESS + REALITY, Telegram support

set -o pipefail

APP_NAME="VLESS REALITY Manager v1"
SCRIPT_VERSION="1.3.0"
GITHUB_VERSION_URL="https://raw.githubusercontent.com/Boogeyman-koding/vless-reality-manager/main/version.txt"
GITHUB_SCRIPT_URL="https://raw.githubusercontent.com/Boogeyman-koding/vless-reality-manager/main/vless-reality-manager-v1.sh"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_DIR="/usr/local/etc/xray"
MANAGER_CONFIG="/etc/vless-reality-manager.conf"
USERS_FILE="/usr/local/etc/xray/users.json"
KEYS_FILE="/usr/local/etc/xray/reality.keys"
BACKUP_ROOT="/root/vless-backups"
XRAY_ACCESS_LOG="/var/log/xray/access.log"
XRAY_ERROR_LOG="/var/log/xray/error.log"
NOTIFY_SCRIPT="/usr/local/bin/vless-reality-notify"
NOTIFY_SERVICE="/etc/systemd/system/vless-reality-notify.service"
NOTIFY_STATE_DIR="/var/lib/vless-reality-manager"

DEFAULT_PORT="443"
DEFAULT_SNI="github.com"
DEFAULT_DEST="github.com:443"
DEFAULT_FP="chrome"

green="\033[32m"
red="\033[31m"
yellow="\033[33m"
reset="\033[0m"

ok() { echo -e "${green}✓ $1${reset}"; }
warn() { echo -e "${yellow}! $1${reset}"; }
err() { echo -e "${red}✗ $1${reset}"; }

pause() {
    echo
    read -r -p "Нажмите Enter для продолжения..."
}

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        err "Запусти от root: sudo bash $0"
        exit 1
    fi
}

load_manager_config() {
    if [[ -f "$MANAGER_CONFIG" ]]; then
        # shellcheck disable=SC1090
        source "$MANAGER_CONFIG"
    fi

    SERVER_IP="${SERVER_IP:-}"
    XRAY_PORT="${XRAY_PORT:-$DEFAULT_PORT}"
    REALITY_SNI="${REALITY_SNI:-$DEFAULT_SNI}"
    REALITY_DEST="${REALITY_DEST:-$DEFAULT_DEST}"
    REALITY_FP="${REALITY_FP:-$DEFAULT_FP}"
    BOT_TOKEN="${BOT_TOKEN:-}"
    CHAT_ID="${CHAT_ID:-}"
    TELEGRAM_NOTIFY="${TELEGRAM_NOTIFY:-off}"
}

save_manager_config() {
    cat > "$MANAGER_CONFIG" <<EOF
SERVER_IP="${SERVER_IP:-}"
XRAY_PORT="${XRAY_PORT:-$DEFAULT_PORT}"
REALITY_SNI="${REALITY_SNI:-$DEFAULT_SNI}"
REALITY_DEST="${REALITY_DEST:-$DEFAULT_DEST}"
REALITY_FP="${REALITY_FP:-$DEFAULT_FP}"
BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"
TELEGRAM_NOTIFY="${TELEGRAM_NOTIFY:-off}"
EOF
    chmod 600 "$MANAGER_CONFIG"
}

sanitize_name() {
    echo "$1" | sed 's/[^0-9a-zA-Z._-]/_/g'
}

detect_ip() {
    local ip
    ip="$(curl -4 -s --max-time 5 icanhazip.com || true)"
    ip="$(echo "$ip" | tr -d '[:space:]')"

    if [[ -z "$ip" ]]; then
        ip="$(curl -4 -s --max-time 5 ifconfig.me || true)"
        ip="$(echo "$ip" | tr -d '[:space:]')"
    fi

    echo "$ip"
}

install_dependencies() {
    apt update
    apt install -y curl jq openssl ca-certificates qrencode cron
}

enable_bbr() {
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        ok "BBR уже включен."
        return 0
    fi

    grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true

    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        ok "BBR включен."
    else
        warn "BBR не включился. Скрипт продолжит установку."
    fi
}

install_xray_core() {
    bash -c "$(curl -4 -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

ensure_files() {
    mkdir -p "$XRAY_DIR"
    mkdir -p /var/log/xray "$NOTIFY_STATE_DIR"

    if [[ ! -f "$USERS_FILE" ]]; then
        echo "[]" > "$USERS_FILE"
        chmod 644 "$USERS_FILE"
    fi

    if [[ ! -f "$KEYS_FILE" ]]; then
        touch "$KEYS_FILE"
        chmod 644 "$KEYS_FILE"
    fi
}

generate_reality_keys() {
    local key_output private_key public_key short_id

    key_output="$(xray x25519)"
    private_key="$(echo "$key_output" | awk -F': ' '/Private key/ {print $2} /PrivateKey/ {print $2}' | head -n1)"
    public_key="$(echo "$key_output" | awk -F': ' '/Public key/ {print $2} /Password/ {print $2}' | head -n1)"
    short_id="$(openssl rand -hex 8)"

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        err "Не удалось сгенерировать Reality-ключи."
        echo "$key_output"
        exit 1
    fi

    cat > "$KEYS_FILE" <<EOF
PRIVATE_KEY="$private_key"
PUBLIC_KEY="$public_key"
SHORT_ID="$short_id"
EOF
    chmod 644 "$KEYS_FILE"
}

load_reality_keys() {
    if [[ ! -f "$KEYS_FILE" ]]; then
        err "Файл ключей не найден: $KEYS_FILE"
        exit 1
    fi

    # shellcheck disable=SC1090
    source "$KEYS_FILE"

    if [[ -z "${PRIVATE_KEY:-}" || -z "${PUBLIC_KEY:-}" || -z "${SHORT_ID:-}" ]]; then
        err "Reality-ключи повреждены."
        exit 1
    fi
}

create_xray_config() {
    load_manager_config
    load_reality_keys

    cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": [
          "geosite:category-ads-all"
        ],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [
            "${REALITY_SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5
      }
    }
  }
}
EOF
}

sync_users_to_xray() {
    local tmp
    tmp="$(mktemp)"

    jq --slurpfile users "$USERS_FILE" '.inbounds[0].settings.clients = $users[0]' "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"
}

test_xray_config() {
    xray -test -config "$XRAY_CONFIG"
}

fix_xray_permissions() {
    chmod 755 /usr/local/etc/xray 2>/dev/null || true
    chmod 644 /usr/local/etc/xray/config.json 2>/dev/null || true
    chmod 644 /usr/local/etc/xray/users.json 2>/dev/null || true
    chmod 644 /usr/local/etc/xray/reality.keys 2>/dev/null || true
    mkdir -p /var/log/xray "$NOTIFY_STATE_DIR" 2>/dev/null || true
    touch "$XRAY_ACCESS_LOG" "$XRAY_ERROR_LOG" 2>/dev/null || true
    chmod 755 /var/log/xray "$NOTIFY_STATE_DIR" 2>/dev/null || true
    chmod 644 "$XRAY_ACCESS_LOG" "$XRAY_ERROR_LOG" 2>/dev/null || true
}

restart_xray() {
    fix_xray_permissions
    systemctl restart xray
    systemctl enable xray >/dev/null 2>&1 || true
}

configure_firewall_note() {
    warn "Проверь у провайдера/VPS firewall: порт ${XRAY_PORT}/tcp должен быть открыт."
}

install_reality() {
    clear
    echo "$APP_NAME — установка"
    echo

    load_manager_config

    read -r -p "IP или домен сервера [авто]: " input_ip
    if [[ -n "$input_ip" ]]; then
        SERVER_IP="$input_ip"
    else
        SERVER_IP="$(detect_ip)"
    fi

    if [[ -z "$SERVER_IP" ]]; then
        read -r -p "Не удалось определить IP. Введи вручную: " SERVER_IP
    fi

    read -r -p "Порт [${DEFAULT_PORT}]: " XRAY_PORT
    XRAY_PORT="${XRAY_PORT:-$DEFAULT_PORT}"

    echo
    echo "SNI/маскировка. Обычно оставь github.com."
    read -r -p "SNI [${DEFAULT_SNI}]: " REALITY_SNI
    REALITY_SNI="${REALITY_SNI:-$DEFAULT_SNI}"

    read -r -p "Dest [${REALITY_SNI}:443]: " REALITY_DEST
    REALITY_DEST="${REALITY_DEST:-${REALITY_SNI}:443}"

    echo
    echo "Fingerprint:"
    echo "1) chrome"
    echo "2) firefox"
    echo "3) safari"
    read -r -p "Выбор [1]: " fp_choice
    case "${fp_choice:-1}" in
        1) REALITY_FP="chrome" ;;
        2) REALITY_FP="firefox" ;;
        3) REALITY_FP="safari" ;;
        *) REALITY_FP="chrome" ;;
    esac

    save_manager_config

    install_dependencies
    enable_bbr
    install_xray_core
    ensure_files
    generate_reality_keys
    create_xray_config
    sync_users_to_xray

    test_xray_config
    restart_xray

    configure_firewall_note

    ok "Xray VLESS REALITY установлен."
    ok "Сервер: ${SERVER_IP}:${XRAY_PORT}"
    ok "SNI: ${REALITY_SNI}"

    read -r -p "Создать первого пользователя main? [Y/n]: " create_main
    create_main="${create_main:-y}"
    if [[ "$create_main" =~ ^[Yy]$ ]]; then
        create_user_with_name "main"
    fi

    pause
}

xray_installed() {
    [[ -f "$XRAY_CONFIG" && -f "$KEYS_FILE" && -f "$USERS_FILE" ]]
}

user_exists() {
    local email="$1"
    jq -e --arg email "$email" '.[] | select(.email == $email)' "$USERS_FILE" >/dev/null
}

add_user_to_file() {
    local email="$1"
    local uuid="$2"
    local tmp
    tmp="$(mktemp)"

    jq --arg email "$email" --arg uuid "$uuid" '. += [{"email": $email, "id": $uuid, "flow": "xtls-rprx-vision"}]' "$USERS_FILE" > "$tmp" && mv "$tmp" "$USERS_FILE"

    chmod 644 "$USERS_FILE"
}

make_link() {
    local email="$1"
    local uuid="$2"

    load_manager_config
    load_reality_keys

    echo "vless://${uuid}@${SERVER_IP}:${XRAY_PORT}?security=reality&sni=${REALITY_SNI}&fp=${REALITY_FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#${email}"
}

send_text_to_telegram() {
    local text="$1"

    load_manager_config

    if [[ -z "${BOT_TOKEN:-}" || -z "${CHAT_ID:-}" ]]; then
        warn "Telegram не настроен, отправка пропущена."
        return 0
    fi

    local response
    response="$(curl -sS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" -d "chat_id=${CHAT_ID}" --data-urlencode "text=${text}")"

    if echo "$response" | grep -q '"ok":true'; then
        ok "Сообщение отправлено в Telegram."
    else
        warn "Telegram не принял сообщение:"
        echo "$response"
    fi
}

send_qr_to_telegram() {
    local link="$1"
    local email="$2"

    load_manager_config

    if [[ -z "${BOT_TOKEN:-}" || -z "${CHAT_ID:-}" ]]; then
        return 0
    fi

    local qr_file="/tmp/${email}_vless_qr.png"
    echo "$link" | qrencode -o "$qr_file" -s 6 -m 2

    local response
    response="$(curl -sS -F "chat_id=${CHAT_ID}" -F "caption=VLESS REALITY: ${email}" -F "photo=@${qr_file}" "https://api.telegram.org/bot${BOT_TOKEN}/sendPhoto")"

    rm -f "$qr_file"

    if echo "$response" | grep -q '"ok":true'; then
        ok "QR отправлен в Telegram."
    else
        warn "Telegram не принял QR:"
        echo "$response"
    fi
}

create_user_with_name() {
    local raw="$1"
    local email uuid link

    email="$(sanitize_name "$raw")"

    if [[ -z "$email" ]]; then
        err "Имя пользователя пустое."
        return 1
    fi

    if user_exists "$email"; then
        err "Пользователь уже существует: $email"
        return 1
    fi

    uuid="$(xray uuid)"

    add_user_to_file "$email" "$uuid"
    sync_users_to_xray
    test_xray_config
    restart_xray

    link="$(make_link "$email" "$uuid")"

    echo
    ok "Пользователь создан: $email"
    echo
    echo "Ссылка:"
    echo "$link"
    echo
    echo "QR:"
    echo "$link" | qrencode -t ansiutf8

    send_text_to_telegram "VLESS REALITY: ${email}

${link}"
    send_qr_to_telegram "$link" "$email"
    telegram_notify "🆕 Пользователь создан через менеджер

Имя: ${email}"
}

create_user() {
    clear

    if ! xray_installed; then
        err "Сначала установи VLESS REALITY."
        pause
        return 1
    fi

    read -r -p "Имя пользователя: " email
    create_user_with_name "$email"
    pause
}

create_many_users() {
    clear

    if ! xray_installed; then
        err "Сначала установи VLESS REALITY."
        pause
        return 1
    fi

    read -r -p "Префикс пользователей: " prefix
    prefix="$(sanitize_name "$prefix")"

    read -r -p "Количество: " count

    if [[ -z "$prefix" || ! "$count" =~ ^[0-9]+$ || "$count" -lt 1 ]]; then
        err "Неверный префикс или количество."
        pause
        return 1
    fi

    local all_links=""
    local created=0

    for i in $(seq 1 "$count"); do
        local email="${prefix}_${i}"
        local uuid link

        if user_exists "$email"; then
            warn "Пропуск, уже существует: $email"
            continue
        fi

        uuid="$(xray uuid)"
        add_user_to_file "$email" "$uuid"
        link="$(make_link "$email" "$uuid")"
        all_links+="${email}: ${link}"$'\n\n'
        created=$((created + 1))
    done

    sync_users_to_xray
    test_xray_config
    restart_xray

    ok "Создано пользователей: $created"

    if [[ "$created" -gt 0 ]]; then
        echo
        echo "$all_links"
        send_text_to_telegram "VLESS REALITY users:

${all_links}"
    fi

    pause
}

list_users() {
    clear

    if [[ ! -f "$USERS_FILE" ]]; then
        err "Файл пользователей не найден."
        pause
        return 1
    fi

    local count
    count="$(jq 'length' "$USERS_FILE")"

    echo "Пользователи: $count"
    echo

    if [[ "$count" -eq 0 ]]; then
        echo "Пользователей пока нет."
    else
        jq -r 'to_entries[] | "\(.key + 1)) \(.value.email) — \(.value.id)"' "$USERS_FILE"
    fi

    pause
}

share_user_link() {
    clear

    if [[ ! -f "$USERS_FILE" ]]; then
        err "Файл пользователей не найден."
        pause
        return 1
    fi

    local count
    count="$(jq 'length' "$USERS_FILE")"

    if [[ "$count" -eq 0 ]]; then
        warn "Пользователей нет."
        pause
        return 0
    fi

    jq -r 'to_entries[] | "\(.key + 1)) \(.value.email)"' "$USERS_FILE"
    echo

    read -r -p "Номер пользователя: " n

    if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > count )); then
        err "Неверный номер."
        pause
        return 1
    fi

    local index=$((n - 1))
    local email uuid link

    email="$(jq -r ".[$index].email" "$USERS_FILE")"
    uuid="$(jq -r ".[$index].id" "$USERS_FILE")"
    link="$(make_link "$email" "$uuid")"

    echo
    echo "Ссылка:"
    echo "$link"
    echo
    echo "QR:"
    echo "$link" | qrencode -t ansiutf8

    read -r -p "Отправить в Telegram? [y/N]: " send
    if [[ "$send" =~ ^[Yy]$ ]]; then
        send_text_to_telegram "VLESS REALITY: ${email}

${link}"
        send_qr_to_telegram "$link" "$email"
    fi

    pause
}

delete_user() {
    clear

    local count
    count="$(jq 'length' "$USERS_FILE" 2>/dev/null || echo 0)"

    if [[ "$count" -eq 0 ]]; then
        warn "Пользователей нет."
        pause
        return 0
    fi

    jq -r 'to_entries[] | "\(.key + 1)) \(.value.email)"' "$USERS_FILE"
    echo

    read -r -p "Номер пользователя для удаления: " n

    if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > count )); then
        err "Неверный номер."
        pause
        return 1
    fi

    local index=$((n - 1))
    local email tmp

    email="$(jq -r ".[$index].email" "$USERS_FILE")"

    read -r -p "Точно удалить $email? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        warn "Отменено."
        pause
        return 0
    fi

    tmp="$(mktemp)"
    jq "del(.[$index])" "$USERS_FILE" > "$tmp" && mv "$tmp" "$USERS_FILE"
    chmod 644 "$USERS_FILE"

    sync_users_to_xray
    test_xray_config
    restart_xray

    ok "Пользователь удалён: $email"
    telegram_notify "🗑 Пользователь удалён через менеджер

Имя: ${email}"
    pause
}

configure_telegram() {
    clear
    echo "Настройка Telegram"
    echo

    load_manager_config

    read -r -p "Bot Token: " BOT_TOKEN
    read -r -p "Chat ID: " CHAT_ID

    save_manager_config

    ok "Telegram сохранён."
    pause
}

show_status() {
    clear
    systemctl status xray --no-pager
    pause
}

show_config() {
    clear
    load_manager_config
    load_reality_keys 2>/dev/null || true

    echo "Настройки:"
    echo
    echo "SCRIPT_VERSION=${SCRIPT_VERSION}"
    echo "SERVER_IP=${SERVER_IP:-не задано}"
    echo "XRAY_PORT=${XRAY_PORT:-не задано}"
    echo "REALITY_SNI=${REALITY_SNI:-не задано}"
    echo "REALITY_DEST=${REALITY_DEST:-не задано}"
    echo "REALITY_FP=${REALITY_FP:-не задано}"
    echo "PUBLIC_KEY=${PUBLIC_KEY:-не задано}"
    echo "SHORT_ID=${SHORT_ID:-не задано}"
    if [[ -n "${BOT_TOKEN:-}" ]]; then
        echo "BOT_TOKEN=задан"
    else
        echo "BOT_TOKEN=не задан"
    fi
    echo "CHAT_ID=${CHAT_ID:-не задано}"
    echo "TELEGRAM_NOTIFY=${TELEGRAM_NOTIFY:-off}"

    pause
}

update_sni_dest() {
    clear
    load_manager_config

    echo "Текущие:"
    echo "SNI:  ${REALITY_SNI}"
    echo "Dest: ${REALITY_DEST}"
    echo

    read -r -p "Новый SNI [${REALITY_SNI}]: " new_sni
    new_sni="${new_sni:-$REALITY_SNI}"

    read -r -p "Новый Dest [${new_sni}:443]: " new_dest
    new_dest="${new_dest:-${new_sni}:443}"

    REALITY_SNI="$new_sni"
    REALITY_DEST="$new_dest"

    save_manager_config
    create_xray_config
    sync_users_to_xray
    test_xray_config
    restart_xray

    ok "SNI/Dest обновлены."
    warn "Старые ссылки больше не подойдут. Выдай пользователям новые ссылки."
    pause
}



create_backup() {
    local reason="${1:-manual}"
    local timestamp
    local backup_dir

    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="${BACKUP_ROOT}/${timestamp}-${reason}"

    mkdir -p "$backup_dir"

    cp "$USERS_FILE" "$backup_dir/users.json" 2>/dev/null || true
    cp "$XRAY_CONFIG" "$backup_dir/config.json" 2>/dev/null || true
    cp "$KEYS_FILE" "$backup_dir/reality.keys" 2>/dev/null || true
    cp "$MANAGER_CONFIG" "$backup_dir/vless-reality-manager.conf" 2>/dev/null || true

    chmod -R 700 "$backup_dir" 2>/dev/null || true

    echo "$backup_dir"
}

create_manual_backup() {
    clear
    echo "Создание резервной копии"
    echo

    local backup_dir
    backup_dir="$(create_backup "manual")"

    ok "Резервная копия создана:"
    echo "$backup_dir"
    pause
}

list_backups() {
    clear
    echo "Резервные копии"
    echo

    if [[ ! -d "$BACKUP_ROOT" ]]; then
        warn "Папка с резервными копиями ещё не создана."
        pause
        return 0
    fi

    local backups
    mapfile -t backups < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort -r)

    if [[ "${#backups[@]}" -eq 0 ]]; then
        warn "Резервных копий пока нет."
        pause
        return 0
    fi

    for i in "${!backups[@]}"; do
        echo "$((i + 1))) ${backups[$i]}"
    done

    pause
}

restore_backup() {
    clear
    echo "Восстановление из резервной копии"
    echo

    if [[ ! -d "$BACKUP_ROOT" ]]; then
        err "Папка с резервными копиями не найдена: $BACKUP_ROOT"
        pause
        return 1
    fi

    local backups
    mapfile -t backups < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort -r)

    if [[ "${#backups[@]}" -eq 0 ]]; then
        warn "Резервных копий пока нет."
        pause
        return 0
    fi

    for i in "${!backups[@]}"; do
        echo "$((i + 1))) ${backups[$i]}"
    done

    echo
    read -r -p "Выбери номер резервной копии: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backups[@]} )); then
        err "Неверный номер."
        pause
        return 1
    fi

    local selected="${backups[$((choice - 1))]}"

    echo
    warn "Будут восстановлены users.json, config.json, reality.keys и конфиг менеджера, если они есть в бэкапе."
    read -r -p "Для подтверждения напиши RESTORE: " confirm

    if [[ "$confirm" != "RESTORE" ]]; then
        warn "Отменено."
        pause
        return 0
    fi

    create_backup "before-restore" >/dev/null

    cp "$selected/users.json" "$USERS_FILE" 2>/dev/null || true
    cp "$selected/config.json" "$XRAY_CONFIG" 2>/dev/null || true
    cp "$selected/reality.keys" "$KEYS_FILE" 2>/dev/null || true
    cp "$selected/vless-reality-manager.conf" "$MANAGER_CONFIG" 2>/dev/null || true

    fix_xray_permissions
    test_xray_config
    restart_xray

    ok "Восстановление завершено."
    ok "Xray перезапущен."
    pause
}

version_to_number() {
    local version="$1"
    local major minor patch
    IFS='.' read -r major minor patch <<< "$version"
    major="${major:-0}"
    minor="${minor:-0}"
    patch="${patch:-0}"
    printf "%03d%03d%03d" "$major" "$minor" "$patch"
}

update_script_from_github() {
    clear
    echo "Проверка обновления скрипта"
    echo

    local remote_version
    local current_num
    local remote_num
    local current_script
    local tmp_script
    local backup_script

    remote_version="$(curl -fsSL "$GITHUB_VERSION_URL" | tr -d '[:space:]' || true)"

    if [[ -z "$remote_version" ]]; then
        err "Не удалось получить version.txt с GitHub."
        echo "Проверь ссылку:"
        echo "$GITHUB_VERSION_URL"
        pause
        return 1
    fi

    echo "Текущая версия:   $SCRIPT_VERSION"
    echo "Версия на GitHub: $remote_version"
    echo

    current_num="$(version_to_number "$SCRIPT_VERSION")"
    remote_num="$(version_to_number "$remote_version")"

    if (( 10#$remote_num <= 10#$current_num )); then
        ok "Обновление не требуется."
        pause
        return 0
    fi

    read -r -p "Доступна новая версия. Обновить скрипт? [Y/n]: " confirm
    confirm="${confirm:-y}"

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        warn "Обновление отменено."
        pause
        return 0
    fi

    current_script="$(readlink -f "$0")"
    tmp_script="/tmp/vless-reality-manager-update.sh"
    backup_script="${current_script}.bak"

    backup_dir="$(create_backup "before-script-update")"
    ok "Создана резервная копия данных:"
    echo "$backup_dir"
    echo

    if ! curl -fsSL "$GITHUB_SCRIPT_URL" -o "$tmp_script"; then
        err "Не удалось скачать новый скрипт с GitHub."
        echo "Проверь ссылку:"
        echo "$GITHUB_SCRIPT_URL"
        pause
        return 1
    fi

    if ! head -n 1 "$tmp_script" | grep -q "bash"; then
        err "Скачанный файл не похож на bash-скрипт. Обновление остановлено."
        rm -f "$tmp_script"
        pause
        return 1
    fi

    cp "$current_script" "$backup_script"
    mv "$tmp_script" "$current_script"
    chmod +x "$current_script"

    ok "Скрипт обновлён."
    ok "Резервная копия: $backup_script"
    echo
    echo "Перезапускаю новую версию..."
    sleep 1
    exec "$current_script"
}

delete_all_users() {
    clear

    if [[ ! -f "$USERS_FILE" ]]; then
        err "Файл пользователей не найден: $USERS_FILE"
        pause
        return 1
    fi

    local count
    count="$(jq 'length' "$USERS_FILE" 2>/dev/null || echo 0)"

    echo "Удаление всех пользователей"
    echo
    echo "Сейчас пользователей: $count"
    echo

    if [[ "$count" -eq 0 ]]; then
        warn "Удалять нечего."
        pause
        return 0
    fi

    warn "Это действие удалит ВСЕ ключи/ссылки пользователей из Xray."
    warn "Старые ссылки перестанут работать."
    echo
    read -r -p "Для подтверждения напиши DELETE: " confirm

    if [[ "$confirm" != "DELETE" ]]; then
        warn "Отменено."
        pause
        return 0
    fi

    create_backup "before-delete-all-users" >/dev/null
    echo "[]" > "$USERS_FILE"
    chmod 644 "$USERS_FILE"

    sync_users_to_xray
    test_xray_config
    restart_xray

    ok "Все пользователи удалены."
    ok "Резервная копия users.json сохранена рядом с исходным файлом."
    pause
}


telegram_notify() {
    local text="$1"

    load_manager_config

    if [[ "${TELEGRAM_NOTIFY:-off}" != "on" ]]; then
        return 0
    fi

    if [[ -z "${BOT_TOKEN:-}" || -z "${CHAT_ID:-}" ]]; then
        return 0
    fi

    text="$(printf '%s' "$text" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || printf '%s' "$text")"

    curl -sS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${text}" >/dev/null 2>&1 || true
}

install_notify_service() {
    cat > "$NOTIFY_SCRIPT" <<'EOF_NOTIFY'
#!/usr/bin/env bash

CONFIG_FILE="/etc/vless-reality-manager.conf"
ACCESS_LOG="/var/log/xray/access.log"
STATE_DIR="/var/lib/vless-reality-manager"
SEEN_FILE="${STATE_DIR}/notify_seen.log"

mkdir -p "$STATE_DIR"
touch "$SEEN_FILE"
touch "$ACCESS_LOG"

send_tg() {
    local text="$1"

    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi

    if [[ "${TELEGRAM_NOTIFY:-off}" != "on" ]]; then
        return 0
    fi

    if [[ -z "${BOT_TOKEN:-}" || -z "${CHAT_ID:-}" ]]; then
        return 0
    fi

    text="$(printf '%s' "$text" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || printf '%s' "$text")"

    curl -sS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${text}" >/dev/null 2>&1 || true
}

parse_and_notify() {
    local line="$1"
    local user ip key now

    user="$(echo "$line" | sed -n 's/.*email: \([^ ]*\).*/\1/p' | head -n1)"
    [[ -z "$user" ]] && user="$(echo "$line" | grep -oE 'email: [^ ]+' | awk '{print $2}' | head -n1)"
    [[ -z "$user" ]] && user="unknown"

    ip="$(echo "$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)"
    [[ -z "$ip" ]] && ip="unknown"

    now="$(date +%Y%m%d%H)"
    key="${now}|${user}|${ip}"

    if grep -qxF "$key" "$SEEN_FILE" 2>/dev/null; then
        return 0
    fi

    echo "$key" >> "$SEEN_FILE"
    tail -n 500 "$SEEN_FILE" > "${SEEN_FILE}.tmp" && mv "${SEEN_FILE}.tmp" "$SEEN_FILE"

    send_tg "🔵 Активность VLESS REALITY

Пользователь: ${user}
IP: ${ip}
Время: $(date '+%Y-%m-%d %H:%M:%S')"
}

tail -n 0 -F "$ACCESS_LOG" | while read -r line; do
    echo "$line" | grep -qiE 'accepted|email:' || continue
    parse_and_notify "$line"
done
EOF_NOTIFY

    chmod +x "$NOTIFY_SCRIPT"

    cat > "$NOTIFY_SERVICE" <<EOF_SERVICE
[Unit]
Description=VLESS Reality Telegram Notifications
After=network.target xray.service
Wants=xray.service

[Service]
Type=simple
ExecStart=${NOTIFY_SCRIPT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    systemctl daemon-reload
}

enable_telegram_notifications() {
    clear
    echo "Включение Telegram-уведомлений"
    echo

    load_manager_config

    if [[ -z "${BOT_TOKEN:-}" || -z "${CHAT_ID:-}" ]]; then
        warn "Сначала настрой Telegram в пункте меню 7."
        pause
        return 1
    fi

    TELEGRAM_NOTIFY="on"
    save_manager_config
    install_notify_service

    systemctl enable --now vless-reality-notify.service

    ok "Telegram-уведомления включены."
    telegram_notify "✅ Telegram-уведомления VLESS REALITY включены."
    pause
}

disable_telegram_notifications() {
    clear

    load_manager_config
    TELEGRAM_NOTIFY="off"
    save_manager_config

    systemctl disable --now vless-reality-notify.service >/dev/null 2>&1 || true

    ok "Telegram-уведомления выключены."
    pause
}

show_notify_status() {
    clear
    echo "Статус Telegram-уведомлений"
    echo

    load_manager_config
    echo "TELEGRAM_NOTIFY=${TELEGRAM_NOTIFY:-off}"
    echo

    systemctl status vless-reality-notify.service --no-pager 2>/dev/null || true
    pause
}

show_online_users() {
    clear
    echo "Активные пользователи по access.log"
    echo

    if [[ ! -f "$XRAY_ACCESS_LOG" ]]; then
        warn "Лог доступа ещё не создан: $XRAY_ACCESS_LOG"
        echo "Попробуй подключиться одним клиентом и зайти на сайт."
        pause
        return 0
    fi

    echo "Показываются последние активности из access.log."
    echo "Это не идеальный real-time online, но хорошо показывает, кто недавно пользовался VPN."
    echo

    local tmp
    tmp="$(mktemp)"

    tail -n 2000 "$XRAY_ACCESS_LOG" | while read -r line; do
        local user ip
        user="$(echo "$line" | sed -n 's/.*email: \([^ ]*\).*/\1/p' | head -n1)"
        [[ -z "$user" ]] && user="unknown"
        ip="$(echo "$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)"
        [[ -z "$ip" ]] && ip="-"
        if echo "$line" | grep -qiE 'accepted|email:'; then
            echo "${user}|${ip}|${line}"
        fi
    done > "$tmp"

    if [[ ! -s "$tmp" ]]; then
        warn "Активности пока не найдено."
        echo
        echo "После обновления подключись одним ключом и открой сайт."
        rm -f "$tmp"
        pause
        return 0
    fi

    awk -F'|' '
    {
        key=$1 "|" $2
        last[key]=$3
        user[key]=$1
        ip[key]=$2
    }
    END {
        i=0
        for (k in last) {
            i++
            print i ") " user[k]
            print "IP: " ip[k]
            print "Последняя активность: " last[k]
            print ""
        }
    }' "$tmp"

    rm -f "$tmp"
    pause
}

main_menu() {
    while true; do
        clear
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "$APP_NAME"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "1) Установить VLESS REALITY"
        echo "2) Создать пользователя"
        echo "3) Создать несколько пользователей"
        echo "4) Список пользователей"
        echo "5) Получить ссылку/QR пользователя"
        echo "6) Удалить пользователя"
        echo "7) Настроить Telegram"
        echo "8) Показать настройки"
        echo "9) Изменить SNI/Dest"
        echo "10) Статус Xray"
        echo "11) Обновить скрипт с GitHub"
        echo "12) Удалить всех пользователей"
        echo "13) Создать резервную копию"
        echo "14) Показать резервные копии"
        echo "15) Восстановить резервную копию"
        echo "16) Активные пользователи"
        echo "17) Включить Telegram-уведомления"
        echo "18) Выключить Telegram-уведомления"
        echo "19) Статус Telegram-уведомлений"
        echo "0) Выход"
        echo
        read -r -p "Выбор: " choice

        case "$choice" in
            1) install_reality ;;
            2) create_user ;;
            3) create_many_users ;;
            4) list_users ;;
            5) share_user_link ;;
            6) delete_user ;;
            7) configure_telegram ;;
            8) show_config ;;
            9) update_sni_dest ;;
            10) show_status ;;
            11) update_script_from_github ;;
            12) delete_all_users ;;
            13) create_manual_backup ;;
            14) list_backups ;;
            15) restore_backup ;;
            16) show_online_users ;;
            17) enable_telegram_notifications ;;
            18) disable_telegram_notifications ;;
            19) show_notify_status ;;
            0) exit 0 ;;
            *) err "Неверный выбор"; sleep 1 ;;
        esac
    done
}

require_root
load_manager_config
main_menu
