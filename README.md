# Server Config Backup & Restore

**Версия 1.4.2** · [English](#english)

Два Bash-скрипта для резервного копирования конфигурации и данных Linux-сервера
и переноса служб на чистую систему. Поддерживаются Docker Compose, Remnawave
Panel и Node, Bedolaga Bot, Cloudflare Tunnel, 3x-ui, telemt, mtproto.zig, mekopr,
nginx, Let's Encrypt, acme.sh и UFW.

В 1.4.2 nginx проверяется после восстановления сертификатов и запуска
приложений. Если `nginx -t` завершается ошибкой, скрипт показывает её и
возвращает ненулевой код. Для отдельного переноса nginx с сертификатами
укажите `--only letsencrypt,nginx`.

В 1.4.1 убрана автоматическая очистка. Уже созданные архивы хранятся
без ограничения по возрасту. Устаревший параметр `--retention` игнорируется.

## Что нового в 1.4

- **Bedolaga Bot.** Бэкап находит проект по метаданным Docker. Сохраняет каталог
  проекта с `.env` и загрузками, исходное имя Compose-проекта, порядок файлов
  `-f` и пути `--env-file`. Тома PostgreSQL и Redis входят в обычный бэкап.
- **Cloudflare Tunnel.** Поддерживаются Compose и отдельный `cloudflared`,
  запущенный через `docker run`. Сохраняются параметры запуска, токен из команды
  или окружения, файлы из bind mounts и данные томов. На новом сервере заранее
  создайте внешние Docker-сети, от которых зависит туннель.
- **Порядок восстановления.** Docker-тома заполняются до запуска контейнеров.
  Для Bedolaga SQL-дамп служит отдельным способом восстановления PostgreSQL,
  если в архиве также есть том с данными.

| Файл | Назначение |
|------|------------|
| [server-backup.sh](BackUp-Script/server-backup.sh) | Создаёт архив `tar.gz` с `MANIFEST.txt` и опциональным шифрованием GPG |
| [server-restore.sh](BackUp-Script/server-restore.sh) | Восстанавливает выбранные компоненты из архива |

Архив содержит приватные ключи, `.env`, токены и дампы БД. Для шифрования
используйте `-e` вместе с экспортированной переменной `BACKUP_PASSPHRASE`.

## Скачать

```bash
wget -O server-backup.sh 'https://raw.githubusercontent.com/psy-factor/server-config-backup/main/BackUp-Script/server-backup.sh' &&
wget -O server-restore.sh 'https://raw.githubusercontent.com/psy-factor/server-config-backup/main/BackUp-Script/server-restore.sh' &&
chmod +x server-backup.sh server-restore.sh
```

Для копии из репозитория перейдите в `BackUp-Script`. Для запуска нужны Linux с
Bash 5, стандартные GNU-утилиты, `rsync` и `python3` для метаданных Docker.
Для контейнеров нужны Docker Engine и плагин Compose v2. Для шифрования нужен
`gpg`. Применение настроек и копирование системных файлов выполняются через
`sudo`.

## Бэкап

```bash
sudo bash ./server-backup.sh
sudo bash ./server-backup.sh --cold-docker -o /mnt/backup
```

По умолчанию архив появляется в каталоге `Backups` рядом со скриптом.
`--cold-docker` останавливает работающие контейнеры на время копирования,
запускает их снова и пропускает `pg_dumpall`. При обычном бэкапе скрипт
пытается снять логический дамп работающих PostgreSQL-контейнеров. Для
согласованной файловой копии PostgreSQL используйте `--cold-docker`.

| Ключ | Действие |
|------|----------|
| `--volumes` | Включить все Docker-тома. По умолчанию снимаются тома найденных Bedolaga Bot и Cloudflare Tunnel |
| `--no-volumes` | Пропустить все Docker-тома |

## Восстановление на чистом сервере

```bash
bash ./server-restore.sh ./Backups/backup.tar.gz --dry-run --all
sudo bash ./server-restore.sh ./Backups/backup.tar.gz
```

Замените `backup.tar.gz` на имя своего архива. Без пути скрипт предложит выбрать
архив рядом со скриптом или в текущем каталоге, включая их подпапки `Backups`.

В интерактивном запуске restore сразу работает в режиме применения и
предлагает чеклист. `--dry-run` показывает план, `--all` пропускает чеклист,
`--ask` добавляет подтверждения, `--no-install` отключает доустановку пакетов.

- Bedolaga Bot выбирается через `docker-compose` и `volumes`. Туннель в Compose
  выбирается так же. Для отдельного контейнера используются `cloudflared` и
  `volumes`, если у него есть тома.
- Если нужен только SQL при наличии тома PostgreSQL, подготовьте пустую БД с
  исходным именем контейнера и запустите restore с `--only postgres`.
- Остальные компоненты можно выбрать через `--only` со списком через запятую,
  например `--only 3x-ui,nginx`.

Restore сохраняет копии заменяемых файлов в `/root/server-restore-pre-*`.
Если перенесены настройки SSH, проверьте доступ во второй сессии перед
закрытием первой.

## English

**Version 1.4.2** provides Bash scripts to back up Linux server configuration
and application data and restore selected services on a fresh system.
Supported services include Docker Compose, Remnawave Panel and Node, Bedolaga
Bot, Cloudflare Tunnel, 3x-ui, telemt, mtproto.zig, mekopr, nginx, Let's
Encrypt, acme.sh and UFW.

Version 1.4.2 validates nginx after restoring certificates and starting the
applications. A failed `nginx -t` is reported with a nonzero exit status.
Use `--only letsencrypt,nginx` to restore nginx and certificates separately.

Version 1.4.1 removes automatic cleanup. Existing archives are kept
regardless of age. The legacy `--retention` option is ignored.

### What's new

- **Bedolaga Bot.** The backup locates the project from Docker metadata and
  includes its directory, `.env`, uploads and PostgreSQL and Redis volumes.
  Restore reuses the original Compose project name, ordered `-f` files and
  `--env-file` paths.
- **Cloudflare Tunnel.** Both Compose and standalone `cloudflared` containers
  are supported, including startup settings, token arguments or environment
  variables, bind-mounted files and volume data. Create any required
  external Docker networks on the destination before restoring.
- **Restore order.** Volume data is restored before containers start. When the
  Bedolaga PostgreSQL volume is present, its SQL dump remains available for
  separate recovery.

| File | Purpose |
|------|---------|
| [server-backup.sh](BackUp-Script/server-backup.sh) | Creates a `tar.gz` archive with `MANIFEST.txt` and optional GPG encryption |
| [server-restore.sh](BackUp-Script/server-restore.sh) | Restores selected components from the archive |

Archives contain private keys, `.env` files, tokens and database dumps.
To encrypt a backup, export `BACKUP_PASSPHRASE` and pass `-e`.

### Quick start

Download both scripts using the commands above or work from `BackUp-Script`
in a checkout. Use Linux with Bash 5, GNU tools, `rsync` and `python3` for Docker
metadata. Container operations require Docker Engine and Compose v2.
Encryption requires `gpg`.

```bash
sudo bash ./server-backup.sh --cold-docker
bash ./server-restore.sh ./Backups/backup.tar.gz --dry-run --all
sudo bash ./server-restore.sh ./Backups/backup.tar.gz
```

Replace `backup.tar.gz` with the actual archive name. Backups go into
`Backups` next to the script by default. Use `-o` to change the destination.
`--cold-docker` stops and restarts the running containers and skips live SQL
dumps. A regular run attempts `pg_dumpall` against running PostgreSQL
containers. Use a cold run for a consistent file-level PostgreSQL copy.

`--volumes` adds all Docker volumes. The default includes the volumes attached
to detected Bedolaga Bot and Cloudflare Tunnel containers. `--no-volumes`
skips all volumes.

The second command previews the plan. The third applies it and offers the
component checklist in an interactive terminal. To select components on the
CLI, use `--only` with a comma-separated list. Select `docker-compose` and
`volumes` for Bedolaga Bot and Compose-based tunnels. Standalone tunnels use
`cloudflared` and `volumes` if applicable. To import SQL separately, prepare
an empty PostgreSQL cluster with the original container name and select
`--only postgres`.

Existing files are copied to `/root/server-restore-pre-*` before replacement.
If SSH settings changed, verify access in a second session before closing
the first one.
