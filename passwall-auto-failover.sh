#!/bin/sh

LOCKDIR="/tmp/passwall-auto-failover.lock"

# =========================================================
# REMOVE STALE LOCK
# =========================================================
#
# Иногда после crash / reboot lock может остаться.
# Удаляем lock старше 10 минут.
#
# =========================================================

if [ -d "$LOCKDIR" ]; then
    if [ "$(find "$LOCKDIR" -mmin +10 2>/dev/null)" ]; then
        rmdir "$LOCKDIR" 2>/dev/null
    fi
fi

if ! mkdir "$LOCKDIR" 2>/dev/null; then
    logger -t passwall-failover "already running"
    exit 0
fi

cleanup() {
    rmdir "$LOCKDIR"
}

trap cleanup EXIT INT TERM

# =========================================================
# Passwall2 Auto Failover (OpenWrt)
#
# Скрипт выбора резервной ноды
#   passwall-select-backup
#
# 📝 Создать / отредактировать скрипт:
#   vi /usr/bin/passwall-auto-failover.sh
#
# 🔍 Проверить текущее состояние:
#   uci get passwall2.@global[0].node
#
# 📋 Посмотреть все серверы (ноды):
#   uci show passwall2 | grep ".remarks="
#
# 🔎 Показать название текущего сервера:
#   uci show passwall2 | grep "$(uci get passwall2.@global[0].node).remarks"
#
# 🔐 Дать права на выполнение:
#   chmod +x /usr/bin/passwall-auto-failover.sh
#
# ⏱ Добавить в автозапуск (cron):
#   crontab -e
#   * * * * * /usr/bin/passwall-auto-failover.sh
#   /etc/init.d/cron restart
#
# 📜 Посмотреть логи:
#   logread | grep passwall-failover

# =========================================================
# SETTINGS
# =========================================================

PRIMARY_NODE_NAME="Shunt"
BACKUP_NODE_NAME="ShuntWhiteList"

FAIL_LIMIT=1
OK_LIMIT=3

DNS_FAIL_LIMIT=2

CHECK_INTERFACE="wan"

ENABLE_ICMP=1
ENABLE_SOCKS=1
ENABLE_DNS_CHECK=1

LTE_MODE=1


# =========================================================
# MEMORY CONTROL
# =========================================================

ENABLE_MEMORY_CONTROL=1

MEMORY_MIN_AVAILABLE=15
MEMORY_COOLDOWN=300

MEMORY_RESTART_FILE="/tmp/passwall_memory_restart"

MEMORY_RECOVERY_COUNT_FILE="/tmp/passwall_memory_recovery.count"

UPTIME_CYCLE_FILE="/tmp/passwall_uptime_cycles"


# =========================================================
# SOCKS CHECK
# =========================================================

SOCKS_PORT="1082"


# =========================================================
# RESTART COOLDOWN
# =========================================================

RESTART_COOLDOWN=120

RESTART_FILE="/tmp/passwall_last_restart"


# =========================================================
# START WARMUP
# =========================================================
#
# После старта:
#
# - observatory rebuild
# - xHTTP reconnect
# - mux rebuild
# - DNS reconnect
#
# Во время warmup:
#
# - проверки работают
# - но restart/switch запрещены
#
# =========================================================

START_WARMUP=20

START_WARMUP_FILE="/tmp/passwall_start_warmup"


# =========================================================
# STORM COOLDOWN
# =========================================================
#
# После stop:
#
# - xHTTP ещё закрывается
# - TCP TIME_WAIT ещё жив
# - conntrack ещё чистится
# - zram ещё разгребает память
#
# =========================================================

TRANSITION_STOP_DELAY=5


# =========================================================
# REAL WAN CHECK
# =========================================================

ENABLE_REAL_WAN_CHECK=1

REAL_WAN_IP="77.88.8.8"

REAL_WAN_FAIL_COOLDOWN=1200

REAL_WAN_FAIL_FILE="/tmp/passwall_real_wan_fail"


# =========================================================
# COUNTERS
# =========================================================

FAIL_FILE="/tmp/passwall_fail.count"
OK_FILE="/tmp/passwall_ok.count"

DNS_FAIL_FILE="/tmp/passwall_dns_fail.count"


# =========================================================
# FIND NODE ID
# =========================================================

get_node_id_by_name() {

    NAME="$1"

    uci show passwall2 | \
    grep -F ".remarks='$NAME'" | \
    head -n1 | \
    cut -d. -f2
}

PRIMARY_NODE=$(get_node_id_by_name "$PRIMARY_NODE_NAME")
BACKUP_NODE=$(get_node_id_by_name "$BACKUP_NODE_NAME")

if [ -z "$PRIMARY_NODE" ] || [ -z "$BACKUP_NODE" ]; then

    logger -t passwall-failover \
        "ERROR: node not found"

    exit 1
fi


# =========================================================
# WAIT CORE STOP
# =========================================================

wait_core_stop() {

    for i in $(seq 1 30); do

        XRAY_RUNNING=0
        SING_RUNNING=0

        pidof xray >/dev/null 2>&1 && XRAY_RUNNING=1
        pidof sing-box >/dev/null 2>&1 && SING_RUNNING=1

        if [ "$XRAY_RUNNING" = "0" ] && \
           [ "$SING_RUNNING" = "0" ]; then

            logger -t passwall-failover \
                "WAIT: proxy core fully stopped"

            break
        fi

        logger -t passwall-failover \
            "WAIT: proxy core still stopping..."

        sleep 1
    done

    sleep 5
}


# =========================================================
# WARMUP HELPERS
# =========================================================

mark_warmup() {

    date +%s > "$START_WARMUP_FILE"
}

warmup_active() {

    NOW=$(date +%s)

    STARTED=$(cat "$START_WARMUP_FILE" \
        2>/dev/null || echo 0)

    [ $((NOW - STARTED)) -lt "$START_WARMUP" ]
}

wait_warmup_finish() {

    while warmup_active; do

        logger -t passwall-failover \
            "WAIT: warmup active"

        sleep 1
    done
}


# =========================================================
# REAL WAN CHECK
# =========================================================

check_real_wan() {

    [ "$ENABLE_REAL_WAN_CHECK" != "1" ] && return 0

    if ping -I "$CHECK_INTERFACE" \
        -c 1 -W 3 "$REAL_WAN_IP" \
        >/dev/null 2>&1; then

        logger -t passwall-failover \
            "CHECK: real WAN OK"

        return 0
    fi

    logger -t passwall-failover \
        "CHECK: real WAN FAIL"

    return 1
}


# =========================================================
# SOCKS CHECK
# =========================================================

check_socks_node() {

    if curl \
        --ipv4 \
        --socks5-hostname 127.0.0.1:$SOCKS_PORT \
        --connect-timeout 4 \
        --max-time 6 \
        --no-keepalive \
        http://cp.cloudflare.com \
        >/dev/null 2>&1; then

        logger -t passwall-failover \
            "CHECK: SOCKS node OK"

        return 0
    fi

    logger -t passwall-failover \
        "CHECK: SOCKS node FAIL"

    return 1
}


# =========================================================
# INTERNET CHECK
# =========================================================

check_internet() {

    if [ "$LTE_MODE" = "1" ]; then

        if ! ip route | grep -q '^default'; then

            logger -t passwall-failover \
                "CHECK: no default route (LTE blink)"

            return 2
        fi
    fi

    if [ "$ENABLE_ICMP" = "1" ]; then

        if ping -I "$CHECK_INTERFACE" \
            -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then

            logger -t passwall-failover \
                "CHECK: ICMP 1.1.1.1 OK"

            return 0
        fi

        if ping -I "$CHECK_INTERFACE" \
            -c 1 -W 2 9.9.9.9 >/dev/null 2>&1; then

            logger -t passwall-failover \
                "CHECK: ICMP 9.9.9.9 OK"

            return 0
        fi

        if ping -I "$CHECK_INTERFACE" \
            -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then

            logger -t passwall-failover \
                "CHECK: ICMP 8.8.8.8 OK"

            return 0
        fi

        if ping -I "$CHECK_INTERFACE" \
            -c 1 -W 2 208.67.222.222 >/dev/null 2>&1; then

            logger -t passwall-failover \
                "CHECK: ICMP OpenDNS OK"

            return 0
        fi

        logger -t passwall-failover \
            "CHECK: all ICMP checks failed"
    fi

    if [ "$ENABLE_SOCKS" = "1" ]; then

        logger -t passwall-failover \
            "CHECK: trying SOCKS"

        if check_socks_node; then

            logger -t passwall-failover \
                "CHECK: SOCKS fallback OK"

            return 0
        fi
    fi

    logger -t passwall-failover \
        "CHECK: FAIL (all enabled checks failed)"

    return 1
}


# =========================================================
# DNS CHECK
# =========================================================

check_dns() {

    if nslookup example.com 1.1.1.1 \
        >/dev/null 2>&1; then

        logger -t passwall-failover \
            "CHECK: DNS OK (1.1.1.1)"

        return 0
    fi

    if nslookup cloudflare.com 8.8.8.8 \
        >/dev/null 2>&1; then

        logger -t passwall-failover \
            "CHECK: DNS OK (8.8.8.8)"

        return 0
    fi

    if nslookup microsoft.com 9.9.9.9 \
        >/dev/null 2>&1; then

        logger -t passwall-failover \
            "CHECK: DNS OK (9.9.9.9)"

        return 0
    fi

    logger -t passwall-failover \
        "CHECK: DNS FAIL"

    return 1
}


# =========================================================
# MEMORY CHECK
# =========================================================

check_memory() {

    [ "$ENABLE_MEMORY_CONTROL" != "1" ] && return 0

    if warmup_active; then

        logger -t passwall-failover \
            "MEMORY: warmup active, skipping recovery"

        return 0
    fi

    AVAILABLE_RAM=$(awk '/MemAvailable/ {
        printf "%.0f\n", $2 / 1024
    }' /proc/meminfo)

    [ -z "$AVAILABLE_RAM" ] && AVAILABLE_RAM=0

    logger -t passwall-failover \
        "MEMORY: available=${AVAILABLE_RAM}MB"

    if [ "$AVAILABLE_RAM" -ge "$MEMORY_MIN_AVAILABLE" ]; then
        return 0
    fi

    logger -t passwall-failover \
        "MEMORY: LOW RAM detected (${AVAILABLE_RAM}MB)"

    NOW=$(date +%s)
    LAST=$(cat "$MEMORY_RESTART_FILE" 2>/dev/null || echo 0)

    if [ $((NOW - LAST)) -lt "$MEMORY_COOLDOWN" ]; then

        logger -t passwall-failover \
            "MEMORY: cooldown active"

        return 1
    fi

    echo "$NOW" > "$MEMORY_RESTART_FILE"

    logger -t passwall-failover \
        "MEMORY: controlled restart passwall2"

    /etc/init.d/passwall2 stop

    wait_core_stop

    logger -t passwall-failover \
        "MEMORY: reconnect storm cooldown"

    sleep "$TRANSITION_STOP_DELAY"

    /etc/init.d/passwall2 start

    mark_warmup

    echo 0 > "$UPTIME_CYCLE_FILE"

    RECOVERY_COUNT=$(($(cat \
        "$MEMORY_RECOVERY_COUNT_FILE" \
        2>/dev/null || echo 0) + 1))

    echo "$RECOVERY_COUNT" > \
        "$MEMORY_RECOVERY_COUNT_FILE"

    logger -t passwall-failover \
        "MEMORY: recovery cycle #$RECOVERY_COUNT"

    return 1
}


# =========================================================
# RESTART PASSWALL
# =========================================================

restart_passwall() {

    NOW=$(date +%s)
    LAST=$(cat "$RESTART_FILE" 2>/dev/null || echo 0)

    if [ $((NOW - LAST)) -lt "$RESTART_COOLDOWN" ]; then

        logger -t passwall-failover \
            "ACTION: restart cooldown active"

        return 1
    fi

    echo "$NOW" > "$RESTART_FILE"

    logger -t passwall-failover \
        "ACTION: controlled restart passwall2"

    echo 0 > "$OK_FILE"
    echo 0 > "$FAIL_FILE"

    ip route flush cache
    echo 1 > /proc/sys/net/ipv4/route/flush

    /etc/init.d/passwall2 stop

    wait_core_stop

    logger -t passwall-failover \
        "ACTION: reconnect storm cooldown"

    sleep "$TRANSITION_STOP_DELAY"

    /etc/init.d/passwall2 start

    mark_warmup

    return 0
}


# =========================================================
# SWITCH NODE
# =========================================================

switch_node() {

    NODE="$1"
    NODE_NAME="$2"

    NOW=$(date +%s)
    LAST=$(cat "$RESTART_FILE" 2>/dev/null || echo 0)

    if [ $((NOW - LAST)) -lt "$RESTART_COOLDOWN" ]; then

        logger -t passwall-failover \
            "ACTION: switch cooldown active"

        return
    fi

    echo "$NOW" > "$RESTART_FILE"

    logger -t passwall-failover \
        "ACTION: controlled switch to $NODE_NAME ($NODE)"

    logger -t passwall-failover \
        "ACTION: stopping passwall before node switch"

    echo 0 > "$OK_FILE"
    echo 0 > "$FAIL_FILE"

    /etc/init.d/passwall2 stop

    wait_core_stop

    logger -t passwall-failover \
        "ACTION: reconnect storm cooldown"

    sleep "$TRANSITION_STOP_DELAY"

    uci set passwall2.@global[0].node="$NODE"
    uci commit passwall2

    logger -t passwall-failover \
         "ACTION: node committed to UCI"

    ip route flush cache
    echo 1 > /proc/sys/net/ipv4/route/flush

    /etc/init.d/passwall2 start

    mark_warmup

    CURRENT_NODE="$NODE"
}


CURRENT_NODE="$(uci get passwall2.@global[0].node 2>/dev/null)"


# =========================================================
# MAIN LOGIC
# =========================================================

if ! check_memory; then
    exit 0
fi

UPTIME_CYCLE=$(($(cat "$UPTIME_CYCLE_FILE" \
    2>/dev/null || echo 0) + 1))

echo "$UPTIME_CYCLE" > "$UPTIME_CYCLE_FILE"

logger -t passwall-failover \
    "STATE: uptime cycle #$UPTIME_CYCLE"


# =========================================================
# WARMUP MODE
# =========================================================

if warmup_active; then

    logger -t passwall-failover \
        "STATE: warmup active"

    check_internet

    exit 0
fi


check_internet
RESULT=$?

# =========================================================
# UNIVERSAL DNS CHECK
# =========================================================

if [ "$ENABLE_DNS_CHECK" = "1" ]; then

    # Если PRIMARY уже не работает,
    # DNS recovery пропускаем.
    # Приоритет — быстрый переход на BACKUP.

    if [ "$RESULT" = "1" ] && \
       [ "$CURRENT_NODE" != "$BACKUP_NODE" ]; then

        logger -t passwall-failover \
            "DNS: skipped due to PRIMARY fail"

        DNS_RESULT=0

    else

        check_dns
        DNS_RESULT=$?

    fi

else

    DNS_RESULT=0
fi


if [ "$DNS_RESULT" != "0" ]; then

    DNS_FAIL=$(($(cat "$DNS_FAIL_FILE" \
        2>/dev/null || echo 0) + 1))

    echo "$DNS_FAIL" > "$DNS_FAIL_FILE"

    logger -t passwall-failover \
        "STATE: DNS FAIL ($DNS_FAIL/$DNS_FAIL_LIMIT)"

    if [ "$DNS_FAIL" -ge "$DNS_FAIL_LIMIT" ]; then

        logger -t passwall-failover \
            "DECISION: restart passwall after DNS failures"

        restart_passwall

        echo 0 > "$DNS_FAIL_FILE"
    fi

else

    echo 0 > "$DNS_FAIL_FILE"
fi


case "$RESULT" in

    0)

        OK=$(($(cat "$OK_FILE" 2>/dev/null || echo 0) + 1))

        echo "$OK" > "$OK_FILE"

        logger -t passwall-failover \
            "STATE: WAN OK ($OK/$OK_LIMIT), node=$CURRENT_NODE"

        echo 0 > "$FAIL_FILE"


        if [ "$OK" -ge "$OK_LIMIT" ] && \
           [ "$CURRENT_NODE" != "$PRIMARY_NODE" ]; then

            logger -t passwall-failover \
                "DECISION: return to PRIMARY"

            switch_node "$PRIMARY_NODE" "$PRIMARY_NODE_NAME"
        fi
        ;;


    1)

        FAIL=$(($(cat "$FAIL_FILE" 2>/dev/null || echo 0) + 1))

        echo "$FAIL" > "$FAIL_FILE"

        logger -t passwall-failover \
            "STATE: FAIL ($FAIL/$FAIL_LIMIT), node=$CURRENT_NODE"

        if [ "$CURRENT_NODE" = "$BACKUP_NODE" ]; then

            if ! check_real_wan; then

                NOW=$(date +%s)
                LAST=$(cat "$REAL_WAN_FAIL_FILE" \
                    2>/dev/null || echo 0)

                if [ $((NOW - LAST)) -lt \
                    "$REAL_WAN_FAIL_COOLDOWN" ]; then

                    logger -t passwall-failover \
                        "STATE: WAN cooldown active"

                    exit 0
                fi

                echo "$NOW" > "$REAL_WAN_FAIL_FILE"

                logger -t passwall-failover \
                    "STATE: real WAN dead, skipping recovery"

                exit 0
            fi
        fi

        if [ "$FAIL" -ge "$FAIL_LIMIT" ] && \
           [ "$CURRENT_NODE" != "$BACKUP_NODE" ]; then

                logger -t passwall-failover \
                        "DECISION: switching to BACKUP"

                switch_node "$BACKUP_NODE" "$BACKUP_NODE_NAME"
        fi
        ;;


    2)

        logger -t passwall-failover \
            "STATE: LTE blink detected, counters unchanged"
        ;;

esac
