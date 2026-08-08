#!/bin/sh

CONFIG="/etc/cake-watchdog.conf"
AUTORATE_CFG="/root/cake-autorate/config.primary.sh"

PIDFILE="/var/run/cake-watchdog.pid"
LOGFILE="/var/log/cake-watchdog.log"
STATSFILE="/tmp/cake-watchdog.stats"

CHECK_INTERVAL=30
FREEZE_TIMEOUT=900
MIN_TRAFFIC_BYTES=1048576
STARTUP_GRACE=120
MAX_RESTARTS_PER_HOUR=5
USE_LOGGER=1

[ -f "$CONFIG" ] && . "$CONFIG"

[ -f "$AUTORATE_CFG" ] || {
    echo "Cannot find $AUTORATE_CFG"
    exit 1
}

. "$AUTORATE_CFG"

BASE_DL="$base_dl_shaper_rate_kbps"
BASE_UL="$base_ul_shaper_rate_kbps"

cleanup() {
    rm -f "$PIDFILE"
    exit
}

trap cleanup INT TERM EXIT

if [ -f "$PIDFILE" ]; then
    OLDPID=$(cat "$PIDFILE")
    if kill -0 "$OLDPID" 2>/dev/null; then
        echo "Already running."
        exit 1
    fi
fi

echo $$ > "$PIDFILE"

log() {
    MSG="$*"
    echo "$(date '+%F %T') $MSG" >> "$LOGFILE"

    if [ "$USE_LOGGER" = "1" ]; then
        logger -t cake-watchdog "$MSG"
    fi
}

get_dl_bw() {
    tc qdisc show dev ifb-wan \
    | awk '/bandwidth/{
        for(i=1;i<=NF;i++)
            if($i=="bandwidth"){
                gsub("Mbit","",$(i+1))
                print $(i+1)*1000
            }
    }'
}

get_ul_bw() {
    tc qdisc show dev wan \
    | awk '/bandwidth/{
        for(i=1;i<=NF;i++)
            if($i=="bandwidth"){
                gsub("Mbit","",$(i+1))
                print $(i+1)*1000
            }
    }'
}

get_rx() {
    cat /sys/class/net/wan/statistics/rx_bytes
}

get_tx() {
    cat /sys/class/net/wan/statistics/tx_bytes
}

traffic_present() {

    RX2=$(get_rx)
    TX2=$(get_tx)

    DELTA=$((RX2-RX1+TX2-TX1))

    RX1=$RX2
    TX1=$TX2

    [ "$DELTA" -ge "$MIN_TRAFFIC_BYTES" ]
}

restart_autorate() {

    log "Restarting cake-autorate"

    /etc/init.d/cake-autorate restart

    sleep 10

    ps | grep '[c]ake-autorate.sh' >/dev/null || {
        log "Restart failed"
        return 1
    }

    RESTARTS=$((RESTARTS+1))
    LAST_RESTART=$(date +%s)

    echo "RESTARTS=$RESTARTS" > "$STATSFILE"
    echo "LAST_RESTART=$LAST_RESTART" >> "$STATSFILE"

    log "Restart successful"

    return 0
}
RX1=$(get_rx)
TX1=$(get_tx)

LAST_DL=$(get_dl_bw)
LAST_UL=$(get_ul_bw)

FREEZE_TIMER=0

RESTARTS=0
HOUR_START=$(date +%s)

log "Started. Base DL=${BASE_DL}kbit Base UL=${BASE_UL}kbit"

sleep "$STARTUP_GRACE"

while true
do

    sleep "$CHECK_INTERVAL"

    NOW=$(date +%s)

    if [ $((NOW-HOUR_START)) -ge 3600 ]; then
        RESTARTS=0
        HOUR_START=$NOW
    fi

    if ! traffic_present; then
        FREEZE_TIMER=0
        LAST_DL=$(get_dl_bw)
        LAST_UL=$(get_ul_bw)
        continue
    fi

    CUR_DL=$(get_dl_bw)
    CUR_UL=$(get_ul_bw)

    if [ "$CUR_DL" != "$LAST_DL" ] || [ "$CUR_UL" != "$LAST_UL" ]; then

        LAST_DL=$CUR_DL
        LAST_UL=$CUR_UL
        FREEZE_TIMER=0

        continue
    fi

    if [ "$CUR_DL" = "$BASE_DL" ] && [ "$CUR_UL" = "$BASE_UL" ]; then
        FREEZE_TIMER=0
        continue
    fi

    FREEZE_TIMER=$((FREEZE_TIMER+CHECK_INTERVAL))

    if [ "$FREEZE_TIMER" -lt "$FREEZE_TIMEOUT" ]; then
        continue
    fi

    log "Freeze suspected DL=${CUR_DL} UL=${CUR_UL}"

    sleep 5

    if ! traffic_present; then
        FREEZE_TIMER=0
        continue
    fi

    VERIFY_DL=$(get_dl_bw)
    VERIFY_UL=$(get_ul_bw)

    if [ "$VERIFY_DL" != "$CUR_DL" ] || [ "$VERIFY_UL" != "$CUR_UL" ]; then
        FREEZE_TIMER=0
        LAST_DL=$VERIFY_DL
        LAST_UL=$VERIFY_UL
        continue
    fi

    if [ "$VERIFY_DL" = "$BASE_DL" ] && [ "$VERIFY_UL" = "$BASE_UL" ]; then
        FREEZE_TIMER=0
        continue
    fi

    if [ "$RESTARTS" -ge "$MAX_RESTARTS_PER_HOUR" ]; then
        log "Restart limit reached"
        FREEZE_TIMER=0
        continue
    fi

    restart_autorate

    sleep 10

    FREEZE_TIMER=0

    LAST_DL=$(get_dl_bw)
    LAST_UL=$(get_ul_bw)

done
