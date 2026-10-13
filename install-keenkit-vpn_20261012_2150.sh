cat > /opt/bin/keenkit-vpn <<'KKVPN'
#!/bin/sh
# keenkit-vpn — запуск KeenKit через VPN-интерфейс с раздельными OTA-источниками:
#   п.5 OTA Update (прошивки)  -> FW_DOMAIN
#   п.8 KeenBOOT OTA Update     -> KB_BASE
# KeenKit не модифицируется: подменяется только curl через PATH (переживает обновления KeenKit).
#
# Использование:
#   keenkit-vpn              автовыбор рабочего интерфейса из IFACES, запуск KeenKit
#   keenkit-vpn nwg1         запуск через указанный интерфейс
#   keenkit-vpn check        диагностика интерфейсов и источников
#   keenkit-vpn uninstall    удалить keenkit-vpn
# Настройки: /opt/etc/keenkit-vpn.conf (создаётся при первом запуске)

VERSION="0.0.1"
CONF="/opt/etc/keenkit-vpn.conf"
WRAP_DIR="/opt/lib/keenkit-vpn"
KK_SCRIPT="/opt/keenkit.sh"
KK_CONF="/opt/etc/KeenKit.conf"
REAL_CURL="/opt/bin/curl"
NET_DIR="/sys/class/net"

RED='\033[1;31m'
GREEN='\033[1;32m'
CYAN='\033[0;36m'
NC='\033[0m'

msg() { printf "${CYAN}%s${NC}\n" "$*" >&2; }
ok() { printf "${GREEN}%s${NC}\n" "$*" >&2; }
die() {
  printf "${RED}%s${NC}\n" "$*" >&2
  exit 1
}

write_default_conf() {
  mkdir -p "${CONF%/*}" || die "Не удалось создать ${CONF%/*}"
  cat >"$CONF" <<'EOF'
# keenkit-vpn: интерфейсы проверяются по порядку, используется первый рабочий
IFACES="nwg0 nwg1 nwg2"
# п.5 OTA Update — прошивки
FW_DOMAIN="https://osvault.project-athens.com"
# п.8 KeenBOOT OTA Update — загрузчики
KB_BASE="https://spatiumstas.github.io/KeenKit"
# адрес для проверки работоспособности интерфейса
PROBE_URL="https://spatiumstas.github.io/KeenKit/"
EOF
  chmod 600 "$CONF"
  msg "Создан $CONF"
}

valid_url() {
  case "$1" in
  https://*/ | *[!A-Za-z0-9.:/_-]*) return 1 ;;
  https://?*) return 0 ;;
  *) return 1 ;;
  esac
}

valid_iface() {
  case "$1" in
  "" | *[!A-Za-z0-9_.-]*) return 1 ;;
  *) [ -d "$NET_DIR/$1" ] ;;
  esac
}

load_conf() {
  [ -f "$CONF" ] || write_default_conf
  # shellcheck source=/dev/null
  . "$CONF" || die "Ошибка чтения $CONF"
  valid_url "$FW_DOMAIN" || die "FW_DOMAIN: нужен https://хост без / в конце ($FW_DOMAIN)"
  valid_url "$KB_BASE" || die "KB_BASE: нужен https://хост[/путь] без / в конце ($KB_BASE)"
  case "$PROBE_URL" in https://?*) ;; *) die "PROBE_URL должен начинаться с https://" ;; esac
  [ -n "$IFACES" ] || die "IFACES пуст"
}

check_deps() {
  [ -x "$REAL_CURL" ] || die "Нет $REAL_CURL (opkg install curl)"
  [ -f "$KK_SCRIPT" ] || die "KeenKit не установлен ($KK_SCRIPT)"
}

list_ifaces() {
  for f in "$NET_DIR"/*; do printf '%s ' "${f##*/}"; done
}

probe_iface() {
  "$REAL_CURL" --interface "$1" -fsS -m 8 -o /dev/null "$PROBE_URL" 2>/dev/null
}

pick_iface() {
  for i in $IFACES; do
    if ! valid_iface "$i"; then
      msg "  $i: нет интерфейса"
      continue
    fi
    if probe_iface "$i"; then
      ok "  $i: OK"
      echo "$i"
      return 0
    fi
    msg "  $i: нет доступа к $PROBE_URL"
  done
  return 1
}

write_wrapper() {
  mkdir -p "$WRAP_DIR" || die "Не удалось создать $WRAP_DIR"
  cat >"$WRAP_DIR/curl.tmp" <<'WRAP'
#!/bin/sh
# Сгенерировано keenkit-vpn, изменения будут перезаписаны.
# Внешние запросы -> через $KK_IFACE; $KK_FW/files/keenboot/* -> $KK_KB/files/keenboot/*;
# локальный RCI (127.0.0.1/localhost) -> напрямую.
REAL=/opt/bin/curl
[ -n "${KK_IFACE:-}" ] || exec "$REAL" "$@"
local_call=0
n=$#
for arg do
  case "$arg" in
  http://127.0.0.1[:/]* | http://localhost[:/]*) local_call=1 ;;
  esac
  if [ -n "${KK_FW:-}" ] && [ -n "${KK_KB:-}" ]; then
    case "$arg" in
    "$KK_FW/files/keenboot" | "$KK_FW/files/keenboot/"*) arg="$KK_KB${arg#"$KK_FW"}" ;;
    esac
  fi
  set -- "$@" "$arg"
done
shift "$n"
[ "$local_call" = 1 ] && exec "$REAL" "$@"
exec "$REAL" --interface "$KK_IFACE" "$@"
WRAP
  if ! { chmod 755 "$WRAP_DIR/curl.tmp" && mv -f "$WRAP_DIR/curl.tmp" "$WRAP_DIR/curl"; }; then
    die "Не удалось записать $WRAP_DIR/curl"
  fi
}

set_kk_domain() {
  if [ "$(sed -n 's/^domain="\([^"]*\)"$/\1/p' "$KK_CONF" 2>/dev/null)" != "$FW_DOMAIN" ]; then
    if ! { mkdir -p "${KK_CONF%/*}" && printf 'domain="%s"\n' "$FW_DOMAIN" >"$KK_CONF"; }; then
      die "Не удалось записать $KK_CONF"
    fi
    msg "Домен OTA в $KK_CONF: $FW_DOMAIN"
  fi
}

cmd_run() {
  check_deps
  if [ -n "$1" ]; then
    valid_iface "$1" || die "Интерфейс $1 не найден. Есть: $(list_ifaces)"
    IFACES="$1"
  fi
  msg "Проверка интерфейсов ($IFACES):"
  iface=$(pick_iface) || die "Нет рабочего интерфейса. Запусти: keenkit-vpn check"
  write_wrapper
  set_kk_domain
  ok "KeenKit через $iface | прошивки: $FW_DOMAIN | KeenBOOT: $KB_BASE"
  KK_IFACE="$iface" KK_FW="$FW_DOMAIN" KK_KB="$KB_BASE" PATH="$WRAP_DIR:$PATH" \
    exec sh "$KK_SCRIPT"
}

http_code() {
  "$REAL_CURL" "$@" -sS -m 10 -o /dev/null -w '%{http_code}' 2>/dev/null || true
}

cmd_check() {
  [ -x "$REAL_CURL" ] || die "Нет $REAL_CURL"
  echo "keenkit-vpn $VERSION"
  echo "Прошивки: $FW_DOMAIN | KeenBOOT: $KB_BASE"
  echo "KeenKit.conf: $(cat "$KK_CONF" 2>/dev/null || echo 'нет')"
  echo "Напрямую: GitHub=$(http_code "$PROBE_URL") osvault=$(http_code "$FW_DOMAIN/osvault/")"
  for i in $IFACES; do
    if ! valid_iface "$i"; then
      echo "$i: нет интерфейса"
      continue
    fi
    ip=$("$REAL_CURL" --interface "$i" -fsS -m 10 https://api.ipify.org 2>/dev/null) || ip="нет"
    echo "$i: IP=$ip GitHub=$(http_code --interface "$i" "$PROBE_URL") osvault=$(http_code --interface "$i" "$FW_DOMAIN/osvault/")"
  done
}

cmd_uninstall() {
  printf "Удалить keenkit-vpn (%s, %s, %s)? (y/n) " "$WRAP_DIR" "$CONF" "$0"
  read -r answer || exit 1
  case "$answer" in
  y | Y)
    rm -rf "$WRAP_DIR" "$CONF" && rm -f "$0" && ok "Удалено. KeenKit.conf не тронут."
    ;;
  *) msg "Отменено" ;;
  esac
}

case "${1:-}" in
-h | --help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' ;;
-V | --version) echo "$VERSION" ;;
check) load_conf && cmd_check ;;
uninstall) cmd_uninstall ;;
"") load_conf && cmd_run "" ;;
-*) die "Неизвестный параметр: $1 (keenkit-vpn --help)" ;;
*) load_conf && cmd_run "$1" ;;
esac
KKVPN
chmod 755 /opt/bin/keenkit-vpn && keenkit-vpn check
