# HCHECK - Система мониторинга состояния сервера

Легковесная, модульная система проверки состояния сервера на Ubuntu Linux.

## Быстрый старт

1. Клонируем репозиторий:
   sudo git clone <repo_url> /opt/hcheck

2. Копируем шаблон конфига:
   sudo cp /opt/hcheck/config/hcheck.conf.example /opt/hcheck/config/hcheck.conf
   sudo chmod 600 /opt/hcheck/config/hcheck.conf

3. Редактируем конфиг (задаём каналы уведомлений):
   sudo nano /opt/hcheck/config/hcheck.conf

4. Тестируем:
   sudo /opt/hcheck/hcheck.sh

5. Настраиваем cron:
   sudo tee /etc/cron.d/hcheck > /dev/null <<'EOF'
   # Запуск каждый час
   0 * * * * root /opt/hcheck/hcheck.sh > /dev/null 2>&1
   EOF

## Структура проекта

/opt/hcheck/
  hcheck.sh               - Главный скрипт-оркестратор
  hcheck.d/               - Скрипты проверок (плагины)
    10_disk_space.sh      - Проверка дисков
    20_load_average.sh    - Проверка Load Average
    30_memory_usage.sh    - Проверка памяти
    40_service_status.sh  - Проверка сервисов
  config/
    hcheck.conf           - Конфиг (НЕ в Git!)
    hcheck.conf.example   - Шаблон конфига
  lib/
    common.sh             - Библиотека функций
  logs/                   - Логи (НЕ в Git)
  README.md

## Режимы отчётности

Задаются переменной REPORT_MODE в config/hcheck.conf:

- silent_ok    : Молчать если всё ОК, иначе слать полный отчёт
- summary_only : Всегда слать только список статусов (exit codes)
- full         : Всегда слать сводку + полные детали всех проверок

## Каналы уведомлений

Задаются переменной NOTIFY_CHANNELS через запятую: email, telegram, webdav, sftp.

### Telegram

1. Создайте бота через @BotFather -> получите токен.
2. Получите Chat ID.
3. Заполните в конфиге:
   TELEGRAM_BOT_TOKEN="123456:ABC-DEF..."
   TELEGRAM_CHAT_ID="-100123456789"

### Email (через msmtp)

sudo apt install msmtp msmtp-mta
sudo nano /etc/msmtprc

### WebDAV

  WEBDAV_URL="https://your-webdav-server.com/reports/"
  WEBDAV_USER="your-username"
  WEBDAV_PASS="your-password"

### SFTP

  SFTP_HOST="sftp.example.com"
  SFTP_PORT="22"
  SFTP_USER="your-username"
  SFTP_PASS="your-password"

## Добавление своей проверки

Создайте файл в hcheck.d/ с именем NN_имя.sh.
Правила:
- Имя: NN_имя.sh (NN - числовой префикс для порядка)
- Исполняемый: chmod +x
- Теги вывода: [INFO], [OK], [WARN], [CRIT]
- Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN

## Лицензия

MIT
