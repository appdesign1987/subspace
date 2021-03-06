#!/usr/bin/env sh
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

# Require environment variables.
if [ -z "${SUBSPACE_HTTP_HOST-}" ] ; then
    echo "Environment variable SUBSPACE_HTTP_HOST required. Exiting."
    exit 1
fi
# Optional environment variables.
if [ -z "${SUBSPACE_BACKLINK-}" ] ; then
    export SUBSPACE_BACKLINK=""
fi

if [ -z "${SUBSPACE_IPV4_POOL-}" ] ; then
    export SUBSPACE_IPV4_POOL="10.99.97.0/24"
fi

if [ -z "${SUBSPACE_NAMESERVER-}" ] ; then
    export SUBSPACE_NAMESERVER="1.1.1.1"
fi

if [ -z "${SUBSPACE_LETSENCRYPT-}" ] ; then
    export SUBSPACE_LETSENCRYPT="true"
fi

if [ -z "${SUBSPACE_HTTP_ADDR-}" ] ; then
    export SUBSPACE_HTTP_ADDR=":80"
fi

if [ -z "${SUBSPACE_LISTENPORT-}" ] ; then
    export SUBSPACE_LISTENPORT="51820"
fi

if [ -z "${SUBSPACE_HTTP_INSECURE-}" ] ; then
    export SUBSPACE_HTTP_INSECURE="false"
fi

export DEBIAN_FRONTEND="noninteractive"

if [ -z "${SUBSPACE_IPV4_GW-}" ] ; then
        export SUBSPACE_IPV4_PREF=$(echo ${SUBSPACE_IPV4_POOL-} | cut -d '/' -f1 |sed 's/.0$/./g' )
	export SUBSPACE_IPV4_GW=$(echo ${SUBSPACE_IPV4_PREF-}1)

fi




# Set DNS server
echo "nameserver ${SUBSPACE_NAMESERVER}" >/etc/resolv.conf

if [ -n "${SUBSPACE_DISABLE_MASQUERADE-}" ] ; then
    # ipv4
    if ! /sbin/iptables -t nat --check POSTROUTING -s ${SUBSPACE_IPV4_POOL} -j MASQUERADE ; then
        /sbin/iptables -t nat --append POSTROUTING -s ${SUBSPACE_IPV4_POOL} -j MASQUERADE
    fi

    if ! /sbin/iptables --check FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT ; then
        /sbin/iptables --append FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
    fi

    if ! /sbin/iptables --check FORWARD -s ${SUBSPACE_IPV4_POOL} -j ACCEPT ; then
        /sbin/iptables --append FORWARD -s ${SUBSPACE_IPV4_POOL} -j ACCEPT
    fi

fi

# ipv4 - DNS Leak Protection
if ! /sbin/iptables -t nat --check OUTPUT -s ${SUBSPACE_IPV4_POOL} -p udp --dport 53 -j DNAT --to ${SUBSPACE_IPV4_GW}:53 ; then
    /sbin/iptables -t nat --append OUTPUT -s ${SUBSPACE_IPV4_POOL} -p udp --dport 53 -j DNAT --to ${SUBSPACE_IPV4_GW}:53
fi

if ! /sbin/iptables -t nat --check OUTPUT -s ${SUBSPACE_IPV4_POOL} -p tcp --dport 53 -j DNAT --to ${SUBSPACE_IPV4_GW}:53 ; then
    /sbin/iptables -t nat --append OUTPUT -s ${SUBSPACE_IPV4_POOL} -p tcp --dport 53 -j DNAT --to ${SUBSPACE_IPV4_GW}:53
fi

#
# WireGuard (${SUBSPACE_IPV4_POOL})
#
if ! test -d /data/wireguard ; then
    mkdir /data/wireguard
    cd /data/wireguard

    mkdir clients
    touch clients/null.conf # So you can cat *.conf safely
    mkdir peers
    touch peers/null.conf # So you can cat *.conf safely

    # Generate public/private server keys.
    /usr/bin/wg genkey | tee server.private | /usr/bin/wg pubkey > server.public
fi

cat <<WGSERVER >/data/wireguard/server.conf
[Interface]
PrivateKey = $(cat /data/wireguard/server.private)
ListenPort = ${SUBSPACE_LISTENPORT}

WGSERVER
cat /data/wireguard/peers/*.conf >>/data/wireguard/server.conf

if ip link show wg0 2>/dev/null; then
    ip link del wg0
fi
ip link add wg0 type wireguard
export SUBSPACE_IPV4_CIDR=$(echo ${SUBSPACE_IPV4_POOL-} |cut -d '/' -f2)
ip addr add ${SUBSPACE_IPV4_GW}/${SUBSPACE_IPV4_CIDR} dev wg0
/usr/bin/wg setconf wg0 /data/wireguard/server.conf
ip link set wg0 up


# dnsmasq service
if ! test -d /etc/sv/dnsmasq ; then
    cat <<DNSMASQ >/etc/dnsmasq.conf
    # Only listen on necessary addresses.
    listen-address=127.0.0.1,${SUBSPACE_IPV4_GW},${SUBSPACE_IPV6_GW}

    # Never forward plain names (without a dot or domain part)
    domain-needed

    # Never forward addresses in the non-routed address spaces.
    bogus-priv
DNSMASQ

    mkdir /etc/sv/dnsmasq
    cat <<RUNIT >/etc/sv/dnsmasq/run
#!/bin/sh
exec /usr/sbin/dnsmasq --no-daemon
RUNIT
    chmod +x /etc/sv/dnsmasq/run

# dnsmasq service log
    mkdir /etc/sv/dnsmasq/log
    mkdir /etc/sv/dnsmasq/log/main
    cat <<RUNIT >/etc/sv/dnsmasq/log/run
#!/bin/sh
exec svlogd -tt ./main
RUNIT
    chmod +x /etc/sv/dnsmasq/log/run
    ln -s /etc/sv/dnsmasq /etc/service/dnsmasq
fi

# subspace service
if ! test -d /etc/sv/subspace ; then
    mkdir /etc/sv/subspace
    cat <<RUNIT >/etc/sv/subspace/run
#!/bin/sh
exec /usr/bin/subspace \
    "--http-host=${SUBSPACE_HTTP_HOST}" \
    "--http-addr=${SUBSPACE_HTTP_ADDR}" \
    "--http-insecure=${SUBSPACE_HTTP_INSECURE}" \
    "--backlink=${SUBSPACE_BACKLINK}" \
    "--letsencrypt=${SUBSPACE_LETSENCRYPT}"
RUNIT
    chmod +x /etc/sv/subspace/run

    # subspace service log
    mkdir /etc/sv/subspace/log
    mkdir /etc/sv/subspace/log/main
    cat <<RUNIT >/etc/sv/subspace/log/run
#!/bin/sh
exec svlogd -tt ./main
RUNIT
    chmod +x /etc/sv/subspace/log/run
    ln -s /etc/sv/subspace /etc/service/subspace
fi

exec $@
