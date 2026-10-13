#!/bin/sh
# installer_firc.sh — меню firc для Entware (Keenetic / Netcraze)
# Репозиторий пакета: https://github.com/hoaxisr/firc
# Обёртка: https://github.com/rndnaame/nfqws-menu
#
# 1) Установка firc (ipk с GitHub Releases)
# 2) Удаление firc
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
GITHUB_REPO="hoaxisr/firc"
INIT_SCRIPT="/opt/etc/init.d/S99firc"
CONF_DIR="/opt/etc/firc"
TMPDIR="/tmp/firc-installer-$$"

# ---------------------------------------------------------------------------
# Архитектура — логика как в nfqws-menu.sh / installer_usque.sh
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

# ARCH меню → суффикс ipk (entware_*_kn)
arch_to_ipk_suffix() {
  case "$1" in
    aarch64) echo "aarch64-3.10" ;;
    mipsel)  echo "mipsel-3.4" ;;
    mips)    echo "mips-3.4" ;;
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

http_get() {
  # http_get URL DEST
  url="$1"
  dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 180 "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$dest" -T 180 "$url"
  else
    error "Нужны curl или wget."
    return 1
  fi
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
# Версии с GitHub Releases
# ---------------------------------------------------------------------------
LATEST_TAG=""   # 0.3.0
LATEST_IPK=""   # firc_0.3.0-1_entware_..._kn.ipk (имя ассета)

fetch_latest() {
  LATEST_TAG=""
  LATEST_IPK=""
  need_arch 2>/dev/null || true
  [ -n "$ARCH" ] || return 0

  suffix=$(arch_to_ipk_suffix "$ARCH")
  [ -n "$suffix" ] || return 0

  # 1) redirect releases/latest → tag
  tag=""
  if command -v curl >/dev/null 2>&1; then
    tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
      "https://github.com/${GITHUB_REPO}/releases/latest" 2>/dev/null \
      | sed 's|.*/||' | tr -d '\r\n')
  fi
  if [ -z "$tag" ] || [ "$tag" = "latest" ]; then
    # 2) HTML releases page
    page=$(http_get_stdout "https://github.com/${GITHUB_REPO}/releases" 2>/dev/null) || page=""
    tag=$(printf '%s' "$page" | sed -n 's|.*href="/'"${GITHUB_REPO}"'/releases/tag/\([^"]*\)".*|\1|p' | head -1)
  fi
  tag=$(printf '%s' "$tag" | sed 's/^v//')
  [ -n "$tag" ] || return 0
  LATEST_TAG="$tag"

  # имя ассета: firc_<tag>-N_entware_<suffix>_kn.ipk (ревизия обычно 1)
  # пробуем -1; если expanded_assets доступен — уточняем
  assets=$(http_get_stdout "https://github.com/${GITHUB_REPO}/releases/expanded_assets/${tag}" 2>/dev/null) || assets=""
  name=$(printf '%s' "$assets" | sed -n "s|.*\(firc_${tag}-[0-9]*_entware_${suffix}_kn\.ipk\).*|\1|p" | head -1)
  if [ -z "$name" ]; then
    name="firc_${tag}-1_entware_${suffix}_kn.ipk"
  fi
  LATEST_IPK="$name"
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

# ---------------------------------------------------------------------------
# 1) Установка
# ---------------------------------------------------------------------------
do_install() {
  echo
  info "Установка $PKG_NAME (GitHub Releases)"
  need_arch || return 1

  suffix=$(arch_to_ipk_suffix "$ARCH")
  if [ -z "$suffix" ]; then
    error "Нет ipk для ARCH=$ARCH."
    return 1
  fi

  fetch_latest
  if [ -z "$LATEST_TAG" ] || [ -z "$LATEST_IPK" ]; then
    error "Не удалось определить последнюю версию на GitHub."
    return 1
  fi

  url="https://github.com/${GITHUB_REPO}/releases/download/${LATEST_TAG}/${LATEST_IPK}"
  info "ARCH=$ARCH ($ARCH_SOURCE) → $LATEST_IPK"
  info "URL: $url"

  mkdir -p "$TMPDIR"
  ipk="$TMPDIR/$LATEST_IPK"
  if ! http_get "$url" "$ipk"; then
    error "Скачивание не удалось."
    rm -rf "$TMPDIR"
    return 1
  fi

  sz=$(wc -c < "$ipk" 2>/dev/null | tr -d ' ')
  if [ -z "$sz" ] || [ "$sz" -lt 10000 ]; then
    error "Файл слишком маленький (${sz:-0} байт) — возможно, обрыв или 404."
    rm -rf "$TMPDIR"
    return 1
  fi
  info "Скачано: $sz байт"

  # зависимости (README: socat)
  if ! opkg list-installed 2>/dev/null | grep -q '^socat '; then
    info "Установка зависимости socat..."
    opkg update 2>/dev/null || true
    opkg install socat 2>/dev/null || warn "socat не установлен (пакет может потребовать его)."
  fi

  if is_pkg_installed; then
    info "Пакет уже установлен — переустановка..."
    if ! opkg install --force-reinstall "$ipk"; then
      # fallback без force
      if ! opkg install "$ipk"; then
        error "opkg install не удался."
        rm -rf "$TMPDIR"
        return 1
      fi
    fi
  else
    if ! opkg install "$ipk"; then
      error "opkg install не удался."
      rm -rf "$TMPDIR"
      return 1
    fi
  fi

  rm -rf "$TMPDIR"
  info "Установка завершена: $(installed_version)"

  if [ -x "$INIT_SCRIPT" ]; then
    info "Запуск сервиса..."
    "$INIT_SCRIPT" start 2>/dev/null || "$INIT_SCRIPT" restart 2>/dev/null || \
      warn "Не удалось запустить $INIT_SCRIPT"
  fi

  echo
  printf '%s\n' "${BOLD}Управление${NC}"
  echo "  $INIT_SCRIPT  (start | stop | restart | status)"
  echo "  WebUI: обычно порт 666 (см. настройки после первого запуска)"
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

  if [ "$remove_conf" = "1" ] && [ -d "$CONF_DIR" ]; then
    rm -rf "$CONF_DIR"
    info "  удалён каталог: $CONF_DIR"
  fi

  # init мог остаться
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
    printf '%s\n' "${DIM}пакет: hoaxisr/firc (GitHub Releases, ipk)${NC}"
    printf '%s\n' "${DIM}(Entware / Keenetic; aarch64, mipsel, mips)${NC}"
    echo
    show_status
    fetch_latest 2>/dev/null || true
    echo
    printf '  1) Установка firc%s\n' "$(fmt_latest)"
    echo "  2) Удаление firc"
    echo "  0) Выход"
    echo
    printf '%s' "${BOLD}Выбор: ${NC}"
    choice=$(read_choice)
    echo
    case "$choice" in
      1) do_install; pause ;;
      2) do_remove; pause ;;
      0|"") info "Выход."; exit 0 ;;
      *) warn "Неверный пункт"; pause ;;
    esac
  done
}

main_menu
