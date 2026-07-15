#!/bin/bash
# Плагин: Проверка статуса сервисов с автозапуском
# ============================================================
# БЛОК КОНФИГУРАЦИИ — список проверяемых сервисов
# Для добавления сервиса: допишите его имя через пробел
# Для удаления сервиса: уберите его имя из списка
# ============================================================
SERVICES="ssh apache2 fail2ban mysql awg-quick@awg0"
# ============================================================

echo "[INFO] Проверка статуса сервисов"

# Загрузка конфигурации — переопределение из hcheck.conf
CONFIG_FILE="${HCHECK_BASE_DIR:-/opt/hcheck}/config/hcheck.conf"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
# Если в конфиге задана SERVICES_TO_CHECK — используем её вместо локального списка
[ -n "$SERVICES_TO_CHECK" ] && SERVICES="$SERVICES_TO_CHECK"

# Проверка наличия systemctl
command -v systemctl &>/dev/null || { echo "[CRIT] systemctl не найден"; exit 3; }

# Цвета — только при выводе в терминал (чтобы не мусорить в Telegram/логах)
if [ -t 1 ]; then
    C_YELLOW="\033[33m"
    C_GREEN="\033[32m"
    C_RESET="\033[0m"
else
    C_YELLOW=""
    C_GREEN=""
    C_RESET=""
fi

worst_code=0
NOW_EPOCH=$(date +%s)

for service in $SERVICES; do
    # Нормализуем имя юнита (добавляем .service, если расширение не указано)
    unit_name="${service}"
    [[ "$unit_name" != *.service && "$unit_name" != *.socket && "$unit_name" != *.timer ]] && unit_name="${unit_name}.service"

    # Проверяем существование юнита через LoadState (надёжно работает с шаблонными юнитами типа awg-quick@awg0)
    load_state=$(systemctl show "$unit_name" --property=LoadState 2>/dev/null | cut -d= -f2)
    if [ "$load_state" = "not-found" ]; then
        echo "[CRIT] Сервис '${service}' не найден в системе"
        [ 2 -gt "$worst_code" ] && worst_code=2
        continue
    fi

    status=$(systemctl is-active "$unit_name" 2>/dev/null)

    if [ "$status" = "active" ]; then
        # Сервис активен — получаем timestamp запуска
        active_enter=$(systemctl show "$unit_name" --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2)

        # Определяем цвет таймстампа по времени с момента запуска
        ts_output=""
        if [ -n "$active_enter" ] && [ "$active_enter" != "n/a" ]; then
            enter_epoch=$(date -d "$active_enter" +%s 2>/dev/null)
            if [ -n "$enter_epoch" ]; then
                diff_seconds=$((NOW_EPOCH - enter_epoch))
                if [ "$diff_seconds" -lt 86400 ]; then
                    # Менее 1 дня — жёлтый
                    ts_output="${C_YELLOW}${active_enter}${C_RESET}"
                else
                    # Более 1 дня — зелёный
                    ts_output="${C_GREEN}${active_enter}${C_RESET}"
                fi
            else
                ts_output="$active_enter"
            fi
        fi

        if [ -n "$ts_output" ]; then
            echo "[OK]   ${service}: active (since: ${ts_output})"
        else
            echo "[OK]   ${service}: active"
        fi
    else
        # Сервис не активен — сбрасываем failed-состояние и пробуем запустить
        systemctl reset-failed "$unit_name" &>/dev/null
        systemctl start "$unit_name" &>/dev/null
        sleep 1
        new_status=$(systemctl is-active "$unit_name" 2>/dev/null)

        if [ "$new_status" = "active" ]; then
            echo "[WARN] ${service}: запущен (был: ${status})"
            [ 1 -gt "$worst_code" ] && worst_code=1
        else
            echo "[CRIT] ${service}: не удалось запустить (status: ${new_status})"
            [ 2 -gt "$worst_code" ] && worst_code=2
        fi
    fi
done

exit $worst_code
