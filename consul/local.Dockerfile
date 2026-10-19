# A Linux Consul binary built outside Docker (CONSUL_BINARY in run.sh), on top
# of a released Consul image.
ARG BASE_IMAGE=hashicorp/consul:2.0.4
FROM ${BASE_IMAGE}
COPY consul /bin/consul
RUN consul version
