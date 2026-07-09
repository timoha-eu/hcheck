#!/bin/bash

# Скрипт для мониторинга статуса fail2ban
# Формат вывода: <jail> failed <current>/<total> banned <current>/<total>
# Exit code: 0 = OK, 2 = Critical

# Функция для извлечения числа из строки
extract_number() {
    # Извлекаем последнее число из строки
    echo "$1" | grep "$2" | grep -oE '[0-9]+$'
}

# Проверка доступности fail2ban-client
if ! command -v fail2ban-client >/dev/null 2>&1; then
    echo "Critical: fail2ban-client не найден"
    exit 2
fi

# Проверка что fail2ban запущен
if ! fail2ban-client ping >/dev/null 2>&1; then
    echo "Critical: fail2ban не запущен"
    exit 2
fi

# Получение списка всех активных jail
jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*Jail list:\s*//')

if [ -z "$jails" ]; then
    echo "Critical: не удалось получить список jail"
    exit 2
fi

# Флаг успешного формирования отчета
report_ok=false

# Перебор каждой jail
for jail in $(echo "$jails" | tr ',' ' '); do
    jail=$(echo "$jail" | tr -d ' ')
    
    # Получение статуса для текущей jail
    status=$(fail2ban-client status "$jail" 2>/dev/null)
    
    if [ -z "$status" ]; then
        continue
    fi
    
    # Извлечение значений - ищем строку с ключевым словом и берем последнее число
    currently_failed=$(echo "$status" | grep "Currently failed" | grep -oE '[0-9]+$')
    total_failed=$(echo "$status" | grep "Total failed" | grep -oE '[0-9]+$')
    currently_banned=$(echo "$status" | grep "Currently banned" | grep -oE '[0-9]+$')
    total_banned=$(echo "$status" | grep "Total banned" | grep -oE '[0-9]+$')
    
    # Значения по умолчанию
    currently_failed=${currently_failed:-0}
    total_failed=${total_failed:-0}
    currently_banned=${currently_banned:-0}
    total_banned=${total_banned:-0}
    
    # Вывод в требуемом формате
    echo "$jail failed ${currently_failed}/${total_failed} banned ${currently_banned}/${total_banned}"
    report_ok=true
done

if [ "$report_ok" = true ]; then
    # echo "OK"
    exit 0
else
    echo "Critical: не удалось сформировать отчет"
    exit 2
fi
