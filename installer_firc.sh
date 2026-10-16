#!/bin/sh
# installer_firc.sh — меню firc для Entware (Keenetic / Netcraze)
# Пакет: https://github.com/hoaxisr/firc
# Репозиторий opkg: http://repo.hoaxisr.ru/
# Обёртка: https://github.com/rndnaame/nfqws-menu
#
# 1) Установка firc (opkg из repo.hoaxisr.ru)
# 2) Удаление firc
# 3) Диагностика
#
# Запуск:
#   sh installer_firc.sh
#   curl -fsSL https://raw.githubusercontent.com/rndnaame/nfqws-menu/main/installer_firc.sh | sh

# ANSI (portable для ash/BusyBox)
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
CYAN=$(printf '\033[0;36m')
BLUE=$(printf '\033[0;34m')
BOLD=$(printf '\033[1m')
DIM=$(printf '\033[2m')
NC=$(printf '\033[0m')

info()  { printf '%s\n' "${GREEN}[+]${NC} $*"; }
warn()  { printf '%s\n' "${YELLOW}[!]${NC} $*"; }
error() { printf '%s\n' "${RED}[!]${NC} $*"; }

PKG_NAME="firc"
REPO_BASE="http://repo.hoaxisr.ru"
# https fallback, если HTTP режут
REPO_BASE_HTTPS="https://repo.hoaxisr.ru"
# как в https://repo.hoaxisr.ru/ — общий фид hoaxisr (firc, awg-manager, …)
OPKG_CONF="/opt/etc/opkg/awg_manager.conf"
OPKG_FEED_NAME="hoaxisr"
INIT_SCRIPT="/opt/etc/init.d/S99firc"
CONF_DIR="/opt/etc/firc"
GITHUB_REPO="hoaxisr/firc"

# ---------------------------------------------------------------------------
# Архитектура — как в nfqws-menu.sh / installer_usque.sh
# ---------------------------------------------------------------------------
ARCH=""
ARCH_RAW=""
ARCH_SOURCE=""

_arch_normalize() {
  case "$1" in
    aarch64*|arm64*)                    echo "aarch64" ;;
    armv7*|armv6*|arm*)                 echo "" ;;
    mipsel*|mipselsf*|mips64el*)        echo "mipsel" ;;
    mips*|mipssf*)                      echo "mips" ;;
    x86_64*|amd64*|x64*)                echo "x86_64" ;;
    i[3-6]86*|x86*|i686*)               echo "x86" ;;
    *)                                  echo "" ;;
  esac
}

_arch_pick_best() {
  awk '
    $1 == "arch" && $2 != "" && $2 != "all" {
      p = $3 + 0
      n = $2
      bonus = 0
      if (n ~ /^mipsel/ || n ~ /^mipselsf/ || n ~ /^mips64el/) bonus = 2
      else if (n ~ /^aarch64/ || n ~ /^arm64/) bonus = 2
      score = p * 10 + bonus
      if (score > best) { best = score; name = n }
    }
    END { if (name != "") print name }
  '
}

_arch_from_opkg() {
  opkg print-architecture 2>/dev/null | _arch_pick_best
}

_arch_from_opkg_conf() {
  conf="${1:-/opt/etc/opkg.conf}"
  [ -f "$conf" ] || return 0

  name=$(grep -E '^[[:space:]]*arch[[:space:]]+' "$conf" 2>/dev/null | _arch_pick_best)
  if [ -n "$name" ]; then
    printf '%s\n' "$name"
    return 0
  fi

  from_url=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      src/gz*|src\ *)
        case "$line" in
          *mipselsf*|*mips64el*) from_url="mipselsf"; break ;;
          *mipssf*)              from_url="mipssf"; break ;;
          *aarch64*|*arm64*)     from_url="aarch64"; break ;;
          */x64*|*x86_64*)       from_url="x86_64"; break ;;
          */x86*|*i386*)         from_url="x86"; break ;;
        esac
        ;;
    esac
  done < "$conf"
  if [ -n "$from_url" ]; then
    printf '%s\n' "$from_url"
  fi
}

detect_arch() {
  um=""
  cand=""
  ARCH=""
  ARCH_RAW=""
  ARCH_SOURCE=""

  ARCH_RAW=$(_arch_from_opkg)
  ARCH=$(_arch_normalize "$ARCH_RAW")
  if [ -n "$ARCH" ]; then
    ARCH_SOURCE="opkg"
  fi

  if [ -z "$ARCH" ]; then
    ARCH_RAW=$(_arch_from_opkg_conf /opt/etc/opkg.conf)
    ARCH=$(_arch_normalize "$ARCH_RAW")
    if [ -n "$ARCH" ]; then
      ARCH_SOURCE="conf"
    fi
  fi

  if [ -z "$ARCH" ]; then
    um=$(uname -m 2>/dev/null)
    case "$um" in
      mips|mipsel|mips64|mips64el|"") ;;
      *)
        cand=$(_arch_normalize "$um")
        if [ -n "$cand" ]; then
          ARCH="$cand"
          ARCH_RAW="$um"
          ARCH_SOURCE="uname"
        fi
        ;;
    esac
  fi

  if [ -z "$ARCH_SOURCE" ]; then
    ARCH_SOURCE="none"
  fi
}

# ARCH → путь в repo.hoaxisr.ru (aarch64-k3.10 | mipsel-k3.4 | mips-k3.4)
arch_to_repo_path() {
  case "$1" in
    aarch64) echo "aarch64-k3.10" ;;
    mipsel)  echo "mipsel-k3.4" ;;
    mips)    echo "mips-k3.4" ;;
    *)       echo "" ;;
  esac
}

need_arch() {
  if [ -z "$ARCH" ]; then
    detect_arch
  fi
  if [ -z "$ARCH" ]; then
    error "Не удалось определить архитектуру (нужны aarch64 / mipsel / mips)."
    return 1
  fi
  case "$ARCH" in
    aarch64|mipsel|mips) ;;
    *)
      error "Архитектура $ARCH не поддерживается firc (только aarch64, mipsel, mips)."
      return 1
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Вспомогательные
# ---------------------------------------------------------------------------
is_pkg_installed() {
  if opkg list-installed 2>/dev/null | grep -q "^${PKG_NAME} "; then
    return 0
  fi
  return 1
}

installed_version() {
  opkg list-installed 2>/dev/null | sed -n "s/^${PKG_NAME} - //p" | head -1
}

http_get_stdout() {
  url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 30 "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O- -T 30 "$url"
  else
    return 1
  fi
}

read_choice() {
  if [ -c /dev/tty ]; then
    read -r choice < /dev/tty
  else
    read -r choice
  fi
  printf '%s' "$choice"
}

confirm_yes() {
  printf '%s' "${YELLOW}[?]${NC} $1 [y/N]: "
  c=$(read_choice)
  case "$c" in
    y|Y|yes|YES|д|Д|да|Да) return 0 ;;
    *) return 1 ;;
  esac
}

pause() {
  printf '%s' "${DIM}Нажмите Enter...${NC} "
  read_choice >/dev/null
}

# ---------------------------------------------------------------------------
# Версия из Packages репозитория
# ---------------------------------------------------------------------------
LATEST_TAG=""

fetch_latest() {
  LATEST_TAG=""
  need_arch 2>/dev/null || true
  [ -n "$ARCH" ] || return 0
  path=$(arch_to_repo_path "$ARCH")
  [ -n "$path" ] || return 0

  for base in "$REPO_BASE" "$REPO_BASE_HTTPS"; do
    pkg=$(http_get_stdout "${base}/${path}/Packages" 2>/dev/null) || pkg=""
    if [ -z "$pkg" ]; then
      # иногда отдают Packages.gz
      if command -v curl >/dev/null 2>&1; then
        pkg=$(curl -fsSL --connect-timeout 10 --max-time 30 "${base}/${path}/Packages.gz" 2>/dev/null | gzip -dc 2>/dev/null) || pkg=""
      fi
    fi
    ver=$(printf '%s\n' "$pkg" | awk '
      $1=="Package:" && $2=="firc" {inpkg=1; next}
      inpkg && $1=="Version:" {print $2; exit}
      inpkg && $1=="Package:" {exit}
    ')
    if [ -n "$ver" ]; then
      LATEST_TAG="$ver"
      return 0
    fi
  done
}

fmt_latest() {
  if [ -n "$LATEST_TAG" ]; then
    printf ' %s%s[ %s ]%s' "$BLUE" "$BOLD" "$LATEST_TAG" "$NC"
  fi
}

show_status() {
  if is_pkg_installed; then
    ver=$(installed_version)
    info "Установлено: ${PKG_NAME} ${ver:-ok}"
    if [ -x "$INIT_SCRIPT" ]; then
      if "$INIT_SCRIPT" status >/dev/null 2>&1; then
        printf '%s\n' "  ${DIM}сервис: ${INIT_SCRIPT} (status ok)${NC}"
      else
        printf '%s\n' "  ${DIM}сервис: ${INIT_SCRIPT}${NC}"
      fi
    fi
  else
    printf '%s\n' "${DIM}Не установлено${NC}"
  fi
}

# Старые NDMS 2.x / Keenetic II — firc не рассчитан
warn_old_platform() {
  ver=""
  if command -v ndmc >/dev/null 2>&1; then
    ver=$(ndmc -c show version 2>/dev/null | head -5)
  fi
  kver=$(uname -r 2>/dev/null || true)
  model=$(cat /proc/device-tree/model 2>/dev/null || true)
  [ -z "$model" ] && model=$(grep -i 'machine\|Hardware' /proc/cpuinfo 2>/dev/null | head -1)

  old=0
  case "$kver" in
    2.*|3.0*|3.1*|3.2*|3.3*) old=1 ;;
  esac
  case "$model" in
    *kn_rb*|*KN-RB*|*Keenetic_II*|*KeeneticII*) old=1 ;;
  esac
  echo "$ver $model $kver" | grep -qiE 'kn_rb|keenetic.?ii|ndms[[:space:]]*2\.|release.*2\.(0|1[0-6])' && old=1

  if [ "$old" = 1 ]; then
    echo
    warn "Похоже на старую платформу (ядро ${kver:-?}; NDMS 2.x / Keenetic II / kn_rb)."
    warn "firc (_kn) рассчитан на KeeneticOS 3+/4+/5+ + Entware (ядро ≥ 3.4, netfilter.d, RCI)."
    warn "На NDMS 2.16 демон обычно не стартует — ограничение платформы."
    echo
  fi
}

diagnose_firc() {
  echo
  printf '%s\n' "${BOLD}Диагностика firc${NC}"
  warn_old_platform

  if [ -x /opt/bin/fircd ]; then
    info "Бинарник: /opt/bin/fircd"
  else
    error "Нет /opt/bin/fircd — пакет не распакован."
    return 1
  fi

  if command -v ldd >/dev/null 2>&1; then
    miss=$(ldd /opt/bin/fircd 2>/dev/null | grep -i 'not found' || true)
    if [ -n "$miss" ]; then
      error "Не хватает библиотек:"
      printf '%s\n' "$miss"
    else
      info "ldd: все библиотеки найдены."
    fi
  fi

  if ! command -v socat >/dev/null 2>&1; then
    error "socat не найден (Depends пакета)."
  else
    info "socat: $(command -v socat)"
  fi

  [ -f /opt/etc/firc/firc.conf ] && info "Конфиг: /opt/etc/firc/firc.conf" || error "Нет firc.conf"
  [ -f /opt/etc/firc/groups.yaml ] && info "Группы: /opt/etc/firc/groups.yaml" || warn "Нет groups.yaml"

  echo
  printf '%s\n' "${DIM}logread | grep -i firc${NC}"
  echo "  /opt/etc/init.d/S99firc restart"
  echo "  /opt/etc/init.d/S99firc status"
  return 0
}

# Прописать src/gz hoaxisr URL в awg_manager.conf (не затирая прочие строки)
ensure_hoaxisr_repo() {
  repo_url="$1"
  mkdir -p /opt/etc/opkg
  line="src/gz ${OPKG_FEED_NAME} ${repo_url}"

  if [ -f "$OPKG_CONF" ]; then
    # обновить существующую строку src/gz hoaxisr или дописать
    tmp="${OPKG_CONF}.$$"
    awk -v feed="$OPKG_FEED_NAME" -v newline="$line" '
      BEGIN { done = 0 }
      $1 == "src/gz" && $2 == feed {
        if (!done) { print newline; done = 1 }
        next
      }
      { print }
      END { if (!done) print newline }
    ' "$OPKG_CONF" > "$tmp" && mv "$tmp" "$OPKG_CONF"
  else
    printf '%s\n' "$line" > "$OPKG_CONF"
  fi
  info "Репозиторий: $repo_url"
  info "Записан: $OPKG_CONF ($line)"
}

# ---------------------------------------------------------------------------
# 1) Установка через opkg-репозиторий repo.hoaxisr.ru
#    src/gz hoaxisr → /opt/etc/opkg/awg_manager.conf (как на сайте репо)
# ---------------------------------------------------------------------------
do_install() {
  echo
  info "Установка $PKG_NAME (repo.hoaxisr.ru)"
  need_arch || return 1
  warn_old_platform

  path=$(arch_to_repo_path "$ARCH")
  if [ -z "$path" ]; then
    error "Нет фида для ARCH=$ARCH."
    return 1
  fi

  repo_url="${REPO_BASE}/${path}"
  ensure_hoaxisr_repo "$repo_url"

  if ! opkg update; then
    warn "opkg update по HTTP не удался — пробуем HTTPS..."
    repo_url="${REPO_BASE_HTTPS}/${path}"
    ensure_hoaxisr_repo "$repo_url"
    if ! opkg update; then
      error "opkg update не удался. Проверьте сеть / DNS / DPI."
      return 1
    fi
  fi

  # Conflicts: отдельный пакет tunvless
  if opkg list-installed 2>/dev/null | grep -q '^tunvless '; then
    warn "Пакет tunvless конфликтует с firc — удаляем..."
    opkg remove tunvless 2>/dev/null || true
  fi

  install_rc=0
  if is_pkg_installed; then
    info "Пакет уже установлен — обновление..."
    opkg upgrade "$PKG_NAME" || opkg install "$PKG_NAME" || install_rc=$?
  else
    info "opkg install $PKG_NAME"
    opkg install "$PKG_NAME" || install_rc=$?
  fi

  # postinst стартует демон; на несовместимой прошивке → exit 1
  if [ "$install_rc" -ne 0 ]; then
    warn "opkg install/upgrade код $install_rc (часто postinst: демон не стартовал)."
    if [ -x /opt/bin/fircd ]; then
      diagnose_firc
      error "Файлы на месте, но демон не запустился."
      return 1
    fi
    error "opkg install $PKG_NAME не удался."
    return 1
  fi

  info "Установка завершена: $(installed_version)"

  echo
  printf '%s\n' "${BOLD}Управление${NC}"
  echo "  $INIT_SCRIPT  (start | stop | restart | status)"
  echo "  WebUI: http://<IP-роутера>:666  (логин — системный account)"
  printf '%s\n' "${DIM}Репозиторий: ${repo_url}${NC}"
  printf '%s\n' "${DIM}Документация: https://github.com/${GITHUB_REPO}${NC}"
  return 0
}

# ---------------------------------------------------------------------------
# 2) Удаление
# ---------------------------------------------------------------------------
do_remove() {
  echo
  info "Удаление $PKG_NAME"
  if ! is_pkg_installed && [ ! -x "$INIT_SCRIPT" ] && [ ! -d "$CONF_DIR" ]; then
    warn "Пакет не установлен."
    return 0
  fi

  if ! confirm_yes "Удалить $PKG_NAME?"; then
    info "Отменено."
    return 0
  fi

  remove_conf=0
  if [ -d "$CONF_DIR" ]; then
    if confirm_yes "Также удалить конфиг ($CONF_DIR)?"; then
      remove_conf=1
    fi
  fi

  if [ -x "$INIT_SCRIPT" ]; then
    "$INIT_SCRIPT" stop 2>/dev/null || true
  fi

  if is_pkg_installed; then
    opkg remove --autoremove "$PKG_NAME" 2>/dev/null \
      || opkg remove "$PKG_NAME" 2>/dev/null \
      || true
    info "Пакет удалён через opkg."
  fi

  # awg_manager.conf общий с awg-manager — не удаляем файл целиком

  if [ "$remove_conf" = "1" ] && [ -d "$CONF_DIR" ]; then
    rm -rf "$CONF_DIR"
    info "  удалён каталог: $CONF_DIR"
  fi

  if [ -f "$INIT_SCRIPT" ] && ! is_pkg_installed; then
    rm -f "$INIT_SCRIPT"
    info "  удалён: $INIT_SCRIPT"
  fi

  info "Готово."
  return 0
}

# ---------------------------------------------------------------------------
# Меню
# ---------------------------------------------------------------------------
main_menu() {
  while true; do
    clear 2>/dev/null || true
    printf '%s\n' "${CYAN}================================================${NC}"
    printf '%s\n' "${CYAN}${BOLD}                    firc${NC}"
    printf '%s\n' "${CYAN}================================================${NC}"
    echo
    printf '%s\n' "${DIM}firc — утилита для точечной маршрутизации трафика${NC}"
    printf '%s\n' "${DIM}по доменным именам (FakeIP) на Keenetic / Entware.${NC}"
    printf '%s\n' "${DIM}Заворачивает нужные домены в выбранный интерфейс${NC}"
    printf '%s\n' "${DIM}(VPN / туннель), не трогая остальной трафик.${NC}"
    echo
    printf '%s\n' "${DIM}пакет: src/gz hoaxisr → repo.hoaxisr.ru (opkg)${NC}"
    printf '%s\n' "${DIM}(KeeneticOS 4+/5+; aarch64, mipsel, mips)${NC}"
    echo
    show_status
    fetch_latest 2>/dev/null || true
    echo
    printf '  1) Установка firc%s\n' "$(fmt_latest)"
    echo "  2) Удаление firc"
    echo "  3) Диагностика (почему не стартует)"
    echo "  0) Выход"
    echo
    printf '%s' "${BOLD}Выбор: ${NC}"
    choice=$(read_choice)
    echo
    case "$choice" in
      1) do_install; pause ;;
      2) do_remove; pause ;;
      3) diagnose_firc; pause ;;
      0|"") info "Выход."; exit 0 ;;
      *) warn "Неверный пункт"; pause ;;
    esac
  done
}

main_menu
