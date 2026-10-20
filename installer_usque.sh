#!/bin/sh
# installer_usque.sh — меню usque-keenetic для Entware (Keenetic / Netcraze)
# Репозиторий: https://github.com/rndnaame/nfqws-menu
#
# 1) Установка usque-keenetic (side-effect-tm opkg)
# 2) Обновление bin usque (Diniboy1123/usque releases)
# 3) Удаление usque-keenetic
#
# Запуск:
#   sh installer_usque.sh
#   curl -fsSL https://raw.githubusercontent.com/rndnaame/nfqws-menu/main/installer_usque.sh | sh

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

PKG_NAME="usque-keenetic"
# per-arch ipk ~4–5 МБ; /all — meta-пакет ~14 МБ со всеми бинарниками
REPO_URL_ALL="https://side-effect-tm.github.io/usque-keenetic/all"
REPO_BASE="https://side-effect-tm.github.io/usque-keenetic"
OPKG_CONF="/opt/etc/opkg/${PKG_NAME}.conf"
INIT_SCRIPT="/opt/etc/init.d/S51usque"
CONF_FILE="/opt/etc/usque/usque.conf"
USQUE_BIN="/opt/usr/bin/usque"
DINIBOY_REPO="Diniboy1123/usque"
TMPDIR="/tmp/usque-installer-$$"

# ---------------------------------------------------------------------------
# Архитектура — логика как в nfqws-menu.sh
# ---------------------------------------------------------------------------
ARCH=""
ARCH_RAW=""
ARCH_SOURCE=""
OS_TITLE=""      # title из RCI, напр. 4.3.6.2 / 5.1.5
OS_MAJOR=""      # major: 4, 5, ...

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

# ARCH меню → суффикс ассета Diniboy (linux_*)
arch_to_diniboy() {
  case "$1" in
    aarch64) echo "arm64" ;;
    mipsel)  echo "mipsle" ;;
    mips)    echo "mips" ;;
    x86_64)  echo "amd64" ;;
    x86)     echo "386" ;;
    *)       echo "" ;;
  esac
}

need_arch() {
  if [ -z "$ARCH" ]; then
    detect_arch
  fi
  if [ -z "$ARCH" ]; then
    error "Архитектура не определена (opkg print-architecture / opkg.conf)."
    error "На Keenetic uname -m для mips/mipsel часто врёт — проверьте /opt/etc/opkg.conf"
    return 1
  fi
  case "$ARCH_SOURCE" in
    opkg) arch_col="$GREEN" ;;
    conf|uname) arch_col="$YELLOW" ;;
    *) arch_col="$DIM" ;;
  esac
  info "Архитектура: ${arch_col}${ARCH}${NC} (источник: $ARCH_SOURCE${ARCH_RAW:+, raw=$ARCH_RAW})"
  return 0
}

# KeeneticOS: RCI show/version → title (4.3.6.2 / 5.1.5)
# usque-keenetic (OpkgTun / NDM) требует OS >= 5.0
detect_os() {
  OS_TITLE=""
  OS_MAJOR=""
  json=""
  if command -v curl >/dev/null 2>&1; then
    json=$(curl -s --connect-timeout 2 --max-time 3 "http://127.0.0.1:79/rci/show/version" 2>/dev/null) || json=""
  fi
  if [ -z "$json" ] && command -v wget >/dev/null 2>&1; then
    json=$(wget -qO- -T 3 "http://127.0.0.1:79/rci/show/version" 2>/dev/null) || json=""
  fi
  if [ -z "$json" ]; then
    return 0
  fi
  OS_TITLE=$(printf '%s' "$json" | sed -n 's/.*"title"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  # title вида 4.3.6.2 / 5.1.5 / 5.0
  OS_MAJOR=$(printf '%s' "$OS_TITLE" | sed -n 's/^\([0-9][0-9]*\).*/\1/p')
}

# 0 = OK (>=5 или неизвестно), 1 = отказ пользователя, 2 = <5 но продолжили
check_os_for_usque() {
  detect_os
  if [ -z "$OS_TITLE" ]; then
    warn "Версия KeeneticOS не определена (RCI недоступен)."
    warn "usque-keenetic рассчитан на OS >= 5.0 (интерфейсы OpkgTun)."
    if ! confirm_yes "Продолжить установку?"; then
      info "Отменено."
      return 1
    fi
    return 0
  fi
  info "KeeneticOS: $OS_TITLE"
  case "$OS_MAJOR" in
    ''|*[!0-9]*)
      warn "Не удалось разобрать major из title «$OS_TITLE»."
      ;;
    *)
      if [ "$OS_MAJOR" -lt 5 ]; then
        echo
        warn "KeeneticOS $OS_TITLE — ниже 5.0."
        warn "Интерфейсы OpkgTun появились только в OS 5.0."
        warn "На 4.x: Cannot create NDM interface OpkgTun* — usque в веб-морде не появится."
        warn "Рекомендуется обновить прошивку до 5.x (если доступна для вашей модели)."
        echo
        if ! confirm_yes "Всё равно установить пакет?"; then
          info "Отменено."
          return 1
        fi
        warn "Продолжаем на свой риск..."
      fi
      ;;
  esac
  return 0
}

is_pkg_installed() {
  if opkg list-installed 2>/dev/null | grep -q "^${PKG_NAME} "; then
    return 0
  fi
  return 1
}

http_get() {
  # http_get URL DEST
  url="$1"
  dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$dest" -T 120 "$url"
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
  # читаем с tty, чтобы работало и через pipe / run_remote_sh
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
# 1) Установка usque-keenetic (side-effect-tm)
# ---------------------------------------------------------------------------
do_install() {
  echo
  info "Установка $PKG_NAME (side-effect-tm)"
  need_arch || return 1
  check_os_for_usque || return 1

  if is_pkg_installed; then
    info "Пакет уже установлен — обновление через opkg..."
  else
    info "Пакет не установлен — установка..."
  fi

  mkdir -p /opt/etc/opkg
  # Сначала per-arch (mipsel/aarch64/mips ~4–5 МБ), fallback на /all (~14 МБ)
  repo_arch="${REPO_BASE}/${ARCH}"
  echo "src/gz ${PKG_NAME} ${repo_arch}" > "$OPKG_CONF"
  info "Репозиторий: ${repo_arch}"
  info "Записан: $OPKG_CONF"

  if ! opkg update; then
    warn "opkg update с /${ARCH} не удался — пробуем /all"
    echo "src/gz ${PKG_NAME} ${REPO_URL_ALL}" > "$OPKG_CONF"
    info "Репозиторий: ${REPO_URL_ALL}"
    if ! opkg update; then
      error "opkg update не удался. Проверьте сеть / DNS / DPI."
      return 1
    fi
  fi

  if is_pkg_installed; then
    if opkg upgrade "$PKG_NAME"; then
      info "Обновление завершено."
    else
      warn "opkg upgrade без изменений (возможно, уже актуальная версия)."
    fi
  else
    if ! opkg install "$PKG_NAME"; then
      error "opkg install $PKG_NAME не удался."
      return 1
    fi
    info "Установка завершена."
  fi

  echo
  printf '%s\n' "${BOLD}Управление сервисом${NC}"
  echo "  $INIT_SCRIPT (start | stop | restart | status)"
  echo
  printf '%s\n' "${BOLD}Конфигурация${NC}"
  echo "  $CONF_FILE"
  echo "  IFACE=\"opkgtun0\"   # вид opkgtun*"
  if [ -x "$USQUE_BIN" ]; then
    info "Бинарник: $USQUE_BIN"
    "$USQUE_BIN" version 2>/dev/null || "$USQUE_BIN" --version 2>/dev/null || true
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 2) Обновление bin (Diniboy1123/usque)
# ---------------------------------------------------------------------------
do_update_bin() {
  echo
  info "Обновление бинарника usque (Diniboy1123/usque)"
  need_arch || return 1

  if [ ! -x "$USQUE_BIN" ] && ! is_pkg_installed; then
    error "usque не установлен. Сначала пункт 1 (установка usque-keenetic)."
    return 1
  fi

  darch=$(arch_to_diniboy "$ARCH")
  if [ -z "$darch" ]; then
    error "Нет готового бинарника Diniboy для ARCH=$ARCH"
    return 1
  fi
  info "Целевой ассет: linux_${darch}"

  # Последний релиз через GitHub API
  info "Запрос latest release..."
  api_json=$(http_get_stdout "https://api.github.com/repos/${DINIBOY_REPO}/releases/latest") || api_json=""
  if [ -z "$api_json" ]; then
    error "Не удалось получить список релизов GitHub."
    return 1
  fi

  tag=$(printf '%s' "$api_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  # version без ведущего v для имени файла: usque_4.2.1_linux_arm64.zip
  ver=$(printf '%s' "$tag" | sed 's/^v//')
  if [ -z "$ver" ]; then
    error "Не удалось разобрать tag_name из API."
    return 1
  fi
  info "Релиз: $tag"

  asset="usque_${ver}_linux_${darch}.zip"
  url=$(printf '%s' "$api_json" | sed -n "s/.*\"browser_download_url\"[[:space:]]*:[[:space:]]*\"\\([^\"]*${asset}\\)\".*/\\1/p" | head -1)
  if [ -z "$url" ]; then
    # fallback прямой URL
    url="https://github.com/${DINIBOY_REPO}/releases/download/${tag}/${asset}"
  fi
  info "Скачивание: $url"

  rm -rf "$TMPDIR"
  mkdir -p "$TMPDIR"
  zipfile="$TMPDIR/$asset"
  if ! http_get "$url" "$zipfile"; then
    error "Скачивание не удалось."
    rm -rf "$TMPDIR"
    return 1
  fi
  sz=$(wc -c < "$zipfile" 2>/dev/null | tr -d ' \t')
  if [ -z "$sz" ] || [ "$sz" -lt 10000 ]; then
    error "Файл слишком маленький (${sz:-0} Б) — возможно, ошибка загрузки."
    rm -rf "$TMPDIR"
    return 1
  fi
  info "Скачано: ${sz} Б"

  # Распаковка (BusyBox unzip не умеет zip flag 8 / streaming)
  extract_ok=0
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import zipfile; zipfile.ZipFile(r'$zipfile').extractall(r'$TMPDIR')" 2>/dev/null; then
      extract_ok=1
      info "Распаковано через python3"
    fi
  fi
  if [ "$extract_ok" != "1" ] && command -v python >/dev/null 2>&1; then
    if python -c "import zipfile; zipfile.ZipFile(r'$zipfile').extractall(r'$TMPDIR')" 2>/dev/null; then
      extract_ok=1
      info "Распаковано через python"
    fi
  fi
  # полный unzip (не symlink на busybox)
  if [ "$extract_ok" != "1" ]; then
    real_unzip=""
    for u in /opt/bin/unzip /usr/bin/unzip unzip; do
      if command -v "$u" >/dev/null 2>&1 || [ -x "$u" ]; then
        # пропускаем busybox-обёртку
        if "$u" -v 2>&1 | grep -qi busybox; then
          continue
        fi
        real_unzip="$u"
        break
      fi
    done
    if [ -n "$real_unzip" ]; then
      if "$real_unzip" -o -q "$zipfile" -d "$TMPDIR" 2>/dev/null; then
        extract_ok=1
        info "Распаковано через $real_unzip"
      fi
    fi
  fi
  # поставить Info-ZIP unzip и повторить
  if [ "$extract_ok" != "1" ]; then
    warn "BusyBox unzip не поддерживает этот архив — ставлю unzip..."
    if opkg update >/dev/null 2>&1 && opkg install unzip >/dev/null 2>&1; then
      if unzip -o -q "$zipfile" -d "$TMPDIR" 2>/dev/null; then
        extract_ok=1
        info "Распаковано через unzip (opkg)"
      fi
    fi
  fi
  if [ "$extract_ok" != "1" ]; then
    error "Не удалось распаковать архив (нужен python3 или unzip: opkg install unzip)."
    rm -rf "$TMPDIR"
    return 1
  fi

  newbin=""
  for c in "$TMPDIR/usque" "$TMPDIR"/*/usque; do
    if [ -f "$c" ]; then
      newbin="$c"
      break
    fi
  done
  if [ -z "$newbin" ] || [ ! -f "$newbin" ]; then
    error "В архиве не найден бинарник usque."
    rm -rf "$TMPDIR"
    return 1
  fi

  # Остановка сервиса перед заменой
  if [ -x "$INIT_SCRIPT" ]; then
    info "Остановка сервиса..."
    "$INIT_SCRIPT" stop 2>/dev/null || true
  fi

  mkdir -p "$(dirname "$USQUE_BIN")"
  if [ -f "$USQUE_BIN" ]; then
    cp -a "$USQUE_BIN" "${USQUE_BIN}.bak" 2>/dev/null || true
    info "Бэкап: ${USQUE_BIN}.bak"
  fi
  cp -f "$newbin" "$USQUE_BIN"
  chmod +x "$USQUE_BIN"
  info "Установлен: $USQUE_BIN ($tag)"

  if [ -x "$USQUE_BIN" ]; then
    "$USQUE_BIN" version 2>/dev/null || "$USQUE_BIN" --version 2>/dev/null || true
  fi

  if [ -x "$INIT_SCRIPT" ]; then
    info "Запуск сервиса..."
    "$INIT_SCRIPT" start 2>/dev/null || warn "Не удалось запустить $INIT_SCRIPT"
  fi

  rm -rf "$TMPDIR"
  info "Бинарник обновлён."
  return 0
}

# ---------------------------------------------------------------------------
# 3) Удаление
# ---------------------------------------------------------------------------
do_remove() {
  echo
  info "Удаление $PKG_NAME"
  if ! is_pkg_installed && [ ! -x "$USQUE_BIN" ] && [ ! -x "$INIT_SCRIPT" ]; then
    warn "Пакет не установлен."
    return 0
  fi

  if ! confirm_yes "Удалить $PKG_NAME?"; then
    info "Отменено."
    return 0
  fi

  # один вопрос про конфиг: ответ уходит и в postrm пакета (Remove config?), и в rm ниже
  remove_conf=0
  if confirm_yes "Также удалить конфиг и сессию (/opt/etc/usque)?"; then
    remove_conf=1
  fi

  if [ -x "$INIT_SCRIPT" ]; then
    "$INIT_SCRIPT" stop 2>/dev/null || true
  fi

  if is_pkg_installed; then
    # postrm пакета делает: echo "Remove config? y/N"; read yn
    if [ "$remove_conf" = "1" ]; then
      printf 'y\n' | opkg remove --autoremove "$PKG_NAME" 2>/dev/null \
        || printf 'y\n' | opkg remove "$PKG_NAME" 2>/dev/null \
        || true
    else
      printf 'N\n' | opkg remove --autoremove "$PKG_NAME" 2>/dev/null \
        || printf 'N\n' | opkg remove "$PKG_NAME" 2>/dev/null \
        || true
    fi
    info "Пакет удалён через opkg."
  fi

  [ -f "$OPKG_CONF" ] && rm -f "$OPKG_CONF" && info "  удалён: $OPKG_CONF"

  if [ "$remove_conf" = "1" ]; then
    if [ -d /opt/etc/usque ]; then
      rm -rf /opt/etc/usque
      info "  удалён каталог: /opt/etc/usque"
    fi
  fi

  # бинарник мог остаться после ручного обновления п.2
  if [ -f "$USQUE_BIN" ] && ! is_pkg_installed; then
    rm -f "$USQUE_BIN" "${USQUE_BIN}.bak" 2>/dev/null || true
    info "  удалён: $USQUE_BIN"
  fi

  info "Готово."
  return 0
}

# ---------------------------------------------------------------------------
# Меню
# ---------------------------------------------------------------------------
# Кэш крайних версий (заполняется один раз за сессию)
LATEST_PKG=""       # usque-keenetic VERSION (0.3.0)
LATEST_PKG_USQUE="" # USQUE_VERSION в пакете (4.2.0)
LATEST_BIN=""       # Diniboy1123/usque tag без v (4.2.1)
LATEST_FETCHED=0

fetch_latest_versions() {
  if [ "$LATEST_FETCHED" = "1" ]; then
    return 0
  fi
  LATEST_FETCHED=1

  # пакет + вшитый usque: raw VERSION / USQUE_VERSION из репозитория
  v=$(http_get_stdout "https://raw.githubusercontent.com/side-effect-tm/usque-keenetic/main/VERSION" 2>/dev/null | tr -d '\r\n' | head -1)
  # отсекаем пустое и HTML-ошибки
  if [ -n "$v" ] && ! printf '%s' "$v" | grep -q '<'; then
    LATEST_PKG="$v"
  fi
  u=$(http_get_stdout "https://raw.githubusercontent.com/side-effect-tm/usque-keenetic/main/USQUE_VERSION" 2>/dev/null | tr -d '\r\n' | head -1)
  if [ -n "$u" ] && ! printf '%s' "$u" | grep -q '<'; then
    LATEST_PKG_USQUE="$u"
  fi

  # latest bin Diniboy
  api=$(http_get_stdout "https://api.github.com/repos/${DINIBOY_REPO}/releases/latest" 2>/dev/null) || api=""
  if [ -n "$api" ]; then
    t=$(printf '%s' "$api" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    t=$(printf '%s' "$t" | sed 's/^v//')
    if [ -n "$t" ]; then
      LATEST_BIN="$t"
    fi
  fi
}

show_status() {
  st=""
  if is_pkg_installed; then
    ver=$(opkg list-installed 2>/dev/null | sed -n "s/^${PKG_NAME} - //p" | head -1)
    st="пакет ${ver:-ok}"
  fi
  if [ -x "$USQUE_BIN" ]; then
    # usque version → "usque version: v4.2.1"
    bin_ver=$("$USQUE_BIN" version 2>/dev/null | sed -n 's/.*version:[[:space:]]*//p' | head -1)
    if [ -z "$bin_ver" ]; then
      bin_ver=$("$USQUE_BIN" --version 2>/dev/null | head -1)
    fi
    if [ -n "$bin_ver" ]; then
      st="${st:+$st, }bin $bin_ver"
    else
      st="${st:+$st, }bin"
    fi
  fi
  if [ -n "$st" ]; then
    info "Обнаружено: $st"
  else
    printf '%s\n' "${DIM}Не установлено${NC}"
  fi
}

# Метка крайних версий для пунктов меню (синий + жирный)
fmt_pkg_latest() {
  if [ -n "$LATEST_PKG" ] && [ -n "$LATEST_PKG_USQUE" ]; then
    printf ' %s%s[ %s / %s ]%s' "$BLUE" "$BOLD" "$LATEST_PKG" "$LATEST_PKG_USQUE" "$NC"
  elif [ -n "$LATEST_PKG" ]; then
    printf ' %s%s[ %s ]%s' "$BLUE" "$BOLD" "$LATEST_PKG" "$NC"
  fi
}

fmt_bin_latest() {
  if [ -n "$LATEST_BIN" ]; then
    printf ' %s%s[%s]%s' "$BLUE" "$BOLD" "$LATEST_BIN" "$NC"
  fi
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    printf '%s\n' "${CYAN}================================================${NC}"
    printf '%s\n' "${CYAN}${BOLD}           usque-keenetic${NC}"
    printf '%s\n' "${CYAN}================================================${NC}"
    echo
    printf '%s\n' "${DIM}Usque — неофициальный клиент Cloudflare WARP с MASQUE:${NC}"
    printf '%s\n' "${DIM}туннель через протокол Cloudflare, интерфейс opkgtun*${NC}"
    printf '%s\n' "${DIM}и маршрутизация по DNS/IP в веб-интерфейсе Keenetic.${NC}"
    echo
    printf '%s\n' "${DIM}пакет: side-effect-tm/usque-keenetic (opkg)${NC}"
    printf '%s\n' "${DIM}bin:   Diniboy1123/usque (GitHub releases)${NC}"
    printf '%s\n' "${DIM}(Entware / Keenetic; aarch64, mipsel, mips)${NC}"
    echo
    show_status
    # крайние версии (тихо, один раз за сессию; при ошибке сети — без меток)
    fetch_latest_versions 2>/dev/null || true
    echo
    printf '  1) Установка (usque-keenetic)%s\n' "$(fmt_pkg_latest)"
    printf '  2) Обновление bin (usque)%s\n' "$(fmt_bin_latest)"
    echo "  3) Удаление usque-keenetic"
    echo "  0) Выход"
    echo
    printf '%s' "${BOLD}Выбор: ${NC}"
    choice=$(read_choice)
    echo
    case "$choice" in
      1) do_install; pause ;;
      2) do_update_bin; pause ;;
      3) do_remove; pause ;;
      0|"") info "Выход."; exit 0 ;;
      *) warn "Неверный пункт"; pause ;;
    esac
  done
}

main_menu
