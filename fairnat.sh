#!/bin/bash
# Use !/bin/bash -x instead if you want to know what the script does.
# -------------------------------------------------------------------------
# File:         http://www.metamorpher.de/fairnat/
# Author:       Andreas Klauer
# Date:         2003-07-31
# Contact:      Andreas.Klauer@metamorpher.de
# Licence:      GPL
# Version:      0.73
# Description:  Traffic Shaping for multiple users on a dedicated linux router
#               using a HTB queue. Please note that this script cannot be run
#               before the internet connection is dialup and ready
# Kernel:       I run this script on a modified 2.4.26 kernel.
#               Modifications in detail:
#                 - TTL patch to modify TTL of outgoing packets
#                 - Use PSCHED_CPU instead of PSCHED_JIFFIES
#                 - Disable HTB_HYSTERICS for better latency (thanks, Andy)
#                 - Lower SFQ queue length: 16 instead of 128 to avoid lags.
# Credits:      Thanks to www.lartc.org for the great HOWTO.
#               Thanks to www.docum.org for great overall FAQ and HINTS.
#               Thanks to various people who published their own scripts on
#               mailing lists. I don't remember your names in detail, but those
#               scripts in general did give me some hints.
#               Thanks to all those people mailing me about suggestions,
#               feature requests and other stuff.
# Modified:     See CHANGELOG
#

# TODO:  Download traffic is only shaped for clients, not for the router.
# TODO:: We somehow have to allow HTB shaping traffic of the router as if it
# TODO:: were just another machine in the LAN.
# TODO:: Maybe it can be done by using a virtual network device (IMQ)?

# === Variables: ===

# Change this if your file is located elsewhere.
FAIRNAT_CONFIG="/etc/ppp/fairnat.config"

# Please note: There are much more variables, but they are defined in
#              configure and in FAIRNAT_CONFIG.

# === Functions: ===

# -----------------------------------------------------------------------------
# FUNCTION:    configure
# DESCRIPTION:
#   This function sets default values for all variables.
#   It has only one parameter: The path/filename for the configuration file.
#   If this configuration file exists, it will be loaded afterwards to replace
#   the default values with the user's own settings.
#
#   The variables are explained in the example fairnat configuration file.
#   Do not modify values here, do it in the config file instead.
#
#   There are also some variables which can't be configured - stuff like your
#   current IP (especially for dynamic IP dialups), subnet, MTU, etc. will be
#   configured automatically. This is done after the config file was loaded.
# SEE ALSO:
# -----------------------------------------------------------------------------
function configure
{
    C_CONFIG_FILE=$1

# System settings:
    BIN_TC=`which tc-htb`
    BIN_IPT=`which iptables`
    BIN_IFC=`which ifconfig`
    BIN_GREP=`which grep`
    BIN_SED=`which sed`
    BIN_ECHO=`which echo`
    BIN_MODPROBE=`which modprobe`

# LAN settings:
    DEV_LAN=eth0
    RATE_LAN=2000

# User settings:
    USERS="1 2 3"
    PORTS=""

# Internet settings:
    DEV_NET=ppp0
    RATE_UP=128
    RATE_DOWN=768
    RATE_SUB_PERCENT=5
    RATE_LOCAL_PERCENT=5

# IPP2P support (experimental)
    IPP2P_ENABLE=0
    IPP2P_DROP_ALL=0
    IPP2P_OPTIONS="--ipp2p --apple --bit"

# Now that all variables have default values set, replace the ones
# defined by the user in the configuration file:
    [ -f $C_CONFIG_FILE ] && source $C_CONFIG_FILE

# Now comes the part that can't be configured by the user:

# Get size of USERS and PORTS. Temporarily convert to Array to do this.
    NUM_USERS=($USERS)
    NUM_USERS=${#NUM_USERS[*]}
    NUM_PORTS=($PORTS)
    NUM_PORTS=${#NUM_PORTS[*]}

# Get some additional stuff from the devices:
    DEV_LAN_IP=`$BIN_IFC $DEV_LAN | \
                $BIN_GREP 'inet addr' | \
                $BIN_SED -e s/^.*inet\ addr://g -e s/\ .*$//g`
    DEV_LAN_SUBNET=`$BIN_ECHO $DEV_LAN_IP | $BIN_SED -e s/\.[0-9]*$//g`
    DEV_NET_IP=`$BIN_IFC $DEV_NET | \
                $BIN_GREP 'inet addr:' | \
                $BIN_SED -e s/^.*inet\ addr://g -e s/\ .*$//g`
    DEV_NET_MTU=`$BIN_IFC $DEV_NET | \
                 $BIN_GREP 'MTU:' | \
                 $BIN_SED -e s/^.*MTU://g -e s/\ .*$//g`

# Convert all rates from KBit to bps.
# Also substract the percentage defined.
    RATE_UP=$((1024*$RATE_UP*(100-$RATE_SUB_PERCENT)/(8*100)))
    RATE_DOWN=$((1024*$RATE_DOWN*(100-$RATE_SUB_PERCENT)/(8*100)))
    RATE_LAN=$((1024*$RATE_LAN/8))

# Rates per User / Local.
# RATE_LOCAL_PERCENT of bandwidth reserved for local upload.
# We don't shape local download as of yet, so no reservation here.
    RATE_USER_DOWN=$(($RATE_DOWN/$NUM_USERS))
    RATE_USER_UP=$((((100-$RATE_LOCAL_PERCENT)*$RATE_UP)/($NUM_USERS*100)))
    RATE_LOCAL_UP=$(($RATE_LOCAL_PERCENT*$RATE_UP/100))

# MARK offset:
# Makes sure that class names per user are unique. Leave this value alone
# unless you really have to create 10 or more subclasses per user. Currently,
# the script uses about 5. Since TC does not accept handles above 4 digits
# and I'm too lazy to implement hexadecimal notation, using values >= 40 may
# lead to weird error messages.
    MARK_OFFSET=10
}

# -----------------------------------------------------------------------------
# FUNCTION:    modules
# DESCRIPTION:
#   This function loads some modules. We don't need them all. But I'm too
#   lazy to sort them out right now. But anyway, nobody in their right mind
#   would use modules for traffic shaping on a router that requires the
#   functionality 24/7.
# SEE ALSO:
# -----------------------------------------------------------------------------
function modules
{
#     note: the /dev/null is just to avoid stupid error messages for
#           all the sane people who compiled the stuff directly into
#           the kernel.
    $BIN_MODPROBE ip_tables 2> /dev/null > /dev/null
    $BIN_MODPROBE ip_conntrack 2> /dev/null > /dev/null
    $BIN_MODPROBE iptable_nat 2> /dev/null > /dev/null
    $BIN_MODPROBE ipt_MASQUERADE 2> /dev/null > /dev/null
    $BIN_MODPROBE iptable_filter 2> /dev/null > /dev/null
    $BIN_MODPROBE ipt_state 2> /dev/null > /dev/null
    $BIN_MODPROBE ipt_limit 2> /dev/null > /dev/null
    $BIN_MODPROBE ip_conntrack_ftp 2> /dev/null > /dev/null
    $BIN_MODPROBE ip_conntrack_irc 2> /dev/null > /dev/null
    $BIN_MODPROBE ip_nat_ftp 2> /dev/null > /dev/null
    $BIN_MODPROBE ip_nat_irc 2> /dev/null > /dev/null
    $BIN_MODPROBE ip_queue 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_api 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_atm 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_cbq 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_csz 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_dsmark 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_fifo 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_generic 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_gred 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_htb 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_ingress 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_sfq 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_red 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_sfq 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_tbf 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_teql 2> /dev/null > /dev/null

#   Experimental IPP2P support:
    if [ $IPP2P_ENABLE == 1 ];
    then
        $BIN_MODPROBE ipt_ipp2p 2> /dev/null > /dev/null
    fi
}

# -----------------------------------------------------------------------------
# FUNCTION:    iptables
# DESCRIPTION:
#   This sets all IPTables rules that are not user-specific.
#   So all the general IPTables stuff goes here.
# SEE ALSO:
# -----------------------------------------------------------------------------
function iptables
{
# 1: TTL generally set to 64, because different TTL values is a dead giveaway
#    that there are multiple machines behind the router.
#    Requires Kernel-TTL-Patch.
    $BIN_IPT -t mangle -A PREROUTING -j TTL --ttl-set 64

# 2: Set TOS for several stuff.
# TODO: Anything missing here? Tell me about it.
    $BIN_IPT -A PREROUTING -t mangle -p icmp -j TOS --set-tos Minimize-Delay
    $BIN_IPT -A PREROUTING -t mangle -p tcp --sport telnet -j TOS --set-tos Minimize-Delay
    $BIN_IPT -A PREROUTING -t mangle -p tcp --sport ssh -j TOS --set-tos Minimize-Delay
    $BIN_IPT -A PREROUTING -t mangle -p tcp --sport ftp -j TOS --set-tos Minimize-Delay
    $BIN_IPT -A PREROUTING -t mangle -p tcp --sport ftp-data -j TOS --set-tos Maximize-Throughput
    $BIN_IPT -A PREROUTING -t mangle -p tcp --dport telnet -j TOS --set-tos Minimize-Delay
    $BIN_IPT -A PREROUTING -t mangle -p tcp --dport ssh -j TOS --set-tos Minimize-Delay
    $BIN_IPT -A PREROUTING -t mangle -p tcp --dport ftp -j TOS --set-tos Minimize-Delay
    $BIN_IPT -A PREROUTING -t mangle -p tcp --dport ftp-data -j TOS --set-tos Maximize-Throughput

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

# 5: IPP2P support (experimental)
    if [ $IPP2P_ENABLE == 1 ];
    then
        if [ $IPP2P_DROP_ALL == 1 ];
        then
# P2P traffic should be forbidden in general.
            $BIN_IPT -A FORWARD -p tcp -m ipp2p $IPP2P_OPTIONS -j DROP
        else
# P2P should be allowed, but with low prio.

# Create a new chain for IPP2P connection marking:
            $BIN_IPT -t mangle -N IPP2PMARK
            $BIN_IPT -t mangle -A IPP2PMARK -j CONNMARK --restore-mark
            $BIN_IPT -t mangle -A IPP2PMARK -m mark --mark 1 -j RETURN
            $BIN_IPT -t mangle -A IPP2PMARK -p tcp -m ipp2p $IPP2P_OPTIONS -j MARK --set-mark 1
            $BIN_IPT -t mangle -A IPP2PMARK -m mark --mark 1 -j CONNMARK --save-mark

# Let all TCP packets run through the IPP2P chain:
            $BIN_IPT -t mangle -A PREROUTING -p tcp -j IPP2PMARK

# Create new chain for IPP2P packets:
            $BIN_IPT -t mangle -N IPP2P
            $BIN_IPT -t mangle -A IPP2P -j TOS --set-tos Maximize-Throughput

# Throw all marked IPP2P packets through the IPP2PMARK chain:
            $BIN_IPT -t mangle -A PREROUTING -m mark --mark 1 -j IPP2P

# NOTE: The mark will be modified again later in the user rules.
        fi
    fi
# End of experimental IPP2P support.
}
# End of iptables.

# -----------------------------------------------------------------------------
# FUNCTION:    user_class(device, mark, rate, ceil)
# DESCRIPTION:
#   This function creates the class structure for a single user.
#   All users have the same class structure for up- and download.
#   This ensures that the sharing is fair between users.
#
#   At the moment, the class setup looks about like this:
#
#    HTB class (for bandwidth sharing)
#    |
#    \-- PRIO (for prioritizing interactive traffic)
#        |
#        \--- Interactive:  SFQ (to treat concurrenct connections fairly)
#        \--- Normal:       SFQ
#        \--- High-Traffic: SFQ
#
#   However, it is possible to treat multiple IPs as a single user (if one
#   guy got more than one machine). So, one user class does not necessarily
#   serve just one IP. See example config file for details.
# SEE ALSO:
# -----------------------------------------------------------------------------
function user_class
{
# Make the positional parameters more readable.
# Use UC_ prefix to make sure that these variables belong to User_Class.
    UC_DEV=$1
    UC_MARK=$2
    UC_RATE=$3
    UC_CEIL=$4

# Add filter for this user.
    $BIN_TC filter add dev $UC_DEV parent 1: protocol ip \
                   handle $UC_MARK fw flowid 1:$UC_MARK


# Add HTB class:
    $BIN_TC class add dev $UC_DEV parent 1:1 classid 1:$UC_MARK \
                  htb rate $(($UC_RATE))bps ceil $(($UC_CEIL))bps \
                  quantum $DEV_NET_MTU

# Add PRIO qdisc on top of HTB:
    if [ $IPP2P_ENABLE == 0 -o $IPP2P_DROP_ALL == 1 ];
    then
# Default: IPP2P disabled. Create 3 bands.
        $BIN_TC qdisc add dev $UC_DEV parent 1:$UC_MARK handle $UC_MARK: prio
    else
# Experimental IPP2P support:

# Add another filter to parent QDisc if IPP2P is active:
        $BIN_TC filter add dev $UC_DEV parent 1: protocol ip \
                       handle $(($UC_MARK+1)) fw flowid 1:$UC_MARK

# Create a prio qdisc with 4 classes. All P2P traffic goes into class 4.
        $BIN_TC qdisc add dev $UC_DEV parent 1:$UC_MARK handle $UC_MARK: prio \
                          bands 4

# Add a filter for IPP2P to this class. The rest depends on TOS.
        $BIN_TC filter add dev $UC_DEV parent $UC_MARK: protocol ip \
                       handle $(($UC_MARK+1)) fw flowid $UC_MARK:4

# Add SFQ QDisc on 4th Prio band.
        $BIN_TC qdisc add dev $UC_DEV parent $UC_MARK:4 handle $(($UC_MARK+4)): \
                      sfq perturb 12

# End of experimental IPP2P support
    fi

# Put SFQ qdisc on top of the prio classes:
    $BIN_TC qdisc add dev $UC_DEV parent $UC_MARK:1 handle $(($UC_MARK+1)): \
                      sfq perturb 9
    $BIN_TC qdisc add dev $UC_DEV parent $UC_MARK:2 handle $(($UC_MARK+2)): \
                      sfq perturb 10
    $BIN_TC qdisc add dev $UC_DEV parent $UC_MARK:3 handle $(($UC_MARK+3)): \
                      sfq perturb 11
}

# -----------------------------------------------------------------------------
# FUNCTION:    fair_nat(ip, mark)
# DESCRIPTION:
#   This function sets up Fair NAT for this ip.
#   mark is the identifier for the user's class this ip belongs to.
#   Packages of this user are marked, so that the Traffic Shaping knows to
#   which User this traffic belongs to.
# SEE ALSO:    forward
# -----------------------------------------------------------------------------
function fair_nat
{
# make positional parameters more readable
    FN_IP=$1

# Add IPTables rules for NAT:
    $BIN_IPT -t nat -A POSTROUTING -o $DEV_NET -s $FN_IP -j MASQUERADE

# Mark packages (if IPP2P is disabled)
    if [ $IPP2P_ENABLE == 0 -o $IPP2P_DROP_ALL == 1 ];
    then
        $BIN_IPT -t mangle -A FORWARD -i $DEV_LAN -o $DEV_NET -s $FN_IP \
                 -j MARK --set-mark $MARK
        $BIN_IPT -t mangle -A FORWARD -i $DEV_NET -o $DEV_LAN -d $FN_IP \
                 -j MARK --set-mark $MARK

# Mark packages (if IPP2P is enabled)
# IPP2P packages will get MARK+1.
# Too bad that there's no --add-mark, it would've made things so much easier.
    else
        $BIN_IPT -t mangle -A FORWARD -i $DEV_LAN -o $DEV_NET -s $FN_IP \
                 -m mark --mark 0 -j MARK --set-mark $MARK
        $BIN_IPT -t mangle -A FORWARD -i $DEV_LAN -o $DEV_NET -s $FN_IP \
                 -m mark --mark 1 -j MARK --set-mark $(($MARK+1))
        $BIN_IPT -t mangle -A FORWARD -i $DEV_NET -o $DEV_LAN -d $FN_IP \
                 -m mark --mark 0 -j MARK --set-mark $MARK
        $BIN_IPT -t mangle -A FORWARD -i $DEV_NET -o $DEV_LAN -d $FN_IP \
                 -m mark --mark 1 -j MARK --set-mark $(($MARK+1))
    fi
}

# -----------------------------------------------------------------------------
# FUNCTION:    forward(ip, port)
# DESCRIPTION:
#   This function sets up port forwarding (DNAT).
#   port is either a single port (a number) or a port range like 1000:2000.
#   Multiple port ranges (like 1000-2000,3100-3200) require multiple calls.
#   Port forwarding will always be done for TCP and UDP.
# SEE ALSO:    nat
# -----------------------------------------------------------------------------
function forward
{
# make positional parameters more readable
    F_IP=$1
    F_PORT=$2

# Add IPTables rules for DNAT:
    $BIN_IPT -t nat -A PREROUTING -i $DEV_NET -p tcp --dport $PORT -j DNAT --to-destination $F_IP
    $BIN_IPT -t nat -A PREROUTING -i $DEV_NET -p udp --dport $PORT -j DNAT --to-destination $F_IP
}

# -----------------------------------------------------------------------------
# FUNCTION:    stop_fairnat
# DESCRIPTION:
#   This function will stop everything. It will delete all IPTables rules,
#   all TC qdiscs and classes.
# SEE ALSO:    start_fairnat
# -----------------------------------------------------------------------------
function stop_fairnat
{
# reset qdisc
    $BIN_TC qdisc del dev $DEV_NET root 2> /dev/null > /dev/null
    $BIN_TC qdisc del dev $DEV_NET ingress 2> /dev/null > /dev/null
    $BIN_TC qdisc del dev $DEV_LAN root 2> /dev/null > /dev/null
    $BIN_TC qdisc del dev $DEV_LAN ingress 2> /dev/null > /dev/null

# reset iptables:

# reset the default policies in the filter table.
    $BIN_IPT -P INPUT ACCEPT
    $BIN_IPT -P FORWARD ACCEPT
    $BIN_IPT -P OUTPUT ACCEPT

# reset the default policies in the nat table.
    $BIN_IPT -t nat -P PREROUTING ACCEPT
    $BIN_IPT -t nat -P POSTROUTING ACCEPT
    $BIN_IPT -t nat -P OUTPUT ACCEPT

# reset the default policies in the mangle table.
    $BIN_IPT -t mangle -P PREROUTING ACCEPT
    $BIN_IPT -t mangle -P OUTPUT ACCEPT

# flush all the rules in the filter and nat tables.
    $BIN_IPT -F
    $BIN_IPT -t nat -F
    $BIN_IPT -t mangle -F

# erase all chains that's not default in filter and nat table.
    $BIN_IPT -X
    $BIN_IPT -t nat -X
    $BIN_IPT -t mangle -X

# reset other stuff
    $BIN_ECHO 1 > /proc/sys/net/ipv4/ip_forward
    $BIN_ECHO 1 > /proc/sys/net/ipv4/ip_dynaddr
    $BIN_ECHO 1 > /proc/sys/net/ipv4/tcp_syncookies
    $BIN_ECHO 1 > /proc/sys/net/ipv4/conf/eth0/rp_filter
    $BIN_ECHO 1 > /proc/sys/net/ipv4/conf/eth1/rp_filter
    $BIN_ECHO 1 > /proc/sys/net/ipv4/conf/ppp0/rp_filter
}

# -----------------------------------------------------------------------------
# FUNCTION:    start_fairnat
# DESCRIPTION:
#   This function starts Fair NAT. It configures your linux box to act as
#   router for the users you specified and sets up Traffic Shaping accordingly.
#   Various subroutines are called to accomplish that.
# SEE ALSO:    stop_fairnat
# -----------------------------------------------------------------------------
function start_fairnat
{
# Fair NAT only works if devices and iptables are 'clean'.
# The function stop_fairnat takes care of that.
    stop_fairnat

# Load some modules.
    modules

# --- Basic IPTables Setup: ---
    iptables

# --- Traffic Shaping: ---

# Ingress policy. Drop anything that comes in too fast.
    $BIN_TC qdisc add dev $DEV_NET handle ffff: ingress
    $BIN_TC filter add dev $DEV_NET parent ffff: protocol ip prio 50 u32 \
            match ip src 0.0.0.0/0 police rate $(($RATE_DOWN))bps burst 20k \
            drop flowid :1

# Just to make sure that Clients can't overflood the Router, same for LAN.
    $BIN_TC qdisc add dev $DEV_LAN handle ffff: ingress
    $BIN_TC filter add dev $DEV_LAN parent ffff: protocol ip prio 50 u32 \
            match ip src 0.0.0.0/0 police rate $(($RATE_LAN))bps burst 20k \
            drop flowid :1

# Root QDisc and parent class for internet device:
    $BIN_TC qdisc add dev $DEV_NET root handle 1: htb default 2
    $BIN_TC class add dev $DEV_NET parent 1: classid 1:1 htb \
                      rate $(($RATE_UP))bps ceil $(($RATE_UP))bps \
                      quantum $DEV_NET_MTU

# Class for local upload. This class gets a lower prio.
    $BIN_TC class add dev $DEV_NET parent 1:1 classid 1:2 htb \
                      rate $(($RATE_LOCAL_UP))bps ceil $(($RATE_UP))bps \
                      quantum $DEV_NET_MTU prio 3


# Root QDisc and parent class for LAN device:
    $BIN_TC qdisc add dev $DEV_LAN root handle 1: htb default 3

# We put a fat class on top here for local LAN traffic that does not
# go to or come from the internet. This fat class gets two children:
# one for the download traffic and one for the local LAN traffic.
    $BIN_TC class add dev $DEV_LAN parent 1: classid 1:2 htb \
                      rate $(($RATE_LAN))bps ceil $(($RATE_LAN))bps \
                      quantum $DEV_NET_MTU

# The download class as a child of the fat class:
    $BIN_TC class add dev $DEV_LAN parent 1:2 classid 1:1 htb \
                      rate $(($RATE_DOWN))bps ceil $(($RATE_DOWN))bps \
                      quantum $DEV_NET_MTU

# The local class as a child of the fat class with lower prio to boot:
    $BIN_TC class add dev $DEV_LAN parent 1:2 classid 1:3 htb \
                      rate $(($RATE_LAN-$RATE_DOWN))bps \
                      ceil $(($RATE_LAN-$RATE_DOWN))bps \
                      quantum $DEV_NET_MTU prio 3

# User classes will be created below.

# --- Fair NAT: ---

# We have to parse a list like "1 2 3 5:6:7 8:9" whereas 1 2 3 are users
# with single IPs and 5 6 7 belong to a single user and 8 9 belong to
# another single user.

    MARK=0
    for user in $USERS;
    do
# user = "1", "2", "3", "5:6:7", "8:9",

# Set MARK to $user*$MARK_OFFSET. For groups (5:6:7), use the first IP (5).
# This makes it easier to create per-user statistics, since the class numbers
# now resemble the User IPs. Thanks to Udo for this suggestion.
        MARK=`$BIN_ECHO $user | $BIN_SED -e s/:.*//g`
        MARK=$(($MARK*$MARK_OFFSET));

# Create classes for this user:
        user_class $DEV_NET $MARK $RATE_USER_UP $RATE_UP
        user_class $DEV_LAN $MARK $RATE_USER_DOWN $RATE_DOWN

# If a user has more than one IP, get the single IPs now.
# This sed converts "5:6:7" to "5 6 7".
        IP_LIST=`$BIN_ECHO $user | $BIN_SED -e s/:/\ /g`

# This can now be used in for loop:
        for ip in $IP_LIST;
        do
# Expand IP by adding subnet:
            ip=$DEV_LAN_SUBNET.$ip

# Subroutine fair_nat does the rest.
            fair_nat $ip $MARK
        done;
    done;

# --- Port Forwarding: ---
    PORT_ARRAY=($PORTS)

    for ((i=0; i<$NUM_PORTS; i+=2));
    do
        IP=$DEV_LAN_SUBNET.${PORT_ARRAY[$i]};
        PORT=${PORT_ARRAY[$i+1]}

        forward $IP $PORT
    done;
}
# end of start_fairnat

# === Main: ===

# First, we need to configure our script:
CONFIG_CALLED=0

# Maybe the user gave us some config parameter:
for arg in $*
do
# Is the argument a file? Load it as configuration.
    if [ -f $arg ];
    then
        configure $arg
        CONFIG_CALLED=1
        break
    fi
done;

# Otherwise just use the standard config.
if [ $CONFIG_CALLED == 0 ];
then
    configure $FAIRNAT_CONFIG
fi

# Does the user want something special?
for arg in $*
do
    case "${arg}" in
        stop)
# The user wants us to stop fairnat and exit.
                stop_fairnat
                echo "Fair NAT stopped."
                exit 0
                ;;
        info)
# Give some information about our config.
                echo "--- LAN ---"
                echo "DEV:       $DEV_LAN"
                echo "IP:        $DEV_LAN_IP"
                echo "SUBNET:    $DEV_LAN_SUBNET"
                echo "RATE:      $RATE_LAN"
                echo "USERS:     $USERS"
                echo "NUM_USERS: $NUM_USERS"
                echo "PORTS:     $PORTS"
                echo "NUM_PORTS: $NUM_PORTS"
                echo "--- NET ---"
                echo "DEV:              $DEV_NET"
                echo "IP:               $DEV_NET_IP"
                echo "RATE_SUB_PERCENT: $RATE_SUB_PERCENT"
                echo "RATE_UP:          $RATE_UP ($RATE_USER_UP per user)"
                echo "RATE_DOWN:        $RATE_DOWN ($RATE_USER_DOWN per user)"
                echo "RATE_LOCAL_UP:    $RATE_LOCAL_UP ($RATE_LOCAL_PERCENT%)"
                echo "--- IPP2P ---"
                echo "IPP2P_ENABLE:   $IPP2P_ENABLE"
                echo "IPP2P_DROP_ALL: $IPP2P_DROP_ALL"
                exit 0
                ;;
    esac
done;

# We are ready to start Fair NAT now.
start_fairnat

# === End of file. ===
