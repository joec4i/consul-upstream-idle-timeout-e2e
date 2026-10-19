# Consul upstream connection idle timeout e2e

This reproduces the 503s a Consul service mesh caller gets after an intention change, when a stateful firewall or NAT gateway between the caller and the destination has already forgotten an idle connection. It also checks that `upstream_connection_idle_timeout_ms`, proposed in [hashicorp/consul PR #24053](https://github.com/hashicorp/consul/pull/24053), prevents them.

## What goes wrong

1. The caller's Envoy keeps a pooled connection to the destination's sidecar. Envoy's default idle timeout for that pool is one hour.
2. The connection sits idle. The firewall forgets it well before an hour: the Google Cloud VPC firewall after 10 minutes, an AWS NAT gateway after 350 seconds.
3. An intention change on the destination updates its sidecar's public listener, which drains the old one. At the end of the drain, Envoy closes the idle connection. The firewall has no record of the connection and drops the FIN.
4. The caller still thinks the connection is open and sends its next request on it. The request gets a reset, and the caller returns a 503.

With `upstream_connection_idle_timeout_ms` set below the firewall's timeout, the caller closes idle connections first, and its next request opens a new one.

## How the harness models it

```
caller-proxy -> nat:21000 -> (DNAT, masquerade) -> sites-proxy:21000 -> sites
```

- `consul` is a Consul dev agent. `caller` and `sites` are busybox containers, each with an Envoy sidecar started by `consul connect envoy` in the same network namespace.
- The sites sidecar is registered at the `nat` container's address. `nat` forwards to it with iptables, so every mesh connection crosses `nat`'s conntrack table. Lowering `nf_conntrack_tcp_timeout_established` in `nat` stands in for the firewall.
- The timings are shrunk so a run takes about a minute: the sites sidecar drains for 30 seconds instead of 600, `nat` forgets idle connections after 20 seconds, and the fix closes them after 10.
- The intention change is a deny for a source that doesn't exist. It changes the sites listener without blocking the caller.

## Requirements

Docker with Compose v2 and privileged containers (Docker Desktop or Linux), plus `bash`, `git` and `jq`. No ports are published.

## Usage

```
./run.sh [control|bug|fix|all]
```

| Mode      | `nat` conntrack timeout | `upstream_connection_idle_timeout_ms` | Expected |
|-----------|-------------------------|---------------------------------------|----------|
| `control` | kernel default (5 days) | not set                               | 200      |
| `bug`     | 20s                     | not set                               | 503      |
| `fix`     | 20s                     | 10000                                 | 200      |

`all` (the default) runs the three in turn and exits non-zero if any of them doesn't get the expected status. Each run prints the caller's sockets to the sites sidecar before and after the drain, the next request's status, and the change in the relevant Envoy counters. In `bug`, the caller's `upstream_cx_destroy_remote_with_active_rq` goes up by one. In `fix`, `upstream_cx_idle_timeout` goes up instead.

Every run starts the compose project from scratch and leaves it running. `docker compose down -v` removes it.

## Versions

By default `run.sh` builds Consul from the head of hashicorp/consul PR #24053, on top of the `hashicorp/consul:2.0.4` image. The first build takes several minutes and needs a few GB of Docker disk. Set `CONSUL_IMAGE` to test something else, for example a release without the key:

```
CONSUL_IMAGE=hashicorp/consul:2.0.4 ./run.sh bug
```

With Go installed, you can skip the build in Docker by cross-compiling a checkout of the PR and passing the binary:

```
(cd ../consul && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o /tmp/consul-linux .)
CONSUL_BINARY=/tmp/consul-linux ./run.sh
```

Use `GOARCH=amd64` on an x86 Docker host.

| Variable          | Default                          |
|-------------------|----------------------------------|
| `CONSUL_IMAGE`    | built from PR `CONSUL_PR` (24053) |
| `CONSUL_BINARY`   | not set                          |
| `ENVOY_IMAGE`     | `envoyproxy/envoy:v1.38.7`       |
| `DRAIN_S`         | `30`                             |
| `CONNTRACK_S`     | `20`                             |
| `IDLE_TIMEOUT_MS` | `10000`                          |
