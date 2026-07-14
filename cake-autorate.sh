#!/bin/sh /etc/rc.common

START=99
STOP=10

start() {
    pid=$(ps w | awk '/[c]ake-autorate\.sh/ {print $1; exit}')
    [ -n "$pid" ] && return 0

    logger -t cake-autorate "Waiting for CAKE..."

    i=0
    while [ $i -lt 30 ]; do
        if ip link show ifb-wan >/dev/null 2>&1 &&
           tc qdisc show dev ifb-wan | grep -q "cake" &&
           tc qdisc show dev wan | grep -q "cake"; then
            break
        fi

        sleep 1
        i=$((i+1))
    done

    logger -t cake-autorate "Starting cake-autorate"

    /bin/bash /root/cake-autorate/cake-autorate.sh >/dev/null 2>&1 &
}

stop() {
    pid=$(ps w | awk '/[c]ake-autorate\.sh/ {print $1; exit}')
    [ -n "$pid" ] && kill "$pid"
}
