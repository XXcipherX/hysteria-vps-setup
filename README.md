# Hysteria 2 VPS Setup

[![CI](https://github.com/XXcipherX/hysteria-vps-setup/actions/workflows/ci.yml/badge.svg)](https://github.com/XXcipherX/hysteria-vps-setup/actions/workflows/ci.yml)

Интерактивный установщик Hysteria 2 для VPS. Разворачивает сервер в Docker,
настраивает автоматическое получение TLS-сертификата, встроенную
HTTP/HTTPS-маскировку и создает готовые YAML и URI для подключения клиента.

## Возможности

- установка Docker Engine и Compose plugin при необходимости;
- получение TLS-сертификата через ACME HTTP-01;
- криптографически стойкий пароль, клиентский YAML и штатный `hysteria2://` URI;
- встроенная HTTP/HTTPS-маскировка Hysteria 2;
- независимые опциональные шаги SSH hardening и nftables с автоматическим откатом;
- локальный список известных адресов сканирования с ограниченным логированием;
- профиль UDP/QUIC согласно специфике Hysteria 2;
- отдельный необязательный помощник установки ядра XanMod;
- резервные копии при повторной установке;
- диагностика конфигурации, контейнеров, DNS, портов и firewall;
- автоматические проверки Bash, YAML и nftables в GitHub Actions.

## Требования

- свежая VPS с Debian или Ubuntu, `apt` и `systemd`;
- права `root` или возможность использовать `sudo`;
- публичный IPv4 и/или IPv6;
- домен с A и/или AAAA-записью, направленной на VPS;
- доступные входящие порты:

  | Порт | Назначение |
  | --- | --- |
  | `80/tcp` | ACME HTTP-01 |
  | `443/tcp` | HTTPS-маскировка |
  | `443/udp` | Hysteria 2 |
  | SSH-порт | Администрирование сервера |

Если провайдер использует отдельный firewall или security group, откройте эти
порты до запуска установщика.

## Быстрый старт

```bash
git clone https://github.com/XXcipherX/hysteria-vps-setup.git
cd hysteria-vps-setup
sudo bash vps-setup.sh
```

Установщик запросит:

1. домен сервера;
2. email для ACME-аккаунта Let's Encrypt;
3. настройку SSH security;
4. отдельное применение nftables firewall;
5. применение UDP/QUIC-профиля производительности.

После завершения импортируйте выведенный URI в клиент Hysteria 2 либо
используйте сохраненный клиентский YAML.

## Что делает установщик

### Развертывание Hysteria 2

Установщик проверяет домен, DNS-записи и необходимые зависимости, затем
создает конфигурацию в `/opt/hysteria-vps-setup` и запускает контейнер в режиме
host network:

| Контейнер | Образ | Назначение |
| --- | --- | --- |
| `hysteria` | `tobyxdd/hysteria:v2` | Hysteria 2, ACME и HTTPS-маскировка |

Hysteria слушает `443/udp` и `443/tcp`. Запросы, не прошедшие
Hysteria-аутентификацию, обрабатываются встроенной маскировкой и получают
обычный HTTP-ответ `404`.

### Настройка SSH

SSH hardening и firewall включаются разными вопросами. При включении SSH
hardening установщик:

- создает отдельного пользователя с указанным SSH-ключом;
- блокирует пароль нового пользователя;
- предоставляет доступ к `sudo` и группе `docker`;
- отключает вход по SSH для `root` и аутентификацию по паролю;
- переносит SSH на выбранный порт;
- сохраняет действующую SSH-конфигурацию перед изменениями.

Скрипт учитывает как обычный `ssh.service`, так и socket activation через
`ssh.socket`/`sshd.socket`. После изменения нужно открыть новую SSH-сессию и
подтвердить успешный вход. До подтверждения работает safety timer; при отказе
предыдущая конфигурация восстанавливается сразу.

> [!WARNING]
> Перед изменением SSH убедитесь, что у вас есть доступ к веб-консоли или
> rescue-режиму провайдера.

Если SSH hardening отключен, но firewall включен, установщик определяет
единственный фактически слушающий SSH-порт через `sshd -T` и `ss`. Если это
невозможно сделать однозначно, firewall не применяется.

### Firewall

Firewall создаёт только отдельную таблицу `inet hysteria_vps_filter`, не
очищая чужие правила nftables. Он разрешает loopback, established/related,
текущий SSH client IP, выбранный SSH-порт, `80/tcp`, `443/tcp`, `443/udp` и
необходимый ICMP/ICMPv6. Для SSH и новых TCP-соединений действуют per-IP rate
limits. Входящий и пересылаемый трафик по умолчанию блокируется, исходящий —
разрешён.

Перед применением сохраняется предыдущая таблица и вооружается safety timer.
Нужно проверить новую SSH-сессию и подтвердить доступ. При отказе старая таблица
восстанавливается; при неинтерактивном запуске таймер остаётся активен, если не
задано `HVS_ASSUME_FIREWALL_OK=1`.

Встроенный файл `lists/cyberok-skipa-v4.txt` содержит зафиксированный список
IPv4/CIDR известных сканирующих узлов. Он основан на снимке
[`CyberOK_Skipa_ips`](https://github.com/tread-lightly/CyberOK_Skipa_ips/blob/a465e13f4cb43c1692eb650430eb857900558c5d/lists/skipa_cidr.txt)
и дополнен шестью IPv4 `/24`-префиксами AS61280 (ФГУП «ГРЧЦ»), отсутствующими
в этом снимке.
При установке внешние списки не скачиваются. Перед блокировкой nftables пишет в
kernel journal только метаданные пакета с тегом `[scanners-activity]`; payload
не журналируется. Сводка текущей загрузки:

```bash
sudo bash scripts/firewall.sh scanners-hits
```

Логирование ограничено per-IP и общим лимитом, а отдельное правило продолжает
считать и блокировать все пакеты независимо от того, попали они в журнал или
нет.

### UDP/QUIC-профиль

Опциональный профиль сохраняет предыдущие значения и устанавливает
рекомендуемые Hysteria 2 максимумы UDP-буферов, а также консервативные параметры
обработки сетевых очередей:

```text
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 250000
net.core.netdev_budget = 600
net.core.optmem_max = 65536
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
```

Профиль намеренно не меняет TCP congestion control и не устанавливает ядро:
основной транспорт Hysteria — QUIC поверх UDP. Исходные значения можно
восстановить командой `scripts/optimize.sh delete`.

## Результат установки

Установщик создает клиентский YAML и передает его штатной команде
`hysteria share`, которая формирует URI. Оба файла сохраняются с правами `0600`,
а URI также выводится в терминал:

```text
hysteria2://PASSWORD@example.com:443/?sni=example.com
/var/lib/hysteria-vps-setup/client.yaml
/var/lib/hysteria-vps-setup/client.uri
```

Основные файлы конфигурации:

```text
/opt/hysteria-vps-setup/docker-compose.yml
/opt/hysteria-vps-setup/hysteria/config.yaml
/opt/hysteria-vps-setup/hysteria/acme/
```

Служебные файлы:

```text
/var/lib/hysteria-vps-setup/install.env
/var/lib/hysteria-vps-setup/client.yaml
/var/lib/hysteria-vps-setup/client.uri
/var/lib/hysteria-vps-setup/firewall.state
/var/lib/hysteria-vps-setup/optimize.state
/var/lib/hysteria-vps-setup/xanmod.state
/etc/hysteria-vps-setup/firewall.nft
/etc/sysctl.d/90-hysteria-vps-setup.conf
/etc/apt/sources.list.d/xanmod-release.sources
```

При повторной установке заменяемые файлы копируются в:

```text
/var/backups/hysteria-vps-setup/<timestamp>/
```

## Диагностика

Запустить полный отчет:

```bash
sudo bash scripts/diagnose.sh
```

Получить результат в JSON:

```bash
sudo bash scripts/diagnose.sh --json
```

Скрипт проверяет серверный и клиентский YAML, согласованность пароля, права
доступа, Compose, контейнер Hysteria, DNS, слушатели, nftables, scanner
blocklist/logging, boot persistence firewall, UDP/QUIC sysctl и активность
XanMod. При критической ошибке команда завершается с ненулевым кодом.

| Переменная | Значение по умолчанию | Описание |
| --- | --- | --- |
| `HVS_INSTALL_DIR` | `/opt/hysteria-vps-setup` | Директория установки |
| `HVS_STATE_DIR` | `/var/lib/hysteria-vps-setup` | Директория состояния |
| `HVS_FIREWALL_TABLE` | `hysteria_vps_filter` | Имя таблицы nftables |

## Управление firewall

```bash
sudo SSH_PORT=2222 bash scripts/firewall.sh apply
sudo bash scripts/firewall.sh status
sudo bash scripts/firewall.sh scanners-hits
sudo bash scripts/firewall.sh delete
```

Проверить правила без применения:

```bash
sudo HVS_DRY_RUN=1 SSH_PORT=2222 \
  HVS_WHITELIST="203.0.113.10,2001:db8::10" \
  bash scripts/firewall.sh apply
```

| Переменная | Значение по умолчанию | Описание |
| --- | --- | --- |
| `SSH_PORT` | сохраненный порт или `22` | Разрешенный SSH-порт |
| `HVS_TCP_PORTS` | `80,443` | Публичные TCP-порты |
| `HVS_UDP_PORTS` | `443` | Публичные UDP-порты |
| `HVS_WHITELIST` | пусто | IPv4, IPv6 или CIDR через запятую |
| `HVS_BLOCKLIST_FILE` | `lists/cyberok-skipa-v4.txt` | Локальный IPv4/CIDR blocklist |
| `HVS_SCANNER_LOG_RATE` | `3` | Записей в минуту для каждого IP после burst |
| `HVS_SCANNER_LOG_BURST` | `5` | Начальный per-IP burst записей |
| `HVS_SCANNER_LOG_GLOBAL_RATE` | `30` | Общий лимит записей в минуту после burst |
| `HVS_SCANNER_LOG_GLOBAL_BURST` | `50` | Общий burst записей |
| `HVS_SCANNER_LOG_TIMEOUT` | `1h` | Время жизни per-IP limiter-записи |
| `HVS_SYN_RATE` | `200` | Лимит новых TCP-соединений в секунду для одного IP |
| `HVS_SYN_BURST` | `400` | Допустимый burst TCP-соединений |
| `HVS_SSH_RATE` | `6` | Лимит новых SSH-соединений в минуту для одного IP |
| `HVS_SSH_BURST` | `5` | Допустимый burst SSH-соединений |
| `HVS_ICMP_RATE` | `10` | Лимит ICMP echo в секунду для одного IP |
| `HVS_ICMP_BURST` | `20` | Допустимый burst ICMP echo |
| `HVS_ICMP_TIMEOUT` | `1h` | Время жизни ICMP meter-записи |
| `HVS_SSH_TIMEOUT` | `24h` | Время жизни SSH meter-записи |
| `HVS_SVC_TIMEOUT` | `24h` | Время жизни TCP service meter-записи |
| `HVS_SAFETY_DELAY` | `300` | Задержка автоматического отката в секундах |
| `HVS_ASSUME_FIREWALL_OK` | `0` | `1` для неинтерактивного подтверждения |
| `HVS_DRY_RUN` | `0` | `1` для проверки правил без применения |
| `HVS_CONF_DIR` | `/etc/hysteria-vps-setup` | Директория конфигурации |
| `HVS_STATE_DIR` | `/var/lib/hysteria-vps-setup` | Директория состояния |

## Управление UDP/QUIC-профилем

```bash
sudo bash scripts/optimize.sh apply
sudo bash scripts/optimize.sh status
sudo bash scripts/optimize.sh delete
```

| Переменная | Значение по умолчанию | Описание |
| --- | --- | --- |
| `HVS_UDP_BUFFER_BYTES` | `16777216` | Значения `rmem_max` и `wmem_max` |
| `HVS_UDP_MIN_BYTES` | `16384` | Минимальные UDP receive/send buffers |
| `HVS_NETDEV_MAX_BACKLOG` | `250000` | Максимум пакетов во входной очереди CPU |
| `HVS_NETDEV_BUDGET` | `600` | Пакетов за цикл kernel networking poll |
| `HVS_OPTMEM_MAX` | `65536` | Максимум ancillary buffer на сокет |
| `HVS_DRY_RUN` | `0` | `1` для проверки без изменений |
| `HVS_STATE_DIR` | `/var/lib/hysteria-vps-setup` | Директория состояния |

Допустимый диапазон `HVS_UDP_BUFFER_BYTES` — от 1 MiB до 1 GiB.

## Ядро XanMod

XanMod полностью отделён от обычной установки Hysteria. Основной установщик
его не вызывает и не требует перезагрузки. Используйте помощник только если вам
осознанно нужно более новое ядро; штатное Debian-ядро при установке не удаляется.

```bash
# Только проверить совместимость, ничего не устанавливая.
sudo bash scripts/xanmod.sh probe

# Установить LTS-ветку, затем перезагрузить VPS.
sudo bash scripts/xanmod.sh install
sudo reboot

# Проверить активное ядро.
sudo bash scripts/xanmod.sh status
```

По умолчанию выбирается LTS-пакет и максимально подходящий CPU psABI уровень с
безопасным fallback: `x64v3 -> x64v2 -> x64v1`. Для других веток и точного
пакета доступны:

```bash
sudo HVS_XANMOD_BRANCH=main bash scripts/xanmod.sh install
sudo HVS_XANMOD_BRANCH=edge bash scripts/xanmod.sh install
sudo HVS_XANMOD_BRANCH=rt bash scripts/xanmod.sh install
sudo HVS_XANMOD_PACKAGE=linux-xanmod-lts-x64v3 bash scripts/xanmod.sh install
```

| Переменная | Значение по умолчанию | Описание |
| --- | --- | --- |
| `HVS_XANMOD_BRANCH` | `lts` | `lts`, `main`, `edge` или `rt` |
| `HVS_XANMOD_PACKAGE` | пусто | Точное имя пакета вместо автоопределения |
| `HVS_XANMOD_DKMS_TOOLS` | `0` | `1` для установки минимального DKMS toolchain |
| `HVS_STATE_DIR` | `/var/lib/hysteria-vps-setup` | Директория состояния |

Скрипт отказывается работать внутри OpenVZ/LXC/другого контейнера, проверяет
архитектуру и полный fingerprint ключа репозитория. `remove` разрешён только
после загрузки в штатное ядро:

```bash
sudo bash scripts/xanmod.sh remove
```

## Обновление

```bash
sudo docker compose -f /opt/hysteria-vps-setup/docker-compose.yml pull
sudo docker compose -f /opt/hysteria-vps-setup/docker-compose.yml up -d
sudo bash scripts/diagnose.sh
```

## Разработка

Локальный smoke-тест:

```bash
bash tests/smoke.sh
```

GitHub Actions также проверяет Bash-синтаксис, запускает ShellCheck, рендерит и
разбирает YAML-шаблоны, выполняет smoke-тесты и валидирует сгенерированные
правила через `nft -c`. Отдельная еженедельная проверка загружает актуальный
образ `tobyxdd/hysteria:v2` и проверяет реальное подключение к тестовому серверу.

## Документация

- [Установка Hysteria 2](https://v2.hysteria.network/docs/getting-started/Installation/)
- [Настройка сервера](https://v2.hysteria.network/docs/getting-started/Server/)
- [Полная конфигурация сервера](https://v2.hysteria.network/docs/advanced/Full-Server-Config/)
- [Рекомендации по производительности](https://v2.hysteria.network/docs/advanced/Performance/)
- [Формат URI](https://v2.hysteria.network/docs/developers/URI-Scheme/)
- [Исходный код Hysteria 2](https://github.com/apernet/hysteria)
