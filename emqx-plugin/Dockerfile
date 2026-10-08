# Multi-stage: compile in erlang:26, deploy into emqx/emqx:5.8.8
FROM erlang:26 AS builder
WORKDIR /build
COPY src ./src
COPY ebin ./ebin
RUN erlc -o ebin src/emqx_plugin_enrich.erl

FROM emqx/emqx:5.8.8
COPY --from=builder /build/ebin /opt/emqx/plugins/emqx_plugin_enrich/ebin
RUN echo '' >> /opt/emqx/etc/plugins.conf \
 && echo 'plugins.emqx_plugin_enrich.enable = true' >> /opt/emqx/etc/plugins.conf