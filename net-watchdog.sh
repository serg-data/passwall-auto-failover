#!/bin/sh

# ===============================
# LOCK — защита от параллельного запуска
# ===============================
LOCK="/tmp/net-watchdog.lock"

if [ -f "$LOCK" ]; then
    OLD_PID=$(cat "$LOCK")

    # если процесс ещё жив — выходим
    if kill -0 "$OLD_PID" 2>/dev/null; then
        exit 0
    else
        # если умер — очищаем lock
        rm -f "$LOCK"
    fi
fi

echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT


# ===============================
# НАСТРОЙКИ
# ===============================
INTERFACE="wwan"

# хосты для проверки интернета
HOSTS="77.88.8.8 77.88.8.1"
TIMEOUT=2

# через сколько секунд считаем интернет "упавшим"
FAIL_TIME=40

# максимум попыток восстановления
MAX_REBOOTS=2

# время "заморозки" после неудачных попыток (сек)
COOLDOWN=3600

# минимальный интервал между действиями (анти-флаппинг)
ACTION_DELAY=70

# режим работы:
# reboot  → сразу reboot
# modem   → только ifdown/ifup
# mixed   → умная лестница (ifdown → uqmi → reboot)
MODE="mixed"

# включение уровней восстановления
ENABLE_IFDOWN="0"
ENABLE_UQMI_RESET="1"


# ===============================
# ФАЙЛЫ СОСТОЯНИЯ
# ===============================
STATE_DIR="/tmp/netwatchdog"

FAIL_FILE="$STATE_DIR/fail_start"      # время начала падения
COUNT_FILE="$STATE_DIR/count"          # счётчик попыток

# ⚠️ ВАЖНО:
# cooldown сохраняем в overlay, чтобы переживал reboot
COOLDOWN_FILE="/overlay/netwatchdog.cooldown"

LAST_ACTION="$STATE_DIR/last_action"   # время последнего действия

# лог в RAM (не убивает флеш)
LOG_FILE="/tmp/net-watchdog.log"
MAX_LINES=200

mkdir -p $STATE_DIR


# ===============================
# ЛОГИРОВАНИЕ
# ===============================
log() {
    MSG="$1"

    # системный лог
    logger -t net-watchdog "$MSG"

    # лог в файл
    echo "$(date '+%H:%M:%S') $MSG" >> $LOG_FILE

    # ограничение размера лога
    LINES=$(wc -l < $LOG_FILE)
    if [ "$LINES" -gt "$MAX_LINES" ]; then
        tail -n $MAX_LINES $LOG_FILE > ${LOG_FILE}.tmp
        mv ${LOG_FILE}.tmp $LOG_FILE
    fi
}

now() {
    date +%s
}

ts() {
    date "+%Y-%m-%d %H:%M:%S"
}


# ===============================
# ПРОВЕРКА ИНТЕРНЕТА
# ===============================
check_net() {
    for H in $HOSTS; do
        ping -c1 -W$TIMEOUT $H >/dev/null 2>&1 && return 0
    done
    return 1
}


# ===============================
# COOLDOWN — защита от флаппинга
# ===============================
if [ -f "$COOLDOWN_FILE" ]; then
    END=$(cat "$COOLDOWN_FILE")
    NOW=$(now)

    # даже в cooldown проверяем интернет
    if check_net; then
        log "Internet restored during cooldown"
        rm -f "$COOLDOWN_FILE" "$COUNT_FILE" "$FAIL_FILE"
        exit 0
    fi

    # если cooldown ещё активен — ничего не делаем
    if [ "$NOW" -lt "$END" ]; then
        log "Cooldown active"
        exit 0
    else
        log "Cooldown finished"
        rm -f "$COOLDOWN_FILE" "$COUNT_FILE"
    fi
fi


# ===============================
# ОСНОВНАЯ ПРОВЕРКА
# ===============================
if check_net; then
    # если интернет восстановился — логируем
    if [ -f "$FAIL_FILE" ]; then
        START=$(cat "$FAIL_FILE")
        DOWN=$(( $(now) - START ))
        log "Internet restored after ${DOWN}s"
    fi

    rm -f "$FAIL_FILE"
    exit 0
fi

NOW=$(now)

# первый раз фиксируем падение
if [ ! -f "$FAIL_FILE" ]; then
    echo "$NOW" > "$FAIL_FILE"
    log "Internet lost at $(ts)"
    exit 0
fi

START=$(cat "$FAIL_FILE")
DOWN=$((NOW - START))

log "No internet for ${DOWN}s"

# ждём порог FAIL_TIME
if [ "$DOWN" -lt "$FAIL_TIME" ]; then
    exit 0
fi


# ===============================
# АНТИ-ДОЛБЁЖКА
# ===============================
if [ -f "$LAST_ACTION" ]; then
    LAST=$(cat "$LAST_ACTION")

    if [ $((NOW - LAST)) -lt "$ACTION_DELAY" ]; then
        log "Too soon after last action → skip"
        exit 0
    fi
fi

echo "$NOW" > "$LAST_ACTION"


# ===============================
# ВОССТАНОВЛЕНИЕ
# ===============================
COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)

# если достигли лимита → cooldown
if [ "$COUNT" -ge "$MAX_REBOOTS" ]; then
    END=$((NOW + COOLDOWN))
    echo "$END" > "$COOLDOWN_FILE"

    log "Max attempts reached → cooldown for $COOLDOWN sec"

    rm -f "$FAIL_FILE"
    exit 0
fi

COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNT_FILE"

log "Recovery attempt $COUNT (mode: $MODE)"


# ===============================
# РЕЖИМЫ РАБОТЫ
# ===============================

# --- только reboot ---
if [ "$MODE" = "reboot" ]; then
    log "Rebooting router"

    echo "$NOW" > "$FAIL_FILE"

    sleep 5
    reboot
fi


# --- только интерфейс ---
if [ "$MODE" = "modem" ]; then
    log "Restarting LTE (ifdown/ifup)"

    ifdown wwan
    sleep 5
    ifup wwan

    WAIT=30
STEP=3
ELAPSED=0

while [ $ELAPSED -lt $WAIT ]; do
    if check_net; then
        log "Recovered after ${ELAPSED}s"

        # считаем что всё починилось
        rm -f "$FAIL_FILE"
        exit 0
    fi

    sleep $STEP
    ELAPSED=$((ELAPSED + STEP))
done

    echo "$NOW" > "$FAIL_FILE"
    exit 0
fi


# --- УМНЫЙ mixed режим ---
if [ "$MODE" = "mixed" ]; then

    STEP=0

    # --- ШАГ 1: ifdown ---
    if [ "$ENABLE_IFDOWN" = "1" ]; then
        STEP=$((STEP + 1))

        if [ "$COUNT" -eq "$STEP" ]; then
            log "Step 1: ifdown/ifup"

            ifdown wwan
            sleep 5
            ifup wwan

            WAIT=30
STEP=3
ELAPSED=0

while [ $ELAPSED -lt $WAIT ]; do
    if check_net; then
        log "Recovered after ${ELAPSED}s"

        # считаем что всё починилось
        rm -f "$FAIL_FILE"
        exit 0
    fi

    sleep $STEP
    ELAPSED=$((ELAPSED + STEP))
done

            echo "$NOW" > "$FAIL_FILE"
            exit 0
        fi
    fi

    # --- ШАГ 2: uqmi ---
    if [ "$ENABLE_UQMI_RESET" = "1" ]; then
        STEP=$((STEP + 1))

        if [ "$COUNT" -eq "$STEP" ]; then
            log "Step 2: uqmi reset"

            uqmi -d /dev/cdc-wdm0 --set-device-operating-mode reset

            # ждём подъёма модема и проверяем интернет
            WAIT=70
            STEP_WAIT=5
            ELAPSED=0

            log "Waiting for modem after uqmi..."

            while [ $ELAPSED -lt $WAIT ]; do
                if check_net; then
                    log "Recovered after uqmi in ${ELAPSED}s"

                    # считаем что всё починилось
                    rm -f "$FAIL_FILE" "$COUNT_FILE"
                    exit 0
                fi

                sleep $STEP_WAIT
                ELAPSED=$((ELAPSED + STEP_WAIT))
            done

            log "uqmi did not recover connection"

            echo "$NOW" > "$FAIL_FILE"
            exit 0
        fi
    fi

    # --- ПОСЛЕДНИЙ ШАГ → reboot ---
    log "Step final: reboot"

    rm -f "$FAIL_FILE"

    sleep 5
    reboot
fi