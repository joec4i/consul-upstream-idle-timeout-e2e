# Envoy with the Consul binary from CONSUL_IMAGE, so `consul connect envoy`
# can bootstrap and exec it.
ARG CONSUL_IMAGE=hashicorp/consul:2.0.4
ARG ENVOY_IMAGE=envoyproxy/envoy:v1.38.7

FROM ${CONSUL_IMAGE} AS consul

FROM ${ENVOY_IMAGE}
COPY --from=consul /bin/consul /usr/local/bin/consul
COPY sidecar.sh /usr/local/bin/sidecar.sh
RUN chmod +x /usr/local/bin/sidecar.sh && consul version && envoy --version
ENTRYPOINT ["/usr/local/bin/sidecar.sh"]
