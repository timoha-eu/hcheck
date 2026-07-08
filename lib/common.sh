#!/bin/bash
# HCHECK Library - Common Functions

HCHECK_LOG_DIR="${HCHECK_BASE_DIR:-/opt/hcheck}/logs"
HCHECK_LOG_FILE="${HCHECK_LOG_DIR}/hcheck_$(date +%Y%m%d).log"

log_msg() {
    local level="$1"; shift
    local msg="$*"
    local emoji=""
    case "$level" in
        INFO)    emoji="";;
        WARNING) emoji="🟡";;
        ERROR)   emoji="🔴";;
        *)       emoji="";;
    esac
    if [ "$level" = "INFO" ]; then
        echo "$msg" >> "$HCHECK_LOG_FILE" 2>/dev/null
    else
        echo "${emoji}[${level}] ${msg}" >> "$HCHECK_LOG_FILE" 2>/dev/null
    fi
}
log_info()    { log_msg "INFO"    "$@"; }
log_warning() { log_msg "WARNING" "$@"; }
log_error()   { log_msg "ERROR"   "$@"; }

format_telegram_message() {
    local text="$1"
    text=$(echo "$text" | sed \
        -e 's/\[CRITICAL\]/🔴/g' -e 's/\[CRIT\]/🔴/g' \
        -e 's/\[WARNING\]/🟡/g'  -e 's/\[WARN\]/🟡/g' \
        -e 's/\[OK\]/🟢/g'       -e 's/\[INFO\] //g' \
        -e 's/\[ERROR\]/🔴/g'    -e 's/\[UNKNOWN\]/⚪/g')
    echo "$text"
}

send_telegram() {
    local body="$1"
    [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ] && { log_error "Telegram: токены не заданы"; return 1; }
    local formatted_body=$(format_telegram_message "$body")
    local max_len=4000; local part=1
    while [ ${#formatted_body} -gt 0 ]; do
        local chunk="${formatted_body:0:$max_len}"
        formatted_body="${formatted_body:$max_len}"
        local response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${chunk}" \
            -d "parse_mode=${TELEGRAM_PARSE_MODE:-Markdown}" 2>&1)
        echo "$response" | grep -q '"ok":true' && log_info "Telegram: часть ${part} OK" || { log_error "Telegram: ошибка: $response"; return 1; }
        part=$((part + 1))
    done
    return 0
}

send_email() {
    local subject="$1"; local body="$2"; local to="${EMAIL_TO}"
    [ -z "$to" ] && { log_error "Email: EMAIL_TO не задан"; return 1; }
    local method="${EMAIL_METHOD:-msmtp}"
    case "$method" in
        msmtp)
            { echo "To: $to"; echo "From: ${EMAIL_FROM:-hcheck@$(hostname)}"; echo "Subject: $subject"
              echo "MIME-Version: 1.0"; echo "Content-Type: text/plain; charset=UTF-8"; echo ""; echo "$body"
            } | msmtp -t 2>>"$HCHECK_LOG_FILE"
            [ $? -eq 0 ] && { log_info "Email (msmtp): OK"; return 0; } || { log_error "Email (msmtp): ошибка"; return 1; } ;;
        curl)
            [ -z "$EMAIL_SMTP_URL" ] && { log_error "Email (curl): SMTP_URL не задан"; return 1; }
            local tmpfile=$(mktemp /tmp/hcheck_email_XXXXXX)
            { echo "From: ${EMAIL_FROM:-hcheck@$(hostname)}"; echo "To: $to"; echo "Subject: $subject"
              echo "MIME-Version: 1.0"; echo "Content-Type: text/plain; charset=UTF-8"; echo ""; echo "$body"
            } > "$tmpfile"
            curl --silent --url "$EMAIL_SMTP_URL" --ssl-reqd --mail-from "${EMAIL_FROM:-hcheck@$(hostname)}" \
                 --mail-rcpt "$to" --user "${EMAIL_SMTP_USER}:${EMAIL_SMTP_PASS}" --upload-file "$tmpfile" 2>>"$HCHECK_LOG_FILE"
            local result=$?; rm -f "$tmpfile"
            [ $result -eq 0 ] && { log_info "Email (curl): OK"; return 0; } || { log_error "Email (curl): ошибка"; return 1; } ;;
        *) log_error "Email: неизвестный метод '$method'"; return 1 ;;
    esac
}

send_webdav() {
    local body="$1"
    [ -z "$WEBDAV_URL" ] && { log_error "WebDAV: URL не задан"; return 1; }
    local hostname=$(hostname); local timestamp=$(date '+%Y%m%d_%H%M%S')
    local filename="${WEBDAV_FILENAME_PREFIX:-hcheck_}${hostname}_${timestamp}${WEBDAV_FILENAME_SUFFIX:-.txt}"
    local tmpfile=$(mktemp /tmp/hcheck_webdav_XXXXXX); echo "$body" > "$tmpfile"
    local url="${WEBDAV_URL%/}/${filename}"
    local curl_opts="--silent --show-error --fail --upload-file $tmpfile"
    [ -n "$WEBDAV_USER" ] && [ -n "$WEBDAV_PASS" ] && curl_opts="$curl_opts --user ${WEBDAV_USER}:${WEBDAV_PASS}"
    curl $curl_opts "$url" 2>>"$HCHECK_LOG_FILE"; local result=$?; rm -f "$tmpfile"
    [ $result -eq 0 ] && { log_info "WebDAV: OK ($url)"; return 0; } || { log_error "WebDAV: ошибка ($result)"; return 1; }
}

send_sftp() {
    local body="$1"
    [ -z "$SFTP_HOST" ] && { log_error "SFTP: HOST не задан"; return 1; }
    local hostname=$(hostname); local timestamp=$(date '+%Y%m%d_%H%M%S')
    local filename="${SFTP_FILENAME_PREFIX:-hcheck_}${hostname}_${timestamp}${SFTP_FILENAME_SUFFIX:-.txt}"
    local remote_path="${SFTP_REMOTE_PATH:-/}"; local port="${SFTP_PORT:-22}"
    local tmpfile=$(mktemp /tmp/hcheck_sftp_XXXXXX); echo "$body" > "$tmpfile"
    local sftp_cmd="put ${tmpfile} ${remote_path%/}/${filename}"
    local sftp_opts="-P $port -b -"
    [ -n "$SFTP_KEY_FILE" ] && sftp_opts="$sftp_opts -i $SFTP_KEY_FILE"
    [ -n "$SFTP_USER" ] && echo "$sftp_cmd" | sftp $sftp_opts "${SFTP_USER}@${SFTP_HOST}" 2>>"$HCHECK_LOG_FILE" \
                       || echo "$sftp_cmd" | sftp $sftp_opts "${SFTP_HOST}" 2>>"$HCHECK_LOG_FILE"
    local result=$?; rm -f "$tmpfile"
    [ $result -eq 0 ] && { log_info "SFTP: OK"; return 0; } || { log_error "SFTP: ошибка ($result)"; return 1; }
}

send_notifications() {
    local report_body="$1"; local full_report_body="$2"; local channels="$3"
    [ -z "$channels" ] && { log_info "Каналы не заданы"; return 0; }
    local success_count=0; local total_count=0
    IFS=',' read -ra CHANNEL_ARRAY <<< "$channels"
    for channel in "${CHANNEL_ARRAY[@]}"; do
        channel=$(echo "$channel" | xargs)
        [ -z "$channel" ] || [ "$channel" = "log" ] && continue
        case "$channel" in
            email)    total_count=$((total_count + 1)); send_email "${EMAIL_SUBJECT_PREFIX:-[hcheck]} $(hostname) $(date '+%Y-%m-%d %H:%M:%S')" "$report_body" && success_count=$((success_count + 1)) ;;
            telegram) total_count=$((total_count + 1)); send_telegram "$report_body" && success_count=$((success_count + 1)) ;;
            webdav)   total_count=$((total_count + 1)); send_webdav "$full_report_body" && success_count=$((success_count + 1)) ;;
            sftp)     total_count=$((total_count + 1)); send_sftp "$full_report_body" && success_count=$((success_count + 1)) ;;
            *) log_warning "Неизвестный канал: $channel" ;;
        esac
    done
    [ "$total_count" -eq 0 ] && return 0
    [ "$success_count" -gt 0 ] && return 0 || return 1
}

get_status_name() {
    case "$1" in 0) echo "OK";; 1) echo "WARNING";; 2) echo "CRITICAL";; 3) echo "UNKNOWN";; *) echo "UNKNOWN";; esac
}

get_status_emoji() {
    case "$1" in 0) echo "🟢";; 1) echo "🟡";; 2) echo "🔴";; 3) echo "⚪";; *) echo "⚪";; esac
}
