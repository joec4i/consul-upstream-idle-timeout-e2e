#!/usr/bin/env bash
# Opens one mesh connection from caller to sites, leaves it idle, changes an
# intention on sites so its sidecar drains the public listener, and sends the
# next request after the drain ends.
#
#   ./run.sh [control|bug|fix|all]
#
#   control  the nat container keeps the kernel's default conntrack timeout. The
#            sites sidecar closes the idle connection at the end of the drain,
#            its FIN reaches the caller, and the caller drops the connection.
#            Expect 200.
#   bug      the nat container forgets connections idle for CONNTRACK_S, so that
#            FIN never reaches the caller. The caller sends its next request on
#            the dead connection. Expect 503.
#   fix      bug, plus proxy-defaults upstream_connection_idle_timeout_ms set to
#            IDLE_TIMEOUT_MS, below CONNTRACK_S, so the caller closes the idle
#            connection itself first. Needs a Consul build with that key.
#            Expect 200.
#   all      control, bug and fix in turn. Exits non-zero if any of them fails.
#
# Environment:
#   CONSUL_IMAGE     Consul to test. Default: built from the head of
#                    hashicorp/consul PR CONSUL_PR (24053).
#   CONSUL_BINARY    a Linux Consul binary to test instead, for example one
#                    cross-compiled from a checkout of the PR.
#   ENVOY_IMAGE      envoyproxy/envoy:v1.38.7
#   DRAIN_S          30     the sites sidecar's --drain-time-s (Envoy default 600)
#   CONNTRACK_S      20     the nat container's idle timeout in bug and fix
#   IDLE_TIMEOUT_MS  10000  upstream_connection_idle_timeout_ms in fix
#
# Every run starts the compose project from scratch and leaves it running.
set -euo pipefail
cd "$(dirname "$0")"

mode=${1:-all}
case "$mode" in control|bug|fix|all) ;; *) sed -n '2,31p' "$0" >&2; exit 2 ;; esac

CONSUL_PR=${CONSUL_PR:-24053}
ENVOY_IMAGE=${ENVOY_IMAGE:-envoyproxy/envoy:v1.38.7}
DRAIN_S=${DRAIN_S:-30}
IDLE_CONNTRACK_S=${CONNTRACK_S:-20}
IDLE_TIMEOUT_MS=${IDLE_TIMEOUT_MS:-10000}
export ENVOY_IMAGE DRAIN_S

compose() { docker compose "$@"; }

# Builds Consul from the PR's head commit, once per commit.
consul_image() {
  local sha image
  sha=$(git ls-remote https://github.com/hashicorp/consul.git "refs/pull/${CONSUL_PR}/head" | cut -f1)
  [ -n "$sha" ] || { echo "!! can't resolve hashicorp/consul PR #${CONSUL_PR}" >&2; exit 1; }
  image=consul-idle-timeout-e2e/consul:${sha:0:12}
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "==> building Consul from hashicorp/consul PR #${CONSUL_PR} at ${sha:0:12} (a few minutes the first time)" >&2
    docker build -q --build-arg CONSUL_COMMIT="$sha" -t "$image" consul >/dev/null ||
      { echo "!! the Consul build failed" >&2; exit 1; }
  fi
  echo "$image"
}

consul() { compose exec -T consul consul "$@"; }

# up <service...>: start services, showing compose's output only if it fails.
up() {
  local out
  out=$(compose up -d --build --quiet-pull "$@" 2>&1) || { echo "$out" >&2; return 1; }
}

# wait_for <what> <seconds> <command...>: retry the command every second.
wait_for() {
  local what=$1 tries=$2
  shift 2
  for _ in $(seq 1 "$tries"); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "!! timed out waiting for ${what}" >&2
  return 1
}

nat_ready() { compose logs nat 2>/dev/null | grep -q '==> forwarding'; }

# envoy <app container> <admin path>: query the sidecar sharing that container's
# network namespace.
envoy() { compose exec -T "$1" wget -qO- "http://127.0.0.1:19000/$2"; }

# request: one request from caller through its sidecar to sites. Prints the
# HTTP status, or wget's error when there is none.
request() {
  local out code
  out=$(compose exec -T caller wget -S -q -T 5 -O /dev/null http://127.0.0.1:9191/ 2>&1 || true)
  code=$(echo "$out" | awk '/HTTP\/1/ { print $2; exit }')
  echo "${code:-no response: $out}"
}

# The caller sidecar's TCP sockets to the sites sidecar, as the caller sees them.
sockets() {
  compose exec -T caller netstat -tn |
    awk -v p="${nat_ip}:21000" '$5 == p { printf "    %s -> %s %s\n", $4, $5, $6; n++ } END { if (!n) print "    none" }'
}

SITES_STATS='^(listener_manager\.listener_in_place_updated|http\.public_listener\.downstream_cx_(total|active|destroy_local_active_rq|destroy_remote|drain_close)):'
CALLER_STATS='^cluster\.sites\.[^:]*\.consul\.upstream_(cx_total|cx_active|cx_idle_timeout|cx_destroy_local|cx_destroy_remote|cx_destroy_remote_with_active_rq|rq_rx_reset|rq_503|rq_200|rq_retry):'

stats() {
  envoy "$1" stats | grep -E "$2" | sed -E 's/^cluster\.sites\.[^:]*\.consul\./cluster.sites./' | LC_ALL=C sort -t: -k1,1
}

# before/after/delta for each counter, keyed on the stat name.
delta() {
  LC_ALL=C join -t: -a1 -a2 -e 0 -o 0,1.2,2.2 "$1" "$2" |
    awk -F: '{ b = $2 + 0; a = $3 + 0; printf "    %-58s %5d -> %5d  (%+d)\n", $1, b, a, a - b }'
}

register_services() {
  compose exec -T consul sh -c 'cat > /tmp/services.hcl && consul services register /tmp/services.hcl' >/dev/null <<EOF
services {
  name    = "sites"
  port    = 8080
  connect {
    sidecar_service {
      # Callers reach the sites sidecar through the nat container.
      address = "${nat_ip}"
      port    = 21000
      proxy {
        config {
          bind_address = "0.0.0.0"
        }
      }
    }
  }
}

services {
  name    = "caller"
  address = "${caller_ip}"
  port    = 8081
  connect {
    sidecar_service {
      port = 21001
      proxy {
        upstreams {
          destination_name = "sites"
          local_bind_port  = 9191
        }
      }
    }
  }
}
EOF
}

# run_mode <mode>: prints the run and ends with a RESULT line. Returns non-zero
# if the last request didn't get the expected status.
run_mode() {
  local mode=$1 expect conntrack
  case "$mode" in
    control) expect=200 conntrack="" ;;
    bug)     expect=503 conntrack=$IDLE_CONNTRACK_S ;;
    fix)     expect=200 conntrack=$IDLE_CONNTRACK_S ;;
  esac

  echo "==> mode ${mode}: starting from scratch"
  compose down -v --remove-orphans >/dev/null 2>&1 || true
  export CONNTRACK_S=$conntrack
  up consul sites caller nat
  wait_for "the Consul agent" 60 consul members
  wait_for "the nat container" 30 nat_ready
  nat_ip=$(compose exec -T nat hostname -i | awk '{ print $1 }')
  caller_ip=$(compose exec -T caller hostname -i | awk '{ print $1 }')
  echo "    $(consul version | head -1), ${ENVOY_IMAGE}"
  echo "    $(compose logs --no-log-prefix nat | grep '==> forwarding' | sed 's/^==> //')"

  consul config write - >/dev/null <<'EOF'
Kind     = "service-defaults"
Name     = "sites"
Protocol = "http"
EOF
  if [ "$mode" = fix ]; then
    consul config write - >/dev/null <<EOF
Kind = "proxy-defaults"
Name = "global"
Config {
  upstream_connection_idle_timeout_ms = ${IDLE_TIMEOUT_MS}
}
EOF
  fi
  register_services
  up sites-proxy caller-proxy

  echo "==> waiting for caller to reach sites through the mesh"
  local code=""
  for _ in $(seq 1 60); do
    code=$(request)
    [ "$code" = 200 ] && break
    sleep 2
  done
  [ "$code" = 200 ] || { echo "!! caller never got a 200 from sites (last: ${code})" >&2; return 1; }
  echo "    caller's sites cluster idle_timeout: $(envoy caller 'config_dump?resource=dynamic_active_clusters' |
    jq -r '[.configs[].cluster | select(.name | startswith("sites."))][0].typed_extension_protocol_options["envoy.extensions.upstreams.http.v3.HttpProtocolOptions"].common_http_protocol_options.idle_timeout // "not set (Envoy default 1h)"')"

  local scratch updates updates_before start
  scratch=$(mktemp -d)
  stats sites "$SITES_STATS" > "$scratch/sites.before"
  stats caller "$CALLER_STATS" > "$scratch/caller.before"
  updates_before=$(awk -F': ' '/^listener_manager.listener_in_place_updated:/ { print $2 }' "$scratch/sites.before")

  echo "==> $(date -u +%H:%M:%S) warm request: $(request); the connection is idle from here"
  sockets
  start=$(date +%s)

  # A deny for a source that doesn't exist changes the RBAC filter on the sites
  # public listener without blocking caller. That's all an intention change
  # needs to do to start a drain.
  consul config write - >/dev/null <<'EOF'
Kind = "service-intentions"
Name = "sites"
Sources = [
  {
    Name   = "intruder"
    Action = "deny"
  }
]
EOF
  for _ in $(seq 1 30); do
    updates=$(stats sites '^listener_manager\.listener_in_place_updated:' | awk -F': ' '{ print $2 }')
    [ "${updates:-0}" -gt "${updates_before:-0}" ] && break
    sleep 0.5
  done
  [ "${updates:-0}" -gt "${updates_before:-0}" ] || { echo "!! the intention change never reached the sites listener" >&2; return 1; }
  echo "==> $(date -u +%H:%M:%S) intention changed; sites listener updated in place, draining for ${DRAIN_S}s"

  while [ "$(date +%s)" -lt $((start + DRAIN_S + 10)) ]; do sleep 1; done

  echo "==> $(date -u +%H:%M:%S) after the drain ($(( $(date +%s) - start ))s idle), caller's sockets to the sites sidecar:"
  sockets
  code=$(request)
  echo "==> $(date -u +%H:%M:%S) next request: ${code}"
  sleep 1

  stats sites "$SITES_STATS" > "$scratch/sites.after"
  stats caller "$CALLER_STATS" > "$scratch/caller.after"
  echo
  echo "==> sites sidecar"
  delta "$scratch/sites.before" "$scratch/sites.after"
  echo
  echo "==> caller sidecar"
  delta "$scratch/caller.before" "$scratch/caller.after"
  rm -rf "$scratch"
  echo

  if [ "$code" = "$expect" ]; then
    echo "RESULT ${mode}: ${code}, expected ${expect}: PASS"
  else
    echo "RESULT ${mode}: ${code}, expected ${expect}: FAIL"
    return 1
  fi
}

# local_consul_image <binary>: wraps a locally built binary in an image.
local_consul_image() {
  local ctx
  ctx=$(mktemp -d)
  cp "$1" "$ctx/consul"
  docker build -q -f consul/local.Dockerfile -t consul-idle-timeout-e2e/consul:local "$ctx" >/dev/null ||
    { rm -rf "$ctx"; echo "!! the Consul image build failed" >&2; exit 1; }
  rm -rf "$ctx"
  echo consul-idle-timeout-e2e/consul:local
}

if [ -n "${CONSUL_BINARY:-}" ]; then
  CONSUL_IMAGE=$(local_consul_image "$CONSUL_BINARY")
elif [ -z "${CONSUL_IMAGE:-}" ]; then
  CONSUL_IMAGE=$(consul_image)
fi
unset CONSUL_BINARY
export CONSUL_IMAGE
echo "==> Consul image ${CONSUL_IMAGE}"

if [ "$mode" != all ]; then
  run_mode "$mode"
  exit
fi

results=() failed=0
for m in control bug fix; do
  echo
  # A fresh run.sh per mode, so set -e applies inside it.
  if "$0" "$m"; then results+=("$m PASS"); else results+=("$m FAIL"); failed=1; fi
done
echo
echo "==> summary"
printf '    %s\n' "${results[@]}"
exit "$failed"
