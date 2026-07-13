# Server Config Backup &amp; Restore

**Русский** · [English](#english)

Набор из двух bash-скриптов для снятия полной резервной копии конфигурации Linux-сервера
и последующего её развёртывания на **чистом сервере** одной командой.

Заточены под типовой VPN/прокси-стек: **3x-ui (VLESS)**, **Remnawave (panel/node)**,
**telemt**, **mtproto.zig (mtbuddy)**, **MTPROTO_FIX_By_MEKO (mekopr)**, **nginx**,
**Let's Encrypt / acme.sh**, **Docker / docker-compose**, **PostgreSQL**, **UFW/iptables**.

> ⚠️ Скрипты собирают чувствительные данные (приватные ключи, сертификаты, `.env`, дампы БД).
> Храните архивы в защищённом месте, а для передачи используйте шифрование (`-e` + `BACKUP_PASSPHRASE`).

## Состав

| Файл | Назначение |
|------|------------|
| [`BackUp-Script/server-backup.sh`](BackUp-Script/server-backup.sh) | Снимает бэкап в один `tar.gz` (+ опционально GPG) |
| [`BackUp-Script/server-restore.sh`](BackUp-Script/server-restore.sh) | Разворачивает сервер из архива (для чистой ОС) |

Текущая версия обоих скриптов — **1.3**.

## Скачать (wget)

Оба скрипта одной командой:

```bash
wget -O server-backup.sh  "https://raw.githubusercontent.com/psy-factor/server-config-backup/main/BackUp-Script/server-backup.sh" && \
wget -O server-restore.sh "https://raw.githubusercontent.com/psy-factor/server-config-backup/main/BackUp-Script/server-restore.sh" && \
chmod +x server-backup.sh server-restore.sh
```

## Возможности

- **Один архив** со всем нужным + `MANIFEST.txt` с метаданными хоста.
- **Логические дампы PostgreSQL** (`pg_dumpall`) из docker-контейнеров — переносимее, чем копия volume.
- **Целостный дамп `x-ui.db`** (порт панели, креды, инбаунды, пути к сертам) + сами TLS-файлы,
  на которые ссылается панель, даже если они лежат вне `/etc/letsencrypt`.
- **acme.sh / Let's Encrypt / `/root/cert`** — переносятся вместе с автопродлением.
- **MTProto-прокси — telemt, mtproto.zig (mtbuddy) и mekopr** — переносятся бинарь, рабочий каталог,
  юниты и таймеры; при восстановлении **чинятся права** рабочих/конфиг-каталогов (частая причина
  краша службы). Установщик запускается только как фолбэк, если бинаря нет ни в системе, ни в бэкапе.
- **Интерактивный чеклист** при восстановлении — отмечаешь галочками, что именно накатывать.
- **Безопасность прода**: dry-run, откат заменяемых файлов, гарантированное открытие SSH-порта
  в UFW перед его включением, отказ от авто-применения сырых iptables (конфликт с Docker).

## Требования

- Bash 4+ (`declare -A`), GNU-утилиты (`grep -P`) — обычный Linux (Debian/Ubuntu, RHEL/Alma).
- Запуск от `root` / через `sudo`.
- Для восстановления недостающие пакеты (`rsync`, `curl`, `wget`, docker, nginx, sqlite3, ufw)
  ставятся автоматически.

## Резервное копирование

```bash
sudo ./server-backup.sh                 # архив в подпапку ./Backups
sudo ./server-backup.sh -o /mnt/backup  # другой каталог назначения
sudo BACKUP_PASSPHRASE='секрет' \
     ./server-backup.sh -e              # + шифрование GPG (AES256)
sudo ./server-backup.sh --volumes       # + дамп docker volume'ов (тяжело!)
```

## Восстановление (на чистом сервере)

```bash
sudo ./server-restore.sh                  # выбрать архив + чеклист компонентов
sudo ./server-restore.sh backup.tar.gz    # чеклист из конкретного архива
sudo ./server-restore.sh backup.tar.gz --all       # накатить всё, без чеклиста
sudo ./server-restore.sh backup.tar.gz --dry-run   # показать план, ничего не менять
sudo ./server-restore.sh backup.tar.gz --only 3x-ui,nginx
sudo BACKUP_PASSPHRASE='секрет' \
     ./server-restore.sh backup.tar.gz.gpg
```

По умолчанию restore **сразу применяет** изменения и **показывает чеклист** найденного софта
(все пункты отмечены). Восстанавливаются только отмеченные компоненты — с их конфигами и правами.

### Компоненты

`sysctl`, `nginx`, `letsencrypt` (TLS), `ssh`, `ssh-keys`, `3x-ui`, `projects` (remnawave/cabinet),
`mtproto` (telemt / mtproto.zig / mekopr), `docker-compose`, `postgres`, `volumes`, `systemd`,
`crontab`, `firewall`.

> После восстановления **обязательно откройте вторую SSH-сессию** и проверьте доступ,
> прежде чем закрывать текущую.

---

## English

Two bash scripts to make a full backup of a Linux server configuration and redeploy it on a
**fresh server** with a single command.

Built for a typical VPN/proxy stack: **3x-ui (VLESS)**, **Remnawave (panel/node)**,
**telemt**, **mtproto.zig (mtbuddy)**, **MTPROTO_FIX_By_MEKO (mekopr)**, **nginx**,
**Let's Encrypt / acme.sh**, **Docker / docker-compose**, **PostgreSQL**, **UFW/iptables**.

> ⚠️ These scripts collect sensitive data (private keys, certificates, `.env`, DB dumps).
> Store archives securely and encrypt them for transfer (`-e` + `BACKUP_PASSPHRASE`).

### Files

| File | Purpose |
|------|---------|
| [`BackUp-Script/server-backup.sh`](BackUp-Script/server-backup.sh) | Makes a single `tar.gz` backup (optionally GPG-encrypted) |
| [`BackUp-Script/server-restore.sh`](BackUp-Script/server-restore.sh) | Restores a server from the archive (fresh OS) |

Both scripts are currently at version **1.3**. Comments inside are in Russian.

### Download (wget)

Both scripts in one command:

```bash
wget -O server-backup.sh  "https://raw.githubusercontent.com/psy-factor/server-config-backup/main/BackUp-Script/server-backup.sh" && \
wget -O server-restore.sh "https://raw.githubusercontent.com/psy-factor/server-config-backup/main/BackUp-Script/server-restore.sh" && \
chmod +x server-backup.sh server-restore.sh
```

### Features

- **Single archive** with everything needed + `MANIFEST.txt` host metadata.
- **Logical PostgreSQL dumps** (`pg_dumpall`) from docker containers — more portable than volume copies.
- **Consistent `x-ui.db` dump** (panel port, creds, inbounds, cert paths) plus the actual TLS files
  the panel references, even outside `/etc/letsencrypt`.
- **acme.sh / Let's Encrypt / `/root/cert`** carried over together with auto-renewal.
- **MTProto proxies — telemt, mtproto.zig (mtbuddy) and mekopr** — binary, working dir, units and
  timers are backed up; on restore the ownership of working/config dirs is **fixed** (a common cause
  of the service crashing). The installer runs only as a fallback when the binary is in neither the
  system nor the backup.
- **Interactive checklist** on restore — tick exactly which components to apply.
- **Production safety**: dry-run mode, rollback copies of replaced files, SSH port force-opened in
  UFW before enabling it, no automatic apply of raw iptables (conflicts with Docker).

### Requirements

- Bash 4+ (`declare -A`), GNU tools (`grep -P`) — a regular Linux (Debian/Ubuntu, RHEL/Alma).
- Run as `root` / via `sudo`.
- On restore, missing packages (`rsync`, `curl`, `wget`, docker, nginx, sqlite3, ufw) are installed
  automatically.

### Backup

```bash
sudo ./server-backup.sh                 # archive into ./Backups
sudo ./server-backup.sh -o /mnt/backup  # custom destination
sudo BACKUP_PASSPHRASE='secret' \
     ./server-backup.sh -e              # + GPG encryption (AES256)
sudo ./server-backup.sh --volumes       # + dump docker volumes (heavy!)
```

### Restore (on a fresh server)

```bash
sudo ./server-restore.sh                  # pick archive + component checklist
sudo ./server-restore.sh backup.tar.gz    # checklist from a specific archive
sudo ./server-restore.sh backup.tar.gz --all       # apply everything, no checklist
sudo ./server-restore.sh backup.tar.gz --dry-run   # print the plan, change nothing
sudo ./server-restore.sh backup.tar.gz --only 3x-ui,nginx
sudo BACKUP_PASSPHRASE='secret' \
     ./server-restore.sh backup.tar.gz.gpg
```

By default restore **applies immediately** and **shows a checklist** of detected software (all ticked).
Only the ticked components are restored — with their configs and permissions.

> After a restore, **always open a second SSH session** and verify access before closing the current one.

---

_Generated with the help of Claude Code._
