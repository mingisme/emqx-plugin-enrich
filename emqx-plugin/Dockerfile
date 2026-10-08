# Multi-stage: compile in erlang:26, deploy into emqx/emqx:5.8.8
# EMQX 5.8 plugin layout (verified against emqx/emqx:5.8.8 source):
#   /opt/emqx/plugins/<rel-name>-<vsn>/release.json
#   /opt/emqx/plugins/<rel-name>-<vsn>/<app-name>-<vsn>/ebin/{*.app,*.beam}
FROM erlang:26 AS builder
WORKDIR /build
COPY src ./src
COPY ebin ./ebin
RUN erlc -o ebin src/emqx_plugin_enrich.erl

FROM emqx/emqx:5.8.8
ARG REL=emqx_plugin_enrich-0.1.0
COPY --from=builder /build/ebin /opt/emqx/plugins/${REL}/${REL}/ebin
COPY release.json /opt/emqx/plugins/${REL}/release.json
# EMQX 5.8 tracks plugin lifecycle via `plugins.states` in the HOCON config,
# not the legacy `plugins.conf` enable flag. Register the plugin here so EMQX
# *starts* the application (runs start/2 → registers the hook) on boot, rather
# than merely loading its code (which leaves config_status=not_configured and
# the hook unregistered).
RUN printf '\nplugins {\n    states = [\n        { name_vsn = "%s", enable = true }\n    ]\n}\n' "${REL}" \
      >> /opt/emqx/etc/base.hocon