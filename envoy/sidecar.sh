#!/bin/sh
# sidecar.sh <service> [envoy args...]: run Envoy as the sidecar for <service>,
# registered on the Consul agent in the consul container. Extra arguments go to
# Envoy.
set -eu
service=$1
shift

# Envoy's bootstrap needs an address for the xDS server, not a hostname.
consul_ip=$(getent hosts consul | awk '{ print $1 }')

exec consul connect envoy \
  -sidecar-for "$service" \
  -http-addr "http://${consul_ip}:8500" \
  -grpc-addr "${consul_ip}:8502" \
  -admin-bind 127.0.0.1:19000 \
  -- "$@"
