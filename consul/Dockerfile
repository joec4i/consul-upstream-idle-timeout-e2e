# Consul built from source at CONSUL_COMMIT, on top of a released Consul image
# so the entrypoint and layout stay the same. run.sh builds this when
# CONSUL_IMAGE isn't set, from the head of hashicorp/consul PR #24053.
#
#   docker build --build-arg CONSUL_COMMIT=<sha> -t consul-e2e:<sha> consul

ARG GO_IMAGE=golang:1.26-bookworm
ARG BASE_IMAGE=hashicorp/consul:2.0.4

FROM ${GO_IMAGE} AS build
ARG CONSUL_REPO=https://github.com/hashicorp/consul.git
ARG CONSUL_COMMIT
WORKDIR /src
RUN test -n "${CONSUL_COMMIT}" \
 && git init -q . \
 && git fetch -q --depth 1 "${CONSUL_REPO}" "${CONSUL_COMMIT}" \
 && git checkout -q FETCH_HEAD
ENV CGO_ENABLED=0 GOTOOLCHAIN=auto
RUN go mod download
# One package at a time: compiling the AWS SDK alongside others can run a
# Docker Desktop VM out of memory.
ARG GO_BUILD_P=1
RUN go build -p "${GO_BUILD_P}" -o /out/consul \
      -ldflags "-X github.com/hashicorp/consul/version.GitCommit=${CONSUL_COMMIT}" .

FROM ${BASE_IMAGE}
COPY --from=build /out/consul /bin/consul
RUN consul version
