#!/bin/bash
# Плагин: Проверка системных параметров (IP, диск, uptime, последний вход)

echo "Проверка системных параметров"

# ============================================
# НАСТРОЙКИ
# ============================================
# Режим 1: Контроль IP. Укажите референсный IP в hcheck.conf (REF_IP).
# Режим 2: Без контроля. Оставьте переменную пустой или не задавайте её.
CONFIG_FILE="${HCHECK_BASE_DIR:-/opt/hcheck}/config/hcheck.conf"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
REF_IP="${REF_IP:-}"

# Пороги для дискового пространства
DISK_WARN_THRESHOLD=15  # <=15% свободного - WARNING
DISK_CRIT_THRESHOLD=10  # <10% свободного - CRITICAL

worst_code=0

# ============================================
# 1. ПРОВЕРКА ВНЕШНЕГО IP
# ============================================
CURRENT_IP=$(curl -s --connect-timeout 5 https://ifconfig.me/ip)

if [ -z "$CURRENT_IP" ]; then
    echo "[WARN] Не удалось определить внешний IP (проверьте сеть или curl)"
    [ 1 -gt "$worst_code" ] && worst_code=1
elif [ -z "$REF_IP" ]; then
    # Режим без контроля
    echo "[OK] $CURRENT_IP"
elif [ "$CURRENT_IP" = "$REF_IP" ]; then
    # Режим контроля: совпадение
    echo "[OK] $CURRENT_IP"
else
    # Режим контроля: несовпадение
    echo "[CRIT] $CURRENT_IP (ref $REF_IP)"
    [ 2 -gt "$worst_code" ] && worst_code=2
fi

echo ""

# ============================================
# 2. ПРОВЕРКА ДИСКОВОГО ПРОСТРАНСТВА
# ============================================
while IFS= read -r line; do
    echo "$line" | grep -q "^Filesystem" && continue
    
    filesystem=$(echo "$line" | awk '{print $1}')
    size=$(echo "$line" | awk '{print $2}')
    used=$(echo "$line" | awk '{print $3}')
    avail=$(echo "$line" | awk '{print $4}')
    use_pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $6}')
    
    case "$filesystem" in 
        tmpfs|devtmpfs|none|udev|shm|overlay) continue;; 
    esac
    
    free_pct=$((100 - use_pct))
    
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

echo ""

# ============================================
# 3. ПРОВЕРКА UPTIME СИСТЕМЫ
# ============================================
if [ -f /proc/uptime ]; then
    uptime_seconds=$(awk '{print int($1)}' /proc/uptime)
else
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

echo ""

# ============================================
# 4. ПРОВЕРКА ПОСЛЕДНЕГО ВХОДА В СИСТЕМУ
# ============================================

last_output=$(last -n 10 2>/dev/null | grep -v "^$" | grep -v "^wtmp" | grep -v "reboot")
login_is_ok=0 # Флаг: 0 = не OK (нужен вывод истории), 1 = OK (историю не выводим)

if [ -z "$last_output" ]; then
    echo "[WARN] Не удалось получить данные о входах в систему"
    [ 1 -gt "$worst_code" ] && worst_code=1
else
    last_entry=$(echo "$last_output" | head -n 1)
    
    last_user=$(echo "$last_entry" | awk '{print $1}')
    last_terminal=$(echo "$last_entry" | awk '{print $2}')
    last_host=$(echo "$last_entry" | awk '{print $3}')
    
    day_of_week=$(echo "$last_entry" | awk '{print $4}')
    month=$(echo "$last_entry" | awk '{print $5}')
    day=$(echo "$last_entry" | awk '{print $6}')
    time=$(echo "$last_entry" | awk '{print $7}')
    
    last_date_str="${day_of_week} ${month} ${day} ${time}"
    
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
                login_is_ok=1 # Вход был давно, всё ОК
            fi
        else
            echo "[WARN] Не удалось распарсить дату последнего входа: $last_date_str"
            [ 1 -gt "$worst_code" ] && worst_code=1
        fi
    else
        echo "[WARN] Утилита date недоступна"
        [ 1 -gt "$worst_code" ] && worst_code=1
    fi
    
    # Выводим историю ТОЛЬКО если последний вход НЕ Ок (login_is_ok == 0)
    if [ "$login_is_ok" -eq 0 ]; then
        echo "Последние входы за сутки:"
        current_timestamp=$(date +%s)
        yesterday_timestamp=$((current_timestamp - 86400))
        
        echo "$last_output" | while read -r entry; do
            [ -z "$entry" ] && continue
            
            entry_day_of_week=$(echo "$entry" | awk '{print $4}')
            entry_month=$(echo "$entry" | awk '{print $5}')
            entry_day=$(echo "$entry" | awk '{print $6}')
            entry_time=$(echo "$entry" | awk '{print $7}')
            
            entry_date_str="${entry_day_of_week} ${entry_month} ${entry_day} ${entry_time}"
            entry_timestamp=$(date -d "$entry_date_str" +%s 2>/dev/null)
            
            if [ -n "$entry_timestamp" ] && [ "$entry_timestamp" -ge "$yesterday_timestamp" ]; then
                echo "  $entry"
            fi
        done
    fi
fi

exit $worst_code
