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
# Особенности логики:
#
#  ICMP можно отключать
#  SOCKS проверяет реальную работу VPN
#  SITE проверяет открытие сайтов
#  MEMORY CHECK контролирует low RAM
#  Защита от restart storm
#  FAIL_LIMIT защищает от LTE jitter
#
# 🔥 ВАЖНО:
#
# OK счетчик НЕ сбрасывается
# при кратковременных FAIL.
#
# OK сбрасывается ТОЛЬКО:
#
# - при switch_node()
# - при restart_passwall()
# - при memory recovery
#
# Это намного стабильнее для LTE/VPN.
# =========================================================
#
# 📝 Редактировать:
#   vi /usr/bin/passwall-auto-failover.sh
#
# 🔐 Права:
#   chmod +x /usr/bin/passwall-auto-failover.sh
#
# ⏱ Cron:
#   */2 * * * * /usr/bin/passwall-auto-failover.sh
#
# 📜 Логи:
#   logread | grep passwall-failover
# =========================================================


# =========================================================
# НАСТРОЙКИ
# =========================================================

PRIMARY_NODE_NAME="Shunt"
BACKUP_NODE_NAME="ShuntWhiteList"

LTE_MODE=1

FAIL_LIMIT=3
OK_LIMIT=3

FAIL_FILE="/tmp/passwall_fail.count"
OK_FILE="/tmp/passwall_ok.count"

SITE_FAIL_FILE="/tmp/passwall_site_fail.count"
SITE_FAIL_LIMIT=2


# =========================================================
# ENABLE / DISABLE CHECKS
# =========================================================

# ICMP проверки
ENABLE_ICMP=1

# SOCKS/VPN проверки
ENABLE_SOCKS=1

# Проверка открытия сайтов
ENABLE_SITE=1


# =========================================================
# MEMORY CONTROL
# =========================================================
#
# Полностью отключаемый memory watchdog.
#
# ENABLE_MEMORY_CONTROL=0
#
# Используется MemAvailable из /proc/meminfo
# (самый правильный вариант для OpenWrt)
#
# Recommended:
#
# 64MB RAM  -> 5-8MB
# 128MB RAM -> 8-12MB
# 256MB RAM -> 10-20MB
# =========================================================

ENABLE_MEMORY_CONTROL=1

# Минимум available RAM в MB
MEMORY_MIN_AVAILABLE=15

# cooldown между memory restart
MEMORY_COOLDOWN=300

MEMORY_RESTART_FILE="/tmp/passwall_memory_restart"


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
# SOCKS / VPN CHECK
# =========================================================

check_socks_node() {

    if curl \
        --socks5-hostname 127.0.0.1:$SOCKS_PORT \
        --connect-timeout 2 \
        --max-time 5 \
        https://cp.cloudflare.com \
        >/dev/null 2>&1; then

        logger -t passwall-failover "CHECK: SOCKS node OK"
        return 0
    fi

    logger -t passwall-failover "CHECK: SOCKS node FAIL"
    return 1
}


# =========================================================
# ПРОВЕРКА WAN
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

        if ping -I wan -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
            logger -t passwall-failover "CHECK: ICMP 1.1.1.1 OK"
            return 0
        fi

        if ping -I wan -c 1 -W 2 9.9.9.9 >/dev/null 2>&1; then
            logger -t passwall-failover "CHECK: ICMP 9.9.9.9 OK"
            return 0
        fi

        if ping -I wan -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            logger -t passwall-failover "CHECK: ICMP 8.8.8.8 OK"
            return 0
        fi

        if ping -I wan -c 1 -W 2 208.67.222.222 >/dev/null 2>&1; then
            logger -t passwall-failover "CHECK: ICMP OpenDNS OK"
            return 0
        fi

        logger -t passwall-failover \
            "CHECK: all ICMP checks failed"
    fi

    # =====================================================
    # SOCKS CHECK
    # =====================================================

    if [ "$ENABLE_SOCKS" = "1" ]; then

        logger -t passwall-failover "CHECK: trying SOCKS"

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

    if wget -4 -q -T 3 -O /dev/null http://example.com; then
        logger -t passwall-failover \
            "CHECK: site OK (example)"

        return 0
    fi

    if wget -4 -q -T 3 -O /dev/null \
        http://detectportal.firefox.com/success.txt; then

        logger -t passwall-failover \
            "CHECK: site OK (firefox)"

        return 0
    fi

    if wget -4 -q -T 3 -O /dev/null \
        http://www.msftconnecttest.com/connecttest.txt; then

        logger -t passwall-failover \
            "CHECK: site OK (msft)"

        return 0
    fi

    logger -t passwall-failover "CHECK: site FAIL"

    return 1
}


# =========================================================
# MEMORY CHECK
# =========================================================

check_memory() {

    # =====================================================
    # MODULE DISABLED
    # =====================================================

    [ "$ENABLE_MEMORY_CONTROL" != "1" ] && return 0

    # =====================================================
    # GET AVAILABLE RAM
    # =====================================================
    #
    # Используем MemAvailable из /proc/meminfo
    #
    # Это самый надежный и OpenWrt-safe способ.
    # =====================================================

    AVAILABLE_RAM=$(awk '/MemAvailable/ {
        printf "%.0f\n", $2 / 1024
    }' /proc/meminfo)

    # fallback protection
    [ -z "$AVAILABLE_RAM" ] && AVAILABLE_RAM=0

    logger -t passwall-failover \
        "MEMORY: available=${AVAILABLE_RAM}MB"

    # =====================================================
    # MEMORY OK
    # =====================================================

    if [ "$AVAILABLE_RAM" -ge "$MEMORY_MIN_AVAILABLE" ]; then
        return 0
    fi

    logger -t passwall-failover \
        "MEMORY: LOW RAM detected (${AVAILABLE_RAM}MB)"

    # =====================================================
    # COOLDOWN PROTECTION
    # =====================================================

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

    # =====================================================
    # SOFT RESTART
    # =====================================================

    /etc/init.d/passwall2 stop

    sleep 10

    /etc/init.d/passwall2 start

    # =====================================================
    # RESET COUNTERS
    # =====================================================

    echo 0 > "$FAIL_FILE"
    echo 0 > "$OK_FILE"

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

    ip route flush cache
    echo 1 > /proc/sys/net/ipv4/route/flush

    /etc/init.d/passwall2 stop

    sleep 8

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

    uci set passwall2.@global[0].node="$NODE"
    uci commit passwall2

    ip route flush cache
    echo 1 > /proc/sys/net/ipv4/route/flush

    /etc/init.d/passwall2 stop

    sleep 8

    /etc/init.d/passwall2 start

    CURRENT_NODE="$NODE"
}


CURRENT_NODE="$(uci get passwall2.@global[0].node 2>/dev/null)"


# =========================================================
# ОСНОВНАЯ ЛОГИКА
# =========================================================

# =========================================================
# LOW MEMORY PROTECTION
# =========================================================
#
# Если был memory restart:
# - завершаем текущий цикл
# - избегаем false FAIL / false failover
# =========================================================

if ! check_memory; then
    exit 0
fi

check_internet
RESULT=$?

case "$RESULT" in

    0)

        # SUCCESS COUNTER
        OK=$(($(cat "$OK_FILE" 2>/dev/null || echo 0) + 1))
        echo "$OK" > "$OK_FILE"

        logger -t passwall-failover \
            "STATE: WAN OK ($OK/$OK_LIMIT), node=$CURRENT_NODE"

        # FAIL COUNTER RESET
        echo 0 > "$FAIL_FILE"

        # =================================================
        # SITE CHECK
        # =================================================

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

        # =================================================
        # RETURN TO PRIMARY
        # =================================================

        if [ "$OK" -ge "$OK_LIMIT" ] && \
           [ "$CURRENT_NODE" != "$PRIMARY_NODE" ]; then

            logger -t passwall-failover \
                "DECISION: return to PRIMARY"

            switch_node "$PRIMARY_NODE" "$PRIMARY_NODE_NAME"
        fi
        ;;


    1)

        # FAIL COUNTER
        FAIL=$(($(cat "$FAIL_FILE" 2>/dev/null || echo 0) + 1))

        echo "$FAIL" > "$FAIL_FILE"

        logger -t passwall-failover \
            "STATE: FAIL ($FAIL/$FAIL_LIMIT), node=$CURRENT_NODE"

        # =================================================
        # CHECK SITE ON BACKUP
        # =================================================

        if [ "$CURRENT_NODE" = "$BACKUP_NODE" ]; then

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
                        "DECISION: restart passwall on BACKUP"

                    restart_passwall

                    echo 0 > "$SITE_FAIL_FILE"
                fi

            else
                echo 0 > "$SITE_FAIL_FILE"
            fi
        fi

        # =================================================
        # FAILOVER
        # =================================================

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