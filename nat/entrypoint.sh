#!/bin/sh
# Stands in for a stateful firewall or NAT gateway between the caller and the
# sites sidecar. The sites sidecar is registered at this container's address.
# Connections to port 21000 here are DNATed to the sites container and
# masqueraded, so replies come back through this container's conntrack table.
#
# With CONNTRACK_S set, conntrack forgets established connections idle for that
# many seconds, like a cloud firewall does (the Google Cloud VPC firewall after
# 10 minutes, an AWS NAT gateway after 350 seconds). After that, a FIN from the
# sites sidecar has no entry to reverse-NAT it and never reaches the caller.
set -eu

until sites_ip=$(getent hosts sites | awk '{ print $1 }') && [ -n "$sites_ip" ]; do
  sleep 0.5
done

sysctl -qw net.ipv4.ip_forward=1
# Traffic goes back out the interface it came in on. Don't tell the caller to
# go straight to the sites container instead.
sysctl -qw net.ipv4.conf.all.send_redirects=0 net.ipv4.conf.eth0.send_redirects=0

iptables -t nat -A PREROUTING -p tcp --dport 21000 -j DNAT --to-destination "${sites_ip}:21000"
iptables -t nat -A POSTROUTING -p tcp -d "$sites_ip" --dport 21000 -j MASQUERADE

timeout=/proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established
if [ -n "${CONNTRACK_S:-}" ]; then
  echo "$CONNTRACK_S" > "$timeout"
fi
echo "==> forwarding :21000 to sites (${sites_ip}:21000), conntrack established timeout $(cat "$timeout")s"

exec tail -f /dev/null
