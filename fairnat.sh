#!/bin/bash -x
# -------------------------------------------------------------------------
# File:         http://www.metamorpher.de/fairnat/
# Author:       Andreas Klauer
# Date:         2003-07-31
# Contact:      Andreas.Klauer@metamorpher.de
# Licence:      GPL
# Version:      0.68 (2004-05-03 15:34)
# Description:  Traffic Shaping for multiple users on a dedicated linux router
#               using a HTB queue. Please note that this script cannot be run
#               before the internet connection is dialup and ready
# Kernel:       I run this script on a modified 2.4.26 kernel.
#               Modifications in detail:
#                 - TTL patch to modify TTL of outgoing packets
#                 - Use PSCHED_CPU instead of PSCHED_JIFFIES
#                 - Lower SFQ queue length: 16 instead of 128 to avoid lags.
# Credits:      Thanks to www.lartc.org for the great HOWTO.
#               Thanks to www.docum.org for great overall FAQ and HINTS.
#               Thanks to various people who published their own scripts on
#               mailing lists. I don't remember your names in detail, but those
#               scripts in general did give me some hints.
#
# Modified:
# ---- 2003-08-01 ---- Andreas Klauer ----
#   did some modifications based on Stef Coene's suggestions:
#   corrected prio values, removed qdisc burst, normalized child rates,
#   lowered total rate values, added quantums. Thanks, Stef!
# ---- 2003-10-22 ---- Andreas Klauer ----
#   new class structure, because the old one grew too big
#   and having too many classes proved to perform really, really bad
# ---- 2004-02-19 ---- Andreas Klauer ----
#   replaced $BIN_BC/echo calculations with $((a*b/c)) syntax for readability
#   added REAL_RATE_UP, REAL_RATE_DOWN for easier rate manipulation
#   added sfq and tbf for prio qdisc classes
# ---- 2004-04-30 ---- Andreas Klauer ----
#   removed tbf since it didn't do anything useful anyway.
#   straightened out sfq qdiscs.
#   prioritizing ACK packets; modifying TOS; as shown by Stef Coene
#   on www.docum.org (great page, thanks, actually I use loads of
#   hints from there and got great results!)
# ---- 2004-04-30 ---- Andreas Klauer ----
#   Added ingress queue again
#   Stupid me, forgot the 'bps' after rate values here and there.
#   This messed everything up :-)
# ---- 2004-05-01 ---- Andreas Klauer ----
#   Added much more flexible user and port forwarding handling.
#   The script now supports any number of users (as long as they
#   are in the same subnet) and complex port forwarding rules.
#       The downside to this is that the script looks more complicated
#   now. I tried to compensate this effect by adding lots of hopefully
#   helpful comments.
# ---- 2004-05-03 ---- Andreas Klauer ----
#   For better readability, moved all variables that are used for basic
#   configuration into a separate file. Now people who don't want to
#   change the script itself don't even need to take a look at it.
# ---- 2004-05-03
#

# TODO:  Download traffic is only shaped for clients, not for the router.
# TODO:: We somehow have to allow HTB shaping traffic of the router as if it
# TODO:: were just another machine in the LAN.
# TODO:: Maybe it can be done by using a virtual network device?

#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# 0. Configuration
#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

# TODO:  Make this more flexible (e.g. search for config file in current dir,
# TODO:: allow filename of config file as parameter, etc.

CONFIG_FILE="/etc/ppp/fairnat.config"
source $CONFIG_FILE

#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# 1. Variables
#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

# We need to find out some stuff.

# TODO:  Isn't there an easier way to get these interface settings?
DEV_LAN_IP=`$BIN_IFC $DEV_LAN | \
            $BIN_GREP 'inet addr' | \
            $BIN_SED -e s/.*addr://g -e s/\ .*//g`
DEV_LAN_SUBNET=`$BIN_ECHO $DEV_LAN_IP | $BIN_SED -e s/\.[0-9]*$//g`
DEV_NET_IP=`$BIN_IFC $DEV_NET | \
            $BIN_GREP 'inet addr:' | \
            $BIN_SED -e s/.*inet\ addr://g -e s/\ .*//g`
DEV_NET_MTU=`$BIN_IFC $DEV_NET | \
             $BIN_GREP 'MTU:' | \
             $BIN_SED -e s/.*MTU://g -e s/\ .*//g`

# TODO:  Isn't there a much easier, nicer way to get the count?
NUM_USERS=0
# actual count is calculated here:
for x in $USERS;
do
    NUM_USERS=$(($NUM_USERS+1));
done;

# TODO:  Isn't there a much easier, nicer way to get the count?
NUM_PORTS=0
# calculate count. required later.
for x in $PORTS;
do
    NUM_PORTS=$(($NUM_PORTS+1))
done;

# --- Rates ---

# We need to convert them to bps.
RATE_UP=$((1024*$RATE_UP*(100-$RATE_SUB_PERCENT)/(8*100)))
RATE_DOWN=$((1024*$RATE_DOWN*(100-$RATE_SUB_PERCENT)/(8*100)))
RATE_LAN=$((1024*$RATE_LAN/8))

# Rates per User / Local.
# RATE_LOCAL_PERCENT of bandwidth reserved for local upload.
# We don't shape local download as of yet, so no reservation here.
RATE_USER_DOWN=$(($RATE_DOWN/$NUM_USERS))
RATE_USER_UP=$((((100-$RATE_LOCAL_PERCENT)*$RATE_UP)/$NUM_USERS))
RATE_LOCAL_UP=$(($RATE_LOCAL_PERCENT*$RATE_UP/100))

# --- Marks ---
MARK=0           # Will be calculated in loops below. Depends on USERS.
MARK_OFFSET=10   # To make sure that classes are unique.
                 # Should be powers of 10 for readability reasons.

#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# 2: Reset (taken from various other scripts...)
#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

# load modules
modprobe ip_tables 2> /dev/null > /dev/null
modprobe ip_conntrack 2> /dev/null > /dev/null
modprobe iptable_nat 2> /dev/null > /dev/null
modprobe ipt_MASQUERADE 2> /dev/null > /dev/null
modprobe iptable_filter 2> /dev/null > /dev/null
modprobe ipt_state 2> /dev/null > /dev/null
modprobe ipt_limit 2> /dev/null > /dev/null
modprobe ip_conntrack_ftp 2> /dev/null > /dev/null
modprobe ip_conntrack_irc 2> /dev/null > /dev/null
modprobe ip_nat_ftp 2> /dev/null > /dev/null
modprobe ip_nat_irc 2> /dev/null > /dev/null
modprobe ip_queue 2> /dev/null > /dev/null
modprobe sch_api 2> /dev/null > /dev/null
modprobe sch_atm 2> /dev/null > /dev/null
modprobe sch_cbq 2> /dev/null > /dev/null
modprobe sch_csz 2> /dev/null > /dev/null
modprobe sch_dsmark 2> /dev/null > /dev/null
modprobe sch_fifo 2> /dev/null > /dev/null
modprobe sch_generic 2> /dev/null > /dev/null
modprobe sch_gred 2> /dev/null > /dev/null
modprobe sch_htb 2> /dev/null > /dev/null
modprobe sch_ingress 2> /dev/null > /dev/null
modprobe sch_sfq 2> /dev/null > /dev/null
modprobe sch_red 2> /dev/null > /dev/null
modprobe sch_sfq 2> /dev/null > /dev/null
modprobe sch_tbf 2> /dev/null > /dev/null
modprobe sch_teql 2> /dev/null > /dev/null

# reset qdisc
$BIN_TC qdisc del dev $DEV_NET root 2> /dev/null > /dev/null
$BIN_TC qdisc del dev $DEV_NET ingress 2> /dev/null > /dev/null
$BIN_TC qdisc del dev $DEV_LAN root 2> /dev/null > /dev/null
$BIN_TC qdisc del dev $DEV_LAN ingress 2> /dev/null > /dev/null

# reset iptables

#
# reset the default policies in the filter table.
#
$BIN_IPT -P INPUT ACCEPT
$BIN_IPT -P FORWARD ACCEPT
$BIN_IPT -P OUTPUT ACCEPT

#
# reset the default policies in the nat table.
#
$BIN_IPT -t nat -P PREROUTING ACCEPT
$BIN_IPT -t nat -P POSTROUTING ACCEPT
$BIN_IPT -t nat -P OUTPUT ACCEPT

#
# reset the default policies in the mangle table.
#
$BIN_IPT -t mangle -P PREROUTING ACCEPT
$BIN_IPT -t mangle -P OUTPUT ACCEPT

#
# flush all the rules in the filter and nat tables.
#
$BIN_IPT -F
$BIN_IPT -t nat -F
$BIN_IPT -t mangle -F

#
# erase all chains that's not default in filter and nat table.
#
$BIN_IPT -X
$BIN_IPT -t nat -X
$BIN_IPT -t mangle -X

# reset other stuff
echo 1 > /proc/sys/net/ipv4/ip_forward
echo 1 > /proc/sys/net/ipv4/ip_dynaddr
echo 1 > /proc/sys/net/ipv4/tcp_syncookies
echo 1 > /proc/sys/net/ipv4/conf/eth0/rp_filter
echo 1 > /proc/sys/net/ipv4/conf/eth1/rp_filter
echo 1 > /proc/sys/net/ipv4/conf/ppp0/rp_filter

#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# 3. Creating QDiscs, Classes, and Filters
#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

# --- Ingress ---
$BIN_TC qdisc add dev $DEV_NET handle ffff: ingress
$BIN_TC filter add dev $DEV_NET parent ffff: protocol ip prio 50 u32 match ip \
        src 0.0.0.0/0 police rate $(($RATE_DOWN))bps burst 20k drop flowid :1
# Drop anything that comes in faster than $RATE_DOWN.

# Just to make sure that Clients can't overflood the Router, same for LAN.
$BIN_TC qdisc add dev $DEV_LAN handle ffff: ingress
$BIN_TC filter add dev $DEV_LAN parent ffff: protocol ip prio 50 u32 match ip \
        src 0.0.0.0/0 police rate $(($RATE_LAN))bps burst 20k drop flowid :1

# --- Upload ---
# NOTE: This is mostly Copy&Paste from the --- Download --- Sections.
#       Only small modifications are made. If you change anything
#       in Download or here check if you should modify the other section too.

# _____________
# 1: Main QDisc

$BIN_TC qdisc add dev $DEV_NET root handle 1: htb default 2

# _____________
# 2: Filters. Set unique $MARK for each user.

MARK=0
for user in $USERS;
do
    MARK=$(($MARK+$MARK_OFFSET));
    $BIN_TC filter add dev $DEV_NET parent 1: protocol ip handle $MARK fw flowid 1:$MARK
done;

# _____________
# 3: Parent (main) class
$BIN_TC class add dev $DEV_NET parent 1: classid 1:1 htb rate $(($RATE_UP))bps ceil $(($RATE_UP))bps quantum $DEV_NET_MTU

# _____________
# 4: Child (user) classes

# Create this class tree for each user:
#
# User (RATE_USER : RATE)
# |
# \-- PRIO (for prioritizing interactive traffic)
#     |
#     \--- 1: SFQ # Interactive Class.     SFQ to treat connections fairly.
#     \--- 2: SFQ # Normal/Reliable Class.
#     \--- 3: SFQ # High-Traffic/Lowest Priority Class.
#
# Class numbers depend on MARK, since that already is a unique counter.

MARK=0
for user in $USERS;
do
    MARK=$(($MARK+$MARK_OFFSET));
    $BIN_TC class add dev $DEV_NET parent 1:1 classid 1:$MARK \
            htb rate $(($RATE_USER_UP))bps ceil $(($RATE_UP))bps quantum $DEV_NET_MTU
    $BIN_TC qdisc add dev $DEV_NET parent 1:$MARK handle $MARK: prio
    $BIN_TC qdisc add dev $DEV_NET parent $MARK:1 handle $(($MARK+1)): sfq perturb 9
    $BIN_TC qdisc add dev $DEV_NET parent $MARK:2 handle $(($MARK+2)): sfq perturb 10
    $BIN_TC qdisc add dev $DEV_NET parent $MARK:3 handle $(($MARK+3)): sfq perturb 11
done;

# _____________
# 5: Other class: For local/unknown traffic.
#    Layout is the same as User class above, but with lowest guaranteed rate.
#    Don't make it too low if you got local services (DNS, Web, ...) that
#    produce traffic. Otherwise it won't perform at all well.
$BIN_TC class add dev $DEV_NET parent 1:1 classid 1:2 htb rate $(($RATE_LOCAL_UP))bps ceil $(($RATE_UP))bps quantum $DEV_NET_MTU
$BIN_TC qdisc add dev $DEV_NET parent 1:2 handle 2: prio
$BIN_TC qdisc add dev $DEV_NET parent 2:1 handle 3: sfq perturb 9
$BIN_TC qdisc add dev $DEV_NET parent 2:2 handle 4: sfq perturb 10
$BIN_TC qdisc add dev $DEV_NET parent 2:3 handle 5: sfq perturb 11

# --- Download ---
# NOTE: This is mostly Copy&Paste from the --- Upload --- Sections.
#       Only small modifications are made. If you change anything
#       in Upload or here check if you should modify the other section too.

# _____________
# 1: Main QDisc
$BIN_TC qdisc add dev $DEV_LAN root handle 1: htb default 3

# _____________
# 2: Filters. Set unique $MARK for each user.
MARK=1; # Use 1 as start value in order not to collide with --- Upload --- Marks.
for user in $USERS;
do
    MARK=$(($MARK+$MARK_OFFSET));
    $BIN_TC filter add dev $DEV_LAN parent 1: protocol ip handle $MARK fw flowid 1:$MARK
done;

# _____________
# 3: Parent (main) class
# Don't forget: This device does not just handle Download traffic,
# but LAN too (File transfers from router to client etc.)
# Put a fat class above the download class for this. We use 10Mbit here.
# If you got loads of LAN traffic (Router == Fileserver), maybe you should
# give this class a lower prio and/or lower rate.
$BIN_TC class add dev $DEV_LAN parent 1: classid 1:2 htb rate $(($RATE_LAN))bps ceil $(($RATE_LAN))bps quantum $DEV_NET_MTU
# The download class as a child of the fat class:
$BIN_TC class add dev $DEV_LAN parent 1:2 classid 1:1 htb rate $(($RATE_DOWN))bps ceil $(($RATE_DOWN))bps quantum $DEV_NET_MTU

# _____________
# 3: Child (user) classes

# Create this class tree for each user:
#
# User (RATE_USER : RATE)
# |
# \-- PRIO (for prioritizing interactive traffic)
#     |
#     \--- 1: SFQ # Interactive Class.     SFQ to treat connections fairly.
#     \--- 2: SFQ # Normal/Reliable Class.
#     \--- 3: SFQ # High-Traffic/Lowest Priority Class.
#
# Class numbers depend on MARK, since that already is a unique counter.

MARK=1; # again, Mark starts with 1 in order not to collide with Upload marks.
for user in $USERS;
do
    MARK=$(($MARK+$MARK_OFFSET));
    $BIN_TC class add dev $DEV_LAN parent 1:1 classid 1:$MARK \
            htb rate $(($RATE_USER_DOWN))bps ceil $(($RATE_DOWN))bps quantum $DEV_NET_MTU
    $BIN_TC qdisc add dev $DEV_LAN parent 1:$MARK handle $MARK: prio
    $BIN_TC qdisc add dev $DEV_LAN parent $MARK:1 handle $(($MARK+1)): sfq perturb 9
    $BIN_TC qdisc add dev $DEV_LAN parent $MARK:2 handle $(($MARK+2)): sfq perturb 10
    $BIN_TC qdisc add dev $DEV_LAN parent $MARK:3 handle $(($MARK+3)): sfq perturb 11
done;

# _____________
# 4: Other class: For LAN traffic. Caused by clients who connect directly
#                 to the router. Example: SSH shell; FTP Server; DNS Service;
#                 Other services you may have running here.
$BIN_TC class add dev $DEV_NET parent 1:2 classid 1:3 htb rate $(($RATE_LAN-$RATE_DOWN))bps ceil $(($RATE_LAN-$RATE_DOWN))bps quantum 10000
$BIN_TC qdisc add dev $DEV_NET parent 1:3 handle 2: prio
$BIN_TC qdisc add dev $DEV_NET parent 2:1 handle 3: sfq perturb 9
$BIN_TC qdisc add dev $DEV_NET parent 2:2 handle 4: sfq perturb 10
$BIN_TC qdisc add dev $DEV_NET parent 2:3 handle 5: sfq perturb 11

#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# 4. IPTables
#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

# --- General Stuff ---

# 1: TTL generally set to 64, because different TTL values is a dead giveaway
#    that there are multiple machines behind the router.
$BIN_IPT -t mangle -A PREROUTING -j TTL --ttl-set 64

# 2: Set TOS for several stuff.
$BIN_IPT -A PREROUTING -t mangle -p tcp --sport telnet -j TOS --set-tos Minimize-Delay
$BIN_IPT -A PREROUTING -t mangle -p tcp --sport ssh -j TOS --set-tos Minimize-Delay
$BIN_IPT -A PREROUTING -t mangle -p tcp --sport ftp -j TOS --set-tos Minimize-Delay
$BIN_IPT -A PREROUTING -t mangle -p tcp --sport ftp-data -j TOS --set-tos Maximize-Throughput
$BIN_IPT -A PREROUTING -t mangle -p tcp --dport telnet -j TOS --set-tos Minimize-Delay
$BIN_IPT -A PREROUTING -t mangle -p tcp --dport ssh -j TOS --set-tos Minimize-Delay
$BIN_IPT -A PREROUTING -t mangle -p tcp --dport ftp -j TOS --set-tos Minimize-Delay
$BIN_IPT -A PREROUTING -t mangle -p tcp --dport ftp-data -j TOS --set-tos Maximize-Throughput

# lowest priority for: Azureus/BitTorrent/P2P.
# TODO:   This setting may collide with other users.
# TODO::  If you're up to it, use IPP2P instead. It has MUCH better means
# TODO::  to detect P2P traffic.
# TODO::  However, IPP2P requires kernel and iptables patching.
$BIN_IPT -A PREROUTING -t mangle -p tcp --sport 2800 -j TOS --set-tos Maximize-Throughput
$BIN_IPT -A PREROUTING -t mangle -p tcp --sport 40000: -j TOS --set-tos Maximize-Throughput
$BIN_IPT -A PREROUTING -t mangle -p udp --sport 2800 -j TOS --set-tos Maximize-Throughput
$BIN_IPT -A PREROUTING -t mangle -p udp --sport 40000: -j TOS --set-tos Maximize-Throughput
$BIN_IPT -A PREROUTING -t mangle -p tcp --sport 6800:7000 -j TOS --set-tos Maximize-Throughput
$BIN_IPT -A PREROUTING -t mangle -p udp --sport 6800:7000 -j TOS --set-tos Maximize-Throughput

# 3: Correcting TOS for large packets with Minimize-Delay-TOS
$BIN_IPT -t mangle -N CHK_TOS
$BIN_IPT -t mangle -A CHK_TOS -p tcp -m length --length 0:512  -j RETURN
$BIN_IPT -t mangle -A CHK_TOS -p udp -m length --length 0:1024 -j RETURN
$BIN_IPT -t mangle -A CHK_TOS -j TOS --set-tos Maximize-Throughput
$BIN_IPT -t mangle -A CHK_TOS -j RETURN

$BIN_IPT -t mangle -A PREROUTING -m tos --tos Minimize-Delay -j CHK_TOS

# 4: Modifying TOS for TCP control packets: (from www.docum.org / Stef Coene)
$BIN_IPT -t mangle -N ACK_TOS
$BIN_IPT -t mangle -A ACK_TOS -m tos --tos ! Normal-Service -j RETURN
$BIN_IPT -t mangle -A ACK_TOS -p tcp -m length --length 0:256 -j TOS --set-tos Minimize-Delay
$BIN_IPT -t mangle -A ACK_TOS -p tcp -m length --length 256: -j TOS --set-tos Maximize-Throughput
$BIN_IPT -t mangle -A ACK_TOS -j RETURN
$BIN_IPT -t mangle -A PREROUTING -p tcp -m tcp --tcp-flags SYN,RST,ACK ACK -j ACK_TOS

# --- NAT: ---

for user in $USERS;
do
    USER=$DEV_LAN_SUBNET.$user;
    $BIN_IPT -t nat -A POSTROUTING -o $DEV_NET -s $USER -j MASQUERADE
done;

# --- DNAT (Port Forwarding) ---

# Sorry, this code is a little complicated. I'll explain what's being done.
# We have to parse a list like: "User Ports User Ports User Ports ..."
# For this, we use a C-Like for loop with a stepping of 2. So in each
# loop we can get one User and one Ports.
# We use ${list[index]} to get elements off the list.

PORT_ARRAY=($PORTS);

for ((i=0; i<$NUM_PORTS; i+=2));
do
    USER=$DEV_LAN_SUBNET.${PORT_ARRAY[$i]};
    PORT=${PORT_ARRAY[$i+1]}
    $BIN_IPT -t nat -A PREROUTING -i $DEV_NET -p tcp --dport $PORT -j DNAT --to-destination $USER
    $BIN_IPT -t nat -A PREROUTING -i $DEV_NET -p udp --dport $PORT -j DNAT --to-destination $USER
done;

# --- Marking Packages: ---

MARK=0

for user in $USERS;
do
    MARK=$(($MARK+$MARK_OFFSET));
    USER=$DEV_LAN_SUBNET.$user;
    # Outgoing (Upload)
    $BIN_IPT -A FORWARD -i $DEV_LAN -o $DEV_NET -s $USER -t mangle -j MARK --set-mark $(($MARK))
    # Incoming (Download). Note the +1 here again :-)
    $BIN_IPT -A FORWARD -i $DEV_NET -o $DEV_LAN -d $USER -t mangle -j MARK --set-mark $(($MARK+1))
done;

# --- Mirroring ---

for user in $USERS;
do
    USER=$DEV_LAN_SUBNET.$user;
    $BIN_IPT -A INPUT -i $DEV_LAN -s $USER -d $DEV_NET_IP -j MIRROR
done;

# INFO:   This hides the 'router' from the machines in the LAN.
# INFO::  (Connection from machine in the LAN to Internet IP lead back to machine in the LAN)
# INFO::  Required to fool some windows apps which deny work behind a router.

#-------------------------------------------------------------------------------
# End of file.
#-------------------------------------------------------------------------------
