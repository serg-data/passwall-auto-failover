#!/bin/sh

BOT_TOKEN="8472993466:AAEelwencKR-V582TdqIZqVDKH54nJFtsTw"
CHAT_ID="880795265"

ROUTER_ID="$(cat /etc/myvpn-id 2>/dev/null || echo OpenWrt)"

STATE_FILE="/tmp/passwall-tg.state"
QUEUE_FILE="/tmp/passwall-tg.queue"

telegram_ok() {
    nslookup api.telegram.org >/dev/null 2>&1
}

send_raw() {
    wget -qO- \
        --post-data="chat_id=${CHAT_ID}&text=$1" \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        >/dev/null 2>&1
}

flush_queue() {

    [ ! -f "$QUEUE_FILE" ] && return 0

    telegram_ok || return 1

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
}

send_tg() {

    MSG="$1"

    telegram_ok || {
        echo "$MSG" >> "$QUEUE_FILE"
        return
    }

    flush_queue

    if ! send_raw "$MSG"; then
        echo "$MSG" >> "$QUEUE_FILE"
    fi
}

logread -f | while read -r line
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
