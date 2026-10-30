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
# Доверенные машины: входы с них учитываются и показываются, но WARN не поднимают.
# Формат: "имя=IP", "имя=подсеть/маска" (IPv4) или без имени, через пробел.
LOGIN_TRUSTED_HOSTS="${LOGIN_TRUSTED_HOSTS:-}"

# Пороги для дискового пространства
DISK_WARN_THRESHOLD=25  # <=25% свободного - WARNING
DISK_CRIT_THRESHOLD=15  # <15% свободного - CRITICAL

worst_code=0

# ============================================
# 1. ПРОВЕРКА ВНЕШНЕГО IP
# ============================================
CURRENT_IP=$(curl -4 -s --connect-timeout 5 https://ifconfig.me/ip)

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
# 4. ПРОВЕРКА ВХОДОВ В СИСТЕМУ
# ============================================
# Два источника:
#   wtmp (last)              — входы с терминалом, включая локальную консоль;
#   auth.log (sshd Accepted) — все SSH-входы, в том числе без терминала
#                              (ssh host 'cmd', scp, sftp). Если auth.log нет — journald.
# Интерактивный SSH-вход попадает в оба источника; дубль из wtmp отбрасывается.

now_ts=$(date +%s)
logins=""          # строки: epoch<TAB>user<TAB>host<TAB>способ
since_ts=""        # с какого момента есть данные (самое позднее начало среди источников)
sources=""

# Перевод даты из лога в epoch. Формат без года ("Oct 30 08:12:26") — если
# получилось будущее, значит запись прошлого года.
to_epoch() {
    local ts e
    ts=$(date -d "$1" +%s 2>/dev/null) || return 1
    if [ "$ts" -gt $((now_ts + 86400)) ]; then
        set -- $1
        e=$(date -d "$1 $2 $(( $(date +%Y) - 1 )) $3" +%s 2>/dev/null) && ts=$e
    fi
    echo "$ts"
}

set_since() {
    [ -z "$1" ] && return
    if [ -z "$since_ts" ] || [ "$1" -gt "$since_ts" ]; then since_ts=$1; fi
}

# --- wtmp ---
if command -v last &>/dev/null; then
    wtmp_raw=$(last -w -i --time-format iso 2>/dev/null)
    if [ -n "$wtmp_raw" ]; then
        sources="${sources:+$sources, }wtmp"
        set_since "$(to_epoch "$(echo "$wtmp_raw" | awk '/^wtmp begins/ {print $3}')")"
        while read -r w_user w_tty w_host w_start _; do
            [ -z "$w_user" ] && continue
            [ "$w_user" = "reboot" ] && continue
            [ "$w_user" = "wtmp" ] && continue
            w_ts=$(to_epoch "$w_start") || continue
            [ "$w_host" = "0.0.0.0" ] && w_host="локально"
            logins+="${w_ts}"$'\t'"${w_user}"$'\t'"${w_host}"$'\t'"терминал ${w_tty}"$'\t'"W"$'\n'
        done <<< "$wtmp_raw"
    fi
fi

# --- SSH: auth.log, иначе journald ---
ssh_re='sshd(-session)?\[[0-9]+\]: Accepted '
auth_lines=""
auth_files=$(ls /var/log/auth.log /var/log/auth.log.[0-9]* 2>/dev/null | sort -V)
if [ -n "$auth_files" ]; then
    sources="${sources:+$sources, }auth.log"
    # auth.log и auth.log.1 читаются всегда (сутки могут попасть на ротацию);
    # более старые — только пока не найден ни один вход (ищем самый свежий).
    oldest=""
    for f in $auth_files; do
        [ -n "$auth_lines" ] && [ "$f" != "/var/log/auth.log.1" ] && break
        oldest=$f
        found=$(zgrep -hE "$ssh_re" "$f" 2>/dev/null)
        [ -n "$found" ] && auth_lines+="${found}"$'\n'
    done
    [ -z "$auth_lines" ] && set_since "$(to_epoch "$(zcat -f "$oldest" 2>/dev/null | head -n 1 | awk '{ if ($1 ~ /^[0-9][0-9][0-9][0-9]-/) print $1; else print $1" "$2" "$3 }')")"
elif command -v journalctl &>/dev/null; then
    sources="${sources:+$sources, }journald"
    auth_lines=$(journalctl -q --no-pager -o short-iso -t sshd -t sshd-session 2>/dev/null | grep -E ": Accepted ")
    [ -z "$auth_lines" ] && set_since "$(to_epoch "$(journalctl -q --no-pager -o short-iso 2>/dev/null | head -n 1 | awk '{print $1}')")"
fi

if [ -n "$auth_lines" ]; then
    while IFS=$'\t' read -r a_ts a_user a_host a_method; do
        a_ts=$(to_epoch "$a_ts") || continue
        logins+="${a_ts}"$'\t'"${a_user}"$'\t'"${a_host}"$'\t'"ssh ${a_method}"$'\t'"A"$'\n'
    done < <(echo "$auth_lines" | awk 'NF {
        ts = ($1 ~ /^[0-9][0-9][0-9][0-9]-/) ? $1 : $1" "$2" "$3
        for (i = 1; i < NF; i++) {
            if ($i == "Accepted") m = $(i+1)
            if ($i == "for")      u = $(i+1)
            if ($i == "from")     h = $(i+1)
        }
        print ts "\t" u "\t" h "\t" m }')
fi

# Убираем дубли: запись wtmp того же пользователя с того же адреса в пределах 10 с от SSH-входа
logins=$(echo -n "$logins" | awk -F'\t' '
    { n++; ts[n]=$1; u[n]=$2; h[n]=$3; how[n]=$4; src[n]=$5 }
    END {
        for (i = 1; i <= n; i++) {
            if (src[i] == "W") {
                dup = 0
                for (j = 1; j <= n; j++)
                    if (src[j] == "A" && u[j] == u[i] && h[j] == h[i] && ts[j]-ts[i] <= 10 && ts[i]-ts[j] <= 10) { dup = 1; break }
                if (dup) continue
            }
            print ts[i] "\t" u[i] "\t" h[i] "\t" how[i]
        }
    }' | sort -t$'\t' -k1,1nr)

fmt_ts() { date -d "@$1" '+%Y-%m-%d %H:%M'; }

# IPv4 → число (пусто, если не IPv4)
ip2int() {
    local IFS=. a b c d
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    read -r a b c d <<< "$1"
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

# Адрес совпадает с IP или попадает в IPv4-подсеть вида 172.16.0.0/12
host_match() {
    local addr=$1 pat=$2 net bits a n mask
    [ "$addr" = "$pat" ] && return 0
    [[ "$pat" == */* ]] || return 1
    net=${pat%/*}; bits=${pat#*/}
    a=$(ip2int "$addr") || return 1
    n=$(ip2int "$net") || return 1
    mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    [ $(( a & mask )) -eq $(( n & mask )) ]
}

# Имя доверенной машины по адресу (или сам шаблон, если имени нет). Код 1 — не доверенная.
trusted_name() {
    local e
    for e in $LOGIN_TRUSTED_HOSTS; do
        host_match "$1" "${e#*=}" && { echo "${e%%=*}"; return 0; }
    done
    return 1
}

# Адрес для вывода: доверенные помечаются именем машины
show_host() {
    local n
    if n=$(trusted_name "$1"); then
        [[ "$n" == "$1" || "$n" == */* ]] && echo "$1 (доверенный)" || echo "$1 ($n)"
    else
        echo "$1"
    fi
}

if [ -z "$sources" ]; then
    echo "[WARN] Не удалось получить данные о входах в систему (нет ни wtmp, ни auth.log, ни journald)"
    [ 1 -gt "$worst_code" ] && worst_code=1
elif [ -z "$logins" ]; then
    if [ -n "$since_ts" ]; then
        echo "[OK]   Входов не было с $(fmt_ts "$since_ts") (${sources})"
    else
        echo "[OK]   Входов не найдено (${sources})"
    fi
else
    day_ago=$((now_ts - 86400))

    # Самый свежий вход вообще и самый свежий — не с доверенной машины
    IFS=$'\t' read -r l_ts l_user l_host l_how <<< "$(echo "$logins" | head -n 1)"
    u_line=""
    while IFS=$'\t' read -r e_ts e_user e_host e_how; do
        trusted_name "$e_host" >/dev/null && continue
        u_line="${e_ts}"$'\t'"${e_user}"$'\t'"${e_host}"$'\t'"${e_how}"
        break
    done <<< "$logins"
    [ -n "$u_line" ] && IFS=$'\t' read -r u_ts u_user u_host u_how <<< "$u_line"

    ago() { local s=$((now_ts - $1)); echo "$((s / 86400))d $(( (s % 86400) / 3600 ))h назад"; }
    day_count=$(echo "$logins" | awk -F'\t' -v since="$day_ago" '$1 >= since' | wc -l)

    if [ -n "$u_line" ] && [ "$u_ts" -ge "$day_ago" ]; then
        echo "[WARN] Последний вход: ${u_user} с $(show_host "$u_host"), ${u_how} ($(ago "$u_ts"))"
        [ 1 -gt "$worst_code" ] && worst_code=1

        # Все входы за сутки (и доверенные тоже), сгруппированные по пользователю, адресу и способу
        echo "Входы за сутки:"
        echo "$logins" | awk -F'\t' -v since="$day_ago" '
            $1 >= since {
                k = $2 "\t" $3 "\t" $4
                if (!(k in cnt)) { order[++n] = k; last[k] = $1 }
                cnt[k]++; first[k] = $1
            }
            END { for (i = 1; i <= n; i++) { k = order[i]; print last[k] "\t" first[k] "\t" cnt[k] "\t" k } }' |
        while IFS=$'\t' read -r g_last g_first g_cnt g_user g_host g_how; do
            if [ "$g_cnt" -eq 1 ]; then
                echo "  ${g_user} с $(show_host "$g_host"), ${g_how}: $(fmt_ts "$g_last")"
            else
                echo "  ${g_user} с $(show_host "$g_host"), ${g_how}: ${g_cnt} раз, $(fmt_ts "$g_first") … $(fmt_ts "$g_last")"
            fi
        done
    elif [ "$day_count" -gt 0 ]; then
        echo "[OK]   Последний вход: ${l_user} с $(show_host "$l_host"), ${l_how} ($(ago "$l_ts")); за сутки ${day_count} вх., все с доверенных машин"
    else
        echo "[OK]   Последний вход: ${l_user} с $(show_host "$l_host"), ${l_how} ($(ago "$l_ts"))"
    fi
fi

exit $worst_code
