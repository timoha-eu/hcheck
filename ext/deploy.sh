#!/bin/bash

# скрипт деплоя проекта hcheck

# создание задачи cron
cp hcheck.cron.example /etc/cron.d/hcheck
chmod 644 /etc/cron.d/hcheck
chown root:root /etc/cron.d/hcheck
