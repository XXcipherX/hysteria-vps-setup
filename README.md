# Hysteria 2 VPS Setup

[![CI](https://github.com/XXcipherX/hysteria-vps-setup/actions/workflows/ci.yml/badge.svg)](https://github.com/XXcipherX/hysteria-vps-setup/actions/workflows/ci.yml)

Интерактивный установщик Hysteria 2 для VPS. Разворачивает сервер в Docker,
настраивает автоматическое получение TLS-сертификата, встроенную
HTTP/HTTPS-маскировку и выводит готовый URI для подключения клиента.

## Возможности

- установка Docker Engine и Compose plugin при необходимости;
- получение TLS-сертификата через ACME HTTP-01;
- криптографически стойкий пароль и готовый `hysteria2://` URI;
- встроенная HTTP/HTTPS-маскировка Hysteria 2;
- опциональная настройка SSH и nftables с автоматическим откатом;
- рекомендуемые Hysteria 2 размеры UDP-буферов;
- резервные копии при повторной установке;
- диагностика конфигурации, контейнеров, DNS, портов и firewall;
- автоматические проверки Bash, YAML и nftables в GitHub Actions.

## Требования

- VPS с Debian или Ubuntu, `apt` и `systemd`;
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
3. параметры усиления безопасности;
4. применение UDP-профиля производительности.

После завершения скопируйте выведенный URI в клиент Hysteria 2.

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

### Настройка безопасности

При включении этого режима установщик:

- создает отдельного пользователя с указанным SSH-ключом;
- блокирует пароль нового пользователя;
- предоставляет доступ к `sudo` и группе `docker`;
- отключает вход по SSH для `root` и аутентификацию по паролю;
- переносит SSH на выбранный порт;
- создает отдельную таблицу nftables `inet hysteria_vps_filter`;
- сохраняет действующую SSH-конфигурацию перед изменениями.

Изменения SSH и firewall защищены таймерами отката. После применения настроек
нужно открыть новую SSH-сессию и подтвердить успешный вход. Если подтверждение
не получено, предыдущая конфигурация восстанавливается автоматически.

> [!WARNING]
> Перед изменением SSH убедитесь, что у вас есть доступ к веб-консоли или
> rescue-режиму провайдера.

Firewall разрешает loopback, established/related соединения, выбранный
SSH-порт, `80/tcp`, `443/tcp`, `443/udp` и необходимый ICMP/ICMPv6. Для SSH и
новых TCP-соединений применяются per-IP rate limits.

### UDP-профиль

Опциональный профиль устанавливает рекомендуемые Hysteria 2 значения:

```text
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
```

Исходные значения сохраняются и могут быть восстановлены командой
`scripts/optimize.sh delete`.

## Результат установки

URI клиента выводится в терминал и сохраняется с правами `0600`:

```text
hysteria2://PASSWORD@example.com:443/?sni=example.com#example.com
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
/var/lib/hysteria-vps-setup/firewall.state
/var/lib/hysteria-vps-setup/optimize.state
/etc/hysteria-vps-setup/firewall.nft
/etc/sysctl.d/90-hysteria-vps-setup.conf
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

Скрипт проверяет конфигурационные файлы и права доступа, Compose, контейнеры,
DNS, nftables, UDP-буферы и слушающие порты. При критической ошибке команда
завершается с ненулевым кодом.

| Переменная | Значение по умолчанию | Описание |
| --- | --- | --- |
| `HVS_INSTALL_DIR` | `/opt/hysteria-vps-setup` | Директория установки |
| `HVS_STATE_DIR` | `/var/lib/hysteria-vps-setup` | Директория состояния |
| `HVS_FIREWALL_TABLE` | `hysteria_vps_filter` | Имя таблицы nftables |

## Управление firewall

```bash
sudo SSH_PORT=2222 bash scripts/firewall.sh apply
sudo bash scripts/firewall.sh status
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
| `HVS_SYN_RATE` | `200` | Лимит новых TCP-соединений в секунду для одного IP |
| `HVS_SYN_BURST` | `400` | Допустимый burst TCP-соединений |
| `HVS_SSH_RATE` | `6` | Лимит новых SSH-соединений в минуту для одного IP |
| `HVS_SSH_BURST` | `5` | Допустимый burst SSH-соединений |
| `HVS_ICMP_RATE` | `10` | Лимит ICMP echo в секунду для одного IP |
| `HVS_ICMP_BURST` | `20` | Допустимый burst ICMP echo |
| `HVS_SAFETY_DELAY` | `300` | Задержка автоматического отката в секундах |
| `HVS_ASSUME_FIREWALL_OK` | `0` | `1` для неинтерактивного подтверждения |
| `HVS_DRY_RUN` | `0` | `1` для проверки правил без применения |
| `HVS_CONF_DIR` | `/etc/hysteria-vps-setup` | Директория конфигурации |
| `HVS_STATE_DIR` | `/var/lib/hysteria-vps-setup` | Директория состояния |

## Управление UDP-профилем

```bash
sudo bash scripts/optimize.sh apply
sudo bash scripts/optimize.sh status
sudo bash scripts/optimize.sh delete
```

| Переменная | Значение по умолчанию | Описание |
| --- | --- | --- |
| `HVS_UDP_BUFFER_BYTES` | `16777216` | Значения `rmem_max` и `wmem_max` |
| `HVS_DRY_RUN` | `0` | `1` для проверки без изменений |
| `HVS_STATE_DIR` | `/var/lib/hysteria-vps-setup` | Директория состояния |

Допустимый диапазон `HVS_UDP_BUFFER_BYTES` — от 1 MiB до 1 GiB.

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
правила через `nft -c`.

## Документация

- [Установка Hysteria 2](https://v2.hysteria.network/docs/getting-started/Installation/)
- [Настройка сервера](https://v2.hysteria.network/docs/getting-started/Server/)
- [Полная конфигурация сервера](https://v2.hysteria.network/docs/advanced/Full-Server-Config/)
- [Рекомендации по производительности](https://v2.hysteria.network/docs/advanced/Performance/)
- [Формат URI](https://v2.hysteria.network/docs/developers/URI-Scheme/)
- [Исходный код Hysteria 2](https://github.com/apernet/hysteria)
