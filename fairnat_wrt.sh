#!/bin/sh

#
# Simplified version of the FairNAT script for OpenWRT.
# Install qos-scripts (this will take care of the dependencies),
# but make it execute this script instead - after you customized
# it to your needs of course.
#
# Author:   Andreas Klauer (Andreas.Klauer@metamorpher.de)
# Version:  0.2 (2009-07-21)
# URL:      http://www.metamorpher.de/fairnat
# License:  GPL
#

# ---- Variables: ----

DEBUG=1
RATE_UP=600
RATE_DOWN=14000
RATE_SUB_PERCENT=10
RATE_LOCAL_PERCENT=1
RATE_TO_QUANTUM=20
OVERHEAD=64
MPU=128

# ---- Helper functions: ----

rate()
{
    RATE=0
    R_RATE=$1
    R_NUMBER=`echo "$R_RATE" | sed -e "s/[^0-9]//g"`
    R_UNIT=`echo "$R_RATE" | sed -e "s/[0-9]//g"`

    if [ "$R_UNIT" == "" ];
    then
        R_UNIT="kbit"
    fi

    # Let's see which unit we have...
    if [ "$R_UNIT" == "kbps" ]
    then
        R_RATE=$(($R_NUMBER * 1024))
    elif [ "$R_UNIT" == "mbps" ]
    then
        R_RATE=$(($R_NUMBER * 1024 * 1024))
    elif [ "$R_UNIT" == "mbit" ]
    then
        R_RATE=$(($R_NUMBER * 1024 * 1024 / 8))
    elif [ "$R_UNIT" == "kbit" ]
    then
        R_RATE=$(($R_NUMBER * 1024 / 8))
    elif [ "$R_UNIT" == "bps" ]
    then
        R_RATE=$R_NUMBER
    else
        echo "Unknown unit '$R_UNIT'. I only know mbps, mbit, kbit, bps."
    fi

    RATE="$R_RATE"
}

load_modules()
{
    insmod imq numdevs=1 >&- 2>&-
    insmod cls_fw >&- 2>&-
    insmod sch_hfsc >&- 2>&-
    insmod sch_sfq >&- 2>&-
    insmod sch_red >&- 2>&-
    insmod sch_htb >&- 2>&-
    insmod sch_prio >&- 2>&-
    insmod ipt_multiport >&- 2>&-
    insmod ipt_CONNMARK >&- 2>&-
    insmod ipt_length >&- 2>&-
    insmod ipt_IMQ >&- 2>&-
}

reset()
{
    ifconfig ppp0 up txqueuelen 5 >&- 2>&-
    ifconfig imq0 up txqueuelen 5 >&- 2>&-
    tc qdisc del dev ppp0 root >&- 2>&-
    tc qdisc del dev imq0 root >&- 2>&-
    iptables -t mangle -F
    iptables -t mangle -X
    iptables -t mangle -N FairNAT >&- 2>&-
    iptables -t mangle -N FairNAT_connmark >&- 2>&-
    iptables -t mangle -N FairNAT_tos >&- 2>&-
    iptables -t mangle -N FairNAT_tos_ack >&- 2>&-
    iptables -t mangle -N FairNAT_tos_chk >&- 2>&-

    # For acquiring DSL data from SpeedTouch modem that is connected to WAN:
    # ifconfig eth0.1 192.168.1.42
}

tc_class_add_htb()
{
    t_parent=$1
    t_classid=$2
    t_rate=$3
    t_ceil=$4

    t_quantum=$(($t_rate/$RATE_TO_QUANTUM))

    if [ $t_quantum -lt 1500 ];
    then
        if [ "$DEBUG" == "1" ]
        then
            echo $DEVICE $t_classid quantum $t_quantum small: increasing to 1500
        fi

        t_quantum=1500
    fi

    if [ $t_quantum -gt 60000 ];
    then
        if [ "$DEBUG" == "1" ]
        then
            echo $DEVICE $t_classid quantum $t_quantum big: reducing to 60000
        fi

        t_quantum=60000
    fi

    if [ "$DEBUG" == "1" ]
    then
        echo tc class add dev $DEVICE parent $t_parent classid $t_classid htb rate "$t_rate"bps ceil "$t_ceil"bps quantum "$t_quantum" overhead $OVERHEAD mpu $MPU
    fi

    tc class add dev $DEVICE parent $t_parent classid $t_classid htb rate "$t_rate"bps ceil "$t_ceil"bps quantum "$t_quantum" overhead $OVERHEAD mpu $MPU
}

# ---- Generic: ----

mangle()
{
    # -- Correcting TOS for known services: --
    # (This is useful only if you prioritize packets by TOS later)
    iptables -t mangle -A FairNAT_tos -p icmp -j TOS --set-tos Minimize-Delay
    iptables -t mangle -A FairNAT_tos -p tcp --sport 23 -j TOS --set-tos Minimize-Delay
    iptables -t mangle -A FairNAT_tos -p tcp --sport 22 -j TOS --set-tos Minimize-Delay
    iptables -t mangle -A FairNAT_tos -p tcp --sport 21 -j TOS --set-tos Minimize-Delay
    iptables -t mangle -A FairNAT_tos -p tcp --sport 20 -j TOS --set-tos Maximize-Throughput
    iptables -t mangle -A FairNAT_tos -p tcp --dport 23 -j TOS --set-tos Minimize-Delay
    iptables -t mangle -A FairNAT_tos -p tcp --dport 22 -j TOS --set-tos Minimize-Delay
    iptables -t mangle -A FairNAT_tos -p tcp --dport 21 -j TOS --set-tos Minimize-Delay
    iptables -t mangle -A FairNAT_tos -p tcp --dport 20 -j TOS --set-tos Maximize-Throughput

    # Correcting TOS for large packets with Minimize-Delay-TOS
    iptables -t mangle -A FairNAT_tos_chk -p tcp -m length --length 0:512  -j RETURN
    iptables -t mangle -A FairNAT_tos_chk -p udp -m length --length 0:1024 -j RETURN
    iptables -t mangle -A FairNAT_tos_chk -j TOS --set-tos Maximize-Throughput

    iptables -t mangle -A FairNAT_tos -m tos --tos Minimize-Delay -j FairNAT_tos_chk

    # Modifying TOS for TCP control packets: (from www.docum.org / Stef Coene)
    iptables -t mangle -A FairNAT_tos_ack -m tos --tos ! Normal-Service -j RETURN
    iptables -t mangle -A FairNAT_tos_ack -p tcp -m length --length 0:256 -j TOS --set-tos Minimize-Delay
    iptables -t mangle -A FairNAT_tos_ack -p tcp -m length --length 256: -j TOS --set-tos Maximize-Throughput

    iptables -t mangle -A FairNAT_tos -p tcp -m tcp --tcp-flags SYN,RST,ACK ACK -j FairNAT_tos_ack

    # Calling TOS chain from PREROUTING chain
    iptables -t mangle -A PREROUTING -j FairNAT_tos

    # -- Marking packets: --
    iptables -t mangle -A FairNAT -j CONNMARK --restore-mark
    iptables -t mangle -A FairNAT -m mark ! --mark 0 -j RETURN
    iptables -t mangle -A FairNAT -j FairNAT_connmark
    iptables -t mangle -A FairNAT -j CONNMARK --save-mark

    # Linking FairNAT chains with standard chains:
    iptables -t mangle -A FORWARD -m mark --mark 0 -o ppp0 -j FairNAT
    iptables -t mangle -A FORWARD -m mark --mark 0 -i ppp0 -j FairNAT
    iptables -t mangle -A POSTROUTING -m mark --mark 0 -o ppp0 -j FairNAT
    iptables -t mangle -A PREROUTING -m mark --mark 0 -i ppp0 -j FairNAT
    iptables -t mangle -A FORWARD -m mark --mark 0 -j FairNAT
    iptables -t mangle -A PREROUTING -i ppp0 -j IMQ --todev 0

    # Adding user specific rules:
    mangle_alexander
    mangle_andreas
}

qos()
{
    if [ "$DEBUG" == "1" ]
    then
        echo --------
    fi

    DEVICE=$1
    rate $2
    TOTAL_RATE=$((($RATE*(100-$RATE_SUB_PERCENT))/100))
    USER_RATE=$((($TOTAL_RATE*(100-$RATE_LOCAL_PERCENT))/100))
    LOCAL_RATE=$(($TOTAL_RATE-$USER_RATE))

    tc qdisc add dev $DEVICE root handle 1: htb default 30 r2q 5
    tc_class_add_htb 1: 1:1 $TOTAL_RATE $TOTAL_RATE
    tc_class_add_htb 1:1 1:30 $LOCAL_RATE $TOTAL_RATE
    tc qdisc add dev $DEVICE parent 1:30 handle 300: prio

    qos_alexander $DEVICE $((USER_RATE/2)) $TOTAL_RATE
    qos_andreas $DEVICE $((USER_RATE/2)) $TOTAL_RATE

    if [ "$DEBUG" == "1" ]
    then
        echo --------
    fi
}

# ---- Alexander: ----

qos_alexander()
{
    DEVICE="$1"
    RATE="$2"
    CEIL="$3"

    tc_class_add_htb 1:1 1:20 $RATE $CEIL
    tc_class_add_htb 1:20 1:210 $(($RATE*9/10)) $CEIL
    tc_class_add_htb 1:20 1:220 $(($RATE/10)) $CEIL
    tc_class_add_htb 1:220 1:221 $(($RATE/20)) $CEIL
    tc_class_add_htb 1:220 1:222 $(($RATE/20)) $CEIL

    tc qdisc add dev $DEVICE parent 1:210 handle 210: prio

    tc filter add dev $DEVICE parent 1: prio 1 protocol ip handle 0x20 fw flowid 1:210
    tc filter add dev $DEVICE parent 1: prio 1 protocol ip handle 0x21 fw flowid 1:221
    tc filter add dev $DEVICE parent 1: prio 1 protocol ip handle 0x22 fw flowid 1:222
}

mangle_alexander()
{
    # reserved mark values: 0x20-0x2F
    iptables -t mangle -A FairNAT_connmark -m mark --mark 0 -s 192.168.0.2 -j MARK --set-mark 0x20
    iptables -t mangle -A FairNAT_connmark -m mark --mark 0x20 -m tos --tos Maximize-Throughput -j MARK --set-mark 0x21
    iptables -t mangle -A FairNAT_connmark -m mark --mark 0x20 -m tos --tos Minimize-Cost -j MARK --set-mark 0x22
    iptables -t mangle -A FairNAT_connmark -m mark --mark 0 -d 192.168.0.2 -j MARK --set-mark 0x20
    iptables -t mangle -A FairNAT_connmark -m mark --mark 0 -i ppp0 -p tcp --dport 22 -j MARK --set-mark 0x20
    iptables -t mangle -A FairNAT_connmark -m mark --mark 0 -i ppp0 -p tcp --dport 47252 -j MARK --set-mark 0x22
}

# ---- Andreas: ----

qos_andreas()
{
    DEVICE="$1"
    RATE="$2"
    CEIL="$3"

    tc_class_add_htb 1:1 1:10 $RATE $CEIL

    tc qdisc add dev $DEVICE parent 1:10 handle 100: prio

    tc filter add dev $DEVICE parent 1: prio 1 protocol ip handle 0x10 fw flowid 1:10
}

mangle_andreas()
{
    # reserved mark values: 0x10-0x1F
    iptables -t mangle -A FairNAT_connmark -m mark --mark 0 -s 192.168.0.3 -j MARK --set-mark 0x10
    iptables -t mangle -A FairNAT_connmark -m mark --mark 0 -d 192.168.0.3 -j MARK --set-mark 0x10
    iptables -t mangle -A FairNAT_connmark -m mark --mark 0 -s 192.168.0.66 -j MARK --set-mark 0x10
    iptables -t mangle -A FairNAT_connmark -m mark --mark 0 -d 192.168.0.66 -j MARK --set-mark 0x10
}

# ---- Main program ----

load_modules
reset
mangle

# Acquire actual rate from SpeedTouch modem:
# BANDWIDTH=`echo -e "root\r\npassword\r\nadsl info\r\nexit\r\n" | nc 192.168.1.254 23 | grep Bandwidth | sed -e s/[^0-9]/\ /g`
#
# for word in $BANDWIDTH
# do
#    RATE_DOWN=$RATE_UP
#    RATE_UP=$word
# done;

if [ "$DEBUG" == "1" ]
then
    echo Setting up Fair NAT with $RATE_UP kbit up / $RATE_DOWN kbit down.
fi

qos ppp0 "$RATE_UP"kbit
qos imq0 "$RATE_DOWN"kbit

# ---- End of file. ----
