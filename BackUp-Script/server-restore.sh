#!/usr/bin/env bash
#
# Версия: 1.3
#
# server-restore.sh — развёртывание сервера из бэкапа, созданного server-backup.sh.
#                     ВЕРСИЯ ДЛЯ ЧИСТОГО СЕРВЕРА (свежая ОС).
#
# ПОВЕДЕНИЕ:
#   • Перед восстановлением показывает ЧЕКЛИСТ найденного в бэкапе софта
#     (все пункты отмечены). Восстанавливаются ТОЛЬКО отмеченные — с их
#     конфигами и правами. Пропустить чеклист и взять всё → --all (или -y).
#   • По умолчанию СРАЗУ применяет изменения и не задаёт лишних вопросов.
#     Нужен «сухой» прогон без изменений  → добавь --dry-run.
#     Нужны подтверждения на каждый шаг    → добавь --ask.
#   • Перед перезаписью любого пути сохраняет его текущую версию в
#     /root/server-restore-pre-<дата>/ (можно откатиться).
#   • Никогда не применяет сырые iptables автоматически (конфликт с Docker).
#   • Перед включением ufw принудительно открывает SSH-порт(ы) из бэкапа.
#
# Что делает (по очереди, только найденное в бэкапе):
#   1. ставит недостающие пакеты (docker + плагин compose v2, nginx, sqlite3, ufw);
#   2. кладёт конфиги/данные на штатные места;
#   3. поднимает docker-compose проекты (3x-ui, remnawave, telemt и др.);
#   4. восстанавливает БД PostgreSQL из дампов (remnawave-db, bedolaga-bot);
#   5. запускает нативные службы (x-ui, telemt, mtproto-proxy) через systemd;
#   6. восстанавливает sysctl, crontab, firewall.
#
# Использование:
#   sudo ./server-restore.sh                        # выбор архива + чеклист компонентов
#   sudo ./server-restore.sh backup.tar.gz          # чеклист компонентов из этого архива
#   sudo ./server-restore.sh backup.tar.gz --all        # восстановить всё, без чеклиста
#   sudo ./server-restore.sh backup.tar.gz --only 3x-ui,nginx   # заранее заданный набор
#   sudo ./server-restore.sh backup.tar.gz --dry-run    # только показать план, ничего не менять
#   sudo ./server-restore.sh backup.tar.gz --ask        # спрашивать подтверждение на каждый шаг
#   sudo ./server-restore.sh backup.tar.gz --no-install # не ставить недостающий софт
#   sudo BACKUP_PASSPHRASE='секрет' ./server-restore.sh backup.tar.gz.gpg
#
# Компоненты для --only:
#   prereqs, sysctl, nginx, letsencrypt, ssh, ssh-keys, 3x-ui, remnawave,
#   projects, mtproto, docker-compose, volumes, postgres, systemd, crontab, firewall
#
set -euo pipefail

# ─────────────────────────────── Аргументы ──────────────────────────────────
ARCHIVE=""
APPLY=1              # 1 = сразу применять (по умолчанию); --dry-run включает сухой прогон
AUTO_YES=1          # 1 = без лишних вопросов (по умолчанию); --ask включает подтверждения
INSTALL_MISSING=1    # ставить недостающий софт
LIST_ONLY=0
SELECT=1             # 1 = показать чеклист компонентов (все включены); --all/-y пропускают
ONLY=""

# Каталог самого скрипта — там же по умолчанию ищем подпапку Backups с архивами.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"

# URL'ы установщиков (используются только если в бэкапе есть юнит, но нет бинаря)
XUI_INSTALL_URL="${XUI_INSTALL_URL:-https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh}"
TELEMT_INSTALL_URL="${TELEMT_INSTALL_URL:-https://raw.githubusercontent.com/telemt/telemt/main/install.sh}"
MTPROTO_BOOTSTRAP_URL="${MTPROTO_BOOTSTRAP_URL:-https://raw.githubusercontent.com/sleep3r/mtproto.zig/main/deploy/bootstrap.sh}"
DOCKER_INSTALL_URL="${DOCKER_INSTALL_URL:-https://get.docker.com}"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '2,42p'; exit 0; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)      APPLY=1; shift ;;
    --dry-run)    APPLY=0; shift ;;
    --yes|-y)     AUTO_YES=1; SELECT=0; shift ;;   # полностью без вопросов и без чеклиста
    --ask|--interactive) AUTO_YES=0; shift ;;
    --all|--no-select)   SELECT=0; shift ;;        # восстановить всё, без чеклиста
    --no-install) INSTALL_MISSING=0; shift ;;
    --only)       ONLY="$2"; shift 2 ;;
    --list)       LIST_ONLY=1; shift ;;
    -h|--help)    usage ;;
    --*)          echo "Неизвестный флаг: $1" >&2; exit 1 ;;
    *)            [[ -z "$ARCHIVE" ]] || { echo "Можно указать только один архив" >&2; exit 1; }
                  ARCHIVE="$1"; shift ;;
  esac
done
# root нужен для реального применения; для просмотра плана используй --dry-run
[[ $APPLY -eq 1 && $EUID -ne 0 ]] && { echo "Нужен root/sudo (реальное восстановление). Только посмотреть план: --dry-run."; exit 1; }
[[ -n "$ARCHIVE" && ! -f "$ARCHIVE" ]] && { echo "Файл не найден: $ARCHIVE"; exit 1; }
# Явный --only с CLI выигрывает у интерактивного чеклиста; без TTY меню невозможно.
[[ -n "$ONLY" ]] && SELECT=0
[[ -e /dev/tty ]] || SELECT=0

# ────────────────────────────── Утилиты вывода ──────────────────────────────
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
step() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
die()  { err "$*"; exit 1; }

WORK="$(mktemp -d /tmp/srvrestore.XXXXXX)"
cleanup() { tput cnorm 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# ────────────── Обёртки исполнения: в dry-run только печатают ────────────────
run() {  # выполнить команду (массив аргументов)
  if [[ $APPLY -eq 1 ]]; then
    "$@"
  else
    printf '\033[2m[dry-run]\033[0m '; printf '%q ' "$@"; printf '\n'
  fi
}
run_sh() {  # выполнить строку через shell (для пайпов/редиректов)
  if [[ $APPLY -eq 1 ]]; then
    bash -c "$1"
  else
    printf '\033[2m[dry-run]\033[0m bash -c %q\n' "$1"
  fi
}
# Подтверждение действия. В dry-run всегда «да» (чтобы показать полный план).
confirm() {
  local q="$1" ans
  [[ $APPLY -eq 0 || $AUTO_YES -eq 1 ]] && return 0
  read -r -p "$(printf '\033[1;33m?\033[0m %s [y/N] ' "$q")" ans </dev/tty || ans=n
  [[ "$ans" =~ ^[Yy] ]]
}
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Нужна команда: $1"; }

# ─────────────── Интерактивное меню выбора (стрелки ↑/↓, Enter) ──────────────
REPLY_INDEX=0
menu_select() {  # menu_select <пункт1> <пункт2> ...
  local options=("$@") sel=0 key key2 n=${#} i
  tput civis 2>/dev/null || true
  printf '\033[2m(↑/↓ — выбор, Enter — подтвердить, q — отмена)\033[0m\n'
  while true; do
    for i in "${!options[@]}"; do
      if [[ $i -eq $sel ]]; then
        printf '\033[1;32m  ▶ %s\033[0m\033[K\n' "${options[$i]}"
      else
        printf '    %s\033[K\n' "${options[$i]}"
      fi
    done
    IFS= read -rsn1 key </dev/tty
    if [[ $key == $'\e' ]]; then
      read -rsn2 -t 0.1 key2 </dev/tty || true
      key+="$key2"
    fi
    case "$key" in
      $'\e[A'|k) ((sel > 0)) && ((sel--)) || true ;;
      $'\e[B'|j) ((sel < n - 1)) && ((sel++)) || true ;;
      ''|$'\n') break ;;
      q|Q) tput cnorm 2>/dev/null || true; echo "Отменено."; exit 1 ;;
    esac
    printf '\033[%dA' "$n"
  done
  tput cnorm 2>/dev/null || true
  REPLY_INDEX=$sel
}

# ─── Меню-чеклист с чекбоксами (↑/↓ — переход, Пробел — вкл/выкл, Enter — ок) ──
# Состояние галочек читается/пишется через глобальный массив MULTI_CHECK (1/0),
# который заполняет вызывающий код (по умолчанию — всё включено).
MULTI_CHECK=()
menu_multiselect() {  # menu_multiselect <пункт1> <пункт2> ...
  local options=("$@") cur=0 key key2 n=${#} i box
  tput civis 2>/dev/null || true
  printf '\033[2m(↑/↓ — переход, Пробел — вкл/выкл, a — все/никого, Enter — подтвердить, q — отмена)\033[0m\n'
  while true; do
    for i in "${!options[@]}"; do
      box='[ ]'; [[ ${MULTI_CHECK[$i]:-0} -eq 1 ]] && box='[x]'
      if [[ $i -eq $cur ]]; then
        printf '\033[1;32m  ▶ %s %s\033[0m\033[K\n' "$box" "${options[$i]}"
      else
        printf '    %s %s\033[K\n' "$box" "${options[$i]}"
      fi
    done
    IFS= read -rsn1 key </dev/tty
    if [[ $key == $'\e' ]]; then
      read -rsn2 -t 0.1 key2 </dev/tty || true
      key+="$key2"
    fi
    case "$key" in
      $'\e[A'|k) ((cur > 0)) && ((cur--)) || true ;;
      $'\e[B'|j) ((cur < n - 1)) && ((cur++)) || true ;;
      ' ')       MULTI_CHECK[$cur]=$(( ${MULTI_CHECK[$cur]:-0} ^ 1 )) ;;
      a|A)       local allon=1
                 for i in "${!options[@]}"; do [[ ${MULTI_CHECK[$i]:-0} -eq 0 ]] && { allon=0; break; }; done
                 for i in "${!options[@]}"; do MULTI_CHECK[$i]=$(( allon ^ 1 )); done ;;
      ''|$'\n')  break ;;
      q|Q)       tput cnorm 2>/dev/null || true; echo "Отменено."; exit 1 ;;
    esac
    printf '\033[%dA' "$n"
  done
  tput cnorm 2>/dev/null || true
}

# Поиск архивов и выбор (whiptail/fzf, иначе своё меню).
# Ищем там, где их кладёт server-backup.sh: рядом со скриптом и в подпапке Backups,
# а также в текущем каталоге и его Backups. Храним ПОЛНЫЕ пути.
pick_archive() {
  local search=("$SCRIPT_DIR" "$SCRIPT_DIR/Backups" "$(pwd)" "$(pwd)/Backups") d
  local raw=() f
  for d in "${search[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do raw+=("$f"); done < <(
      find "$d" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.tgz' \
           -o -name '*.tar.gz.gpg' -o -name '*.tgz.gpg' \) 2>/dev/null
    )
  done
  # дедуп (pwd может совпасть с каталогом скрипта), сортировка по убыванию (свежие сверху)
  local files=() p
  while IFS= read -r p; do [[ -n "$p" ]] && files+=("$p"); done \
    < <(printf '%s\n' ${raw[@]+"${raw[@]}"} | sort -u -r)
  [[ ${#files[@]} -gt 0 ]] || die "Не нашёл бэкапов (*.tar.gz/*.tgz[.gpg]) в: ${search[*]}. Укажи путь явно."
  step "Найденные бэкапы"
  local labels=() sz dt
  for f in "${files[@]}"; do
    sz="$(du -h "$f" 2>/dev/null | cut -f1)"
    dt="$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || true)"
    labels+=("$(printf '%-40s %6s %s  [%s]' "$(basename "$f")" "$sz" "$dt" "$(dirname "$f")")")
  done
  if command -v whiptail >/dev/null 2>&1; then
    local items=() i choice
    for i in "${!files[@]}"; do items+=("$i" "${labels[$i]}"); done
    choice="$(whiptail --title "Выбор бэкапа" --menu "Стрелки + Enter:" 24 100 14 "${items[@]}" 3>&1 1>&2 2>&3)" \
      || die "Отменено."
    ARCHIVE="${files[$choice]}"
  elif command -v fzf >/dev/null 2>&1; then
    ARCHIVE="$(printf '%s\n' "${files[@]}" | fzf --height=40% --border --prompt='backup> ')" \
      || die "Отменено."
  else
    menu_select "${labels[@]}"
    ARCHIVE="${files[$REPLY_INDEX]}"
  fi
  ok "Выбран: $ARCHIVE"
}

# ───────────────────── Выбор архива (если не задан явно) ─────────────────────
[[ -z "$ARCHIVE" ]] && pick_archive

# ───────────────────── Распаковка / расшифровка архива ───────────────────────
# Эти шаги выполняются ВСЕГДА (даже в dry-run): они нужны для анализа содержимого
# и пишут только во временный каталог $WORK — на систему не влияют.
require_cmd tar
TARBALL="$ARCHIVE"
if [[ "$ARCHIVE" == *.gpg ]]; then
  log "Расшифровка архива GPG"
  require_cmd gpg
  TARBALL="$WORK/backup.tar.gz"
  if [[ -n "${BACKUP_PASSPHRASE:-}" ]]; then
    gpg --batch --yes --pinentry-mode loopback --passphrase "$BACKUP_PASSPHRASE" -o "$TARBALL" -d "$ARCHIVE"
  else
    gpg -o "$TARBALL" -d "$ARCHIVE"
  fi
fi
log "Распаковка архива во временный каталог"
EXTRACT="$WORK/extract"; mkdir -p "$EXTRACT"
tar xzf "$TARBALL" -C "$EXTRACT"
STAGEROOT="$(find "$EXTRACT" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[[ -d "$STAGEROOT" ]] || die "Не удалось определить корень бэкапа после распаковки."
PRE_RESTORE_DIR="/root/server-restore-pre-$(date +%Y%m%d-%H%M%S)"

# ─────────────────────── Определяем, что есть в бэкапе ───────────────────────
declare -A HAS
[[ -d "$STAGEROOT/docker/compose" ]]            && HAS[docker-compose]=1
[[ -d "$STAGEROOT/3x-ui" ]]                     && HAS[3x-ui]=1
[[ -d "$STAGEROOT/remnawave" ]]                 && HAS[remnawave]=1
[[ -d "$STAGEROOT/projects" ]]                  && HAS[projects]=1
[[ -d "$STAGEROOT/mtproto" ]]                   && HAS[mtproto]=1
[[ -d "$STAGEROOT/docker/volumes-data" ]]       && HAS[volumes]=1
[[ -d "$STAGEROOT/system/etc/nginx" ]]          && HAS[nginx]=1
[[ -d "$STAGEROOT/system/etc/letsencrypt" || -d "$STAGEROOT/system/root/cert" || -d "$STAGEROOT/system/root/.acme.sh" ]] && HAS[letsencrypt]=1
[[ -d "$STAGEROOT/system/etc/ssh" ]]            && HAS[ssh]=1
[[ -d "$STAGEROOT/ssh-keys" ]]                  && HAS[ssh-keys]=1
[[ -e "$STAGEROOT/system/etc/sysctl.conf" || -d "$STAGEROOT/system/etc/sysctl.d" ]] && HAS[sysctl]=1
[[ -d "$STAGEROOT/system/etc/systemd/system" ]] && HAS[systemd]=1
[[ -e "$STAGEROOT/system/etc/crontab" || -d "$STAGEROOT/system/crontabs" ]] && HAS[crontab]=1
[[ -d "$STAGEROOT/system/etc/ufw" || -e "$STAGEROOT/system/iptables.txt" ]] && HAS[firewall]=1
{ ls "$STAGEROOT/docker/pg-dumps/"*.sql.gz >/dev/null 2>&1 && HAS[postgres]=1; } || true

# ────────────────────────────── Печать плана ────────────────────────────────
step "Содержимое бэкапа"
[[ -f "$STAGEROOT/MANIFEST.txt" ]] && sed -n '1,12p' "$STAGEROOT/MANIFEST.txt"
echo "Обнаруженные компоненты:"
for k in prereqs sysctl nginx letsencrypt ssh ssh-keys 3x-ui remnawave projects \
         mtproto docker-compose postgres volumes systemd crontab firewall; do
  [[ -n "${HAS[$k]:-}" ]] && printf '   \033[1;32m✓\033[0m %s\n' "$k"
done
echo
echo "Режим:        $([[ $APPLY -eq 1 ]] && echo 'APPLY (реальные изменения)' || echo 'DRY-RUN (ничего не меняется)')"
echo "Доустановка:  $([[ $INSTALL_MISSING -eq 1 ]] && echo 'разрешена (с подтверждением)' || echo 'отключена')"
[[ -n "$ONLY" ]] && echo "Только:       $ONLY"
echo "Откат:        копии заменяемых файлов → $PRE_RESTORE_DIR"

[[ $LIST_ONLY -eq 1 ]] && exit 0

if [[ $APPLY -eq 0 ]]; then
  warn "Это DRY-RUN — реальных изменений НЕ будет. Убери --dry-run для реального применения."
elif [[ $AUTO_YES -ne 1 ]]; then
  confirm "Начать РЕАЛЬНОЕ восстановление на этот сервер?" || die "Отменено пользователем."
fi

# ─────── Чеклист: что именно восстанавливать (по умолчанию — всё найденное) ───
# Строим список ТОЛЬКО из реально найденного в бэкапе (HAS), показываем чекбоксы
# (все включены). Выбор пользователя превращаем в фильтр $ONLY, по которому ниже
# in_only/should_do восстанавливают лишь отмеченные компоненты с их правами.
select_components() {
  local -a toks=() labs=()
  # add <token> <detected?> <label>  (return 0 обязателен: иначе set -e оборвёт скрипт
  # на первом ненайденном компоненте, где условие ложно)
  add() { [[ -n "$2" ]] && { toks+=("$1"); labs+=("$3"); }; return 0; }
  add sysctl         "${HAS[sysctl]:-}"                      "sysctl — параметры ядра/сети"
  add nginx          "${HAS[nginx]:-}"                       "nginx — веб-сервер и конфиги"
  add letsencrypt    "${HAS[letsencrypt]:-}"                 "TLS-сертификаты — Let's Encrypt / acme.sh / cert"
  add ssh            "${HAS[ssh]:-}"                         "SSH — sshd_config и host-ключи"
  add ssh-keys       "${HAS[ssh-keys]:-}"                    "SSH — authorized_keys пользователей"
  add 3x-ui          "${HAS[3x-ui]:-}"                       "3x-ui — VLESS-панель (x-ui.db, серты, инбаунды)"
  add projects       "${HAS[projects]:-}${HAS[remnawave]:-}" "Проекты — remnawave (panel/node), cabinet, photo"
  add mtproto        "${HAS[mtproto]:-}"                     "MTProto — telemt / mtproto.zig / mekopr (+права)"
  add docker-compose "${HAS[docker-compose]:-}"              "Docker Compose — проекты и контейнеры"
  add postgres       "${HAS[postgres]:-}"                    "PostgreSQL — восстановление баз из дампов"
  add volumes        "${HAS[volumes]:-}"                     "Docker volumes — данные (перезапись!)"
  add systemd        "${HAS[systemd]:-}"                     "systemd — кастомные службы (unit-файлы, запуск)"
  add crontab        "${HAS[crontab]:-}"                     "Cron — задачи планировщика"
  add firewall       "${HAS[firewall]:-}"                    "Firewall — ufw / iptables (rules.v4)"

  [[ ${#toks[@]} -gt 0 ]] || { warn "В бэкапе не обнаружено восстанавливаемых компонентов."; return 0; }

  step "Выбор компонентов для восстановления (по умолчанию отмечено всё)"
  local i chosen=""
  if command -v whiptail >/dev/null 2>&1; then
    local items=()
    for i in "${!toks[@]}"; do items+=("${toks[$i]}" "${labs[$i]}" "ON"); done
    chosen="$(whiptail --title "Что восстанавливать" \
             --checklist "Пробел — переключить, Enter — подтвердить:" \
             24 94 14 "${items[@]}" 3>&1 1>&2 2>&3)" || die "Отменено пользователем."
    chosen="$(printf '%s' "$chosen" | tr -d '"' | tr ' ' ',')"
  else
    MULTI_CHECK=(); for i in "${!toks[@]}"; do MULTI_CHECK+=(1); done
    menu_multiselect "${labs[@]}"
    local picked=()
    for i in "${!toks[@]}"; do [[ ${MULTI_CHECK[$i]:-0} -eq 1 ]] && picked+=("${toks[$i]}"); done
    chosen="$(IFS=,; printf '%s' "${picked[*]}")"
  fi

  [[ -n "$chosen" ]] || die "Не выбрано ни одного компонента — восстанавливать нечего."
  # prereqs (доустановка софта) держим включённым всегда — иначе выбранное не на что ставить
  ONLY="prereqs,$chosen"
  ok "К восстановлению: $chosen"
}
[[ $SELECT -eq 1 ]] && select_components

# ─────────────────── Фильтр компонентов и подтверждение ──────────────────────
in_only() { [[ -z "$ONLY" ]] && return 0; [[ ",$ONLY," == *",$1,"* ]]; }
should_do() {  # should_do <component> <описание>
  in_only "$1" || return 1
  confirm "Установить «$1» ($2)?"
}

# ─────────────────────────── Менеджер пакетов ───────────────────────────────
PKG=""
command -v apt-get >/dev/null 2>&1 && PKG=apt
command -v dnf      >/dev/null 2>&1 && PKG=dnf
command -v yum      >/dev/null 2>&1 && PKG=${PKG:-yum}
pkg_install() {
  case "$PKG" in
    apt) run_sh "DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y $*" ;;
    dnf) run_sh "dnf install -y $*" ;;
    yum) run_sh "yum install -y $*" ;;
    *)   warn "Неизвестный пакетный менеджер — установи вручную: $*"; return 1 ;;
  esac
}

# ───────────────────────── Восстановление путей ─────────────────────────────
# Перед перезаписью сохраняем текущую версию пути (для отката).
backup_existing() {
  local p="$1"
  [[ -e "$p" ]] || return 0
  local dst="$PRE_RESTORE_DIR/${p#/}"
  run mkdir -p "$(dirname "$dst")"
  run cp -a "$p" "$dst"
}
# Пути в бэкапе хранятся как зеркало абсолютного: /etc/nginx -> <section>/etc/nginx
restore_path() {  # restore_path <section> <abs-path>
  local src="$STAGEROOT/$1$2"
  if [[ -e "$src" ]]; then
    backup_existing "$2"
    run mkdir -p "$(dirname "$2")"
    if command -v rsync >/dev/null 2>&1; then
      run rsync -a "$src" "$(dirname "$2")/"
    else
      run cp -a "$src" "$(dirname "$2")/"   # fallback, если rsync недоступен
    fi
    ok "восстановлено: $2"
  fi
  return 0
}

# Чиним владельца рабочих/конфиг-каталогов службы. Без этого telemt и подобные
# службы падают с «permission denied» к своей рабочей папке или конфигу: после
# restore файлы могут принадлежать чужому/несуществующему UID, а нужного
# системного пользователя на чистом сервере ещё нет (install.sh мы пропускаем,
# когда бинарь есть в бэкапе — значит и юзера никто не создаёт).
fix_service_perms() {  # fix_service_perms <unit-file> <dir>...
  local unit="$1"; shift
  [[ -f "$unit" ]] || return 0
  local u g wd
  u="$(grep -oP '^\s*User=\s*\K\S+'  "$unit" 2>/dev/null | tail -n1 || true)"
  g="$(grep -oP '^\s*Group=\s*\K\S+' "$unit" 2>/dev/null | tail -n1 || true)"
  wd="$(grep -oP '^\s*WorkingDirectory=\s*\K\S+' "$unit" 2>/dev/null | tail -n1 || true)"
  [[ -z "$u" ]] && u=root
  [[ -z "$g" ]] && g="$u"
  # создаём группу/пользователя, если это выделенный системный аккаунт и его нет
  if [[ "$u" != root ]]; then
    getent group "$g" >/dev/null 2>&1 || run groupadd --system "$g" || true
    id "$u" >/dev/null 2>&1 || run useradd --system -g "$g" --no-create-home --shell /usr/sbin/nologin "$u" || true
  fi
  local d
  for d in "$wd" "$@"; do
    [[ -n "$d" && -e "$d" ]] || continue
    run chown -R "$u:$g" "$d" || warn "не удалось chown $d"
    ok "права $d → $u:$g (служба $(basename "$unit" .service))"
  done
}

# Все SSH-порты из БЭКАПА (sshd_config + sshd_config.d/*.conf). По умолчанию 22.
# Читаем из архива, чтобы работало и в dry-run, и до восстановления /etc/ssh.
detect_ssh_ports() {
  local base="$STAGEROOT/system/etc/ssh" ports
  ports="$(grep -rhoP '^\s*Port\s+\K[0-9]+' "$base/sshd_config" "$base/sshd_config.d/" 2>/dev/null | sort -u || true)"
  [[ -z "$ports" ]] && ports=22
  echo "$ports"
}

# ════════════════════════════ ФАЗА 1: ПАКЕТЫ ════════════════════════════════
step "Фаза 1 — необходимые пакеты"

# Базовые утилиты, без которых сам restore не отработает:
#   rsync      — копирование путей (restore_path и compose-проекты);
#   curl/wget  — докачка установщиков (docker/3x-ui/telemt) и их зависимостей;
#   tar/gzip   — распаковка. Ставим ВСЕГДА и без лишних вопросов.
BASE_MISSING=()
for c in rsync curl wget tar gzip; do
  command -v "$c" >/dev/null 2>&1 || BASE_MISSING+=("$c")
done
if [[ ${#BASE_MISSING[@]} -gt 0 ]]; then
  if [[ $INSTALL_MISSING -eq 1 ]]; then
    log "Ставлю базовые утилиты: ${BASE_MISSING[*]}"
    pkg_install "${BASE_MISSING[@]}" || warn "не удалось поставить: ${BASE_MISSING[*]} — поставь вручную."
  else
    warn "Не хватает утилит: ${BASE_MISSING[*]} — восстановление может частично не сработать (доустановка отключена)."
  fi
else
  ok "базовые утилиты на месте (rsync/curl/wget/tar/gzip)"
fi

NEED_DOCKER=0
[[ -n "${HAS[docker-compose]:-}${HAS[remnawave]:-}${HAS[projects]:-}${HAS[postgres]:-}${HAS[volumes]:-}" ]] && NEED_DOCKER=1

# Docker Engine
if [[ $NEED_DOCKER -eq 1 ]] && ! command -v docker >/dev/null 2>&1; then
  if [[ $INSTALL_MISSING -eq 1 ]] && should_do prereqs "Docker Engine"; then
    require_cmd curl
    log "Установка Docker (get.docker.com)"
    run_sh "curl -fsSL '$DOCKER_INSTALL_URL' -o /tmp/get-docker.sh && sh /tmp/get-docker.sh"
    run_sh "systemctl enable --now docker 2>/dev/null || true"
  else
    warn "Docker не установлен — docker-проекты будут пропущены."
  fi
fi

# Плагин docker compose (v2) — НЕ legacy docker-compose
ensure_compose_plugin() {
  command -v docker >/dev/null 2>&1 || return 0
  if docker compose version >/dev/null 2>&1; then
    ok "docker compose (v2) доступен"
    return 0
  fi
  [[ $INSTALL_MISSING -eq 1 ]] || { warn "плагин docker compose не установлен (доустановка отключена)"; return 0; }
  log "Установка плагина docker compose (v2)"
  case "$PKG" in
    apt|dnf|yum) pkg_install docker-compose-plugin || true ;;
  esac
  [[ $APPLY -eq 0 ]] && return 0
  docker compose version >/dev/null 2>&1 && { ok "плагин docker compose установлен из пакетов"; return 0; }
  warn "Пакет недоступен — ставлю плагин из GitHub."
  local arch plugdir
  case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    armv7l) arch=armv7 ;;
    *) arch="$(uname -m)" ;;
  esac
  plugdir="/usr/libexec/docker/cli-plugins"
  run mkdir -p "$plugdir"
  run_sh "curl -fsSL 'https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}' -o '$plugdir/docker-compose' && chmod +x '$plugdir/docker-compose'"
  if docker compose version >/dev/null 2>&1; then
    ok "плагин docker compose установлен из GitHub"
  else
    err "не удалось активировать docker compose — проверь вручную."
  fi
}
[[ $NEED_DOCKER -eq 1 ]] && should_do prereqs "плагин docker compose (v2)" && ensure_compose_plugin || true

# Прочие пакеты
if [[ -n "${HAS[nginx]:-}" ]] && ! command -v nginx >/dev/null 2>&1 && [[ $INSTALL_MISSING -eq 1 ]]; then
  should_do prereqs "nginx" && pkg_install nginx || true
fi
if [[ -n "${HAS[3x-ui]:-}" ]] && ! command -v sqlite3 >/dev/null 2>&1 && [[ $INSTALL_MISSING -eq 1 ]]; then
  should_do prereqs "sqlite3" && pkg_install sqlite3 || true
fi
if [[ -n "${HAS[firewall]:-}" ]] && ! command -v ufw >/dev/null 2>&1 && [[ $INSTALL_MISSING -eq 1 ]]; then
  should_do prereqs "ufw" && pkg_install ufw || true
fi

# ═══════════════════════ ФАЗА 2: КОНФИГИ И ДАННЫЕ ═══════════════════════════
step "Фаза 2 — восстановление конфигов и данных"

# sysctl
if [[ -n "${HAS[sysctl]:-}" ]] && should_do sysctl "ядро / сеть"; then
  restore_path system /etc/sysctl.conf
  restore_path system /etc/sysctl.d
  run_sh "sysctl --system >/dev/null 2>&1 || true"
fi

# nginx
if [[ -n "${HAS[nginx]:-}" ]] && should_do nginx "веб-сервер nginx"; then
  restore_path system /etc/nginx
  # перезапуск только если конфиг валиден
  run_sh "nginx -t >/dev/null 2>&1 && { systemctl enable nginx >/dev/null 2>&1 || true; systemctl restart nginx; } || echo '[!] nginx -t показал ошибки — НЕ перезапускаю, проверь конфиг.'"
fi

# Let's Encrypt + серты в /root/cert
if [[ -n "${HAS[letsencrypt]:-}" ]] && should_do letsencrypt "TLS-сертификаты"; then
  restore_path system /etc/letsencrypt
  restore_path system /root/cert
  restore_path system /root/.acme.sh   # acme.sh-аккаунт → автопродление сертов 3x-ui
fi

# SSH-конфиг (host-ключи + sshd_config с твоим кастомным портом)
if [[ -n "${HAS[ssh]:-}" ]] && should_do ssh "SSH-конфиг и host-ключи"; then
  restore_path system /etc/ssh
  run_sh "chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || true"
  ok "SSH-порт(ы) из бэкапа: $(detect_ssh_ports | tr '\n' ' ')"
  warn "Порт применится после reload; firewall откроет его на шаге 3.4."
  run_sh "sshd -t >/dev/null 2>&1 && (systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true) || echo '[!] sshd -t ошибки — службу НЕ трогаю.'"
fi

# authorized_keys пользователей
if [[ -n "${HAS[ssh-keys]:-}" ]] && should_do ssh-keys "ключи доступа пользователей"; then
  while IFS= read -r ak; do
    rel="${ak#"$STAGEROOT"/ssh-keys/}"   # user/<абс путь>
    abs="/${rel#*/}"
    backup_existing "$abs"
    run mkdir -p "$(dirname "$abs")"
    run install -m 600 "$ak" "$abs"
    ok "ключи: $abs"
  done < <(find "$STAGEROOT/ssh-keys" -name authorized_keys 2>/dev/null)
fi

# 3x-ui (нативная установка).
# ВАЖНО: порт панели, пути к сертам и все инбаунды лежат В x-ui.db — мы их НЕ
# задаём заново, а восстанавливаем БД целиком. Сами серты возвращаются файлами
# (/root/cert, /etc/letsencrypt). install.sh запускаем ТОЛЬКО как фолбэк —
# когда бинаря НЕТ в бэкапе; иначе ставим твой бинарь из бэкапа (точная версия).
if [[ -n "${HAS[3x-ui]:-}" ]] && should_do 3x-ui "панель 3x-ui (порт/серты/инбаунды — из x-ui.db)"; then
  if [[ $INSTALL_MISSING -eq 1 ]] \
     && [[ ! -e "$STAGEROOT/3x-ui/native/usr/local/x-ui" ]] \
     && ! command -v x-ui >/dev/null 2>&1 \
     && ! systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
    warn "Бинарь 3x-ui в бэкапе отсутствует — нужен официальный install.sh."
    warn "Он может быть интерактивным; порт/креды всё равно перезапишутся из x-ui.db."
    if confirm "Поставить MHSanaei/3x-ui через install.sh?"; then
      require_cmd curl
      run_sh "curl -fsSL '$XUI_INSTALL_URL' -o /tmp/3x-ui-install.sh && bash /tmp/3x-ui-install.sh || true"
    fi
  else
    ok "Бинарь 3x-ui берём из бэкапа (install.sh не нужен) — версия сохранится точно."
  fi
  # бинарь + management-CLI + unit + конфиг
  for p in /etc/x-ui /usr/local/x-ui /usr/bin/x-ui /etc/systemd/system/x-ui.service; do
    restore_path "3x-ui/native" "$p"
  done
  # целостный дамп x-ui.db кладём поверх (порт, webBasePath, креды, инбаунды, пути к сертам)
  dump=""
  for cand in "$STAGEROOT/3x-ui/db-dumps/_etc_x-ui_x-ui.db" "$STAGEROOT/3x-ui/native/etc/x-ui/x-ui.db"; do
    if [[ -f "$cand" ]]; then dump="$cand"; break; fi
  done
  if [[ -z "$dump" ]]; then
    dump="$(find "$STAGEROOT/3x-ui/db-dumps" -maxdepth 1 -name '*x-ui.db' 2>/dev/null | sort | head -n1 || true)"
  fi
  if [[ -n "$dump" ]]; then
    backup_existing /etc/x-ui/x-ui.db
    run mkdir -p /etc/x-ui
    run cp -a "$dump" /etc/x-ui/x-ui.db
    ok "восстановлена БД 3x-ui (порт/серты/инбаунды) из целостного дампа"
  fi
  # серты: db ссылается на пути к файлам — они должны существовать. Если файла
  # нет, но он есть в зеркале system бэкапа — восстанавливаем его по точному пути
  # (покрывает нестандартные места вне /etc/letsencrypt и /root/cert).
  if [[ $APPLY -eq 1 ]] && command -v sqlite3 >/dev/null 2>&1; then
    for key in webCertFile webKeyFile; do
      cpath="$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='$key';" 2>/dev/null || true)"
      [[ -n "$cpath" ]] || continue
      if [[ ! -e "$cpath" && -e "$STAGEROOT/system$cpath" ]]; then
        restore_path system "$cpath"
      fi
      [[ -e "$cpath" ]] || err "ВНИМАНИЕ: 3x-ui ждёт TLS ($key) '$cpath', но файла нет — восстанови из letsencrypt/cert или перевыпусти в панели."
    done
  fi
fi

# remnawave + явные каталоги проектов (/opt/remnawave, /opt/remnanode, /var/lib/remnawave, /srv/cabinet)
if [[ -n "${HAS[projects]:-}${HAS[remnawave]:-}" ]] && should_do projects "каталоги проектов (remnawave panel/node, cabinet)"; then
  for p in /var/www/photo /root/photo-site-src /opt/remnawave /opt/remnanode /var/lib/remnawave /srv/cabinet; do
    restore_path projects "$p"
    restore_path remnawave "$p"   # совместимость со старыми бэкапами
  done
fi

# mtproto / telemt / mtproto.zig
if [[ -n "${HAS[mtproto]:-}" ]] && should_do mtproto "MTProto-прокси (telemt / mtproto.zig)"; then
  # Бинарь telemt в бэкапе? Тогда install.sh НЕ нужен — берём точную версию из бэкапа.
  telemt_in_backup=0
  for b in "$STAGEROOT"/mtproto/usr/local/bin/telemt "$STAGEROOT"/mtproto/usr/bin/telemt "$STAGEROOT"/mtproto/opt/telemt/telemt; do
    [[ -e "$b" ]] && { telemt_in_backup=1; break; }
  done
  # доустановка telemt только как фолбэк: есть юнит, но бинаря нет НИ в системе, НИ в бэкапе
  if [[ $INSTALL_MISSING -eq 1 ]] && [[ -f "$STAGEROOT/mtproto/etc/systemd/system/telemt.service" ]] \
     && ! command -v telemt >/dev/null 2>&1 && [[ $telemt_in_backup -eq 0 ]]; then
    confirm "telemt не установлен и его нет в бэкапе — поставить telemt/telemt?" && { require_cmd curl; run_sh "curl -fsSL '$TELEMT_INSTALL_URL' -o /tmp/telemt-install.sh && sh /tmp/telemt-install.sh || true"; } || true
  fi
  # доустановка mtproto.zig (mtbuddy) только как фолбэк: конфиг есть, а бинаря нет ни в системе, ни в бэкапе
  if [[ $INSTALL_MISSING -eq 1 ]] && [[ -e "$STAGEROOT/mtproto/opt/mtproto-proxy" ]] \
     && ! command -v mtbuddy >/dev/null 2>&1 && [[ ! -e "$STAGEROOT/mtproto/usr/local/bin/mtbuddy" ]]; then
    confirm "mtbuddy не установлен и его нет в бэкапе — поставить sleep3r/mtproto.zig?" && { require_cmd curl; run_sh "curl -fsSL '$MTPROTO_BOOTSTRAP_URL' -o /tmp/mtproto-bootstrap.sh && bash /tmp/mtproto-bootstrap.sh || true"; } || true
  fi
  for p in /etc/telemt /opt/telemt /usr/local/etc/telemt /var/lib/telemt \
           /usr/local/bin/telemt /usr/bin/telemt /etc/systemd/system/telemt.service \
           /opt/mtproto-proxy /etc/mtproto-proxy /usr/local/bin/mtbuddy /usr/local/bin/mtproto-proxy \
           /etc/systemd/system/mtproto-proxy.service /etc/systemd/system/mtproto-tunnel-pool.timer \
           /etc/systemd/system/mtproto-tunnel-pool.service /etc/systemd/system/mtproto-syn-limit.service \
           /opt/mtpr-simple /usr/local/bin/mekopr \
           /etc/systemd/system/mtpr-synfix.service /etc/systemd/system/mtpr-nft-synfix.service; do
    restore_path mtproto "$p"
  done
  # отдельно найденные файлы (mtproto/found/<абс>)
  if [[ -d "$STAGEROOT/mtproto/found" ]]; then
    while IFS= read -r f; do
      abs="/${f#"$STAGEROOT"/mtproto/found/}"
      backup_existing "$abs"
      run mkdir -p "$(dirname "$abs")"
      run cp -a "$f" "$abs"
      ok "восстановлен найденный конфиг: $abs"
    done < <(find "$STAGEROOT/mtproto/found" -type f 2>/dev/null)
  fi
  # Права на рабочие/конфиг-каталоги: без этого telemt падает с «permission denied».
  # Читаем User=/Group=/WorkingDirectory= из юнита и создаём юзера + chown'им папки.
  run_sh "systemctl daemon-reload 2>/dev/null || true"   # нужно до чтения/старта юнита
  fix_service_perms /etc/systemd/system/telemt.service \
      /etc/telemt /opt/telemt /usr/local/etc/telemt /var/lib/telemt
  fix_service_perms /etc/systemd/system/mtproto-proxy.service \
      /opt/mtproto-proxy /etc/mtproto-proxy
  # mekopr (MTPROTO_FIX_By_MEKO): юниты работают от root, но выравниваем владельца
  # рабочего каталога и делаем скрипты исполняемыми — иначе service не стартует.
  fix_service_perms /etc/systemd/system/mtpr-synfix.service     /opt/mtpr-simple
  fix_service_perms /etc/systemd/system/mtpr-nft-synfix.service /opt/mtpr-simple
  if [[ -d /opt/mtpr-simple ]]; then
    run_sh "chmod +x /opt/mtpr-simple/*.sh /opt/mtpr-simple/proxys/*.sh /opt/mtpr-simple/*.py 2>/dev/null || true"
  fi
fi

# systemd unit-файлы (кастомные службы)
if [[ -n "${HAS[systemd]:-}" ]] && should_do systemd "кастомные systemd-службы"; then
  restore_path system /etc/systemd/system
  run_sh "systemctl daemon-reload || true"
fi

# ════════════════════ ФАЗА 3: ЗАПУСК ПРОЕКТОВ ПО ОЧЕРЕДИ ════════════════════
step "Фаза 3 — запуск проектов"

# 3.1 docker-compose проекты
if [[ -n "${HAS[docker-compose]:-}" ]] && should_do docker-compose "docker-compose проекты"; then
  if [[ $APPLY -eq 0 ]] || { command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }; then
    while IFS= read -r cf; do
      proj_src="$(dirname "$cf")"
      real_dir="${proj_src#"$STAGEROOT"/docker/compose}"
      log "Проект: $real_dir"
      backup_existing "$real_dir"
      run mkdir -p "$real_dir"
      if command -v rsync >/dev/null 2>&1; then
        run rsync -a "$proj_src/" "$real_dir/"
      else
        run cp -a "$proj_src/." "$real_dir/"   # fallback, если rsync недоступен
      fi
      run_sh "cd '$real_dir' && docker compose up -d || echo '[!] не удалось поднять $real_dir (проверь .env/порты)'"
    done < <(find "$STAGEROOT/docker/compose" \
                \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' \
                   -o -name 'compose.yml' -o -name 'compose.yaml' \) 2>/dev/null | sort)
  else
    warn "docker compose недоступен — compose-проекты пропущены."
  fi
fi

# 3.1b именованные docker volume'ы (только если в бэкапе есть дампы; перезаписывает данные!)
if [[ -n "${HAS[volumes]:-}" ]] && should_do volumes "данные docker volume (перезапись!)"; then
  while IFS= read -r vd; do
    vname="$(basename "$vd" .tar.gz)"
    confirm "Перезаписать данные volume '$vname'?" || continue
    run docker volume create "$vname"
    run_sh "docker run --rm -v '$vname':/to -v '$(dirname "$vd")':/from alpine sh -c 'cd /to && tar xzf /from/$(basename "$vd")'"
    ok "volume восстановлен: $vname"
  done < <(find "$STAGEROOT/docker/volumes-data" -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null | sort)
fi

# 3.1c восстановление баз PostgreSQL из дампов
if [[ -n "${HAS[postgres]:-}" ]] && should_do postgres "восстановление баз PostgreSQL"; then
  for dump in "$STAGEROOT/docker/pg-dumps/"*.sql.gz; do
    [[ -e "$dump" ]] || continue
    c="$(basename "$dump" .sql.gz)"
    log "БД контейнера: $c"
    if [[ $APPLY -eq 1 ]]; then
      if ! docker inspect "$c" >/dev/null 2>&1; then
        warn "контейнер $c не запущен — пропускаю (подними его compose-проект)."; continue
      fi
      rdy=0
      for _ in $(seq 1 30); do
        docker exec "$c" sh -c 'pg_isready -U "${POSTGRES_USER:-postgres}"' >/dev/null 2>&1 && { rdy=1; break; }
        sleep 2
      done
      [[ $rdy -eq 1 ]] || { warn "postgres в $c не готов — пропускаю."; continue; }
    fi
    run_sh "gunzip -c '$dump' | docker exec -i '$c' sh -c 'psql -v ON_ERROR_STOP=0 -U \"\${POSTGRES_USER:-postgres}\" -d postgres' >/dev/null 2>&1 && echo '[+] БД восстановлена в $c' || echo '[!] ошибки при восстановлении БД в $c'"
  done
  warn "После восстановления БД перезапусти зависимые сервисы: docker compose restart в каталоге проекта."
fi

# 3.2 нативные службы (если unit восстановлен в /etc/systemd/system)
run_sh "systemctl daemon-reload 2>/dev/null || true"
for svc in x-ui telemt mtproto-proxy mtpr-synfix mtpr-nft-synfix; do
  { [[ -f "/etc/systemd/system/${svc}.service" ]] || [[ -f "$STAGEROOT/system/etc/systemd/system/${svc}.service" ]] \
    || [[ -f "$STAGEROOT/mtproto/etc/systemd/system/${svc}.service" ]] \
    || [[ -f "$STAGEROOT/3x-ui/native/etc/systemd/system/${svc}.service" ]]; } || continue
  if should_do systemd "запуск службы ${svc}.service"; then
    run_sh "systemctl enable '${svc}.service' >/dev/null 2>&1 || true; systemctl restart '${svc}.service' && echo '[+] служба ${svc} запущена' || echo '[!] ${svc} не стартовала (возможно, она в docker — это норм)'"
  fi
done
if { [[ -f /etc/systemd/system/mtproto-tunnel-pool.timer ]] || [[ -f "$STAGEROOT/mtproto/etc/systemd/system/mtproto-tunnel-pool.timer" ]]; } \
   && should_do systemd "таймер mtproto-tunnel-pool"; then
  run_sh "systemctl enable --now mtproto-tunnel-pool.timer 2>/dev/null && echo '[+] таймер mtproto-tunnel-pool включён' || true"
fi

# 3.3 crontab
if [[ -n "${HAS[crontab]:-}" ]] && should_do crontab "запланированные задачи (cron)"; then
  restore_path system /etc/crontab
  restore_path system /etc/cron.d
  if [[ -d "$STAGEROOT/system/crontabs" ]]; then
    for cf in "$STAGEROOT/system/crontabs"/*.cron; do
      [[ -e "$cf" ]] || continue
      u="$(basename "$cf" .cron)"
      if id "$u" >/dev/null 2>&1; then run crontab -u "$u" "$cf"; ok "crontab пользователя $u"
      else warn "пользователь $u не найден — crontab пропущен"; fi
    done
  fi
fi

# 3.4 firewall (в самом конце; гарантируем SSH, чтобы не отрезать доступ)
if [[ -n "${HAS[firewall]:-}" ]] && should_do firewall "firewall (ufw)"; then
  restore_path system /etc/ufw
  if command -v ufw >/dev/null 2>&1 || [[ $APPLY -eq 0 ]]; then
    for p in $(detect_ssh_ports); do
      run_sh "ufw allow ${p}/tcp comment 'restored sshd port' >/dev/null 2>&1 || true"
      warn "SSH-порт ${p}/tcp разрешён в ufw перед включением."
    done
    run_sh "ufw --force enable && echo '[+] ufw включён (правила восстановлены из /etc/ufw)' || echo '[!] ufw не включился'"
    if [[ $APPLY -eq 1 ]]; then
      echo "── ufw status ──"; ufw status verbose 2>/dev/null || true; echo "────────────────"
      for p in $(detect_ssh_ports); do
        if ufw status 2>/dev/null | grep -qE "(^|[[:space:]])${p}/tcp[[:space:]].*ALLOW"; then
          ok "SSH-порт ${p}/tcp открыт в ufw ✓"
        else
          err "ВНИМАНИЕ: SSH-порт ${p}/tcp НЕ найден в разрешённых! Не закрывай текущую сессию."
        fi
      done
    fi
  fi
  # Персистентные правила /etc/iptables (rules.v4/v6, в т.ч. MTPR_SYNFIX от mekopr).
  # Возвращаем ФАЙЛ на место (грузится netfilter-persistent при загрузке), но НЕ
  # применяем сейчас — свежие правила переприменит служба mtpr-synfix при старте.
  if [[ -d "$STAGEROOT/system/etc/iptables" ]]; then
    restore_path system /etc/iptables
    warn "Восстановлен /etc/iptables (rules.v4/v6). Сейчас НЕ применяю; применится при загрузке или при старте mtpr-synfix."
  fi
  if [[ -f "$STAGEROOT/system/iptables.txt" ]]; then
    run cp -a "$STAGEROOT/system/iptables.txt" /root/iptables-backup.rules
    warn "Сырые правила iptables сохранены в /root/iptables-backup.rules (НЕ применяю автоматически: конфликт с Docker)."
    echo "      Применить вручную при необходимости: iptables-restore < /root/iptables-backup.rules"
  fi
fi

# ───────────────────────────────── Итог ─────────────────────────────────────
step "Готово"
if [[ $APPLY -eq 1 ]]; then
  command -v docker >/dev/null 2>&1 && docker ps --format '   docker: {{.Names}} ({{.Status}})' 2>/dev/null || true
  systemctl is-active --quiet nginx 2>/dev/null && echo "   nginx: active" || true
  for svc in x-ui telemt mtproto-proxy mtpr-synfix mtpr-nft-synfix; do
    systemctl is-active --quiet "$svc" 2>/dev/null && echo "   $svc: active" || true
  done
  echo
  ok "Копии заменённых файлов (для отката): $PRE_RESTORE_DIR"
  warn "ОБЯЗАТЕЛЬНО открой ВТОРУЮ SSH-сессию и проверь доступ ДО выхода из текущей."
  echo "fstab/hosts/hostname НЕ применялись (другое железо) — лежат в $STAGEROOT/system/etc/"
else
  echo
  warn "Это был DRY-RUN. Команды выше НЕ выполнялись. Запусти без --dry-run для реального восстановления."
fi
