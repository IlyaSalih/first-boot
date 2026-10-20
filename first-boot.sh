#!/usr/bin/env bash
# =============================================================================
#  first-boot.sh — первичная защита нового Linux-сервера
#
#  Семейства и дистрибутивы:
#    debian : Debian 11-13, Ubuntu 20.04+, Astra Linux SE*
#    rhel   : RHEL 8-10, Rocky, AlmaLinux, Oracle Linux, CentOS Stream,
#             Fedora, Amazon Linux 2023, RED OS*, MSVSphere*
#    suse   : SLES 15, openSUSE Leap 15, openSUSE Tumbleweed
#    (* — поддержка по ID_LIKE/совместимости, на реальных ВМ не проверялось)
#
#  Запуск (на сервере):
#    sudo SSH_PORT=2222 bash first-boot.sh
#
#  ВАЖНО: не закрывай текущую SSH-сессию, пока не проверишь вход
#  в НОВОМ окне терминала под новым пользователем и портом.
# =============================================================================
set -Eeuo pipefail

### ===================== НАСТРОЙКИ (задаются через env) ======================
NEW_USER="${NEW_USER:-}"                   # пользователь для входа по SSH; не задан —
DEFAULT_USER="noroot"                      # спросим при запуске (по умолчанию noroot)
SSH_PUBKEY="${SSH_PUBKEY:-}"               # публичный ключ(и), по одному на строку
SSH_PORT="${SSH_PORT:-22}"                 # порт SSH
EXTRA_TCP_PORTS="${EXTRA_TCP_PORTS:-}"     # доп. TCP-порты: "80 443"
EXTRA_UDP_PORTS="${EXTRA_UDP_PORTS:-}"     # доп. UDP-порты: "51820"
SUDO_NOPASSWD="${SUDO_NOPASSWD:-false}"    # true = sudo без пароля (для Ansible)
TIMEZONE="${TIMEZONE:-Europe/Moscow}"
FIREWALL="${FIREWALL:-true}"               # false = не трогать firewall на хосте
AUTO_UPDATES="${AUTO_UPDATES:-default}"    # true / false; default = true (кроме Astra)
AUTO_REBOOT="${AUTO_REBOOT:-false}"        # перезагрузка, если обновление её требует
AUTO_REBOOT_TIME="${AUTO_REBOOT_TIME:-04:00}"
SKIP_UPGRADE="${SKIP_UPGRADE:-false}"      # true = не делать полное обновление системы
SAFE_PORT_SWITCH="${SAFE_PORT_SWITCH:-auto}" # держать старый порт SSH открытым, пока не подтвердишь
                                           # вход по новому: auto (если есть терминал) / true / false
### ===========================================================================

# shellcheck disable=SC2034  # переменные семейных модулей используются в общих функциях

# ############################################################################
#  ОБЩИЕ ФУНКЦИИ
# ############################################################################

FIREWALL_KIND="none"
HARDEN_TAG="first-boot"

# ------------------------------------------------------------------ вывод
log()  { printf '\e[1;32m[+]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[!]\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31m[x]\e[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\e[1;36m==> %s\e[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# Ставит пакеты по одному; отсутствующие в репозиториях только предупреждают
pkg_try() {
  local p
  for p in "$@"; do
    if pkg_install "$p" >/dev/null 2>&1; then
      log "Пакет $p установлен"
    else
      warn "Пакет $p недоступен в репозиториях — пропускаю"
    fi
  done
}

# ini_set FILE SECTION KEY VALUE — задать ключ в INI-файле
ini_set() {
  local f=$1 s=$2 k=$3 v=$4
  [[ -f "$f" ]] || touch "$f"
  if grep -qE "^[[:space:]]*${k}[[:space:]]*=" "$f"; then
    sed -i -E "s|^[[:space:]]*${k}[[:space:]]*=.*|${k} = ${v}|" "$f"
  elif grep -qE "^[[:space:]]*\[${s}\]" "$f"; then
    sed -i -E "/^[[:space:]]*\[${s}\]/a ${k} = ${v}" "$f"
  else
    printf '\n[%s]\n%s = %s\n' "$s" "$k" "$v" >> "$f"
  fi
}

# ------------------------------------------------------------------ проверки
preflight() {
  [[ $EUID -eq 0 ]] || die "Запусти от root или через sudo"
  [[ -d /run/systemd/system ]] || die "Нужен systemd (контейнеры и WSL без systemd не поддерживаются)"
  if have findmnt && findmnt -no OPTIONS / | tr ',' '\n' | grep -qx ro; then
    die "Корневая ФС только для чтения (immutable-система вроде SLE Micro / Fedora CoreOS) — не поддерживается"
  fi
  if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    die "Некорректный SSH_PORT: $SSH_PORT"
  fi
  [[ "$AUTO_REBOOT_TIME" =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || die "AUTO_REBOOT_TIME должен быть в формате ЧЧ:ММ"
  local p
  for p in $EXTRA_TCP_PORTS $EXTRA_UDP_PORTS; do
    [[ "$p" =~ ^[0-9]+(:[0-9]+)?$ ]] || die "Некорректный порт в EXTRA_*_PORTS: $p"
  done
}

# Определяет семейство ОС и подключает нужный модуль
detect_os() {
  local f="${OS_RELEASE_FILE:-/etc/os-release}"
  [[ -r "$f" ]] || die "Не найден $f — не могу определить дистрибутив"
  local fields
  # Читаем в подоболочке, чтобы переменные os-release не попали в скрипт
  # shellcheck disable=SC1090
  fields=$(. "$f"; printf '%s\n%s\n%s\n%s\n' "${ID:-unknown}" "${ID_LIKE:-}" "${VERSION_ID:-}" "${PRETTY_NAME:-}")
  { read -r OS_ID; read -r OS_LIKE; read -r OS_VER; read -r OS_NAME; } <<< "$fields"
  [[ -n "$OS_NAME" ]] || OS_NAME="$OS_ID"
  OS_MAJOR="${OS_VER%%.*}"

  case "$OS_ID" in
    debian|ubuntu|astra|linuxmint|pop)                         OS_FAMILY=debian ;;
    rhel|centos|rocky|almalinux|ol|fedora|amzn|redos|msvsphere) OS_FAMILY=rhel ;;
    sles|sled|opensuse-leap|opensuse-tumbleweed|opensuse-slowroll|opensuse) OS_FAMILY=suse ;;
    *)
      case " $OS_LIKE " in
        *" debian "*|*" ubuntu "*)            OS_FAMILY=debian ;;
        *" rhel "*|*" fedora "*|*" centos "*) OS_FAMILY=rhel ;;
        *" suse "*|*" sles "*|*" opensuse "*) OS_FAMILY=suse ;;
        *) die "Дистрибутив '$OS_ID' не поддерживается" ;;
      esac
      warn "Дистрибутив '$OS_ID' определён по ID_LIKE как $OS_FAMILY — проверь результат внимательно"
      ;;
  esac

  case "$OS_ID" in
    astra|redos|msvsphere) warn "$OS_NAME на реальных ВМ не тестировался — проверь результат внимательно" ;;
  esac

  "load_${OS_FAMILY}"
}

# Выясняет SSH-ключ: из SSH_PUBKEY или из authorized_keys вызвавшего / root
resolve_pubkey() {
  local src_user src_home
  if [[ -z "$SSH_PUBKEY" ]]; then
    for src_user in "${SUDO_USER:-}" root; do
      [[ -n "$src_user" ]] || continue
      src_home=$(getent passwd "$src_user" | cut -d: -f6)
      if [[ -s "$src_home/.ssh/authorized_keys" ]]; then
        SSH_PUBKEY=$(grep -E '^(ssh-|ecdsa-|sk-)' "$src_home/.ssh/authorized_keys" || true)
        if [[ -n "$SSH_PUBKEY" ]]; then log "Ключи взяты из $src_home/.ssh/authorized_keys"; break; fi
      fi
    done
  fi
  [[ -n "$SSH_PUBKEY" ]] || die "Нет SSH-ключа. Передай SSH_PUBKEY — иначе после отключения паролей войти будет нельзя"

  # Проверяем, что каждый ключ валиден — опечатка здесь = потеря доступа
  if have ssh-keygen; then
    local key n=0
    while IFS= read -r key; do
      [[ -z "$key" ]] && continue
      ssh-keygen -l -f /dev/stdin <<< "$key" >/dev/null 2>&1 || die "Невалидный SSH-ключ: ${key:0:40}..."
      n=$((n + 1))
    done <<< "$SSH_PUBKEY"
    log "Проверено ключей: $n"
  fi
}

report_tools() {
  local t
  for t in ufw firewall-cmd fail2ban-client semanage unattended-upgrade dnf-automatic zypper sudo; do
    if have "$t"; then log "  есть: $t"; fi
  done
  if have dnf && dnf --version 2>/dev/null | head -1 | grep -q dnf5 && rpm -q dnf5-plugin-automatic >/dev/null 2>&1; then
    log "  есть: dnf5-plugin-automatic"
  fi
}

# ------------------------------------------------------------------ время
setup_time() {
  timedatectl set-timezone "$TIMEZONE" 2>/dev/null || warn "Не удалось выставить таймзону $TIMEZONE"
  timedatectl set-ntp true 2>/dev/null || warn "Не удалось включить синхронизацию времени (NTP)"
}

# ------------------------------------------------------------------ SELinux
selinux_enabled() { have getenforce && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; }

# Без метки ssh_port_t sshd не сможет слушать нестандартный порт → потеря доступа
setup_selinux_ssh_port() {
  if ! selinux_enabled; then log "SELinux выключен или отсутствует — пропускаю"; return 0; fi
  if [[ "$SSH_PORT" == "22" ]]; then log "SELinux: порт 22 уже разрешён для sshd"; return 0; fi
  if ! have semanage; then
    [[ "$(getenforce)" == "Enforcing" ]] && die "SELinux в режиме Enforcing, а semanage нет — sshd не сможет слушать порт $SSH_PORT. Установи policycoreutils-python-utils или оставь SSH_PORT=22"
    warn "semanage нет, SELinux в режиме Permissive — пропускаю метку порта"
    return 0
  fi
  if semanage port -l | awk '$1=="ssh_port_t"' | grep -qw "$SSH_PORT"; then
    log "SELinux: порт $SSH_PORT уже помечен как ssh_port_t"
  else
    semanage port -a -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null \
      || semanage port -m -t ssh_port_t -p tcp "$SSH_PORT"
    log "SELinux: порт $SSH_PORT разрешён для sshd"
  fi
}

# ------------------------------------------------------------------ пользователь
# Проверка имени. Печатает причину отказа; код 0 — имя подходит
user_name_problem() {
  local u=$1 uid
  if ! [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "допустимы строчные латинские буквы, цифры, '-' и '_', начинать с буквы или '_', до 32 символов"
    return 1
  fi
  if [[ "$u" == "root" ]]; then echo "root нельзя — смысл скрипта в том, чтобы под root не входить"; return 1; fi
  if getent group "$u" >/dev/null && ! id "$u" &>/dev/null; then
    echo "есть группа с таким именем, но нет такого пользователя — выбери другое имя"; return 1
  fi
  if id "$u" &>/dev/null; then
    uid=$(id -u "$u")
    if (( uid < 1000 )); then echo "это системная учётная запись (UID $uid)"; return 1; fi
  fi
  return 0
}

choose_user() {
  local why ans
  if [[ -n "$NEW_USER" ]]; then
    why=$(user_name_problem "$NEW_USER") || die "Некорректное имя пользователя '$NEW_USER': $why"
  elif [[ -t 0 ]]; then
    while true; do
      read -r -p "Имя пользователя для входа по SSH [${DEFAULT_USER}]: " NEW_USER || NEW_USER=""
      NEW_USER="${NEW_USER:-$DEFAULT_USER}"
      if why=$(user_name_problem "$NEW_USER"); then break; fi
      warn "Имя '$NEW_USER' не подходит: $why"
    done
  else
    NEW_USER="$DEFAULT_USER"
  fi

  # Уже существующий обычный пользователь (например, ubuntu) — переспросим
  # (не спрашиваем при повторном запуске — если пользователя создал сам скрипт)
  if id "$NEW_USER" &>/dev/null && [[ -t 0 ]] \
     && [[ ! -f "/etc/sudoers.d/90-${HARDEN_TAG}-${NEW_USER}" ]]; then
    warn "Пользователь '$NEW_USER' уже существует: ему добавятся sudo и SSH-ключ, а остальные пользователи потеряют вход по SSH"
    read -r -p "Продолжить с '$NEW_USER'? [y/n]: " ans || ans=n
    [[ "$ans" =~ ^(y|Y|д|Д|yes|да)$ ]] || die "Остановлено. Запусти заново и выбери другое имя"
  fi
  log "Пользователь для входа: $NEW_USER"
}

setup_user() {
  if ! id "$NEW_USER" &>/dev/null; then
    log "Создаю пользователя $NEW_USER"
    useradd -m -s /bin/bash "$NEW_USER"
  fi
  if getent group "$SUDO_GROUP" >/dev/null; then usermod -aG "$SUDO_GROUP" "$NEW_USER"; fi

  local home ak key
  home=$(getent passwd "$NEW_USER" | cut -d: -f6)
  install -d -m 700 -o "$NEW_USER" -g "$(id -gn "$NEW_USER")" "$home/.ssh"
  ak="$home/.ssh/authorized_keys"
  touch "$ak"
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    grep -qxF "$key" "$ak" || echo "$key" >> "$ak"
  done <<< "$SSH_PUBKEY"
  chmod 600 "$ak"
  chown "$NEW_USER:$(id -gn "$NEW_USER")" "$ak"
  if have restorecon; then restorecon -R "$home/.ssh" 2>/dev/null || true; fi
  log "SSH-ключи добавлены в $ak"

  # sudo — отдельным файлом. !targetpw нужен на SUSE: там sudo по умолчанию
  # спрашивает пароль root, а root мы заблокируем
  local sf="/etc/sudoers.d/90-${HARDEN_TAG}-${NEW_USER}"
  if [[ "$SUDO_NOPASSWD" == "true" ]]; then
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$NEW_USER" > "$sf"
  else
    printf 'Defaults:%s !targetpw\n%s ALL=(ALL:ALL) ALL\n' "$NEW_USER" "$NEW_USER" > "$sf"
  fi
  chmod 440 "$sf"
  visudo -cf "$sf" >/dev/null || { rm -f "$sf"; die "Ошибка в sudoers-файле"; }
  if [[ -f /etc/sudoers ]] && ! grep -qE '^[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers; then
    cp -a /etc/sudoers /etc/sudoers.bak-hardening
    echo '#includedir /etc/sudoers.d' >> /etc/sudoers
    visudo -c >/dev/null || { cp -a /etc/sudoers.bak-hardening /etc/sudoers; die "Не удалось подключить /etc/sudoers.d"; }
  fi

  # Пароль: нужен для sudo (если не NOPASSWD) и для входа через серийную консоль облака
  local hash
  hash=$(getent shadow "$NEW_USER" | cut -d: -f2)
  if [[ "$SUDO_NOPASSWD" == "true" ]]; then
    # '!' = учётка заблокирована; '*' = пароля нет, но вход по ключу разрешён
    if [[ -z "$hash" || "$hash" == '!'* ]]; then usermod -p '*' "$NEW_USER"; fi
  elif [[ -z "$hash" || "$hash" == '!'* || "$hash" == '*'* ]]; then
    if [[ -t 0 ]]; then
      log "Задай пароль для $NEW_USER (нужен для sudo; по SSH с ним войти будет нельзя):"
      until passwd "$NEW_USER"; do warn "Попробуй ещё раз"; done
    else
      die "Нет TTY для ввода пароля. Запусти через 'ssh -t' или с SUDO_NOPASSWD=true"
    fi
  fi

  # Убеждаемся, что sudo реально работает, ДО блокировки root
  sudo -l -U "$NEW_USER" 2>/dev/null | grep -q '(ALL' \
    || die "У $NEW_USER нет прав sudo — root НЕ заблокирован, разберись вручную"
  log "sudo для $NEW_USER работает"

  passwd -l root >/dev/null 2>&1 && log "Пароль root заблокирован"
}

# ------------------------------------------------------------------ firewall
setup_firewall() {
  if [[ "$FIREWALL" != "true" ]]; then
    warn "FIREWALL=false — firewall на хосте не настраиваю (полагаюсь на облачный)"
    return 0
  fi
  os_firewall
}

ufw_setup() {
  ufw default deny incoming  >/dev/null
  ufw default allow outgoing >/dev/null
  ufw limit "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
  if [[ "$PORT_TRANSITION" == "true" ]]; then
    ufw limit "${OLD_SSH_PORT}/tcp" comment 'SSH old port (temporary, first-boot)' >/dev/null
  fi
  local p
  for p in $EXTRA_TCP_PORTS; do ufw allow "${p}/tcp" >/dev/null; done
  for p in $EXTRA_UDP_PORTS; do ufw allow "${p}/udp" >/dev/null; done
  ufw --force enable >/dev/null
  ufw status verbose
  FIREWALL_KIND=ufw
}

firewalld_setup() {
  local -a fw
  if systemctl is-active --quiet firewalld; then
    fw=(firewall-cmd --permanent)
  else
    fw=(firewall-offline-cmd)   # правила до запуска — чтобы не отрезать SSH
  fi
  "${fw[@]}" --add-port="${SSH_PORT}/tcp" >/dev/null
  if [[ "$PORT_TRANSITION" == "true" ]]; then
    "${fw[@]}" --add-port="${OLD_SSH_PORT}/tcp" >/dev/null   # временно, до подтверждения входа
  elif [[ "$SSH_PORT" != "22" ]]; then
    "${fw[@]}" --remove-service=ssh >/dev/null 2>&1 || true
  fi
  "${fw[@]}" --remove-service=cockpit >/dev/null 2>&1 || true   # веб-консоль RHEL, порт 9090
  local p
  for p in $EXTRA_TCP_PORTS; do "${fw[@]}" --add-port="${p/:/-}/tcp" >/dev/null; done
  for p in $EXTRA_UDP_PORTS; do "${fw[@]}" --add-port="${p/:/-}/udp" >/dev/null; done
  systemctl enable --now firewalld >/dev/null 2>&1
  firewall-cmd --reload >/dev/null
  firewall-cmd --list-all
  FIREWALL_KIND=firewalld
}

# ------------------------------------------------------------------ Fail2Ban
setup_fail2ban() {
  if ! have fail2ban-client; then
    warn "Fail2Ban не установлен — пропускаю (защиту от перебора даст только отключение паролей)"
    return 0
  fi
  local action
  case "$FIREWALL_KIND" in
    ufw)       action=ufw ;;
    firewalld) action=firewallcmd-rich-rules ;;
    *)         if have nft; then action=nftables-multiport; else action=iptables-multiport; fi ;;
  esac
  mkdir -p /etc/fail2ban/jail.d
  cat > /etc/fail2ban/jail.d/00-hardening.local <<EOF
# managed by ${HARDEN_TAG}
[DEFAULT]
bantime  = 1h
bantime.increment = true
bantime.maxtime   = 1w
findtime = 10m
maxretry = 5
banaction = ${action}

[sshd]
enabled = true
port    = ${SSH_PORT}
backend = systemd
EOF
  if ! fail2ban-client -t >/dev/null 2>&1; then
    warn "Конфиг Fail2Ban не прошёл проверку (fail2ban-client -t) — сервис не включаю"
    return 0
  fi
  systemctl enable fail2ban >/dev/null 2>&1
  systemctl restart fail2ban
  log "Fail2Ban включён (banaction: $action)"
}

# ------------------------------------------------------------------ автообновления
setup_auto_updates() {
  if [[ "$AUTO_UPDATES" != "true" ]]; then
    warn "Автообновления выключены (AUTO_UPDATES=$AUTO_UPDATES)"
    return 0
  fi
  os_auto_updates
  if [[ "$AUTO_REBOOT" == "true" && "${NATIVE_REBOOT:-false}" != "true" ]]; then
    setup_reboot_timer
  fi
}

# Таймер: в AUTO_REBOOT_TIME проверить, нужна ли перезагрузка, и перезагрузить
setup_reboot_timer() {
  [[ -n "${REBOOT_CHECK:-}" ]] || { warn "Автоперезагрузка для этой ОС не поддерживается"; return 0; }
  cat > /usr/local/sbin/hardening-reboot-check <<EOF
#!/bin/sh
# managed by ${HARDEN_TAG}: перезагрузка, если её требуют установленные обновления
if ${REBOOT_CHECK}; then
  /usr/sbin/shutdown -r +5 "Reboot required by security updates (${HARDEN_TAG})"
fi
EOF
  chmod 755 /usr/local/sbin/hardening-reboot-check
  cat > /etc/systemd/system/hardening-reboot.service <<EOF
[Unit]
Description=Reboot if required by updates (${HARDEN_TAG})

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hardening-reboot-check
EOF
  cat > /etc/systemd/system/hardening-reboot.timer <<EOF
[Unit]
Description=Daily reboot check (${HARDEN_TAG})

[Timer]
OnCalendar=*-*-* ${AUTO_REBOOT_TIME}:00

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now hardening-reboot.timer >/dev/null 2>&1
  log "Автоперезагрузка при необходимости — ежедневно в ${AUTO_REBOOT_TIME}"
}

# ------------------------------------------------------------------ sysctl
setup_sysctl() {
  # ip_forward НЕ трогаем — он нужен для Docker, Kubernetes и VPN
  cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
# managed by first-boot
# Защита от SYN-flood
net.ipv4.tcp_syncookies = 1
# Анти-спуфинг (2 = loose: совместимо с k8s/VPN; 1 = strict)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
# Не принимать/не отправлять ICMP redirect и source routing
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
# Скрыть адреса ядра и dmesg от непривилегированных
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
# Защита ссылок и core dump у suid-программ
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
EOF
  if sysctl --system >/dev/null 2>&1; then
    log "sysctl применён"
  else
    warn "Часть sysctl-ключей не применилась (проверь: sysctl --system)"
  fi
}

# ------------------------------------------------------------------ SSH
# Оставляет из списка WANT только алгоритмы, которые знает установленный OpenSSH
ssh_pick() {
  local want=$1 type=$2 avail a out=()
  avail=$(ssh -Q "$type" 2>/dev/null) || return 0
  for a in ${want//,/ }; do
    if grep -qxF "$a" <<< "$avail"; then out+=("$a"); fi
  done
  (IFS=,; echo "${out[*]}")
}

ssh_crypto_lines() {
  have ssh || return 0
  local kex ciphers macs
  kex=$(ssh_pick "mlkem768x25519-sha256,sntrup761x25519-sha512,sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org" kex)
  ciphers=$(ssh_pick "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr" cipher)
  macs=$(ssh_pick "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com" mac)
  echo "# Только современная криптография (из того, что поддерживает этот OpenSSH)"
  if [[ -n "$kex" ]]; then echo "KexAlgorithms $kex"; fi
  if [[ -n "$ciphers" ]]; then echo "Ciphers $ciphers"; fi
  if [[ -n "$macs" ]]; then echo "MACs $macs"; fi
}

# На старых системах (RHEL 8, SLES 15) в sshd_config нет Include sshd_config.d
ensure_sshd_include() {
  local main=/etc/ssh/sshd_config
  mkdir -p /etc/ssh/sshd_config.d
  # Нет /etc/ssh/sshd_config (openSUSE Tumbleweed) — работает вендорский
  # /usr/etc/ssh/sshd_config, который сам подключает sshd_config.d
  [[ -f "$main" ]] || return 0
  grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$main" && return 0
  cp -a "$main" "${main}.bak-hardening"
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$main"
  log "В $main добавлен Include sshd_config.d (бэкап: ${main}.bak-hardening)"
}

# Проверяет ИТОГОВЫЕ настройки sshd — то, что реально применится
verify_sshd_effective() {
  local eff bad=0 want
  eff=$(sshd -T 2>/dev/null) || { warn "sshd -T не выполнился"; return 1; }
  for want in "port $SSH_PORT" "permitrootlogin no" "passwordauthentication no" \
              "kbdinteractiveauthentication no" "pubkeyauthentication yes" \
              "allowusers $NEW_USER"; do
    grep -qix "$want" <<< "$eff" || { warn "sshd: ожидалось '$want', но итоговый конфиг другой"; bad=1; }
  done
  local extra
  extra=$(grep -i '^port ' <<< "$eff" | grep -vix "port $SSH_PORT" || true)
  if [[ "$PORT_TRANSITION" == "true" ]]; then
    extra=$(grep -vix "port $OLD_SSH_PORT" <<< "$extra" || true)
  fi
  if [[ -n "$extra" ]]; then warn "sshd будет слушать ещё и: $(echo "$extra" | tr '\n' ' ')— где-то в конфиге есть другой Port"; fi
  return "$bad"
}

setup_ssh() {
  ensure_sshd_include
  local conf=/etc/ssh/sshd_config.d/00-hardening.conf
  # 00- — чтобы наш файл читался первым: в sshd побеждает ПЕРВОЕ значение параметра
  {
    cat <<EOF
# managed by ${HARDEN_TAG}
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers ${NEW_USER}

MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2

X11Forwarding no
AllowAgentForwarding no
PermitUserEnvironment no
EOF
    if [[ "$MANAGE_CRYPTO" == "true" ]]; then
      echo
      ssh_crypto_lines
    else
      echo
      echo "# Алгоритмы шифрования задаёт системная crypto-policy (update-crypto-policies)"
    fi
  } > "$conf"
  chmod 600 "$conf"

  # Старый порт временно остаётся открытым (Port можно указать несколько раз)
  if [[ "$PORT_TRANSITION" == "true" ]]; then
    printf '# managed by %s: старый порт, временно — до подтверждения входа по новому\n# Закрыть: sudo first-boot-close-old-port\nPort %s\n' \
      "$HARDEN_TAG" "$OLD_SSH_PORT" > "$TRANSITION_CONF"
    chmod 600 "$TRANSITION_CONF"
  else
    rm -f "$TRANSITION_CONF"
  fi
  if have restorecon; then restorecon /etc/ssh/sshd_config.d/* 2>/dev/null || true; fi

  mkdir -p /run/sshd
  if ! sshd -t; then
    rm -f "$conf" "$TRANSITION_CONF"
    die "Конфиг sshd невалиден — SSH НЕ перезапущен, текущий доступ сохранён"
  fi
  if ! verify_sshd_effective; then
    rm -f "$conf" "$TRANSITION_CONF"
    die "Итоговые настройки sshd не совпадают с ожидаемыми — SSH НЕ перезапущен. Проверь другие файлы в /etc/ssh/sshd_config.d/ и порядок Include"
  fi

  # Ubuntu 22.10+ использует socket activation — переводим на обычный сервис,
  # иначе смена порта в sshd_config не подхватится
  local u
  for u in ssh.socket sshd.socket; do
    if systemctl is-enabled "$u" &>/dev/null; then
      systemctl disable --now "$u" >/dev/null 2>&1 || true
      log "Отключён socket activation ($u)"
    fi
  done
  systemctl enable "$SSH_SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$SSH_SERVICE"
  sleep 2
  if ! have ss; then
    warn "Нет утилиты ss — не могу проверить, что sshd слушает порт $SSH_PORT"
  elif ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${SSH_PORT}\$"; then
    log "sshd слушает порт $SSH_PORT"
  else
    warn "sshd НЕ слушает порт $SSH_PORT — проверь 'systemctl status $SSH_SERVICE' НЕ закрывая сессию"
  fi
}

# ------------------------------------------------------------------ смена порта
TRANSITION_CONF=/etc/ssh/sshd_config.d/01-first-boot-old-port.conf
CLOSE_HELPER=/usr/local/sbin/first-boot-close-old-port
OLD_SSH_PORT=22
PORT_TRANSITION=false

# Какой порт sshd слушает сейчас и нужно ли держать его открытым при смене
plan_port_switch() {
  local cur
  # Повторный запуск, когда старый порт ещё не закрыт — продолжаем ту же смену
  if [[ -f "$TRANSITION_CONF" ]]; then
    cur=$(awk '$1=="Port"{print $2; exit}' "$TRANSITION_CONF")
    if [[ -n "$cur" && "$cur" != "$SSH_PORT" ]]; then
      OLD_SSH_PORT="$cur"
      PORT_TRANSITION=true
      warn "Запасной порт ${OLD_SSH_PORT} с прошлого запуска ещё открыт — оставляю до подтверждения"
      return 0
    fi
  fi
  cur=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}') || true
  OLD_SSH_PORT="${cur:-22}"
  if [[ "$OLD_SSH_PORT" == "$SSH_PORT" ]]; then
    PORT_TRANSITION=false
    return 0
  fi
  case "$SAFE_PORT_SWITCH" in
    true)  PORT_TRANSITION=true ;;
    false) PORT_TRANSITION=false ;;
    *)     if [[ -t 0 ]]; then PORT_TRANSITION=true; else PORT_TRANSITION=false; fi ;;
  esac

  printf '\n\e[1;33m'
  cat <<EOF
  ┌────────────────────────────────────────────────────────────────────┐
  │  SSH переезжает с порта ${OLD_SSH_PORT} на ${SSH_PORT}.
  │  Открой входящий TCP ${SSH_PORT} в security group облака (если она есть)
  │  — сейчас, пока скрипт работает. Firewall внутри ВМ скрипт настроит сам.
EOF
  if [[ "$PORT_TRANSITION" == "true" ]]; then
    echo "  │  Порт ${OLD_SSH_PORT} останется открытым как запасной, пока ты не"
    echo "  │  подтвердишь вход по новому порту."
  fi
  echo "  └────────────────────────────────────────────────────────────────────┘"
  printf '\e[0m\n'
}

# Скрипт, закрывающий старый порт (запускается сразу или позже вручную)
write_close_helper() {
  {
    echo '#!/bin/sh'
    echo "# managed by ${HARDEN_TAG}: закрыть временный старый порт SSH ${OLD_SSH_PORT}"
    echo 'set -e'
    echo "rm -f ${TRANSITION_CONF}"
    echo 'sshd -t'
    echo "systemctl restart ${SSH_SERVICE}"
    case "$FIREWALL_KIND" in
      ufw)       echo "ufw delete limit ${OLD_SSH_PORT}/tcp >/dev/null 2>&1 || true" ;;
      firewalld) echo "firewall-cmd --permanent --remove-port=${OLD_SSH_PORT}/tcp >/dev/null 2>&1 || true"
                 if [[ "$OLD_SSH_PORT" == "22" ]]; then
                   echo "firewall-cmd --permanent --remove-service=ssh >/dev/null 2>&1 || true"
                 fi
                 echo 'firewall-cmd --reload >/dev/null' ;;
    esac
    echo "echo 'Порт ${OLD_SSH_PORT} закрыт. SSH работает только на порту ${SSH_PORT}.'"
    echo 'rm -f "$0"'
  } > "$CLOSE_HELPER"
  chmod 700 "$CLOSE_HELPER"
}

# Ждём, пока пользователь проверит вход по новому порту
confirm_port_switch() {
  [[ "$PORT_TRANSITION" == "true" ]] || return 0
  write_close_helper
  local ip ans
  ip="${PUBLIC_IP:-<ПУБЛИЧНЫЙ_IP>}"
  if [[ ! -t 0 ]]; then
    warn "Порт ${OLD_SSH_PORT} оставлен открытым. Когда проверишь вход по ${SSH_PORT}: sudo first-boot-close-old-port"
    return 0
  fi
  printf '\n\e[1;36m'
  cat <<EOF
  ┌────────────────────────────────────────────────────────────────────┐
  │  ПРОВЕРЬ ВХОД ПО НОВОМУ ПОРТУ (в новом окне терминала):
  │
  │     ssh -p ${SSH_PORT} ${NEW_USER}@${ip}
  │
  │  Подвисло без ответа — порт ${SSH_PORT} закрыт в security group облака.
  │  Сразу «Permission denied» — проблема с ключом.
  │  Пока не подтвердишь, запасной вход открыт: ssh -p ${OLD_SSH_PORT} ${NEW_USER}@${ip}
  └────────────────────────────────────────────────────────────────────┘
EOF
  printf '\e[0m'
  while true; do
    read -r -p "  Вход по порту ${SSH_PORT} работает? Закрыть порт ${OLD_SSH_PORT}? [y/n]: " ans || ans=n
    case "$ans" in
      y|Y|д|Д|yes|да)
        "$CLOSE_HELPER"
        return 0 ;;
      n|N|н|Н|no|нет)
        warn "Порт ${OLD_SSH_PORT} оставлен открытым. Закрыть позже: sudo first-boot-close-old-port"
        return 0 ;;
    esac
  done
}

# ------------------------------------------------------------------ итог
# Публичный IP: метаданные облака (Yandex Cloud / GCP / AWS), затем внешний сервис
detect_public_ip() {
  local ip="" token="" re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  have curl || return 0
  ip=$(curl -fsS -m 2 -H 'Metadata-Flavor: Google' \
    http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip 2>/dev/null) || ip=""
  if ! [[ "$ip" =~ $re ]]; then
    token=$(curl -fsS -m 2 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
      http://169.254.169.254/latest/api/token 2>/dev/null) || token=""
    ip=$(curl -fsS -m 2 ${token:+-H "X-aws-ec2-metadata-token: $token"} \
      http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null) || ip=""
  fi
  if ! [[ "$ip" =~ $re ]]; then
    ip=$(curl -fsS -m 3 https://api.ipify.org 2>/dev/null) || ip=""
  fi
  if [[ "$ip" =~ $re ]]; then PUBLIC_IP="$ip"; fi
}

summary() {
  local priv
  priv=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo
  log "Готово. Слушающие порты:"
  if have ss; then ss -tulpnH 2>/dev/null | awk '{print "    " $1 "  " $5}' | sort -u || true; fi

  local reboot_msg=""
  if [[ -f /var/run/reboot-required ]] || { [[ -n "${REBOOT_CHECK:-}" ]] && sh -c "$REBOOT_CHECK"; }; then
    reboot_msg="  Обновилось ядро или системные библиотеки — после проверки входа: sudo reboot"
  fi
  local old_msg=""
  if [[ -f "$TRANSITION_CONF" ]]; then
    old_msg="  Запасной порт ${OLD_SSH_PORT} ещё открыт. Закрыть: sudo first-boot-close-old-port"
  fi

  cat <<EOF

=====================================================================
  Вход на сервер:

     ssh -p ${SSH_PORT} ${NEW_USER}@${PUBLIC_IP:-<ПУБЛИЧНЫЙ_IP>}

  Публичный IP:  ${PUBLIC_IP:-не определён — смотри в консоли облака}
  Внутренний IP: ${priv:-?} (доступен только изнутри облачной сети)

  Не пускает и висит — порт ${SSH_PORT} закрыт в security group облака.
${old_msg}
${reboot_msg}
=====================================================================
EOF
}

# ############################################################################
#  МОДУЛЬ: Debian, Ubuntu, Astra Linux и производные
#  (функции определяются только после определения ОС)
# ############################################################################
load_debian() {

SUDO_GROUP=sudo
SSH_SERVICE=ssh
MANAGE_CRYPTO=true
NATIVE_REBOOT=true          # unattended-upgrades перезагружает сам
REBOOT_CHECK='[ -f /var/run/reboot-required ]'

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a   # needrestart: перезапускать сервисы без вопросов

APT_OPTS=(-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

pkg_install() { apt-get "${APT_OPTS[@]}" install "$@"; }

os_prepare() {
  apt-get update -qq
}

os_upgrade() {
  apt-get "${APT_OPTS[@]}" full-upgrade
}

os_install_packages() {
  pkg_install sudo ca-certificates curl openssh-server >/dev/null
  pkg_try ufw fail2ban python3-systemd unattended-upgrades apt-listchanges needrestart
}

os_firewall() {
  if have ufw; then
    ufw_setup
  elif have firewall-cmd; then
    firewalld_setup
  else
    warn "Ни ufw, ни firewalld не установлены — firewall на хосте НЕ настроен, закрой порты в облаке"
  fi
}

os_auto_updates() {
  if ! have unattended-upgrade; then
    warn "unattended-upgrades не установлен — автообновления не настроены"
    return 0
  fi
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  cat > /etc/apt/apt.conf.d/52unattended-upgrades-hardening <<EOF
// managed by ${HARDEN_TAG}
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "${AUTO_REBOOT}";
Unattended-Upgrade::Automatic-Reboot-Time "${AUTO_REBOOT_TIME}";
EOF
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  log "unattended-upgrades включён (security-обновления ставятся ежедневно)"
}
}

# ############################################################################
#  МОДУЛЬ: RHEL, Rocky, AlmaLinux, Oracle Linux, CentOS Stream, Fedora,
#  (функции определяются только после определения ОС)
# ############################################################################
load_rhel() {

SUDO_GROUP=wheel
SSH_SERVICE=sshd
# На RHEL алгоритмы SSH задаются системной crypto-policy. Свой список
# в sshd_config ломает единообразие и может нарушить требования аудита.
MANAGE_CRYPTO=false
NATIVE_REBOOT=false
# needs-restarting -r: код 1 = нужна перезагрузка, 0 = не нужна
REBOOT_CHECK='dnf -q needs-restarting -r >/dev/null 2>&1; [ $? -eq 1 ]'

if dnf --version 2>/dev/null | head -1 | grep -q dnf5; then DNF5=true; else DNF5=false; fi

pkg_install() { dnf -y -q install "$@"; }

os_prepare() {
  dnf -y -q makecache >/dev/null
}

os_upgrade() {
  dnf -y -q upgrade --refresh
}

# EPEL нужен ради fail2ban (в базовых репозиториях RHEL-клонов его нет)
enable_epel() {
  case "$OS_ID" in
    rocky|almalinux|centos|msvsphere)
      pkg_install epel-release || return 1
      if have crb; then crb enable >/dev/null 2>&1 || true; fi   # CodeReady/PowerTools для зависимостей
      ;;
    ol)
      pkg_install "oracle-epel-release-el${OS_MAJOR}" || return 1
      ;;
    rhel)
      if have subscription-manager; then
        subscription-manager repos --enable "codeready-builder-for-rhel-${OS_MAJOR}-$(arch)-rpms" >/dev/null 2>&1 || true
      fi
      pkg_install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_MAJOR}.noarch.rpm" || return 1
      ;;
    *)
      return 1   # Fedora — fail2ban в основном репо; Amazon Linux / RED OS — EPEL не подходит
      ;;
  esac
  log "EPEL подключён"
}

install_fail2ban() {
  # fail2ban-firewalld — действия для firewalld, fail2ban-systemd — чтение журнала
  pkg_install fail2ban-firewalld fail2ban-systemd >/dev/null 2>&1 && return 0
  pkg_install fail2ban >/dev/null 2>&1 && return 0
  return 1
}

os_install_packages() {
  pkg_install sudo ca-certificates openssh-server >/dev/null
  # curl не ставим принудительно: в минимальных образах есть curl-minimal,
  # и установка полного curl упадёт с конфликтом
  have curl || pkg_try curl
  pkg_try firewalld chrony
  if [[ "$DNF5" == "true" ]]; then
    pkg_try dnf5-plugin-automatic dnf5-plugins
  else
    pkg_try dnf-automatic dnf-plugins-core
  fi

  if selinux_enabled; then
    if [[ "$SSH_PORT" != "22" ]]; then
      pkg_install policycoreutils-python-utils >/dev/null 2>&1 \
        || warn "Не удалось установить policycoreutils-python-utils (нужен semanage)"
    else
      pkg_try policycoreutils-python-utils
    fi
  fi

  if install_fail2ban; then
    log "Fail2Ban установлен"
  elif enable_epel && install_fail2ban; then
    log "Fail2Ban установлен из EPEL"
  else
    warn "Fail2Ban недоступен для $OS_NAME — пропускаю"
  fi
  if have fail2ban-client && selinux_enabled; then pkg_try fail2ban-selinux; fi
}

os_firewall() {
  if have firewall-cmd; then
    firewalld_setup
  else
    warn "firewalld не установлен — firewall на хосте НЕ настроен (на Amazon Linux это норма: используй Security Groups)"
  fi
}

os_auto_updates() {
  local conf=/etc/dnf/automatic.conf timer type=security
  # В CentOS Stream нет метаданных security-errata: "security" не поставит ничего
  if [[ "$OS_ID" == "centos" ]]; then
    type=default
    warn "CentOS Stream: нет security-errata — автоматически ставятся ВСЕ обновления"
  fi

  if [[ "$DNF5" == "true" ]]; then
    rpm -q dnf5-plugin-automatic >/dev/null 2>&1 || { warn "dnf5-plugin-automatic не установлен — автообновления не настроены"; return 0; }
    timer=dnf5-automatic.timer
  else
    rpm -q dnf-automatic >/dev/null 2>&1 || { warn "dnf-automatic не установлен — автообновления не настроены"; return 0; }
    timer=dnf-automatic.timer
  fi

  ini_set "$conf" commands upgrade_type "$type"
  ini_set "$conf" commands apply_updates yes
  systemctl enable --now "$timer" >/dev/null 2>&1 \
    || { warn "Не удалось включить $timer"; return 0; }
  log "Автообновления включены ($timer, тип: $type)"
}
}

# ############################################################################
#  МОДУЛЬ: SLES 15, openSUSE Leap 15, openSUSE Tumbleweed / Slowroll
#  (функции определяются только после определения ОС)
# ############################################################################
load_suse() {

SUDO_GROUP=wheel
SSH_SERVICE=sshd
MANAGE_CRYPTO=true
NATIVE_REBOOT=false
# zypper needs-rebooting: код 102 = нужна перезагрузка
REBOOT_CHECK='zypper -q needs-rebooting >/dev/null 2>&1; [ $? -eq 102 ]'

ZYP=(zypper --non-interactive --quiet)

is_rolling() { [[ "$OS_ID" == "opensuse-tumbleweed" || "$OS_ID" == "opensuse-slowroll" ]]; }

pkg_install() { "${ZYP[@]}" install --no-recommends --auto-agree-with-licenses "$@"; }

os_prepare() {
  "${ZYP[@]}" refresh >/dev/null
}

os_upgrade() {
  if is_rolling; then
    "${ZYP[@]}" dup --no-recommends --auto-agree-with-licenses
  else
    "${ZYP[@]}" update --auto-agree-with-licenses
  fi
}

os_install_packages() {
  pkg_install sudo ca-certificates >/dev/null
  have sshd || pkg_install openssh-server >/dev/null || pkg_install openssh >/dev/null
  have curl || pkg_try curl
  pkg_try firewalld chrony fail2ban python3-systemd

  # openSUSE Tumbleweed с 2025 года по умолчанию на SELinux
  if selinux_enabled; then
    if [[ "$SSH_PORT" != "22" ]]; then
      pkg_install policycoreutils-python-utils >/dev/null 2>&1 \
        || warn "Не удалось установить policycoreutils-python-utils (нужен semanage)"
    else
      pkg_try policycoreutils-python-utils
    fi
  fi

  if ! have fail2ban-client && [[ "$OS_ID" == "sles" ]]; then
    warn "На SLES fail2ban лежит в PackageHub. Подключить: SUSEConnect -p PackageHub/${OS_VER}/$(uname -m) и перезапустить скрипт"
  fi
}

os_firewall() {
  if have firewall-cmd; then
    firewalld_setup
  else
    warn "firewalld не установлен — firewall на хосте НЕ настроен, закрой порты в облаке"
  fi
}

os_auto_updates() {
  if is_rolling; then
    warn "Tumbleweed — rolling-релиз без отдельных security-патчей; автообновление (zypper dup) не включаю, обновляй вручную"
    return 0
  fi

  cat > /usr/local/sbin/hardening-security-patch <<'EOF'
#!/bin/sh
# managed by first-boot: установка security-патчей
# Код 103 = обновился сам zypper, нужен повторный запуск
for i in 1 2 3; do
  zypper --non-interactive patch --category security --auto-agree-with-licenses
  rc=$?
  [ "$rc" -eq 103 ] || break
done
# 0 = всё ок, 100/101 = есть/установлены патчи, 102 = нужна перезагрузка
case "$rc" in 0|100|101|102) exit 0 ;; *) exit "$rc" ;; esac
EOF
  chmod 755 /usr/local/sbin/hardening-security-patch

  cat > /etc/systemd/system/hardening-security-patch.service <<EOF
[Unit]
Description=Install security patches (${HARDEN_TAG})
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hardening-security-patch
EOF
  cat > /etc/systemd/system/hardening-security-patch.timer <<EOF
[Unit]
Description=Daily security patches (${HARDEN_TAG})

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=45m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now hardening-security-patch.timer >/dev/null 2>&1
  log "Автоустановка security-патчей: ежедневно ~03:00 (hardening-security-patch.timer)"
}
}

# ############################################################################
#  ЗАПУСК
# ############################################################################
trap 'die "Ошибка на строке $LINENO: $BASH_COMMAND"' ERR

# Тестовый режим для CI: только определить ОС и поставить пакеты (без systemd)
if [[ "${HARDEN_TEST_STAGE:-}" == "packages" ]]; then
  [[ $EUID -eq 0 ]] || die "Нужен root"
  detect_os
  os_prepare
  os_install_packages
  report_tools
  exit 0
fi

preflight
detect_os
choose_user
resolve_pubkey

log "Система: $OS_NAME (семейство: $OS_FAMILY)"

if [[ "$AUTO_UPDATES" == "default" ]]; then
  AUTO_UPDATES=true
  if [[ "$OS_ID" == "astra" ]]; then
    AUTO_UPDATES=false
    warn "Astra Linux: автообновления по умолчанию выключены (в сертифицированных средах обновления ставятся по бюллетеням). Включить: AUTO_UPDATES=true"
  fi
fi

step "1/8 Репозитории и обновление системы"
os_prepare
if [[ "$SKIP_UPGRADE" == "true" ]]; then warn "Полное обновление пропущено (SKIP_UPGRADE=true)"; else os_upgrade; fi

step "2/8 Пакеты"
os_install_packages
report_tools
setup_time
detect_public_ip
plan_port_switch

step "3/8 SELinux"
setup_selinux_ssh_port

step "4/8 Пользователь и sudo"
setup_user

step "5/8 Firewall"
setup_firewall

step "6/8 Fail2Ban"
setup_fail2ban

step "7/8 Автообновления и ядро"
setup_auto_updates
setup_sysctl

step "8/8 SSH"
setup_ssh
confirm_port_switch

summary
