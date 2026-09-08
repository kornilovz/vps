#!/usr/bin/env bash
set -Eeuo pipefail

DOMAIN_DEFAULT="chat.example.com"
WORKSPACE_USER_DEFAULT="workspace"

DISPLAY_NUM=":99"
SCREEN_WIDTH_DEFAULT="1440"
SCREEN_HEIGHT_DEFAULT="900"
SCREEN_DEPTH_DEFAULT="24"

VNC_PORT="5900"
NOVNC_PORT="6080"

CPU_QUOTA_DEFAULT="70%"
SWAP_SIZE_DEFAULT="2G"

INSTALL_MARKER="/etc/chatgpt-vps-installed"
CONFIG_FILE="/etc/chatgpt-vps.conf"

CADDY_ACME_STAGING_URL="https://acme-staging-v02.api.letsencrypt.org/directory"

SERVICES=(
  chatgpt-xvfb.service
  chatgpt-desktop.service
  chatgpt-vnc.service
  chatgpt-novnc.service
)

ALL_SERVICES=(
  chatgpt-xvfb.service
  chatgpt-desktop.service
  chatgpt-vnc.service
  chatgpt-novnc.service
  caddy.service
)

DOMAIN=""
WORKSPACE_USER=""
SCREEN_WIDTH=""
SCREEN_HEIGHT=""
SCREEN_DEPTH=""
CPU_QUOTA=""
SWAP_SIZE=""
ENABLE_UI_AUTOBOOT=""

CADDY_USER=""
CADDY_HASH=""
CADDY_ACME_MODE=""


require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Запустите скрипт от root:"
    echo "sudo bash install.sh"
    exit 1
  fi
}


check_os() {
  if ! grep -q '^ID=ubuntu' /etc/os-release || \
     ! grep -q '^VERSION_ID="24.04"' /etc/os-release; then
    echo "Этот скрипт рассчитан на Ubuntu 24.04."
    exit 1
  fi

  if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
    echo "Этот скрипт рассчитан на x86_64 / amd64."
    exit 1
  fi
}


validate_install_settings() {
  if [[ ! "${DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]] || [[ "${DOMAIN}" != *.* ]]; then
    echo "Некорректный домен: ${DOMAIN}"
    echo "Пример: chat.example.com"
    exit 1
  fi

  if [[ ! "${WORKSPACE_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "Некорректное имя Linux-пользователя: ${WORKSPACE_USER}"
    exit 1
  fi

  if [[ ! "${SCREEN_WIDTH}" =~ ^[0-9]+$ ]] || \
     [[ ! "${SCREEN_HEIGHT}" =~ ^[0-9]+$ ]] || \
     [[ ! "${SCREEN_DEPTH}" =~ ^[0-9]+$ ]]; then
    echo "Размер экрана и глубина цвета должны быть числами."
    exit 1
  fi

  if [[ ! "${CPU_QUOTA}" =~ ^[0-9]+%$ ]]; then
    echo "CPU quota должна выглядеть, например, как 70%."
    exit 1
  fi
}


ask_install_settings() {
  echo
  echo "==> Параметры установки"

  read -r -p "Домен для HTTPS [${DOMAIN_DEFAULT}]: " DOMAIN
  DOMAIN="${DOMAIN:-${DOMAIN_DEFAULT}}"

  read -r -p "Имя Linux-пользователя [${WORKSPACE_USER_DEFAULT}]: " WORKSPACE_USER
  WORKSPACE_USER="${WORKSPACE_USER:-${WORKSPACE_USER_DEFAULT}}"

  read -r -p "Ширина экрана [${SCREEN_WIDTH_DEFAULT}]: " SCREEN_WIDTH
  SCREEN_WIDTH="${SCREEN_WIDTH:-${SCREEN_WIDTH_DEFAULT}}"

  read -r -p "Высота экрана [${SCREEN_HEIGHT_DEFAULT}]: " SCREEN_HEIGHT
  SCREEN_HEIGHT="${SCREEN_HEIGHT:-${SCREEN_HEIGHT_DEFAULT}}"

  read -r -p "Глубина цвета [${SCREEN_DEPTH_DEFAULT}]: " SCREEN_DEPTH
  SCREEN_DEPTH="${SCREEN_DEPTH:-${SCREEN_DEPTH_DEFAULT}}"

  read -r -p "Ограничение CPU [${CPU_QUOTA_DEFAULT}]: " CPU_QUOTA
  CPU_QUOTA="${CPU_QUOTA:-${CPU_QUOTA_DEFAULT}}"

  read -r -p "Размер swap-файла [${SWAP_SIZE_DEFAULT}]: " SWAP_SIZE
  SWAP_SIZE="${SWAP_SIZE:-${SWAP_SIZE_DEFAULT}}"

  read -r -p "Включить автозагрузку UI после reboot? [y/N]: " ENABLE_UI_AUTOBOOT
  ENABLE_UI_AUTOBOOT="${ENABLE_UI_AUTOBOOT:-N}"

  validate_install_settings

  echo
  echo "Выбрано:"
  echo "DOMAIN=${DOMAIN}"
  echo "WORKSPACE_USER=${WORKSPACE_USER}"
  echo "SCREEN=${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}"
  echo "CPU_QUOTA=${CPU_QUOTA}"
  echo "SWAP_SIZE=${SWAP_SIZE}"
  echo "UI_AUTOBOOT=${ENABLE_UI_AUTOBOOT}"
  echo
}


load_existing_config() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Файл ${CONFIG_FILE} не найден."
    echo "Сначала выполните установку (пункт 1)."
    return 1
  fi

  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
}


save_config() {
  cat > "${CONFIG_FILE}" <<EOF
DOMAIN="${DOMAIN}"
WORKSPACE_USER="${WORKSPACE_USER}"
DISPLAY_NUM="${DISPLAY_NUM}"
SCREEN_WIDTH="${SCREEN_WIDTH}"
SCREEN_HEIGHT="${SCREEN_HEIGHT}"
SCREEN_DEPTH="${SCREEN_DEPTH}"
VNC_PORT="${VNC_PORT}"
NOVNC_PORT="${NOVNC_PORT}"
CPU_QUOTA="${CPU_QUOTA}"
SWAP_SIZE="${SWAP_SIZE}"
CADDY_USER="${CADDY_USER}"
CADDY_HASH="${CADDY_HASH}"
CADDY_ACME_MODE="${CADDY_ACME_MODE}"
EOF

  chmod 600 "${CONFIG_FILE}"
}


is_installed() {
  [[ -f "${INSTALL_MARKER}" ]]
}


ensure_user_directories() {
  local home="/home/${WORKSPACE_USER}"

  echo "==> Проверяем права пользовательских каталогов"

  install -d -m 750 \
    -o "${WORKSPACE_USER}" \
    -g "${WORKSPACE_USER}" \
    "${home}"

  install -d -m 700 \
    -o "${WORKSPACE_USER}" \
    -g "${WORKSPACE_USER}" \
    "${home}/.config"

  install -d -m 700 \
    -o "${WORKSPACE_USER}" \
    -g "${WORKSPACE_USER}" \
    "${home}/.config/openbox"

  install -d -m 700 \
    -o "${WORKSPACE_USER}" \
    -g "${WORKSPACE_USER}" \
    "${home}/.cache"

  install -d -m 700 \
    -o "${WORKSPACE_USER}" \
    -g "${WORKSPACE_USER}" \
    "${home}/.local"

  install -d -m 700 \
    -o "${WORKSPACE_USER}" \
    -g "${WORKSPACE_USER}" \
    "${home}/.local/share"

  install -d -m 700 \
    -o "${WORKSPACE_USER}" \
    -g "${WORKSPACE_USER}" \
    "${home}/.local/state"

  install -d -m 700 \
    -o "${WORKSPACE_USER}" \
    -g "${WORKSPACE_USER}" \
    "${home}/.vnc"

  install -d -m 755 \
    -o "${WORKSPACE_USER}" \
    -g "${WORKSPACE_USER}" \
    "${home}/projects"

  chown -R "${WORKSPACE_USER}:${WORKSPACE_USER}" \
    "${home}/.config" \
    "${home}/.cache" \
    "${home}/.local" \
    "${home}/.vnc"
}


configure_default_browser() {
  local home="/home/${WORKSPACE_USER}"

  echo "==> Настраиваем Falkon браузером по умолчанию"

  cat > "${home}/.config/mimeapps.list" <<'EOF'
[Default Applications]
x-scheme-handler/http=org.kde.falkon.desktop
x-scheme-handler/https=org.kde.falkon.desktop
text/html=org.kde.falkon.desktop

[Added Associations]
x-scheme-handler/http=org.kde.falkon.desktop;
x-scheme-handler/https=org.kde.falkon.desktop;
text/html=org.kde.falkon.desktop;
EOF

  chown "${WORKSPACE_USER}:${WORKSPACE_USER}" \
    "${home}/.config/mimeapps.list"

  chmod 600 \
    "${home}/.config/mimeapps.list"
}


write_openbox_autostart() {
  local home="/home/${WORKSPACE_USER}"

  echo "==> Создаём autostart Openbox"

  cat > "${home}/.config/openbox/autostart" <<'EOF'
xsetroot -solid "#1e1e1e" &

/usr/bin/autocutsel -fork
/usr/bin/autocutsel -selection PRIMARY -fork

xterm \
  -geometry 120x32+20+20 \
  -fa Monospace \
  -fs 11 \
  -bg "#111111" \
  -fg "#dddddd" \
  -title "Terminal" &

(
  sleep 2

  /usr/bin/chatgpt --disable-gpu \
    >>"$HOME/.local/state/chatgpt-desktop.log" 2>&1
) &
EOF

  chown "${WORKSPACE_USER}:${WORKSPACE_USER}" \
    "${home}/.config/openbox/autostart"

  chmod 700 \
    "${home}/.config/openbox/autostart"
}


ensure_dns_points_here() {
  echo "==> Проверяем DNS для ${DOMAIN}"

  local server_ip
  local dns_ips

  server_ip="$(curl -4 -fsSL https://api.ipify.org || true)"

  dns_ips="$(
    getent ahostsv4 "${DOMAIN}" |
      awk '{print $1}' |
      sort -u || true
  )"

  if [[ -z "${server_ip}" ]]; then
    echo "Не удалось определить внешний IPv4 сервера."
    exit 1
  fi

  if [[ -z "${dns_ips}" ]]; then
    echo "DNS для ${DOMAIN} пока не резолвится."
    echo "Создайте A-запись:"
    echo "${DOMAIN} -> ${server_ip}"
    exit 1
  fi

  if ! grep -qx "${server_ip}" <<< "${dns_ips}"; then
    echo "DNS для ${DOMAIN} не указывает на этот VPS."
    echo
    echo "IP VPS:"
    echo "${server_ip}"
    echo
    echo "DNS сейчас указывает на:"
    echo "${dns_ips}"
    exit 1
  fi

  echo "DNS OK: ${DOMAIN} -> ${server_ip}"
}


install_caddy() {
  if command -v caddy >/dev/null 2>&1; then
    return
  fi

  echo "==> Устанавливаем Caddy из официального репозитория"

  DEBIAN_FRONTEND=noninteractive apt install -y \
    debian-keyring \
    debian-archive-keyring \
    apt-transport-https \
    curl \
    gnupg

  rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg

  curl -1sLf \
    'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor \
      -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

  curl -1sLf \
    'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    -o /etc/apt/sources.list.d/caddy-stable.list

  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  chmod o+r /etc/apt/sources.list.d/caddy-stable.list

  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y caddy
}


configure_firewall() {
  echo "==> Настраиваем firewall"

  local ssh_port

  ssh_port="$(
    sshd -T 2>/dev/null |
      awk '$1 == "port" {print $2; exit}' || true
  )"

  ssh_port="${ssh_port:-22}"

  ufw allow "${ssh_port}/tcp"
  ufw allow 80/tcp
  ufw allow 443/tcp

  ufw --force enable
}


write_caddyfile() {
  if [[ -z "${DOMAIN}" || -z "${CADDY_USER}" || -z "${CADDY_HASH}" || -z "${CADDY_ACME_MODE}" ]]; then
    echo "ОШИБКА: недостаточно данных для генерации Caddyfile."
    exit 1
  fi

  echo "==> Создаём Caddyfile (${CADDY_ACME_MODE})"

  if [[ "${CADDY_ACME_MODE}" == "staging" ]]; then
    cat > /etc/caddy/Caddyfile <<EOF
{
    acme_ca ${CADDY_ACME_STAGING_URL}
}

${DOMAIN} {
    basic_auth {
        ${CADDY_USER} ${CADDY_HASH}
    }

    @root path /
    redir @root /vnc.html?resize=scale&autoconnect=true 302

    reverse_proxy 127.0.0.1:${NOVNC_PORT}
}
EOF
  elif [[ "${CADDY_ACME_MODE}" == "production" ]]; then
    cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN} {
    basic_auth {
        ${CADDY_USER} ${CADDY_HASH}
    }

    @root path /
    redir @root /vnc.html?resize=scale&autoconnect=true 302

    reverse_proxy 127.0.0.1:${NOVNC_PORT}
}
EOF
  else
    echo "ОШИБКА: неизвестный режим Caddy ACME: ${CADDY_ACME_MODE}"
    exit 1
  fi

  caddy fmt --overwrite /etc/caddy/Caddyfile
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
}


reload_caddy_with_current_mode() {
  write_caddyfile

  echo "==> Перезагружаем Caddy"
  systemctl reload caddy.service
}


switch_caddy_acme_mode() {
  load_existing_config || return 1

  echo
  echo "Текущий режим Caddy TLS: ${CADDY_ACME_MODE}"
  echo "1. staging"
  echo "2. production"
  echo

  local choice
  read -r -p "Выберите режим: " choice

  case "${choice}" in
    1)
      if [[ "${CADDY_ACME_MODE}" == "staging" ]]; then
        echo "Caddy уже в режиме staging."
        return 0
      fi
      CADDY_ACME_MODE="staging"
      ;;
    2)
      if [[ "${CADDY_ACME_MODE}" == "production" ]]; then
        echo "Caddy уже в режиме production."
        return 0
      fi
      CADDY_ACME_MODE="production"
      ;;
    *)
      echo "Неверный пункт."
      return 1
      ;;
  esac

  save_config
  reload_caddy_with_current_mode

  echo
  echo "Готово. Новый режим Caddy TLS: ${CADDY_ACME_MODE}"

  if [[ "${CADDY_ACME_MODE}" == "staging" ]]; then
    echo "Браузер покажет предупреждение о недоверенном сертификате — это нормально для staging."
  else
    echo "Теперь Caddy будет пытаться получить production-сертификат."
  fi
}


start_ui_now() {
  load_existing_config || return 1

  ensure_user_directories

  echo "==> Запускаем UI"

  systemctl start chatgpt-xvfb.service
  systemctl start chatgpt-desktop.service
  systemctl start chatgpt-vnc.service
  systemctl start chatgpt-novnc.service
  systemctl start caddy.service

  echo
  echo "UI запущен:"
  echo "https://${DOMAIN}/"
}


stop_ui_now() {
  load_existing_config || return 1

  echo "==> Останавливаем UI"

  systemctl stop chatgpt-novnc.service || true
  systemctl stop chatgpt-vnc.service || true
  systemctl stop chatgpt-desktop.service || true
  systemctl stop chatgpt-xvfb.service || true

  echo "UI остановлен."
}


restart_ui_now() {
  load_existing_config || return 1

  ensure_user_directories

  echo "==> Перезапускаем UI"

  systemctl restart chatgpt-xvfb.service
  systemctl restart chatgpt-desktop.service
  systemctl restart chatgpt-vnc.service
  systemctl restart chatgpt-novnc.service
  systemctl restart caddy.service

  echo "UI перезапущен."
}


enable_ui_autoload() {
  load_existing_config || return 1

  echo "==> Включаем автозагрузку UI"

  systemctl enable "${SERVICES[@]}"
  systemctl enable caddy.service

  echo "Автозагрузка включена."
}


disable_ui_autoload() {
  load_existing_config || return 1

  echo "==> Выключаем автозагрузку UI"

  systemctl disable chatgpt-novnc.service || true
  systemctl disable chatgpt-vnc.service || true
  systemctl disable chatgpt-desktop.service || true
  systemctl disable chatgpt-xvfb.service || true

  echo "Автозагрузка UI выключена."
  echo "Caddy оставляем включённым."
}


service_active_state() {
  local svc="$1"

  if systemctl is-active --quiet "$svc"; then
    echo "active"
  else
    echo "inactive"
  fi
}


service_enabled_state() {
  local svc="$1"
  local state

  state="$(systemctl is-enabled "$svc" 2>/dev/null || true)"

  if [[ -z "${state}" ]]; then
    echo "unknown"
  else
    echo "${state}"
  fi
}


show_status() {
  load_existing_config || return 1

  echo
  echo "==================== STATUS ===================="
  echo "DOMAIN=${DOMAIN}"
  echo "WORKSPACE_USER=${WORKSPACE_USER}"
  echo "CADDY_ACME_MODE=${CADDY_ACME_MODE}"
  echo "URL=https://${DOMAIN}/vnc.html?resize=scale&autoconnect=true"
  echo

  for svc in "${ALL_SERVICES[@]}"; do
    printf '%-24s active=%-8s enabled=%s\n' \
      "$svc" \
      "$(service_active_state "$svc")" \
      "$(service_enabled_state "$svc")"
  done

  echo "================================================"
  echo

  echo "Процесс ChatGPT:"
  if pgrep -afu "${WORKSPACE_USER}" '/usr/lib/chatgpt/ChatGPT' >/dev/null; then
    pgrep -afu "${WORKSPACE_USER}" '/usr/lib/chatgpt/ChatGPT'
  else
    echo "ChatGPT НЕ запущен."
  fi

  echo
  echo "HTTPS-порты:"
  ss -ltnp | grep -E ':80|:443' || true

  echo
  echo "Последние логи ChatGPT:"
  tail -n 20 "/home/${WORKSPACE_USER}/.local/state/chatgpt-desktop.log" \
    2>/dev/null || echo "Лог пока отсутствует."

  echo
  echo "Последние логи chatgpt-desktop:"
  journalctl -u chatgpt-desktop.service -n 20 --no-pager || true

  echo
  echo "Последние логи Caddy:"
  journalctl -u caddy.service -n 20 --no-pager || true
}


install_everything() {
  if is_installed; then
    echo "Установка уже выполнялась ранее."
    echo
    echo "Если это новый VPS после переустановки ОС,"
    echo "маркера установки быть не должно."
    echo
    echo "Для обычного запуска используйте пункт 4 или 7."
    return 0
  fi

  ask_install_settings

  echo "==> Обновляем список пакетов"
  apt update

  echo "==> Включаем репозиторий Universe"
  DEBIAN_FRONTEND=noninteractive apt install -y software-properties-common
  add-apt-repository -y universe
  apt update

  echo "==> Устанавливаем системные пакеты"
  DEBIAN_FRONTEND=noninteractive apt install -y \
    ca-certificates \
    curl \
    wget \
    gnupg \
    apt-transport-https \
    dbus-x11 \
    xvfb \
    x11vnc \
    novnc \
    websockify \
    openbox \
    python3-xdg \
    xdg-utils \
    x11-xserver-utils \
    autocutsel \
    xterm \
    xfonts-base \
    falkon \
    tmux \
    vim \
    nano \
    git \
    htop \
    ufw

  echo "==> Создаём пользователя ${WORKSPACE_USER}, если его ещё нет"
  if ! id "${WORKSPACE_USER}" >/dev/null 2>&1; then
    adduser \
      --disabled-password \
      --gecos "" \
      "${WORKSPACE_USER}"
  fi

  echo
  echo "==> Задайте пароль Linux-пользователя ${WORKSPACE_USER}"
  passwd "${WORKSPACE_USER}"

  ensure_user_directories
  configure_default_browser

  echo
  echo "==> Создайте отдельный пароль VNC"
  echo "Это не Linux-пароль и не пароль ChatGPT."
  runuser -l "${WORKSPACE_USER}" -c 'x11vnc -storepasswd'

  write_openbox_autostart

  echo "==> Создаём swap, если его ещё нет"
  if ! swapon --show=NAME | grep -qx '/swapfile'; then
    fallocate -l "${SWAP_SIZE}" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
  fi

  if ! grep -q '^/swapfile ' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  echo "==> Загружаем ChatGPT Desktop"
  mkdir -p /root/Downloads

  wget \
    -q \
    --show-progress \
    -O /root/Downloads/chatgpt_amd64.deb \
    https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb

  echo "==> Устанавливаем ChatGPT Desktop"
  DEBIAN_FRONTEND=noninteractive apt install -y /root/Downloads/chatgpt_amd64.deb
  rm -f /root/Downloads/chatgpt_amd64.deb

  if [[ ! -x /usr/bin/chatgpt ]]; then
    echo "ОШИБКА: /usr/bin/chatgpt не найден после установки."
    exit 1
  fi

  ensure_user_directories
  configure_default_browser

  echo "==> Создаём сервис Xvfb"
  cat > /etc/systemd/system/chatgpt-xvfb.service <<EOF
[Unit]
Description=Virtual X11 display for ChatGPT Desktop

[Service]
User=${WORKSPACE_USER}
Group=${WORKSPACE_USER}
ExecStart=/usr/bin/Xvfb ${DISPLAY_NUM} -screen 0 ${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH} -nolisten tcp
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  echo "==> Создаём сервис Openbox + ChatGPT"
  cat > /etc/systemd/system/chatgpt-desktop.service <<EOF
[Unit]
Description=Openbox session with ChatGPT, Falkon and terminal
After=chatgpt-xvfb.service
Requires=chatgpt-xvfb.service

[Service]
User=${WORKSPACE_USER}
Group=${WORKSPACE_USER}

RuntimeDirectory=chatgpt-workspace
RuntimeDirectoryMode=0700

Environment=DISPLAY=${DISPLAY_NUM}
Environment=HOME=/home/${WORKSPACE_USER}
Environment=XDG_RUNTIME_DIR=/run/chatgpt-workspace
Environment=XDG_CONFIG_HOME=/home/${WORKSPACE_USER}/.config
Environment=XDG_CACHE_HOME=/home/${WORKSPACE_USER}/.cache
Environment=XDG_CURRENT_DESKTOP=Openbox
Environment=BROWSER=/usr/bin/falkon

WorkingDirectory=/home/${WORKSPACE_USER}

ExecStart=/usr/bin/dbus-run-session -- /usr/bin/openbox-session

Restart=on-failure
RestartSec=10

CPUQuota=${CPU_QUOTA}
Nice=10

[Install]
WantedBy=multi-user.target
EOF

  echo "==> Создаём VNC сервис"
  cat > /etc/systemd/system/chatgpt-vnc.service <<EOF
[Unit]
Description=Local VNC server for ChatGPT Desktop
After=chatgpt-desktop.service
Requires=chatgpt-desktop.service

[Service]
User=${WORKSPACE_USER}
Group=${WORKSPACE_USER}

Environment=DISPLAY=${DISPLAY_NUM}

ExecStart=/usr/bin/x11vnc -display ${DISPLAY_NUM} -localhost -rfbport ${VNC_PORT} -rfbauth /home/${WORKSPACE_USER}/.vnc/passwd -forever -shared -noxrecord -noxfixes -noxdamage

Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  echo "==> Создаём noVNC сервис"
  cat > /etc/systemd/system/chatgpt-novnc.service <<EOF
[Unit]
Description=Local noVNC gateway for ChatGPT Desktop
After=chatgpt-vnc.service
Requires=chatgpt-vnc.service

[Service]
User=${WORKSPACE_USER}
Group=${WORKSPACE_USER}

ExecStart=/usr/bin/websockify --web=/usr/share/novnc 127.0.0.1:${NOVNC_PORT} 127.0.0.1:${VNC_PORT}

Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  install_caddy
  ensure_dns_points_here

  echo
  read -r -p "Введите логин для HTTPS-доступа через Caddy [chatuser]: " CADDY_USER
  CADDY_USER="${CADDY_USER:-chatuser}"

  echo
  read -r -s -p "Введите пароль для HTTPS-доступа через Caddy: " CADDY_PASS
  echo
  read -r -s -p "Повторите пароль для HTTPS-доступа через Caddy: " CADDY_PASS2
  echo

  if [[ -z "${CADDY_PASS}" ]]; then
    echo "Пароль Caddy не может быть пустым."
    exit 1
  fi

  if [[ "${CADDY_PASS}" != "${CADDY_PASS2}" ]]; then
    echo "Пароли Caddy не совпадают."
    exit 1
  fi

  echo "==> Хэшируем пароль Caddy"
  CADDY_HASH="$(
    caddy hash-password --plaintext "${CADDY_PASS}"
  )"

  unset CADDY_PASS CADDY_PASS2

  CADDY_ACME_MODE="staging"
  write_caddyfile

  configure_firewall

  echo "==> Перечитываем systemd"
  systemctl daemon-reload

  echo "==> Включаем и перезапускаем Caddy"
  systemctl enable caddy.service
  systemctl restart caddy.service

  if [[ "${ENABLE_UI_AUTOBOOT}" =~ ^[Yy]$ ]]; then
    echo "==> Включаем автозагрузку UI"
    systemctl enable "${SERVICES[@]}"
  else
    echo "==> UI после reboot автоматически запускаться не будет"
  fi

  save_config
  touch "${INSTALL_MARKER}"

  echo "==> Запускаем UI сейчас"
  start_ui_now

  echo
  echo "============================================================"
  echo "Установка завершена."
  echo
  echo "Откройте:"
  echo "https://${DOMAIN}/"
  echo
  echo "ВАЖНО: сейчас Caddy работает в режиме STAGING."
  echo "Браузер покажет предупреждение о недоверенном сертификате — это нормально."
  echo "После проверки работоспособности переключите режим через пункт 8."
  echo
  echo "Первый вход:"
  echo "1. Caddy: логин ${CADDY_USER} и заданный HTTPS-пароль."
  echo "2. noVNC: отдельный VNC-пароль."
  echo "3. Внутри рабочего стола запустится ChatGPT и Terminal."
  echo "4. При входе в ChatGPT браузер должен открыться в Falkon."
  echo "5. Для текста работает clipboard noVNC/X11."
  echo
  echo "Если что-то не работает:"
  echo "bash install.sh"
  echo "затем пункт 6"
  echo "============================================================"
}


show_menu() {
  echo
  echo "==================== MENU ===================="
  echo "1. Установить"
  echo "2. Включить автозагрузку"
  echo "3. Выключить автозагрузку"
  echo "4. Просто включить все"
  echo "5. Выключить все"
  echo "6. Статус"
  echo "7. Рестарт"
  echo "8. Переключить TLS режим Caddy (staging / production)"
  echo "0. Выход"
  echo "=============================================="
}


main() {
  require_root
  check_os

  while true; do
    show_menu
    read -r -p "Выберите пункт: " choice

    case "${choice}" in
      1)
        install_everything
        ;;
      2)
        if ! is_installed; then
          echo "Сначала выполните установку (пункт 1)."
        else
          enable_ui_autoload
        fi
        ;;
      3)
        if ! is_installed; then
          echo "Сначала выполните установку (пункт 1)."
        else
          disable_ui_autoload
        fi
        ;;
      4)
        if ! is_installed; then
          echo "Сначала выполните установку (пункт 1)."
        else
          start_ui_now
        fi
        ;;
      5)
        if ! is_installed; then
          echo "Сначала выполните установку (пункт 1)."
        else
          stop_ui_now
        fi
        ;;
      6)
        if ! is_installed; then
          echo "Сначала выполните установку (пункт 1)."
        else
          show_status
        fi
        ;;
      7)
        if ! is_installed; then
          echo "Сначала выполните установку (пункт 1)."
        else
          restart_ui_now
        fi
        ;;
      8)
        if ! is_installed; then
          echo "Сначала выполните установку (пункт 1)."
        else
          switch_caddy_acme_mode
        fi
        ;;
      0)
        echo "Выход."
        exit 0
        ;;
      *)
        echo "Неверный пункт меню."
        ;;
    esac
  done
}


main
