#!/bin/sh

BOT_TOKEN="..."
CHAT_ID="..."

ROUTER_ID="$(cat /etc/myvpn-id 2>/dev/null || echo OpenWrt)"

send_tg() {
    wget -qO- \
      --post-data="chat_id=${CHAT_ID}&text=$1" \
      "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      >/dev/null 2>&1
}

logread -f | while read -r line
do
    case "$line" in

        *"passwall-failover: MEMORY: LOW RAM detected"*)
            send_tg "[$ROUTER_ID] ⚠️ ${line#*passwall-failover: }"
        ;;

        *"passwall-failover: MEMORY: controlled restart passwall2"*)
            send_tg "[$ROUTER_ID] ♻️ PassWall restart (low memory)"
        ;;

        *"passwall-failover: DECISION: switching to BACKUP"*)
            send_tg "[$ROUTER_ID] 🔴 Switching to BACKUP"
        ;;

        *"passwall-failover: DECISION: return to PRIMARY"*)
            send_tg "[$ROUTER_ID] 🟢 Return to PRIMARY"
        ;;

        *"passwall-failover: DECISION: restart passwall after DNS failures"*)
            send_tg "[$ROUTER_ID] 🟠 DNS recovery restart"
        ;;

        *"passwall-failover: ACTION: controlled switch to "*)
            send_tg "[$ROUTER_ID] 🔀 ${line#*passwall-failover: }"
        ;;

        *"passwall-failover: ACTION: controlled restart passwall2"*)
            send_tg "[$ROUTER_ID] ♻️ Controlled restart"
        ;;

        *"passwall-failover: ERROR:"*)
            send_tg "[$ROUTER_ID] ❌ ${line#*passwall-failover: }"
        ;;

    esac
done
