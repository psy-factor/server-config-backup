#!/usr/bin/env bash
#
# Версия: 1.4.1
#
# server-backup.sh — резервная копия конфигурации сервера для быстрого развёртывания.
#
# Что собирает:
#   - Docker: Compose-проекты, .env, список образов, контейнеров, сетей и томов
#   - Bedolaga Bot и Cloudflare Tunnel: конфиги, bind mounts и тома Docker
#   - 3x-ui (VLESS): база x-ui.db + сертификаты (native или docker-вариант)
#   - Remnawave node: docker-compose.yml + .env + сертификаты
#   - nginx: /etc/nginx целиком
#   - Let's Encrypt: /etc/letsencrypt (сертификаты + ключи)
#   - SSH: /etc/ssh (sshd_config, host-ключи), authorized_keys пользователей
#   - Сеть/доступ: ufw/iptables, кастомные порты, sysctl
#   - Система: crontab'ы, список установленных пакетов, fstab, systemd unit'ы
#
# Результат: один tar.gz (опционально зашифрованный GPG) + manifest с метаданными.
#
# Использование:
#   sudo ./server-backup.sh                 # бэкап в Backups рядом со скриптом
#   sudo ./server-backup.sh -o /mnt/backup  # другой каталог назначения
#   sudo BACKUP_PASSPHRASE='секрет' ./server-backup.sh -e   # с шифрованием
#   sudo ./server-backup.sh --volumes       # включить все тома Docker
#   sudo ./server-backup.sh --no-volumes    # исключить тома Docker
#   sudo ./server-backup.sh --cold-docker   # остановить контейнеры на время копирования
#
set -euo pipefail
SCRIPT_VERSION="1.4.1"
if [[ "${1:-}" == --version ]]; then
  printf '%s %s\n' "${0##*/}" "$SCRIPT_VERSION"
  exit 0
fi

# ─────────────────────────────── Настройки ──────────────────────────────────
# По умолчанию архивы кладём в подпапку Backups РЯДОМ со скриптом (можно переопределить -o).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"
DEST_DIR="$SCRIPT_DIR/Backups"      # куда складывать архивы
ENCRYPT=0                            # 1 = шифровать GPG (нужен BACKUP_PASSPHRASE)
DUMP_VOLUMES=targets                 # targets, all или none
COLD_DOCKER=0
STOPPED_CONTAINERS=()
HOSTNAME_TAG="$(hostname -s 2>/dev/null || echo server)"

# Каталоги, где обычно лежат docker-compose проекты (3x-ui, remnanode и пр.).
# Добавь свои пути, если разворачивал в нестандартных местах.
COMPOSE_SEARCH_DIRS=(
  /opt
  /root
  /home
  /srv
  /etc/x-ui
)

# Пути 3x-ui при нативной установке.
XUI_NATIVE_PATHS=(
  /etc/x-ui
  /usr/local/x-ui                      # бинарь + ассеты панели
  /usr/bin/x-ui                        # management-CLI (меню `x-ui`)
  /etc/systemd/system/x-ui.service
)

# Явные пути к конфигам MTProto-прокси (telemt / mtproto.zig и т.п.).
# Добавь сюда точные пути, если знаешь их; ниже скрипт ещё и сам поищет по имени.
MTPROTO_PATHS=(
  # telemt (telemt/telemt): config.toml + compose/systemd + сам бинарь
  /etc/telemt
  /opt/telemt
  /usr/local/etc/telemt
  /var/lib/telemt                      # рабочий каталог службы (если используется)
  /usr/local/bin/telemt                # нативный бинарь (чтобы не переустанавливать)
  /usr/bin/telemt
  /etc/systemd/system/telemt.service
  # mtproto.zig (sleep3r/mtproto.zig): mtbuddy ставит сюда
  /opt/mtproto-proxy
  /etc/mtproto-proxy
  /etc/systemd/system/mtproto-proxy.service
  /etc/systemd/system/mtproto-tunnel-pool.timer
  /etc/systemd/system/mtproto-tunnel-pool.service
  /etc/systemd/system/mtproto-syn-limit.service
  /usr/local/bin/mtbuddy
  /usr/local/bin/mtproto-proxy
  # MTPROTO_FIX_By_MEKO (команда mekopr): SYN-fix для MTProto
  /opt/mtpr-simple                     # установка + рабочий каталог (config_path, port, apply/nft-скрипты, proxys/, data/)
  /usr/local/bin/mekopr                # команда-симлинк на /opt/mtpr-simple/main.sh
  /etc/systemd/system/mtpr-synfix.service       # iptables-вариант SYN-fix
  /etc/systemd/system/mtpr-nft-synfix.service   # nftables-вариант SYN-fix
)

# Имена файлов конфигурации MTProto, которые ищем по дереву каталогов.
MTPROTO_FILE_GLOBS=(
  'telemt*'
  'mtproto.zig'
  'mtproto*.conf'
  'mtproto*.toml'
  'mtproto*.json'
)
# Где искать эти файлы.
MTPROTO_SEARCH_DIRS=(/etc /opt /root /srv /usr/local/etc)

# Прочие явные пути проектов (бэкапятся «как есть»).
EXTRA_PROJECT_PATHS=(
  /var/www/photo                 # photo site: code/storage/orders/config.local.php
  /root/photo-site-src            # source repo if exists
  /opt/remnawave                 # remnawave panel: .env, docker-compose.yml, app-config.json
  /opt/remnanode                 # remnawave node
  /var/lib/remnawave             # xray-конфиги и TLS-серты ноды
  /srv/cabinet                   # bedolaga-cabinet (статика + .env)
)

# Имена docker-контейнеров с PostgreSQL, которые нужно дампить через pg_dump.
# Скрипт также автоматически найдёт контейнеры с образом postgres/postgis.
PG_CONTAINERS_EXTRA=(remnawave-db remnawave_bot_db)

# ─────────────────────────── Разбор аргументов ──────────────────────────────
usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '2,30p'
  exit 0
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out)      DEST_DIR="$2"; shift 2 ;;
    -e|--encrypt)  ENCRYPT=1; shift ;;
    --volumes)     DUMP_VOLUMES=all; shift ;;
    --no-volumes)  DUMP_VOLUMES=none; shift ;;
    --cold-docker) COLD_DOCKER=1; shift ;;
    --retention)   echo "Параметр --retention игнорируется. Старые архивы сохраняются." >&2; shift 2 ;;
    -h|--help)     usage ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

# ───────────────────────────── Подготовка ───────────────────────────────────
# Определяем IP-адрес сервера для имени архива: сначала внешний (через сервисы),
# при недоступности сети — основной локальный IP, в крайнем случае — hostname.
detect_ip() {
  local ip=""
  for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://ipinfo.io/ip"; do
    ip="$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" || true
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { echo "$ip"; return; }
  done
  # локальный IP основного маршрута
  ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { echo "$ip"; return; }
  echo "$HOSTNAME_TAG"
}
IP_TAG="$(detect_ip)"

TS="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d /tmp/srvbak.XXXXXX)"
STAGE="$WORK/${IP_TAG}-${TS}"
mkdir -p "$STAGE"
mkdir -p "$DEST_DIR"

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }

# Копирование «как есть», без падения если путь отсутствует.
copy() {  # copy <src> <dest-subdir>
  local src="$1" sub="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$STAGE/$sub"
    cp -a --parents "$src" "$STAGE/$sub" 2>/dev/null \
      || cp -a "$src" "$STAGE/$sub/" 2>/dev/null \
      || warn "не удалось скопировать $src"
    ok "сохранено: $src"
  fi
}

# Выполнить команду, если она есть, и сохранить вывод в файл.
dump_cmd() {  # dump_cmd <file> <cmd...>
  local out="$1"; shift
  command -v "$1" >/dev/null 2>&1 || return 0
  mkdir -p "$(dirname "$STAGE/$out")"
  "$@" > "$STAGE/$out" 2>/dev/null || true
}

restart_containers() {
  [[ ${#STOPPED_CONTAINERS[@]} -gt 0 ]] || return 0
  docker start "${STOPPED_CONTAINERS[@]}" >/dev/null || return
  STOPPED_CONTAINERS=()
}
cleanup() {
  local status=$?
  restart_containers || status=1
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT

[[ $EUID -ne 0 ]] && warn "Скрипт лучше запускать через sudo/root, иначе часть файлов будет пропущена."

# ───────────────────────────── 1. Docker ────────────────────────────────────
if command -v docker >/dev/null 2>&1; then
  log "Сбор информации о Docker"
  dump_cmd docker/ps.txt           docker ps -a
  dump_cmd docker/images.txt       docker images
  dump_cmd docker/networks.txt     docker network ls
  dump_cmd docker/volumes.txt      docker volume ls
  dump_cmd docker/compose-ls.txt   docker compose ls --all

  # inspect всех контейнеров (восстановить ручные docker run проще по этим данным)
  if docker ps -aq >/dev/null 2>&1; then
    mkdir -p "$STAGE/docker/inspect"
    for c in $(docker ps -aq); do
      name="$(docker inspect --format '{{.Name}}' "$c" 2>/dev/null | tr -d '/')"
      docker inspect "$c" > "$STAGE/docker/inspect/${name:-$c}.json" 2>/dev/null || true
    done
  fi

  if [[ $COLD_DOCKER -eq 1 ]]; then
    mapfile -t STOPPED_CONTAINERS < <(docker ps -q)
    if [[ ${#STOPPED_CONTAINERS[@]} -gt 0 ]]; then
      log "Остановка контейнеров для холодной копии"
      docker stop "${STOPPED_CONTAINERS[@]}" >/dev/null
    fi
  fi

  copy_docker_source() {
    local source="$1"
    mkdir -p "$STAGE/docker/files"
    rsync -aR -- "$source" "$STAGE/docker/files/"
  }

  declare -A SEEN=()
  backup_compose_dir() {
    local d="$1" base="docker/compose$1"
    [[ -z "${SEEN[$d]:-}" ]] || return 0
    SEEN[$d]=1
    mkdir -p "$STAGE/$base"
    rsync -a --exclude='/Backups/' --exclude='*.log' "$d/" "$STAGE/$base/" 2>/dev/null \
      || cp -a "$d/." "$STAGE/$base/" || return
    ok "compose-проект: $d"
  }

  # Активные и остановленные контейнеры дают исходный каталог, имя проекта,
  # порядок -f и --env-file, даже если проект лежит вне стандартных папок.
  python3 - "$STAGE/docker" "$WORK" "$DUMP_VOLUMES" <<'DOCKER_TARGETS'
import json
import posixpath
import re
import sys
from pathlib import Path

docker = Path(sys.argv[1])
work = Path(sys.argv[2])
with_volumes = sys.argv[3] != 'none'
containers = []
for path in sorted((docker / 'inspect').glob('*.json')):
    if path.stat().st_size:
        containers.extend(json.loads(path.read_text()))

prefix = 'com.docker.compose.'
projects = {}
tunnels = set()
for container in containers:
    config = container.get('Config') or {}
    labels = config.get('Labels') or {}
    if labels.get(prefix + 'oneoff', '').lower() == 'true':
        continue
    name = container['Name'].lstrip('/')
    image = config.get('Image', '').rsplit('/', 1)[-1].split('@')[0].split(':')[0]
    project = labels.get(prefix + 'project')
    workdir = labels.get(prefix + 'project.working_dir', '')
    bot_id = f'{project} {workdir} {image}'.lower()
    bot = name in ('remnawave_bot', 'remnawave_bot_db', 'remnawave_bot_redis') or (
        'bedolaga-cabinet' not in bot_id and
        any(key in bot_id for key in ('remnawave-bedolaga-telegram-bot', 'bedolaga-bot'))
    )
    tunnel = image == 'cloudflared'
    if not (bot or tunnel):
        continue
    if not project:
        if tunnel:
            tunnels.add(name)
            path = docker / 'cloudflared' / f'{name}.json'
            path.parent.mkdir(exist_ok=True)
            path.write_text(json.dumps(container, indent=2) + '\n')
        continue
    if not re.fullmatch('[a-z0-9][a-z0-9_-]*', project):
        raise SystemExit('Не удалось определить имя Compose-проекта')
    files = labels.get(prefix + 'project.config_files', '')
    env_files = labels.get(prefix + 'project.environment_file', '')
    if not workdir.startswith('/') or workdir == '/' or not files:
        raise SystemExit(f'Не удалось определить файлы Compose-проекта {project}')
    workdir = posixpath.normpath(workdir)
    plan = projects.setdefault(project, {
        'project': project, 'directory': workdir,
        'files': [posixpath.normpath(posixpath.join(workdir, path)) for path in files.split(',')],
        'env_files': [posixpath.normpath(posixpath.join(workdir, path)) for path in env_files.split(',')] if env_files else [],
        'components': [], 'binds': [],
    })
    for component, enabled in (('bedolaga-bot', bot), ('cloudflared', tunnel)):
        if enabled and component not in plan['components']:
            plan['components'].append(component)

binds = set()
volumes = set()
for container in containers:
    name = container['Name'].lstrip('/')
    config = container.get('Config') or {}
    labels = config.get('Labels') or {}
    plan = projects.get(labels.get(prefix + 'project'))
    if plan is None and name not in tunnels:
        continue
    pgdata = next((env.partition('=')[2] for env in config.get('Env') or []
                   if env.startswith('PGDATA=')), '/var/lib/postgresql/data')
    for mount in container.get('Mounts') or []:
        if mount['Type'] == 'bind':
            source = mount['Source']
            if source == '/' or source.startswith(('/proc/', '/sys/', '/dev/', '/run/', '/var/run/', '/var/lib/docker/')):
                continue
            if source in ('/proc', '/sys', '/dev', '/run', '/var/run', '/var/lib/docker') or Path(source).is_socket():
                continue
            if plan is not None and source not in plan['binds']:
                plan['binds'].append(source)
            if plan is None or not source.startswith(plan['directory'] + '/'):
                binds.add(source)
        elif with_volumes and mount['Type'] == 'volume':
            volumes.add(mount['Name'])
            destination = mount['Destination'].rstrip('/')
            if pgdata == destination or pgdata.startswith(destination + '/'):
                path = docker / 'pg-data-volumes' / name
                path.parent.mkdir(exist_ok=True)
                path.write_text(mount['Name'] + '\n')

(work / 'docker-target-volumes').write_text(''.join(v + '\n' for v in sorted(volumes)))
with (work / 'docker-target-binds').open('wb') as paths:
    for source in sorted(binds):
        paths.write(source.encode() + b'\0')

for project, plan in projects.items():
    path = docker / 'compose-targets' / f'{project}.json'
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(plan, indent=2) + '\n')
DOCKER_TARGETS

  while IFS= read -r -d '' source; do
    if [[ -e "$source" ]]; then
      copy_docker_source "$source"
    fi
  done < "$WORK/docker-target-binds"

  for plan in "$STAGE/docker/compose-targets/"*.json; do
    [[ -f "$plan" ]] || continue
    mapfile -d '' -t compose_paths < <(python3 -c '
import json, os, sys
plan = json.load(open(sys.argv[1]))
for path in [plan["directory"], *plan["files"], *plan["env_files"]]:
    sys.stdout.buffer.write(os.fsencode(path) + b"\0")
' "$plan")
    d="${compose_paths[0]}"
    if [[ ! -d "$d" ]]; then
      warn "Каталог Compose-проекта не найден: $d"; exit 1
    fi
    backup_compose_dir "$d"
    for f in "${compose_paths[@]:1}"; do
      if [[ ! -f "$f" ]]; then
        warn "Файл Compose-проекта недоступен для копирования: $f"; exit 1
      fi
      [[ "$f" == "$d/"* ]] || copy_docker_source "$f"
    done
    ok "Bedolaga Bot / Cloudflare Tunnel: сохранён план Compose ${plan##*/}"
  done

  log "Поиск docker-compose проектов"
  while IFS= read -r f; do
    backup_compose_dir "$(dirname "$f")" || warn "Ошибка проекта: $f"
  done < <(
    for sd in "${COMPOSE_SEARCH_DIRS[@]}"; do
      log "Поиск Compose: $sd" >&2
      [[ -d "$sd" ]] && find "$sd" -maxdepth 4 \
        \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) \
        2>/dev/null
    done | sort -u
  )

  # Дамп баз PostgreSQL из контейнеров (remnawave-db, БД bedolaga-bot и т.п.).
  # Логический дамп надёжнее копии volume'а: его можно восстановить на новую БД.
  log "Поиск PostgreSQL-контейнеров для pg_dump"
  mkdir -p "$STAGE/docker/pg-dumps"
  # автопоиск по образу + явный список
  pg_found="$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
              | awk '/postgres|postgis/ {print $1}')"
  while IFS= read -r c; do
    [[ $COLD_DOCKER -eq 0 && -n "$c" ]] || continue
    [[ "$(docker inspect --format '{{.State.Running}}' "$c" 2>/dev/null)" == true ]] || continue
    # POSTGRES_USER/POSTGRES_DB заданы внутри контейнера — используем их
    if docker exec "$c" sh -c 'pg_dumpall -U "${POSTGRES_USER:-postgres}"' 2>/dev/null \
         | gzip > "$STAGE/docker/pg-dumps/${c}.sql.gz" \
       && [[ -s "$STAGE/docker/pg-dumps/${c}.sql.gz" ]]; then
      ok "pg_dumpall: $c"
    else
      rm -f "$STAGE/docker/pg-dumps/${c}.sql.gz"
      warn "не удалось дампить БД контейнера $c"
    fi
  done < <(printf '%s\n' "$pg_found" "${PG_CONTAINERS_EXTRA[@]}" | sort -u)

  # Тома бота и туннеля входят в обычный бэкап. --volumes добавляет остальные.
  if [[ $DUMP_VOLUMES == all ]]; then
    docker volume ls -q > "$WORK/docker-all-volumes"
  else
    cp "$WORK/docker-target-volumes" "$WORK/docker-all-volumes"
  fi
  if [[ -s "$WORK/docker-all-volumes" ]]; then
    if [[ $COLD_DOCKER -eq 0 ]]; then
      warn "Для согласованной файловой копии БД используй --cold-docker."
    fi
    mkdir -p "$STAGE/docker/volumes-data"
    while IFS= read -r v; do
      [[ -n "$v" ]] || continue
      archive="$STAGE/docker/volumes-data/$v.tar.gz"
      if docker run --rm --mount "type=volume,src=$v,dst=/from,readonly" \
          alpine tar czf - -C /from . > "$archive"; then
        ok "volume: $v"
      else
        rm -f "$archive"
        warn "volume $v не выгружен"
        if grep -Fxq -- "$v" "$WORK/docker-target-volumes"; then exit 1; fi
      fi
    done < "$WORK/docker-all-volumes"
  fi
  restart_containers
else
  warn "docker не найден — раздел Docker пропущен."
fi

# ───────────────────────────── 2. 3x-ui ─────────────────────────────────────
log "3x-ui (VLESS панель)"
# Нативная установка
for p in "${XUI_NATIVE_PATHS[@]}"; do copy "$p" "3x-ui/native"; done
# База SQLite — отдельно делаем целостный дамп, если есть sqlite3
if command -v sqlite3 >/dev/null 2>&1; then
  for db in /etc/x-ui/x-ui.db $(find "${COMPOSE_SEARCH_DIRS[@]}" -maxdepth 4 -name 'x-ui.db' 2>/dev/null); do
    [[ -f "$db" ]] || continue
    mkdir -p "$STAGE/3x-ui/db-dumps"
    safe="$(echo "$db" | tr '/' '_')"
    sqlite3 "$db" ".backup '$STAGE/3x-ui/db-dumps/${safe}'" 2>/dev/null \
      && ok "целостный дамп БД: $db"
    # Бэкапим сами TLS-файлы, на которые ссылается панель (webCertFile/webKeyFile),
    # даже если они лежат вне /etc/letsencrypt и /root/cert — иначе после restore
    # панель по HTTPS не поднимется. Кладём в зеркало system, откуда их вернёт restore.
    for key in webCertFile webKeyFile; do
      val="$(sqlite3 "$db" "SELECT value FROM settings WHERE key='$key';" 2>/dev/null || true)"
      [[ -n "$val" && -e "$val" ]] && copy "$val" "system"
    done
  done
fi

# ─────────────────────────── 3. Remnawave node ──────────────────────────────
log "Remnawave node"
for d in /opt/remnanode /opt/remnawave* /root/remnanode; do
  [[ -d "$d" ]] && copy "$d" "remnawave"
done

# ─────────────── 3a. Явные пути проектов (remnawave/cabinet) ────────────────
log "Явные каталоги проектов"
for p in "${EXTRA_PROJECT_PATHS[@]}"; do copy "$p" "projects"; done

# ───────────────────── 3b. MTProto-прокси (telemt) ──────────────────────────
log "MTProto-прокси (telemt / mtproto.zig)"
# Явно заданные пути
for p in "${MTPROTO_PATHS[@]}"; do copy "$p" "mtproto"; done
# Поиск по именам файлов
for sd in "${MTPROTO_SEARCH_DIRS[@]}"; do
  [[ -d "$sd" ]] || continue
  for glob in "${MTPROTO_FILE_GLOBS[@]}"; do
    while IFS= read -r f; do
      copy "$f" "mtproto/found"
    done < <(find "$sd" -maxdepth 4 -name "$glob" 2>/dev/null)
  done
done

# ───────────────────────────── 4. nginx ─────────────────────────────────────
log "nginx"
copy /etc/nginx              "system"
dump_cmd system/nginx-T.txt  nginx -T

# ──────────────────────── 5. TLS / Let's Encrypt ────────────────────────────
log "TLS-сертификаты"
copy /etc/letsencrypt "system"
copy /root/cert       "system"     # частое место для сертов 3x-ui/remnawave
copy /root/.acme.sh   "system"     # acme.sh-аккаунт и конфиг автопродления (3x-ui «Get cert»)

# ───────────────────────────── 6. SSH ───────────────────────────────────────
log "SSH"
copy /etc/ssh "system"
# authorized_keys всех пользователей
while IFS=: read -r user _ uid _ _ home _; do
  [[ "$uid" -ge 1000 || "$user" == "root" ]] || continue
  [[ -f "$home/.ssh/authorized_keys" ]] && copy "$home/.ssh/authorized_keys" "ssh-keys/$user"
done < /etc/passwd

# ──────────────────────── 7. Сеть / firewall / порты ────────────────────────
log "Firewall и сетевые настройки"
copy /etc/ufw                "system"
copy /etc/iptables           "system"     # персистентные rules.v4/rules.v6 (в т.ч. MTPR_SYNFIX от mekopr)
dump_cmd system/ufw-status.txt   ufw status verbose
dump_cmd system/iptables.txt     iptables-save
dump_cmd system/ip6tables.txt    ip6tables-save
dump_cmd system/listen-ports.txt ss -tulpn
copy /etc/sysctl.conf        "system"
copy /etc/sysctl.d           "system"

# ──────────────────────── 8. Системное окружение ────────────────────────────
log "Системные настройки"
copy /etc/fstab              "system"
copy /etc/hosts              "system"
copy /etc/hostname           "system"
copy /etc/crontab            "system"
copy /etc/cron.d             "system"
copy /etc/systemd/system     "system"   # кастомные unit'ы (x-ui, и т.п.)
# crontab'ы пользователей
mkdir -p "$STAGE/system/crontabs"
for u in $(cut -d: -f1 /etc/passwd); do
  crontab -l -u "$u" 2>/dev/null > "$STAGE/system/crontabs/$u.cron" || true
  [[ -s "$STAGE/system/crontabs/$u.cron" ]] || rm -f "$STAGE/system/crontabs/$u.cron"
done
# список установленных пакетов (для восстановления окружения)
dump_cmd system/packages-dpkg.txt   dpkg --get-selections
dump_cmd system/packages-rpm.txt    rpm -qa

# ───────────────────────────── Манифест ─────────────────────────────────────
{
  echo "Backup manifest"
  echo "==============="
  echo "script_version: $SCRIPT_VERSION"
  echo "host        : $(hostname -f 2>/dev/null || hostname)"
  echo "ip          : $IP_TAG"
  echo "date        : $(date -Iseconds)"
  echo "kernel      : $(uname -a)"
  echo "os          : $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
  echo "docker      : $(docker --version 2>/dev/null || echo 'нет')"
  echo "encrypted   : $([[ $ENCRYPT -eq 1 ]] && echo yes || echo no)"
  echo "volumes     : $DUMP_VOLUMES"
  echo "cold_docker : $COLD_DOCKER"
  echo
  echo "Содержимое:"
  ( cd "$STAGE" && find . -maxdepth 3 -type d | sort )
} > "$STAGE/MANIFEST.txt"

# ─────────────────────────── Упаковка архива ────────────────────────────────
log "Упаковка архива"
ARCHIVE="$DEST_DIR/${IP_TAG}-${TS}.tar.gz"
tar czf "$ARCHIVE" -C "$WORK" "$(basename "$STAGE")"
chmod 600 "$ARCHIVE"

if [[ $ENCRYPT -eq 1 ]]; then
  if [[ -z "${BACKUP_PASSPHRASE:-}" ]]; then
    warn "ENCRYPT=1, но BACKUP_PASSPHRASE не задан — архив оставлен без шифрования."
  else
    log "Шифрование GPG (AES256)"
    gpg --batch --yes --pinentry-mode loopback \
        --passphrase "$BACKUP_PASSPHRASE" \
        --symmetric --cipher-algo AES256 \
        -o "${ARCHIVE}.gpg" "$ARCHIVE"
    rm -f "$ARCHIVE"
    ARCHIVE="${ARCHIVE}.gpg"
    chmod 600 "$ARCHIVE"
  fi
fi

SIZE="$(du -h "$ARCHIVE" | cut -f1)"
ok "Готово: $ARCHIVE ($SIZE)"
echo
echo "Восстановление:"
echo "  # расшифровать (если шифровали):"
echo "  gpg -d -o backup.tar.gz '$ARCHIVE'"
echo "  # распаковать:"
echo "  tar xzf backup.tar.gz -C /tmp/restore"
echo "  # затем вернуть нужные каталоги на места и поднять docker compose проекты."
