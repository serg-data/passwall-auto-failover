#!/bin/sh

LOCKDIR="/tmp/passwall-auto-failover.lock"

# =========================================================
# REMOVE STALE LOCK
# =========================================================
#
# Иногда после crash / reboot lock может остаться.
# Удаляем lock старше 10 минут.
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
# Универсальный failover:
#
# - sing-box
# - xray
#
# Поддерживает:
#
# ICMP checks
# SOCKS checks
# SITE checks
# MEMORY watchdog
# LTE blink protection
# restart cooldown
# failover progression
#
# =========================================================


# =========================================================
# НАСТРОЙКИ
# =========================================================

PRIMARY_NODE_NAME="Shunt"
BACKUP_NODE_NAME="ShuntWhiteList"

FAIL_LIMIT=1
OK_LIMIT=3

FAIL_FILE="/tmp/passwall_fail.count"
OK_FILE="/tmp/passwall_ok.count"

SITE_FAIL_FILE="/tmp/passwall_site_fail.count"

# =========================================================
# SITE FAIL LIMIT
# =========================================================
#
# Проверка сайтов может иногда фейлиться:
#
# - LTE reconnect
# - DNS rebuild
# - shunt recovery
# - временные route delay
#
# Поэтому 2 безопаснее чем 1.
# =========================================================

SITE_FAIL_LIMIT=2


# =========================================================
# INTERFACE SETTINGS
# =========================================================
#
# ICMP проверки идут ИМЕННО через этот интерфейс.
#
# Примеры:
#
# wan        -> ethernet WAN
# wwan       -> logical WWAN
# phy5-sta0  -> реальное Wi-Fi client устройство
# usb0       -> USB tether/modem
#
# ВАЖНО:
#
# Для Wi-Fi client лучше использовать
# реальное устройство:
#
# phyX-sta0
#
# потому что wwan иногда не подходит
# для ping -I.
# =========================================================

CHECK_INTERFACE="wan"


# =========================================================
# ENABLE / DISABLE CHECKS
# =========================================================

ENABLE_ICMP=1
ENABLE_SOCKS=1
ENABLE_SITE=1


# =========================================================
# LTE MODE
# =========================================================

LTE_MODE=1


# =========================================================
# MEMORY CONTROL
# =========================================================

ENABLE_MEMORY_CONTROL=1

MEMORY_MIN_AVAILABLE=25
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
# REAL WAN CHECK
# =========================================================
#
# Проверяет:
# жив ли физически WAN/LTE.
#
# ВАЖНО:
#
# НЕ проверяет обычный интернет.
#
# Используется whitelist IP,
# доступный даже во время shutdown.
#
# Это позволяет:
#
# - отличить shutdown от dead WAN
# - не ломать backup whitelist node
# - остановить recovery storm
# - защитить RAM/xray/swap
#
# Можно отключить:
#
# ENABLE_REAL_WAN_CHECK=0
# =========================================================

ENABLE_REAL_WAN_CHECK=1

REAL_WAN_IP="77.88.8.8"

# cooldown при dead WAN
REAL_WAN_FAIL_COOLDOWN=300

REAL_WAN_FAIL_FILE="/tmp/passwall_real_wan_fail"


# =========================================================
# ПОИСК ID НОДЫ ПО НАЗВАНИЮ
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

    logger -t passwall-failover "ERROR: node not found"

    exit 1
fi


# =========================================================
# WAIT PROXY CORE STOP
# =========================================================
#
# Ждём graceful shutdown:
#
# - xray
# - sing-box
#
# БЕЗ force kill.
#
# Это безопаснее для:
#
# - shunt rules
# - nft state
# - routing consistency
# - dns rules
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
        --max-time 10 \
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

    # =====================================================
    # LTE BLINK PROTECTION
    # =====================================================

    if [ "$LTE_MODE" = "1" ]; then

        if ! ip route | grep -q '^default'; then

            logger -t passwall-failover \
                "CHECK: no default route (LTE blink)"

            return 2
        fi
    fi

    # =====================================================
    # ICMP CHECKS
    # =====================================================

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

    # =====================================================
    # SOCKS CHECK
    # =====================================================

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
# SITE CHECK
# =========================================================

check_site() {

    if wget -4 -q -T 5 -O /dev/null \
        http://example.com; then

        logger -t passwall-failover \
            "CHECK: site OK (example)"

        return 0
    fi

    if wget -4 -q -T 5 -O /dev/null \
        http://detectportal.firefox.com/success.txt; then

        logger -t passwall-failover \
            "CHECK: site OK (firefox)"

        return 0
    fi

    if wget -4 -q -T 5 -O /dev/null \
        http://www.msftconnecttest.com/connecttest.txt; then

        logger -t passwall-failover \
            "CHECK: site OK (msft)"

        return 0
    fi

    logger -t passwall-failover \
        "CHECK: site FAIL"

    return 1
}


# =========================================================
# MEMORY CHECK
# =========================================================

check_memory() {

    [ "$ENABLE_MEMORY_CONTROL" != "1" ] && return 0

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
        "MEMORY: restarting passwall2"

    /etc/init.d/passwall2 stop

    wait_core_stop

    /etc/init.d/passwall2 start

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

        return
    fi

    echo "$NOW" > "$RESTART_FILE"

    logger -t passwall-failover \
        "ACTION: restarting passwall2"

    echo 0 > "$OK_FILE"
    echo 0 > "$MEMORY_RECOVERY_COUNT_FILE"

    ip route flush cache
    echo 1 > /proc/sys/net/ipv4/route/flush

    /etc/init.d/passwall2 stop

    wait_core_stop

    /etc/init.d/passwall2 start
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
        "ACTION: switching node to $NODE_NAME ($NODE)"

    echo 0 > "$OK_FILE"
    echo 0 > "$MEMORY_RECOVERY_COUNT_FILE"

    uci set passwall2.@global[0].node="$NODE"
    uci commit passwall2

    ip route flush cache
    echo 1 > /proc/sys/net/ipv4/route/flush

    /etc/init.d/passwall2 stop

    wait_core_stop

    /etc/init.d/passwall2 start

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

check_internet
RESULT=$?

case "$RESULT" in

    0)

        OK=$(($(cat "$OK_FILE" 2>/dev/null || echo 0) + 1))

        echo "$OK" > "$OK_FILE"

        logger -t passwall-failover \
            "STATE: WAN OK ($OK/$OK_LIMIT), node=$CURRENT_NODE"

        echo 0 > "$FAIL_FILE"

        if [ "$ENABLE_SITE" = "1" ]; then
            check_site
            SITE_RESULT=$?
        else
            SITE_RESULT=0
        fi

        if [ "$SITE_RESULT" != "0" ]; then

            SITE_FAIL=$(($(cat "$SITE_FAIL_FILE" \
                2>/dev/null || echo 0) + 1))

            echo "$SITE_FAIL" > "$SITE_FAIL_FILE"

            logger -t passwall-failover \
                "STATE: site FAIL ($SITE_FAIL/$SITE_FAIL_LIMIT)"

            if [ "$SITE_FAIL" -ge "$SITE_FAIL_LIMIT" ]; then

                logger -t passwall-failover \
                    "DECISION: restart passwall after site failures"

                restart_passwall

                echo 0 > "$SITE_FAIL_FILE"
            fi

        else
            echo 0 > "$SITE_FAIL_FILE"
        fi

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

            # =============================================
            # REAL WAN PROTECTION
            # =============================================

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

            if [ "$ENABLE_SITE" = "1" ]; then
                check_site
                SITE_RESULT=$?
            else
                SITE_RESULT=0
            fi

            if [ "$SITE_RESULT" != "0" ]; then

                SITE_FAIL=$(($(cat "$SITE_FAIL_FILE" \
                    2>/dev/null || echo 0) + 1))

                echo "$SITE_FAIL" > "$SITE_FAIL_FILE"

                logger -t passwall-failover \
                    "STATE: site FAIL ($SITE_FAIL/$SITE_FAIL_LIMIT) on BACKUP"

                if [ "$SITE_FAIL" -ge "$SITE_FAIL_LIMIT" ]; then

                    logger -t passwall-failover \
                        "STATE: skipping site recovery on BACKUP"

                    echo 0 > "$SITE_FAIL_FILE"
                fi

            else
                echo 0 > "$SITE_FAIL_FILE"
            fi
        fi

        if [ "$FAIL" -ge "$FAIL_LIMIT" ] && \
           [ "$CURRENT_NODE" != "$BACKUP_NODE" ]; then

            logger -t passwall-failover \
                "DECISION: switch to BACKUP"

            switch_node "$BACKUP_NODE" "$BACKUP_NODE_NAME"
        fi
        ;;


    2)

        logger -t passwall-failover \
            "STATE: LTE blink detected, counters unchanged"
        ;;

esac
