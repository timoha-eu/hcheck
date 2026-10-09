#!/bin/bash

# скрипт деплоя проекта hcheck

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# создание задачи cron
cp "${SCRIPT_DIR}/hcheck.cron.example" /etc/cron.d/hcheck
chmod 644 /etc/cron.d/hcheck
chown root:root /etc/cron.d/hcheck
