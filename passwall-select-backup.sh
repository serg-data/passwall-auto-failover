#!/bin/sh

FAILOVER_SCRIPT="/usr/bin/passwall-auto-failover.sh"

echo "Searching Passwall2 nodes..."
echo

NODES=$(uci show passwall2 | grep ".remarks=")

[ -z "$NODES" ] && {
    echo "No nodes found."
    exit 1
}

echo "Select what to change:"
echo
echo "1) Backup node"
echo "2) Primary node"
echo "3) Both nodes"
echo
echo "Press Enter to exit."
echo

read MODE

[ -z "$MODE" ] && exit 0


print_nodes() {

i=1
echo "$NODES" | while read line
do
    ID=$(echo "$line" | cut -d. -f2)
    REMARK=$(echo "$line" | cut -d= -f2 | tr -d "'")

    echo "$i) $ID  — $REMARK"

    i=$((i+1))
done

}


case "$MODE" in

1)

echo
echo "Select BACKUP node:"
echo

print_nodes

echo
echo "Enter number:"
read NUM

LINE=$(echo "$NODES" | sed -n "${NUM}p")

REMARK=$(echo "$LINE" | cut -d= -f2 | tr -d "'")

sed -i "s/^BACKUP_NODE_NAME=.*/BACKUP_NODE_NAME=\"$REMARK\"/" "$FAILOVER_SCRIPT"

echo
echo "Backup node set to:"
echo "$REMARK"

logger -t passwall-failover "Backup node selected: $REMARK"

;;


2)

echo
echo "Select PRIMARY node:"
echo

print_nodes

echo
echo "Enter number:"
read NUM

LINE=$(echo "$NODES" | sed -n "${NUM}p")

REMARK=$(echo "$LINE" | cut -d= -f2 | tr -d "'")

sed -i "s/^PRIMARY_NODE_NAME=.*/PRIMARY_NODE_NAME=\"$REMARK\"/" "$FAILOVER_SCRIPT"

echo
echo "Primary node set to:"
echo "$REMARK"

logger -t passwall-failover "Primary node selected: $REMARK"

;;


3)

echo
echo "Select PRIMARY node:"
echo

print_nodes

echo
echo "Enter number:"
read NUM

LINE=$(echo "$NODES" | sed -n "${NUM}p")
PRIMARY=$(echo "$LINE" | cut -d= -f2 | tr -d "'")

echo
echo "Select BACKUP node:"
echo

print_nodes

echo
echo "Enter number:"
read NUM

LINE=$(echo "$NODES" | sed -n "${NUM}p")
BACKUP=$(echo "$LINE" | cut -d= -f2 | tr -d "'")

sed -i "s/^PRIMARY_NODE_NAME=.*/PRIMARY_NODE_NAME=\"$PRIMARY\"/" "$FAILOVER_SCRIPT"
sed -i "s/^BACKUP_NODE_NAME=.*/BACKUP_NODE_NAME=\"$BACKUP\"/" "$FAILOVER_SCRIPT"

echo
echo "Primary node:"
echo "$PRIMARY"

echo
echo "Backup node:"
echo "$BACKUP"

logger -t passwall-failover "Primary node selected: $PRIMARY"
logger -t passwall-failover "Backup node selected: $BACKUP"

;;

*)

echo "Invalid selection."

;;

esac
