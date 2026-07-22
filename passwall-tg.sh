#!/bin/sh

BOT_TOKEN="..........."
CHAT_ID="..........."

ROUTER_ID="$(cat /etc/myvpn-id 2>/dev/null || echo OpenWrt)"

STATE_FILE="/tmp/passwall-tg.state"
QUEUE_FILE="/tmp/passwall-tg.queue"
QUEUE_LOCK="/tmp/passwall-tg.queue.lock"
LOCK_FILE="/tmp/passwall-tg.lock"

# Защита от двойного запуска
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    logger -t passwall-tg "already running, exiting"
    exit 0
fi

FLUSH_PID=""

cleanup() {
    trap - TERM INT HUP
    logger -t passwall-tg "shutting down"

    if [ -n "$FLUSH_PID" ]; then
        kill "$FLUSH_PID" 2>/dev/null
        wait "$FLUSH_PID" 2>/dev/null
    fi

    exit 0
}

trap cleanup TERM INT HUP

telegram_ok() {
    nslookup api.telegram.org >/dev/null 2>&1
}

send_raw() {
    curl -s --fail --retry 1 --retry-delay 1 --max-time 5 \
        -d "chat_id=${CHAT_ID}&text=$1" \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        >/dev/null 2>&1
}

queue_lock() {
    exec 201>"$QUEUE_LOCK"
    flock -w 2 201
}

queue_unlock() {
    flock -u 201
}

queue_add() {
    queue_lock || return 1
    echo "$1" >> "$QUEUE_FILE"
    queue_unlock
}

flush_queue() {

    [ ! -f "$QUEUE_FILE" ] && return 0

    queue_lock || return 1

    TMP_FILE="${QUEUE_FILE}.tmp"
    : > "$TMP_FILE"

    while IFS= read -r msg
    do
        [ -z "$msg" ] && continue

        if ! send_raw "$msg"; then
            echo "$msg" >> "$TMP_FILE"
        fi
    done < "$QUEUE_FILE"

    if [ -s "$TMP_FILE" ]; then
        mv "$TMP_FILE" "$QUEUE_FILE"
    else
        rm -f "$QUEUE_FILE" "$TMP_FILE"
    fi

    queue_unlock
}

send_tg() {

    MSG="[$(date '+%H:%M:%S')] $1"

    if telegram_ok; then
        flush_queue

        if ! send_raw "$MSG"; then
            queue_add "$MSG"
        fi
    else
        queue_add "$MSG"
    fi
}

(
    while true
    do
        flush_queue
        sleep 60
    done
) &
FLUSH_PID=$!

while true
do
    logread -f 2>/dev/null | while read -r line
    do
        case "$line" in

            *"passwall-failover: MEMORY: LOW RAM detected"*)
                send_tg "[$ROUTER_ID] ⚠️ Low RAM detected"
            ;;

            *"passwall-failover: MEMORY: controlled restart passwall2"*)
                send_tg "[$ROUTER_ID] ♻️ Memory recovery started"
            ;;

            *"passwall-failover: MEMORY: recovery cycle #"*)
                send_tg "[$ROUTER_ID] ♻️ Memory recovery completed"
            ;;

            *"passwall-failover: DECISION: switching to BACKUP"*)
                echo "BACKUP" > "$STATE_FILE"
            ;;

            *"passwall-failover: DECISION: return to PRIMARY"*)
                echo "PRIMARY" > "$STATE_FILE"
            ;;

            *"passwall-failover: DECISION: restart passwall after DNS failures"*)
                send_tg "[$ROUTER_ID] 🟠 DNS recovery restart"
            ;;

            *"passwall-failover: ACTION: node committed to UCI"*)

                MODE="$(cat "$STATE_FILE" 2>/dev/null)"

                case "$MODE" in

                    BACKUP)
                        send_tg "[$ROUTER_ID] 🔴 Backup node activated"
                    ;;

                    PRIMARY)
                        send_tg "[$ROUTER_ID] 🟢 Primary node restored"
                    ;;

                    *)
                        send_tg "[$ROUTER_ID] ✅ Node switch completed"
                    ;;

                esac

                rm -f "$STATE_FILE"
            ;;

            *"passwall-failover: ACTION: controlled restart passwall2"*)
                send_tg "[$ROUTER_ID] 🔄 PassWall restart started"
            ;;

            *"passwall-failover: ERROR:"*)
                send_tg "[$ROUTER_ID] ❌ ${line#*passwall-failover: }"
            ;;

        esac
    done

    logger -t passwall-tg "logread exited, restarting in 5s"
    sleep 5
done
