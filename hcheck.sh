#!/bin/bash
# HCHECK - Главный скрипт-оркестратор
set -o pipefail

HCHECK_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HCHECK_BASE_DIR

CONFIG_FILE="${HCHECK_BASE_DIR}/config/hcheck.conf"
[ ! -f "$CONFIG_FILE" ] && { echo "ОШИБКА: Конфиг не найден: $CONFIG_FILE"; exit 1; }
source "$CONFIG_FILE"

LIB_FILE="${HCHECK_BASE_DIR}/lib/common.sh"
[ ! -f "$LIB_FILE" ] && { echo "ОШИБКА: Библиотека не найдена: $LIB_FILE"; exit 1; }
source "$LIB_FILE"

mkdir -p "${HCHECK_LOG_DIR}" 2>/dev/null
[ "$(id -u)" -ne 0 ] && log_warning "Запущен не от root"

HOSTNAME=$(hostname)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
PLUGIN_DIR="${HCHECK_BASE_DIR}/hcheck.d"
PLUGIN_TIMEOUT="${PLUGIN_TIMEOUT:-15}"
REPORT_MODE="${REPORT_MODE:-silent_ok}"
NOTIFY_CHANNELS="${NOTIFY_CHANNELS:-}"

declare -a PLUGIN_NAMES=() PLUGIN_CODES=() PLUGIN_OUTPUTS=()

log_info "=== [$TIMESTAMP] Запуск hcheck ==="
log_info "Хост: $HOSTNAME | Режим: $REPORT_MODE | Каналы: ${NOTIFY_CHANNELS:-<нет>}"

PLUGINS=()
[ -d "$PLUGIN_DIR" ] && while IFS= read -r -d '' plugin; do PLUGINS+=("$plugin"); done < <(find "$PLUGIN_DIR" -maxdepth 1 -type f -executable -print0 | sort -z)
[ ${#PLUGINS[@]} -eq 0 ] && { log_warning "Нет плагинов"; echo "Нет плагинов."; exit 0; }

log_info "Плагинов: ${#PLUGINS[@]}"

for plugin in "${PLUGINS[@]}"; do
    plugin_name=$(basename "$plugin")
    tmp_output=$(mktemp /tmp/hcheck_plugin_XXXXXX)
    exit_code=3
    timeout "$PLUGIN_TIMEOUT" "$plugin" > "$tmp_output" 2>&1 && exit_code=$? || exit_code=$?
    [ $exit_code -eq 124 ] && { echo "[CRIT] Таймаут (${PLUGIN_TIMEOUT}с)" > "$tmp_output"; exit_code=3; log_error "$plugin_name: таймаут"; }
    PLUGIN_NAMES+=("$plugin_name"); PLUGIN_CODES+=("$exit_code"); PLUGIN_OUTPUTS+=("$(cat "$tmp_output")")
    rm -f "$tmp_output"
done

overall_code=0
for code in "${PLUGIN_CODES[@]}"; do [ "$code" -gt "$overall_code" ] && overall_code=$code; done
overall_status=$(get_status_name "$overall_code")

build_summary() {
    local s="==========================================\n"
    s+="=== HCHECK SUMMARY [${HOSTNAME}] ${TIMESTAMP} ===\n"
    for i in "${!PLUGIN_NAMES[@]}"; do
        local emoji=$(get_status_emoji "${PLUGIN_CODES[$i]}")
        case "${PLUGIN_CODES[$i]}" in
            0) s+="${emoji}[OK]        ${PLUGIN_NAMES[$i]}\n";;
            1) s+="${emoji}[WARNING]   ${PLUGIN_NAMES[$i]}\n";;
            2) s+="${emoji}[CRITICAL]  ${PLUGIN_NAMES[$i]}\n";;
            3) s+="${emoji}[UNKNOWN]   ${PLUGIN_NAMES[$i]}\n";;
        esac
    done
    s+="=========================================="
    echo -e "$s"
}

build_details() {
    local d="\n=== DETAILED REPORTS ===\n"; local only_errors="$1"
    for i in "${!PLUGIN_NAMES[@]}"; do
        [ "$only_errors" = "true" ] && [ "${PLUGIN_CODES[$i]}" -eq 0 ] && continue
        d+="\n--- ${PLUGIN_NAMES[$i]} ---\n"
        local output="${PLUGIN_OUTPUTS[$i]}"
        output=$(echo "$output" | sed \
            -e 's/\[CRITICAL\]/🔴[CRITICAL]/g' \
            -e 's/\[CRIT\]/🔴[CRIT]/g' \
            -e 's/\[WARNING\]/🟡[WARNING]/g' \
            -e 's/\[WARN\]/🟡[WARN]/g' \
            -e 's/\[OK\]/🟢[OK]/g' \
            -e 's/\[INFO\] //g' \
            -e 's/\[ERROR\]/🔴[ERROR]/g' \
            -e 's/\[UNKNOWN\]/⚪[UNKNOWN]/g')
        d+="$output\n"
    done
    echo -e "$d"
}

summary_text=$(build_summary)

case "$REPORT_MODE" in
    silent_ok)
        [ "$overall_code" -eq 0 ] && { 
            log_info "Всё OK, молчим"
            echo -e "$summary_text" >> "${HCHECK_LOG_DIR}/hcheck_$(date +%Y%m%d).log"
            exit 0
        }
        report_text="${summary_text}$(build_details true)"
        full_report_text="${summary_text}$(build_details false)" ;;
    summary_only)
        report_text="$summary_text"
        full_report_text="${summary_text}$(build_details false)" ;;
    full)
        report_text="${summary_text}$(build_details false)"
        full_report_text="$report_text" ;;
    *)
        log_error "Неизвестный REPORT_MODE: $REPORT_MODE"
        report_text="$summary_text"
        full_report_text="$report_text" ;;
esac

# Запись в лог
echo -e "$full_report_text" >> "${HCHECK_LOG_DIR}/hcheck_$(date +%Y%m%d).log"

# Отправка уведомлений
if [ "$NOTIFY_CHANNELS" != "log" ] && [ -n "$NOTIFY_CHANNELS" ]; then
    log_info "[$TIMESTAMP] Отправка уведомлений..."
    send_notifications "$report_text" "$full_report_text" "$NOTIFY_CHANNELS"
    [ $? -eq 0 ] && log_info "Уведомления OK" || log_error "Все каналы провалились"
fi

log_info "=== [$TIMESTAMP] Завершение (overall: $overall_status) ==="
exit $overall_code
