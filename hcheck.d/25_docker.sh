#!/bin/bash
# Плагин: Проверка здоровья Docker-контейнеров с автозапуском
# ============================================================
# БЛОК КОНФИГУРАЦИИ — список проверяемых контейнеров
# Для добавления контейнера: допишите его имя через пробел
# Для удаления контейнера: уберите его имя из списка
# ============================================================
CONTAINERS="wg-easy"
# ============================================================

echo "[INFO] Проверка Docker-контейнеров"

# Загрузка конфигурации — переопределение из hcheck.conf
CONFIG_FILE="${HCHECK_BASE_DIR:-/opt/hcheck}/config/hcheck.conf"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
# Если в конфиге задана CONTAINERS_TO_CHECK — используем её вместо локального списка
[ -n "$CONTAINERS_TO_CHECK" ] && CONTAINERS="$CONTAINERS_TO_CHECK"

# Проверка наличия docker
command -v docker &>/dev/null || { echo "[CRIT] docker не найден"; exit 3; }

# Проверка что docker daemon отвечает
docker info &>/dev/null || { echo "[CRIT] Docker daemon не отвечает"; exit 2; }

worst_code=0

for container in $CONTAINERS; do
    # Проверяем существование контейнера
    if ! docker inspect "$container" &>/dev/null; then
        echo "[CRIT] Контейнер '${container}' не найден"
        [ 2 -gt "$worst_code" ] && worst_code=2
        continue
    fi

    running=$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)

    if [ "$running" != "true" ]; then
        # Контейнер не запущен — пробуем запустить
        docker start "$container" &>/dev/null
        sleep 2
        new_running=$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)

        if [ "$new_running" = "true" ]; then
            echo "[WARN] ${container}: запущен (был остановлен)"
            [ 1 -gt "$worst_code" ] && worst_code=1
        else
            echo "[CRIT] ${container}: не удалось запустить"
            [ 2 -gt "$worst_code" ] && worst_code=2
        fi
        continue
    fi

    # Контейнер запущен — смотрим healthcheck, если он определён
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null)

    case "$health" in
        healthy|none)
            echo "[OK]   ${container}: running (health: ${health})"
            ;;
        starting)
            echo "[WARN] ${container}: running (health: starting)"
            [ 1 -gt "$worst_code" ] && worst_code=1
            ;;
        unhealthy)
            echo "[CRIT] ${container}: running, но health: unhealthy"
            [ 2 -gt "$worst_code" ] && worst_code=2
            ;;
        *)
            echo "[WARN] ${container}: running (health: ${health})"
            [ 1 -gt "$worst_code" ] && worst_code=1
            ;;
    esac
done

exit $worst_code
