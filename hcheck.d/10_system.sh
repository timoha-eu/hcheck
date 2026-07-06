#!/bin/bash
# Плагин: Проверка системных параметров (диск, uptime, последний вход)

echo "Проверка системных параметров"

# Пороги для дискового пространства
DISK_WARN_THRESHOLD=15  # <=15% свободного - WARNING
DISK_CRIT_THRESHOLD=10  # <10% свободного - CRITICAL

worst_code=0

# ============================================
# 1. ПРОВЕРКА ДИСКОВОГО ПРОСТРАНСТВА
# ============================================
echo ""
echo "=== Дисковое пространство ==="

while IFS= read -r line; do
    # Пропускаем заголовок
    echo "$line" | grep -q "^Filesystem" && continue
    
    filesystem=$(echo "$line" | awk '{print $1}')
    size=$(echo "$line" | awk '{print $2}')
    used=$(echo "$line" | awk '{print $3}')
    avail=$(echo "$line" | awk '{print $4}')
    use_pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $6}')
    
    # Пропускаем виртуальные файловые системы
    case "$filesystem" in 
        tmpfs|devtmpfs|none|udev|shm|overlay) continue;; 
    esac
    
    # Вычисляем процент свободного места
    free_pct=$((100 - use_pct))
    
    # Проверяем пороги
    if [ "$free_pct" -lt "$DISK_CRIT_THRESHOLD" ]; then
        echo "[CRIT] ${mount}: total ${size}, used ${used}, free ${avail} (${free_pct}% free)"
        [ 2 -gt "$worst_code" ] && worst_code=2
    elif [ "$free_pct" -le "$DISK_WARN_THRESHOLD" ]; then
        echo "[WARN] ${mount}: total ${size}, used ${used}, free ${avail} (${free_pct}% free)"
        [ 1 -gt "$worst_code" ] && worst_code=1
    else
        echo "[OK]   ${mount}: total ${size}, used ${used}, free ${avail} (${free_pct}% free)"
    fi
done < <(df -h 2>/dev/null)

# Проверка inodes
while IFS= read -r line; do
    echo "$line" | grep -q "^Filesystem" && continue
    
    filesystem=$(echo "$line" | awk '{print $1}')
    inodes_pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $6}')
    
    case "$filesystem" in 
        tmpfs|devtmpfs|none|udev|shm|overlay) continue;; 
    esac
    
    [ -z "$inodes_pct" ] || [ "$inodes_pct" = "-" ] && continue
    
    if [ "$inodes_pct" -ge 90 ]; then
        echo "[CRIT] Inodes ${mount}: ${inodes_pct}% used"
        [ 2 -gt "$worst_code" ] && worst_code=2
    elif [ "$inodes_pct" -ge 80 ]; then
        echo "[WARN] Inodes ${mount}: ${inodes_pct}% used"
        [ 1 -gt "$worst_code" ] && worst_code=1
    else
        echo "[OK]   Inodes ${mount}: ${inodes_pct}% used"
    fi
done < <(df -i 2>/dev/null)

# ============================================
# 2. ПРОВЕРКА UPTIME СИСТЕМЫ
# ============================================
echo ""

# Получаем uptime в секундах
if [ -f /proc/uptime ]; then
    uptime_seconds=$(awk '{print int($1)}' /proc/uptime)
else
    # Fallback: парсим вывод uptime
    uptime_output=$(uptime 2>/dev/null)
    if echo "$uptime_output" | grep -q "day"; then
        days=$(echo "$uptime_output" | grep -oP '\d+ day' | awk '{print $1}')
        hours=$(echo "$uptime_output" | grep -oP '\d+:\d+' | head -1 | cut -d: -f1)
        minutes=$(echo "$uptime_output" | grep -oP '\d+:\d+' | head -1 | cut -d: -f2)
        uptime_seconds=$((days * 86400 + hours * 3600 + minutes * 60))
    elif echo "$uptime_output" | grep -q "min"; then
        minutes=$(echo "$uptime_output" | grep -oP '\d+ min' | awk '{print $1}')
        uptime_seconds=$((minutes * 60))
    else
        uptime_seconds=0
    fi
fi

# Вычисляем дни, часы, минуты
uptime_days=$((uptime_seconds / 86400))
uptime_hours=$(( (uptime_seconds % 86400) / 3600 ))
uptime_minutes=$(( (uptime_seconds % 3600) / 60 ))

uptime_human="${uptime_days}d ${uptime_hours}h ${uptime_minutes}m"

if [ "$uptime_seconds" -lt 86400 ]; then
    echo "[WARN] Uptime: ${uptime_human} (менее 1 дня)"
    [ 1 -gt "$worst_code" ] && worst_code=1
else
    echo "[OK]   Uptime: ${uptime_human}"
fi

# ============================================
# 3. ПРОВЕРКА ПОСЛЕДНЕГО ВХОДА В СИСТЕМУ
# ============================================
echo ""

# Получаем информацию о последнем входе
last_output=$(last -n 10 2>/dev/null | grep -v "^$" | grep -v "^wtmp" | grep -v "reboot")

if [ -z "$last_output" ]; then
    echo "[WARN] Не удалось получить данные о входах в систему"
    [ 1 -gt "$worst_code" ] && worst_code=1
else
    # Берем первый (самый свежий) вход
    last_entry=$(echo "$last_output" | head -n 1)
    
    # Парсим данные
    last_user=$(echo "$last_entry" | awk '{print $1}')
    last_terminal=$(echo "$last_entry" | awk '{print $2}')
    last_host=$(echo "$last_entry" | awk '{print $3}')
    
    # Извлекаем дату и время входа (поля 4-6: день недели, месяц, день)
    # Формат: user pts/0 host Mon Jul  6 13:56 still logged in
    day_of_week=$(echo "$last_entry" | awk '{print $4}')
    month=$(echo "$last_entry" | awk '{print $5}')
    day=$(echo "$last_entry" | awk '{print $6}')
    time=$(echo "$last_entry" | awk '{print $7}')
    
    # Формируем строку даты без "still logged in"
    last_date_str="${day_of_week} ${month} ${day} ${time}"
    
    # Пытаемся распарсить дату
    if command -v date &>/dev/null; then
        last_timestamp=$(date -d "$last_date_str" +%s 2>/dev/null)
        
        if [ -n "$last_timestamp" ]; then
            current_timestamp=$(date +%s)
            seconds_ago=$((current_timestamp - last_timestamp))
            days_ago=$((seconds_ago / 86400))
            hours_ago=$(( (seconds_ago % 86400) / 3600 ))
            
            last_human="${days_ago}d ${hours_ago}h назад"
            
            if [ "$seconds_ago" -lt 86400 ]; then
                echo "[WARN] Последний вход: ${last_user} с ${last_host} на ${last_terminal} (${last_human})"
                [ 1 -gt "$worst_code" ] && worst_code=1
            else
                echo "[OK]   Последний вход: ${last_user} с ${last_host} на ${last_terminal} (${last_human})"
            fi
        else
            echo "[WARN] Не удалось распарсить дату последнего входа: $last_date_str"
            [ 1 -gt "$worst_code" ] && worst_code=1
        fi
    else
        echo "[WARN] Утилита date недоступна"
        [ 1 -gt "$worst_code" ] && worst_code=1
    fi
    
    # Показываем последние входы за последние 24 часа
    echo "Последние входы за сутки:"
    
    # Получаем текущее время минус 24 часа
    current_timestamp=$(date +%s)
    yesterday_timestamp=$((current_timestamp - 86400))
    
    # Обрабатываем каждую запись
    echo "$last_output" | while read -r entry; do
        [ -z "$entry" ] && continue
        
        # Парсим дату из записи
        entry_day_of_week=$(echo "$entry" | awk '{print $4}')
        entry_month=$(echo "$entry" | awk '{print $5}')
        entry_day=$(echo "$entry" | awk '{print $6}')
        entry_time=$(echo "$entry" | awk '{print $7}')
        
        entry_date_str="${entry_day_of_week} ${entry_month} ${entry_day} ${entry_time}"
        entry_timestamp=$(date -d "$entry_date_str" +%s 2>/dev/null)
        
        # Проверяем, была ли запись в последние 24 часа
        if [ -n "$entry_timestamp" ] && [ "$entry_timestamp" -ge "$yesterday_timestamp" ]; then
            echo "  $entry"
        fi
    done
fi

exit $worst_code
