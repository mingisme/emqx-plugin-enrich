{application, emqx_plugin_enrich,
 [{description, "EMQX Plugin: in-place enrichment from Device Registry (POC)"},
  {vsn, "0.1.0"},
  {applications, [kernel, stdlib, inets]},
  {modules, [emqx_plugin_enrich]},
  {registered, [emqx_plugin_enrich_loader]},
  %% `mod` makes this an *active* application: OTP calls
  %% emqx_plugin_enrich:start/2 when the app starts, which is what
  %% registers the message.publish hook and starts the loader. Without
  %% it, EMQX reports the plugin as "running" but start/2 never runs.
  {mod, {emqx_plugin_enrich, []}},
  {licenses, ["Apache-2.0"]}
 ]}.