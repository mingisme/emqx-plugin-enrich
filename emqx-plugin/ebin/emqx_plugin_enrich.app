{application, emqx_plugin_enrich,
 [{description, "EMQX Plugin: in-place enrichment from Device Registry (POC)"},
  {vsn, "0.1.0"},
  {applications, [kernel, stdlib, inets]},
  {modules, [emqx_plugin_enrich]},
  {registered, [emqx_plugin_enrich_loader]},
  {licenses, ["Apache-2.0"]}
 ]}.