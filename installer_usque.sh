#!/bin/sh
# installer_usque.sh — меню usque-keenetic для Entware (Keenetic / Netcraze)
# Репозиторий: https://github.com/rndnaame/nfqws-menu
#
# 1) Установка usque-keenetic (side-effect-tm opkg)
# 2) Обновление bin usque (Diniboy1123/usque releases)
# 3) Проверка интерфейса (сервис + google/telegram через IFACE)
# 88) Удаление usque-keenetic
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
SESSION_FILE="/opt/etc/usque/session.conf"
CF_API_HOST="api.cloudflareclient.com"
# CDN IP, на котором обычно проходит TLS (8.6/8.47 часто RST при DPI)
CF_API_IP="104.16.24.84"
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

# Свободное место на /opt (КБ). ipk per-arch ~4.5–5 МБ + tmp opkg → желательно ≥12 МБ
check_opt_space() {
  min_kb="${1:-12288}"
  avail=""
  # df -k: колонка Available (часто 4-я)
  avail=$(df -k /opt 2>/dev/null | awk 'NR==2 {print $4}')
  case "$avail" in
    ''|*[!0-9]*) 
      avail=$(df -k /opt 2>/dev/null | awk 'NR==2 {print $(NF-2)}')
      ;;
  esac
  case "$avail" in
    ''|*[!0-9]*)
      warn "Не удалось определить свободное место на /opt."
      return 0
      ;;
  esac
  # человекочитаемо
  if [ "$avail" -ge 1024 ]; then
    human="$((avail / 1024))M"
  else
    human="${avail}K"
  fi
  info "Свободно на /opt: $human"
  if [ "$avail" -lt "$min_kb" ]; then
    echo
    error "Мало места на /opt (нужно ≥$((min_kb / 1024)) МБ, есть $human)."
    error "ipk usque-keenetic ~5 МБ + временные файлы opkg."
    error "Освободите место, иначе бинарник будет битым (segfault при register)."
    echo
    printf '%s\n' "${DIM}Подсказка: df -h /opt ; du -sh /opt/* 2>/dev/null | sort -hr | head${NC}"
    if ! confirm_yes "Всё равно продолжить?"; then
      info "Отменено."
      return 1
    fi
    warn "Продолжаем на свой риск..."
  fi
  return 0
}

is_pkg_installed() {
  if opkg list-installed 2>/dev/null | grep -q "^${PKG_NAME} "; then
    return 0
  fi
  return 1
}

# Зеркала GitHub (как в nfqws-menu): оригинал → ghproxy / jsdelivr
github_alt_urls() {
  url="$1"
  case "$url" in
    https://github.com/*/releases/download/*)
      printf '%s\n' "$url"
      printf '%s\n' "https://ghproxy.net/${url}"
      printf '%s\n' "https://mirror.ghproxy.com/${url}"
      printf '%s\n' "https://gh.ddlc.top/${url}"
      printf '%s\n' "https://gitproxy.click/${url}"
      ;;
    https://api.github.com/*)
      printf '%s\n' "$url"
      printf '%s\n' "https://ghproxy.net/${url}"
      printf '%s\n' "https://mirror.ghproxy.com/${url}"
      ;;
    https://raw.githubusercontent.com/*)
      rest="${url#https://raw.githubusercontent.com/}"
      owner="${rest%%/*}"; rest="${rest#*/}"
      repo="${rest%%/*}"; rest="${rest#*/}"
      ref="${rest%%/*}"; path_rest="${rest#*/}"
      printf '%s\n' "$url"
      if [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$ref" ]; then
        printf '%s\n' "https://fastly.jsdelivr.net/gh/${owner}/${repo}@${ref}/${path_rest}"
        printf '%s\n' "https://cdn.jsdelivr.net/gh/${owner}/${repo}@${ref}/${path_rest}"
      fi
      printf '%s\n' "https://ghproxy.net/${url}"
      ;;
    *)
      printf '%s\n' "$url"
      ;;
  esac
}

_http_get_one() {
  # _http_get_one URL DEST (stderr глушим — иначе curl: (35) путает вывод)
  u="$1"
  d="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 180 "$u" -o "$d" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$d" -T 180 "$u" 2>/dev/null
  else
    return 1
  fi
}

http_get() {
  # http_get URL DEST — с перебором зеркал
  url="$1"
  dest="$2"
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    error "Нужны curl или wget."
    return 1
  fi
  rm -f "$dest"
  github_alt_urls "$url" | while IFS= read -r alt || [ -n "$alt" ]; do
    [ -n "$alt" ] || continue
    info "Пробуем: $alt"
    if _http_get_one "$alt" "$dest" && [ -s "$dest" ]; then
      [ "$alt" != "$url" ] && info "Скачано через зеркало"
      # while в пайпе — нельзя return наружу; маркер успеха
      echo OK > "${dest}.ok"
      break
    fi
    rm -f "$dest"
  done
  if [ -f "${dest}.ok" ] && [ -s "$dest" ]; then
    rm -f "${dest}.ok"
    return 0
  fi
  rm -f "${dest}.ok" "$dest"
  return 1
}

http_get_stdout() {
  url="$1"
  tmp_body="/tmp/usque-http-body-$$"
  rm -f "$tmp_body"
  github_alt_urls "$url" | while IFS= read -r alt || [ -n "$alt" ]; do
    [ -n "$alt" ] || continue
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --connect-timeout 10 --max-time 30 "$alt" -o "$tmp_body" 2>/dev/null || continue
    elif command -v wget >/dev/null 2>&1; then
      wget -q -O "$tmp_body" -T 30 "$alt" 2>/dev/null || continue
    else
      return 1
    fi
    if [ -s "$tmp_body" ]; then
      break
    fi
    rm -f "$tmp_body"
  done
  if [ -s "$tmp_body" ]; then
    cat "$tmp_body"
    rm -f "$tmp_body"
    return 0
  fi
  rm -f "$tmp_body"
  return 1
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
  # по умолчанию Да (Enter / Y)
  printf '%s' "${YELLOW}[?]${NC} $1 [Y/n]: "
  c=$(read_choice)
  case "$c" in
    n|N|no|NO|н|Н|нет|Нет) return 1 ;;
    *) return 0 ;;
  esac
}

pause() {
  printf '%s' "${DIM}Нажмите Enter...${NC} "
  read_choice >/dev/null
}

# ndmc: системные libs первыми (как в nfqws-menu) — иначе OpenSSL из Entware ломает ndmc
ndmc_cli() {
  LD_LIBRARY_PATH=/lib:/usr/lib command ndmc -c "$@"
}

# Статический DNS для CF Client API (обход «кривых» A-записей / DPI на 8.x)
ensure_cf_api_dns() {
  info "DNS для ${CF_API_HOST} → ${CF_API_IP} (ndmc ip host)"
  if ! command -v ndmc >/dev/null 2>&1; then
    warn "ndmc не найден — добавьте вручную: ndmc -c \"ip host ${CF_API_HOST} ${CF_API_IP}\""
    return 1
  fi
  if ndmc_cli "ip host ${CF_API_HOST} ${CF_API_IP}" >/dev/null 2>&1; then
    ndmc_cli "system configuration save" >/dev/null 2>&1 || true
    info "Запись ip host сохранена."
    return 0
  fi
  warn "ndmc не принял ip host — попробуйте вручную из CLI Keenetic."
  return 1
}

# Регистрация Cloudflare, если нет session.conf
ensure_session() {
  if [ -f "$SESSION_FILE" ] && [ -s "$SESSION_FILE" ]; then
    info "Сессия уже есть: $SESSION_FILE"
    return 0
  fi

  echo
  warn "Нет $SESSION_FILE — нужна регистрация в Cloudflare."
  warn "Частая причина сбоя: TLS RST на ${CF_API_HOST} (DPI / «левые» A-записи 8.x)."
  echo

  if confirm_yes "Добавить статический DNS ${CF_API_HOST} → ${CF_API_IP}?"; then
    ensure_cf_api_dns || true
  fi

  if [ ! -x "$USQUE_BIN" ]; then
    error "Нет $USQUE_BIN — регистрация невозможна."
    return 1
  fi

  info "Пробуем register (--accept-tos --config $SESSION_FILE)..."
  mkdir -p /opt/etc/usque
  # как в side-effect-tm scripts/usque: register --accept-tos --config session.conf
  # иначе usque пишет config.json в CWD и сервис не видит сессию
  if ! "$USQUE_BIN" register --accept-tos --config "$SESSION_FILE" 2>&1; then
    warn "register вернул ошибку — пробуем через init..."
    [ -x "$INIT_SCRIPT" ] && "$INIT_SCRIPT" start 2>&1 || true
  fi

  # на всякий случай: если создался только config.json рядом
  if [ ! -f "$SESSION_FILE" ] && [ -f /opt/etc/usque/config.json ]; then
    mv -f /opt/etc/usque/config.json "$SESSION_FILE" 2>/dev/null && info "config.json → session.conf"
  fi
  if [ ! -f "$SESSION_FILE" ] && [ -f ./config.json ]; then
    mv -f ./config.json "$SESSION_FILE" 2>/dev/null && info "config.json → session.conf"
  fi

  if [ -f "$SESSION_FILE" ] && [ -s "$SESSION_FILE" ]; then
    info "Регистрация OK: $SESSION_FILE"
    if [ -x "$INIT_SCRIPT" ]; then
      "$INIT_SCRIPT" start 2>/dev/null || "$INIT_SCRIPT" restart 2>/dev/null || true
    fi
    return 0
  fi

  echo
  error "Регистрация не удалась (session.conf нет)."
  printf '%s\n' "${DIM}Проверьте:${NC}"
  echo "  curl -v --connect-timeout 10 -o /dev/null https://${CF_API_HOST}/"
  echo "  ndmc -c \"ip host ${CF_API_HOST} ${CF_API_IP}\""
  echo "  ndmc -c \"system configuration save\""
  echo "  /opt/usr/bin/usque register"
  echo "  $INIT_SCRIPT start"
  return 1
}

# Скачать ipk в /tmp и поставить локально (не занимает /opt на время загрузки)
# $1 = base URL репозитория без хвоша, напр. .../usque-keenetic/mipsel
install_ipk_via_tmp() {
  repo_url="$1"
  pkg_idx="$TMPDIR/Packages"
  mkdir -p "$TMPDIR"

  info "Индекс: ${repo_url}/Packages"
  if ! http_get "${repo_url}/Packages" "$pkg_idx"; then
    # иногда только Packages.gz
    if command -v gzip >/dev/null 2>&1 && http_get "${repo_url}/Packages.gz" "${pkg_idx}.gz"; then
      gzip -dc "${pkg_idx}.gz" > "$pkg_idx" 2>/dev/null || return 1
    else
      return 1
    fi
  fi

  # Filename: usque-keenetic_0.3.0_mipsel-3.4.ipk
  fname=$(awk -v p="$PKG_NAME" '
    $1=="Package:" && $2==p {inpkg=1; next}
    inpkg && $1=="Filename:" {print $2; exit}
    inpkg && $1=="Package:" {inpkg=0}
  ' "$pkg_idx")
  if [ -z "$fname" ]; then
    error "В индексе нет Filename для $PKG_NAME"
    return 1
  fi
  fsize=$(awk -v p="$PKG_NAME" '
    $1=="Package:" && $2==p {inpkg=1; next}
    inpkg && $1=="Size:" {print $2; exit}
    inpkg && $1=="Package:" {inpkg=0}
  ' "$pkg_idx")

  ipk_url="${repo_url}/${fname}"
  ipk_path="$TMPDIR/$fname"
  info "Скачивание ipk в /tmp: $fname${fsize:+ ($fsize Б)}"
  if ! http_get "$ipk_url" "$ipk_path"; then
    error "Не удалось скачать $ipk_url"
    return 1
  fi
  got=$(wc -c < "$ipk_path" 2>/dev/null | tr -d ' \t')
  case "$got" in ''|*[!0-9]*) got=0 ;; esac
  if [ "$got" -lt 100000 ]; then
    error "ipk слишком маленький (${got} Б) — обрыв загрузки."
    rm -f "$ipk_path"
    return 1
  fi
  info "Скачано в $ipk_path ($got Б)"

  # локальная установка — download cache на /opt не нужен
  if ! opkg install "$ipk_path"; then
    error "opkg install $ipk_path не удался."
    rm -f "$ipk_path"
    return 1
  fi
  rm -f "$ipk_path" "$pkg_idx" "${pkg_idx}.gz" 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------------------
# 1) Установка usque-keenetic (side-effect-tm)
# ---------------------------------------------------------------------------
do_install() {
  echo
  info "Установка $PKG_NAME (side-effect-tm)"
  need_arch || return 1
  check_os_for_usque || return 1
  # ipk качается в /tmp; на /opt нужно место только под распаковку (~6–8 МБ)
  check_opt_space 8192 || return 1

  if is_pkg_installed; then
    info "Пакет уже установлен — обновление..."
  else
    info "Пакет не установлен — установка..."
  fi

  mkdir -p /opt/etc/opkg
  # Сначала per-arch (mipsel/aarch64/mips ~4–5 МБ), fallback на /all (~14 МБ)
  repo_arch="${REPO_BASE}/${ARCH}"
  repo_use="$repo_arch"
  echo "src/gz ${PKG_NAME} ${repo_arch}" > "$OPKG_CONF"
  info "Репозиторий: ${repo_arch}"
  info "Записан: $OPKG_CONF"

  # индекс нужен и для opkg status, и для имени файла
  if ! opkg update; then
    warn "opkg update с /${ARCH} не удался — пробуем /all"
    repo_use="$REPO_URL_ALL"
    echo "src/gz ${PKG_NAME} ${REPO_URL_ALL}" > "$OPKG_CONF"
    info "Репозиторий: ${REPO_URL_ALL}"
    if ! opkg update; then
      error "opkg update не удался. Проверьте сеть / DNS / DPI."
      return 1
    fi
  fi

  # при нехватке места на /opt — ipk через /tmp (иначе opkg качает в свой cache под /opt)
  opt_free=$(df -k /opt 2>/dev/null | awk 'NR==2 {print $4}')
  case "$opt_free" in ''|*[!0-9]*) opt_free=0 ;; esac
  use_tmp=0
  if [ "$opt_free" -lt 15360 ]; then
    use_tmp=1
    info "На /opt мало места (${opt_free} КБ) — качаем ipk в /tmp"
  fi

  if [ "$use_tmp" = "1" ]; then
    if ! install_ipk_via_tmp "$repo_use"; then
      # fallback: обычный opkg install
      warn "Установка через /tmp не удалась — пробуем opkg install..."
      if ! opkg install "$PKG_NAME"; then
        error "opkg install $PKG_NAME не удался."
        return 1
      fi
    fi
    info "Установка/обновление завершено."
  else
    if is_pkg_installed; then
      if opkg upgrade "$PKG_NAME"; then
        info "Обновление завершено."
      else
        # upgrade мог ничего не сделать — дожимаем свежим ipk из /tmp
        if ! install_ipk_via_tmp "$repo_use"; then
          warn "opkg upgrade без изменений (возможно, уже актуальная версия)."
        else
          info "Обновление через ipk (/tmp) завершено."
        fi
      fi
    else
      if ! opkg install "$PKG_NAME"; then
        warn "opkg install не удался — пробуем скачать ipk в /tmp..."
        if ! install_ipk_via_tmp "$repo_use"; then
          error "Установка $PKG_NAME не удалась."
          return 1
        fi
      fi
      info "Установка завершена."
    fi
  fi

  echo
  printf '%s\n' "${BOLD}Управление сервисом${NC}"
  echo "  $INIT_SCRIPT (start | stop | restart | status)"
  echo
  printf '%s\n' "${BOLD}Конфигурация${NC}"
  echo "  $CONF_FILE"
  echo "  IFACE=\"opkgtun0\"   # вид opkgtun*"
  if [ -f "$USQUE_BIN" ]; then
    bsz=$(wc -c < "$USQUE_BIN" 2>/dev/null | tr -d ' \t')
    case "$bsz" in ''|*[!0-9]*) bsz=0 ;; esac
    if [ "$bsz" -lt 1000000 ]; then
      error "Бинарник $USQUE_BIN слишком маленький (${bsz} Б) — установка, скорее всего, оборвалась (нет места)."
      error "Освободите /opt и переустановите (п.3 → п.1) или: opkg remove usque-keenetic && opkg install usque-keenetic"
      return 1
    fi
    info "Бинарник: $USQUE_BIN (${bsz} Б)"
    if [ -x "$USQUE_BIN" ]; then
      "$USQUE_BIN" version 2>/dev/null || "$USQUE_BIN" --version 2>/dev/null || true
    fi
  else
    error "Бинарник $USQUE_BIN не найден после установки."
    return 1
  fi

  # postinst пакета часто не может register из-за DPI — дожимаем здесь
  ensure_session || true
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
    if confirm_yes "Сделать бэкап текущего bin (${USQUE_BIN}.bak)?"; then
      if cp -a "$USQUE_BIN" "${USQUE_BIN}.bak" 2>/dev/null; then
        info "Бэкап: ${USQUE_BIN}.bak"
      else
        warn "Не удалось создать бэкап (мало места?)."
      fi
    else
      info "Бэкап пропущен."
    fi
  fi
  cp -f "$newbin" "$USQUE_BIN"
  chmod +x "$USQUE_BIN"
  info "Установлен: $USQUE_BIN ($tag)"

  if [ -x "$USQUE_BIN" ]; then
    "$USQUE_BIN" version 2>/dev/null || "$USQUE_BIN" --version 2>/dev/null || true
  fi

  if [ ! -f "$SESSION_FILE" ] || [ ! -s "$SESSION_FILE" ]; then
    ensure_session || true
  elif [ -x "$INIT_SCRIPT" ]; then
    info "Запуск сервиса..."
    "$INIT_SCRIPT" start 2>/dev/null || warn "Не удалось запустить $INIT_SCRIPT"
  fi

  rm -rf "$TMPDIR"
  info "Бинарник обновлён."
  return 0
}

# ---------------------------------------------------------------------------
# 3) Проверка интерфейса
# ---------------------------------------------------------------------------
get_usque_iface() {
  iface=""
  if [ -f "$CONF_FILE" ]; then
    iface=$(sed -n 's/^IFACE="\(.*\)"/\1/p' "$CONF_FILE" | head -1)
    [ -z "$iface" ] && iface=$(sed -n "s/^IFACE='\(.*\)'/\1/p" "$CONF_FILE" | head -1)
    [ -z "$iface" ] && iface=$(sed -n 's/^IFACE=\([^#[:space:]]*\).*/\1/p' "$CONF_FILE" | head -1)
  fi
  [ -z "$iface" ] && iface="opkgtun0"
  printf '%s' "$iface"
}

is_usque_running() {
  if [ -x "$INIT_SCRIPT" ]; then
    if "$INIT_SCRIPT" status 2>/dev/null | grep -qiE 'running|запущен|pid'; then
      return 0
    fi
  fi
  # pidfile пакета
  if [ -f /opt/var/run/usque.pid ]; then
    pid=$(cat /opt/var/run/usque.pid 2>/dev/null | tr -d ' \t\r\n')
    case "$pid" in
      ''|*[!0-9]*) ;;
      *) kill -0 "$pid" 2>/dev/null && return 0 ;;
    esac
  fi
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f '/opt/usr/bin/usque' >/dev/null 2>&1 && return 0
  fi
  # fallback
  if ps 2>/dev/null | grep -v grep | grep -q '[u]sque'; then
    return 0
  fi
  return 1
}

# Cloudflare colo list (кэш в /tmp)
COLO_CACHE="/tmp/usque-dc-colos.json"
COLO_LIST_URL="https://raw.githubusercontent.com/Netrvin/cloudflare-colo-list/main/DC-Colos.json"

ensure_colo_cache() {
  if [ -s "$COLO_CACHE" ]; then
    # не старше ~7 дней
    if [ -n "$(find "$COLO_CACHE" -mtime -7 2>/dev/null)" ] || [ -s "$COLO_CACHE" ]; then
      # find -mtime может отсутствовать на busybox — достаточно наличия файла
      return 0
    fi
  fi
  info "Справочник colo (Netrvin/cloudflare-colo-list)..."
  if http_get "$COLO_LIST_URL" "$COLO_CACHE" && [ -s "$COLO_CACHE" ]; then
    return 0
  fi
  rm -f "$COLO_CACHE"
  return 1
}

# Расшифровка кода colo → "City, Country"
lookup_colo() {
  code="$1"
  [ -n "$code" ] || return 1
  # небольшой RU-словарь для частых точек
  case "$code" in
    HEL) printf '%s' "Хельсинки, Финляндия"; return 0 ;;
    ARN) printf '%s' "Стокгольм, Швеция"; return 0 ;;
    OSL) printf '%s' "Осло, Норвегия"; return 0 ;;
    CPH) printf '%s' "Копенгаген, Дания"; return 0 ;;
    FRA) printf '%s' "Франкфурт, Германия"; return 0 ;;
    AMS) printf '%s' "Амстердам, Нидерланды"; return 0 ;;
    LHR|LON) printf '%s' "Лондон, Великобритания"; return 0 ;;
    WAW) printf '%s' "Варшава, Польша"; return 0 ;;
    VIE) printf '%s' "Вена, Австрия"; return 0 ;;
    PRG) printf '%s' "Прага, Чехия"; return 0 ;;
    BUD) printf '%s' "Будапешт, Венгрия"; return 0 ;;
    RIX) printf '%s' "Рига, Латвия"; return 0 ;;
    TLL) printf '%s' "Таллин, Эстония"; return 0 ;;
    LED|SVO|DME|VKO) printf '%s' "Москва, Россия"; return 0 ;;
    MSQ) printf '%s' "Минск, Беларусь"; return 0 ;;
    KBP|IEV) printf '%s' "Киев, Украина"; return 0 ;;
    IST) printf '%s' "Стамбул, Турция"; return 0 ;;
    DXB) printf '%s' "Дубай, ОАЭ"; return 0 ;;
    SIN) printf '%s' "Сингапур"; return 0 ;;
    NRT|HND) printf '%s' "Токио, Япония"; return 0 ;;
    ICN) printf '%s' "Сеул, Южная Корея"; return 0 ;;
    LAX) printf '%s' "Лос-Анджелес, США"; return 0 ;;
    SJC) printf '%s' "Сан-Хосе, США"; return 0 ;;
    SEA) printf '%s' "Сиэтл, США"; return 0 ;;
    ORD) printf '%s' "Чикаго, США"; return 0 ;;
    EWR|JFK|LGA) printf '%s' "Нью-Йорк, США"; return 0 ;;
    CDG) printf '%s' "Париж, Франция"; return 0 ;;
    MAD) printf '%s' "Мадрид, Испания"; return 0 ;;
    MXP|LIN) printf '%s' "Милан, Италия"; return 0 ;;
    ZRH) printf '%s' "Цюрих, Швейцария"; return 0 ;;
  esac
  if ensure_colo_cache 2>/dev/null; then
    # "HEL": { ... "name": "Helsinki, Finland" ... }
    name=$(sed -n "/"$code":/,/}/p" "$COLO_CACHE" 2>/dev/null | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    if [ -n "$name" ]; then
      printf '%s' "$name"
      return 0
    fi
  fi
  return 1
}

# curl --interface IFACE https://cloudflare.com/cdn-cgi/trace
show_cf_trace() {
  ifc="$1"
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl нет — trace недоступен"
    return 1
  fi
  info "Cloudflare trace (cdn-cgi/trace) via $ifc..."
  trace=$(curl -sS --connect-timeout 5 --max-time 10 --interface "$ifc"     "https://cloudflare.com/cdn-cgi/trace" 2>/dev/null) || trace=""
  if [ -z "$trace" ]; then
    warn "trace: нет ответа via $ifc"
    return 1
  fi
  # ключевые поля
  cf_ip=$(printf '%s\n' "$trace" | sed -n 's/^ip=//p' | head -1)
  cf_colo=$(printf '%s\n' "$trace" | sed -n 's/^colo=//p' | head -1)
  cf_loc=$(printf '%s\n' "$trace" | sed -n 's/^loc=//p' | head -1)
  cf_warp=$(printf '%s\n' "$trace" | sed -n 's/^warp=//p' | head -1)
  cf_http=$(printf '%s\n' "$trace" | sed -n 's/^http=//p' | head -1)
  cf_tls=$(printf '%s\n' "$trace" | sed -n 's/^tls=//p' | head -1)
  cf_gateway=$(printf '%s\n' "$trace" | sed -n 's/^gateway=//p' | head -1)

  [ -n "$cf_ip" ] && info "  ip=$cf_ip"
  if [ -n "$cf_colo" ]; then
    colo_name=$(lookup_colo "$cf_colo" 2>/dev/null) || colo_name=""
    if [ -n "$colo_name" ]; then
      info "  colo=$cf_colo — $colo_name"
    else
      info "  colo=$cf_colo"
    fi
  fi
  [ -n "$cf_loc" ] && info "  loc=$cf_loc"
  [ -n "$cf_warp" ] && info "  warp=$cf_warp"
  [ -n "$cf_http" ] && info "  http=$cf_http"
  [ -n "$cf_tls" ] && info "  tls=$cf_tls"
  [ -n "$cf_gateway" ] && info "  gateway=$cf_gateway"

  # warp=on — ожидаемо для usque/WARP
  case "$cf_warp" in
    on|ON) info "  WARP/MASQUE: активен" ;;
    off|OFF) warn "  WARP: off (трафик не через WARP?)" ;;
  esac
  return 0
}

# HTTP-проверка через интерфейс usque (короткие таймауты — не зависаем)
check_url_via_iface() {
  # check_url_via_iface IFACE URL LABEL
  ifc="$1"
  url="$2"
  label="$3"
  code="000"
  err=""
  if ! command -v curl >/dev/null 2>&1; then
    error "Нужен curl для проверки через интерфейс."
    return 1
  fi
  # stderr отдельно, http_code — только на stdout
  errf="/tmp/usque-curl-err-$$"
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    --interface "$ifc" -L "$url" 2>"$errf") || true
  code=$(printf '%s' "$code" | tr -d '\r\n ')
  case "$code" in
    ''|*[!0-9]*) code="000" ;;
  esac
  if [ -s "$errf" ]; then
    err=$(tr '\n' ' ' < "$errf" | head -c 100)
  fi
  rm -f "$errf"

  case "$code" in
    2??|3??)
      info "$label: OK (HTTP $code) via $ifc"
      return 0
      ;;
    000)
      warn "$label: нет ответа via $ifc (timeout/unreachable)${err:+ — $err}"
      return 1
      ;;
    *)
      warn "$label: HTTP $code via $ifc${err:+ — $err}"
      return 1
      ;;
  esac
}

run_iface_probes() {
  # run_iface_probes IFACE → печатает ok count в stdout последней строкой? лучше через global
  _probe_ok=0
  check_url_via_iface "$1" "https://2ip.io/" "2ip.io" && _probe_ok=$((_probe_ok + 1))
  check_url_via_iface "$1" "https://www.google.com/" "google.com" && _probe_ok=$((_probe_ok + 1))
  check_url_via_iface "$1" "https://web.telegram.org/" "web.telegram.org" && _probe_ok=$((_probe_ok + 1))
}

do_check_iface() {
  echo
  info "Проверка интерфейса usque"
  iface=$(get_usque_iface)
  info "IFACE: $iface (из $CONF_FILE)"

  if ! is_usque_running; then
    error "Сервис usque не запущен."
    echo "  Запуск: $INIT_SCRIPT start"
    if confirm_yes "Запустить сервис сейчас?"; then
      if [ -x "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" start 2>&1 || true
      fi
      if ! is_usque_running; then
        error "Сервис так и не запустился."
        return 1
      fi
      info "Сервис: запущен"
    else
      return 1
    fi
  else
    info "Сервис: запущен"
  fi

  if ip link show "$iface" >/dev/null 2>&1 || ifconfig "$iface" >/dev/null 2>&1; then
    info "Интерфейс $iface: есть в системе"
  else
    warn "Интерфейс $iface не найден (ip link / ifconfig)."
  fi

  echo
  run_iface_probes "$iface"
  ok=$_probe_ok
  echo
  # Cloudflare colo / WARP trace
  show_cf_trace "$iface" || true
  echo
  if [ "$ok" -ge 2 ]; then
    info "Проверка пройдена: $ok/3 хостов доступны через $iface"
    return 0
  fi

  # процесс жив, но туннель «тухлый» — часто лечится restart
  warn "Слабый/нулевой ответ через $iface ($ok/3). Туннель мог «залипнуть»."
  if [ -x "$INIT_SCRIPT" ] && confirm_yes "Перезапустить usque и проверить снова?"; then
    info "Restart..."
    "$INIT_SCRIPT" restart 2>&1 || {
      "$INIT_SCRIPT" stop 2>/dev/null || true
      "$INIT_SCRIPT" start 2>&1 || true
    }
    sleep 2
    echo
    run_iface_probes "$iface"
    ok=$_probe_ok
    echo
    show_cf_trace "$iface" || true
    echo
    if [ "$ok" -ge 2 ]; then
      info "После restart: $ok/3 OK через $iface"
      return 0
    fi
  fi

  error "Хосты недоступны через $iface ($ok/3)"
  printf '%s\n' "${DIM}Вручную: curl --interface $iface -m 10 -L https://2ip.io/${NC}"
  return 1
}

# ---------------------------------------------------------------------------
# 88) Удаление
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

# Метка версий (синий + жирный), без ведущего пробела — отступ даёт menu_item
fmt_pkg_latest() {
  if [ -n "$LATEST_PKG" ] && [ -n "$LATEST_PKG_USQUE" ]; then
    printf '%s%s[%s / %s]%s' "$BLUE" "$BOLD" "$LATEST_PKG" "$LATEST_PKG_USQUE" "$NC"
  elif [ -n "$LATEST_PKG" ]; then
    printf '%s%s[%s]%s' "$BLUE" "$BOLD" "$LATEST_PKG" "$NC"
  fi
}

fmt_bin_latest() {
  if [ -n "$LATEST_BIN" ]; then
    printf '%s%s[%s]%s' "$BLUE" "$BOLD" "$LATEST_BIN" "$NC"
  fi
}

# Ровная строка меню: "  1)  label................  tag"
# label_pad — целевая ширина подписи в байтах (кириллица ≈ 2 байта/символ в UTF-8)
menu_item() {
  # menu_item NUM LABEL [TAG]
  num="$1"
  label="$2"
  tag="${3:-}"
  # номер: ширина 3, вправо — "  1)" и " 88)" с общим краем ")"
  printf '%s%3s)%s  ' "$BOLD" "$num" "$NC"
  printf '%s' "$label"
  if [ -n "$tag" ]; then
    # добиваем пробелами до ~34 байт подписи, чтобы теги шли одной колонкой
    # (на UTF-8 это приблизительно; для кириллицы берём запас)
    pad=34
    # длина в байтах
    llen=$(printf '%s' "$label" | wc -c | tr -d ' ')
    case "$llen" in ''|*[!0-9]*) llen=0 ;; esac
    n=$((pad - llen))
    if [ "$n" -gt 0 ]; then
      while [ "$n" -gt 0 ]; do
        printf ' '
        n=$((n - 1))
      done
    else
      printf '  '
    fi
    printf '%s' "$tag"
  fi
  printf '\n'
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    printf '%s\n' "${CYAN}================================================${NC}"
    printf '%s\n' "${CYAN}${BOLD}           usque-keenetic${NC}"
    printf '%s\n' "${CYAN}================================================${NC}"
    echo
    printf '%s\n' "${DIM}  Usque — Cloudflare WARP (MASQUE) для Keenetic${NC}"
    printf '%s\n' "${DIM}  интерфейс opkgtun* · маршруты DNS/IP в веб-морде${NC}"
    printf '%s\n' "${DIM}  pkg: side-effect-tm  ·  bin: Diniboy1123${NC}"
    echo
    show_status
    fetch_latest_versions 2>/dev/null || true
    echo
    printf '%s\n' "${DIM}  ──────────────────────────────────────────${NC}"
    menu_item "1"  "Установка (usque-keenetic)" "$(fmt_pkg_latest)"
    menu_item "2"  "Обновление bin (usque)"     "$(fmt_bin_latest)"
    menu_item "3"  "Проверка интерфейса"
    printf '%s\n' "${DIM}  ──────────────────────────────────────────${NC}"
    menu_item "88" "Удаление usque-keenetic"
    menu_item "0"  "Выход"
    printf '%s\n' "${DIM}  ──────────────────────────────────────────${NC}"
    echo
    printf '  %sВыбор:%s ' "$BOLD" "$NC"
    choice=$(read_choice)
    echo
    case "$choice" in
      1) do_install; pause ;;
      2) do_update_bin; pause ;;
      3) do_check_iface; pause ;;
      88) do_remove; pause ;;
      0|"") info "Выход."; exit 0 ;;
      *) warn "Неверный пункт"; pause ;;
    esac
  done
}

main_menu
