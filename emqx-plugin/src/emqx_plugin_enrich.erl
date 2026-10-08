%% emqx_plugin_enrich.erl - EMQX 5.8.8 plugin: in-place enrichment from Device Registry
%% POC: single file, microsecond hook, inets/httpc, ETS cache, async loader.

-module(emqx_plugin_enrich).
-behaviour(application).
-behaviour(gen_server).

-export([start/2, stop/1]).
-export([load/1, unload/1]).
-export([on_message_publish/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).
-export([start_link/0]).

-define(CACHE_TABLE, emqx_plugin_enrich_cache).
-define(LOADER, emqx_plugin_enrich_loader).
-define(TOPIC_FILTER, <<"plant/+/telemetry">>).
-define(REGISTRY_URL_PREFIX, <<"http://registry:8080/devices/">>).
-define(DEVICE_ID_FIELD, <<"device_id">>).
-define(CONNECT_TIMEOUT, 2000).
-define(REQUEST_TIMEOUT, 2000).
-define(HP_HIGHEST, 100).

%%====================================================================
%% Application callbacks
%%====================================================================
%%
%% PROD-DEV (config schema): the constants below (TOPIC_FILTER,
%% REGISTRY_URL_PREFIX, DEVICE_ID_FIELD, CONNECT_TIMEOUT, REQUEST_TIMEOUT)
%% are hardcoded for the POC. For product, define a HOCON schema in
%% `priv/emqx_plugin_enrich.conf`, parse it on load/1, and pass the values
%% via the hook args (third element of the MFA tuple).
%%
%% Recommended schema keys (see also GUIDE.md "Production development notes"):
%%   topic_filter            "plant/+/telemetry"
%%   registry_url            "http://registry:8080"
%%   device_id_field         "device_id"
%%   connect_timeout_ms      2000
%%   request_timeout_ms      2000
%%   known_lifetime_ms       3600000
%%   unknown_lifetime_ms     30000
%%   backoff_refused_ms      30000
%%   backoff_timeout_ms      5000
%%   unresolved_horizon_ms   900000
%%   sweep_interval_ms       10000
%%   max_concurrent_loads    8
%%   hook_priority           100

start(_StartType, _Args) ->
    ok = ensure_cache(),
    {ok, _} = start_link(),
    ok.

stop(_State) ->
    ok.

%%====================================================================
%% EMQX plugin lifecycle
%%====================================================================

load(_Env) ->
    ok = emqx_hook:add('message.publish',
                       {?MODULE, on_message_publish, []},
                       ?HP_HIGHEST),
    ok.

unload(_Env) ->
    ok = emqx_hook:del('message.publish',
                       {?MODULE, on_message_publish, []}),
    ok.

%%====================================================================
%% Hook: message.publish
%%====================================================================

on_message_publish(Msg = #{topic := Topic, payload := Payload}, _Args) ->
    case emqx_topic:match(Topic, ?TOPIC_FILTER) of
        true  -> do_enrich(Msg, Payload);
        false -> {ok, Msg}
    end.

do_enrich(Msg, Payload) ->
    T0 = erlang:monotonic_time(microsecond),
    Result =
        try
            Decoded = decode(Payload),
            enrich(Msg, Decoded, maps:get(?DEVICE_ID_FIELD, Decoded, undefined))
        catch
            Class:Reason ->
                logger:warning("emqx_plugin_enrich decode/enrich failed: ~p:~p",
                               [Class, Reason]),
                {ok, Msg}
        end,
    logger:info("emqx_plugin_enrich hook_us=~p",
                [erlang:monotonic_time(microsecond) - T0]),
    Result.

enrich(Msg, _Decoded, undefined) ->
    {ok, Msg};
enrich(Msg, Decoded, DeviceId) when is_binary(DeviceId) ->
    case cache_lookup(DeviceId) of
        {known, Fields} ->
            {ok, Msg#{payload := encode(maps:merge(Decoded, Fields))}};
        _ ->
            %% cold | unknown | in_flight — async (non-blocking)
            async_lookup(DeviceId),
            {ok, Msg}
    end;
enrich(Msg, _Decoded, _) ->
    {ok, Msg}.

%%====================================================================
%% Cache (ETS-backed, microsecond reads)
%%====================================================================
%%
%% PROD-DEV (cache lifetimes): the POC stores entries forever (`nil` as
%% expiry). For product, the fourth tuple element should be a deadline in
%% monotonic time, computed at write:
%%
%%   Deadline = erlang:monotonic_time(millisecond) + LifetimeMs
%%
%% `cache_lookup/1` then returns `expired` if `now > Deadline`, and the
%% hook treats `expired` like `cold` (async reload). A separate gen_server
%% ticks on `sweep_interval_ms` to evict expired entries by iterating the
%% table (or maintain a sorted index for O(log n) eviction).
%%
%% PROD-DEV (multi-node coherence): the cache is per-node. Three options:
%%   a) Mria replication — declare the table in `mria_schema` and add to
%%      `mria:start/0`'s schema; the table becomes cluster-wide.
%%   b) External cache (Redis) — adds a network hop; reconsider Q2.
%%   c) Accept per-node divergence — invisible at single-node, genuinely
%%      wrong at scale; documented in DESIGN.md.
%%
%% For product, default to (a) unless a good reason forces (b) or (c).

ensure_cache() ->

ensure_cache() ->
    case ets:info(?CACHE_TABLE) of
        undefined ->
            ets:new(?CACHE_TABLE,
                    [set, named_table, public, {read_concurrency, true}]),
            ok;
        _ ->
            ok
    end.

cache_lookup(Key) ->
    case ets:lookup(?CACHE_TABLE, Key) of
        []                              -> cold;
        [{_, known, Value, _}]         -> {known, Value};
        [{_, unknown, _, _}]           -> unknown;
        [{_, in_flight, _, _}]         -> in_flight
    end.

cache_set_known(K, V)        -> ets:insert(?CACHE_TABLE, {K, known, V, nil}).
cache_set_unknown(K)         -> ets:insert(?CACHE_TABLE, {K, unknown, [], nil}).
cache_set_in_flight(K)       -> ets:insert(?CACHE_TABLE, {K, in_flight, [], nil}).
cache_clear_in_flight(K)     -> ets:delete(?CACHE_TABLE, K).

%%====================================================================
%% JSON helpers
%%====================================================================

decode(undefined) -> #{};
decode(P) when is_binary(P) ->
    emqx_utils_json:decode(P, [return_maps]).

encode(M) when is_map(M) ->
    emqx_utils_json:encode(M).

%%====================================================================
%% Loader (gen_server — single-flight over async HTTP)
%%====================================================================
%%
%% PROD-DEV (loader pool): the POC has a single loader. It serializes
%% lookups through one mailbox, so cold-cache throughput is one lookup at
%% a time. For product, replace this with a worker pool of N (= 8 by
%% default) workers, supervised by `emqx_plugin_enrich_sup`. The hook
%% stays microsecond either way; only the cold path does.
%%
%% Minimal pattern using Erlang's `pool` module:
%%
%%     ChildSpecs = [#{id => enrich_loader_worker,
%%                     start => {emqx_plugin_enrich_loader_worker,
%%                               start_link, []},
%%                     type => worker} || _ <- lists:seq(1, N)],
%%
%%     init:start_pool(emqx_plugin_enrich_pool,
%%                     ChildSpecs, [{size, N}, {max_overflow, 2*N}]),
%%
%% Then `async_lookup/1` becomes:
%%
%%     async_lookup(Dev) ->
%%         pool:transaction(emqx_plugin_enrich_pool,
%%                          fun(W) -> lookup_via_worker(W, Dev) end,
%%                          #{timeout => infinity}).
%%
%% PROD-DEV (never-block guarantee): `spawn/3` (not `spawn_link/3`) is
%% used here on purpose — see the design constraint in the conversation:
%% `spawn_link` from a `message.publish` hook is fatal, but here the spawn
%% is from the supervised gen_server's process, not the hook's. Keep it
%% that way: the loader must remain the only place that does HTTP work.

start_link() ->

start_link() ->
    gen_server:start_link({local, ?LOADER}, ?MODULE, [], []).

async_lookup(DeviceId) ->
    gen_server:cast(?LOADER, {lookup, DeviceId}).

%% gen_server callbacks
init([]) ->
    {ok, #{in_flight => sets:new()}}.

handle_call(_, _, S) ->
    {reply, ok, S}.

handle_cast({lookup, Dev}, S = #{in_flight := I}) ->
    case sets:is_element(Dev, I) of
        true ->
            {noreply, S};
        false ->
            cache_set_in_flight(Dev),
            spawn(?MODULE, do_lookup, [Dev, self()]),
            {noreply, S#{in_flight := sets:add_element(Dev, I)}}
    end;
handle_cast(_, S) ->
    {noreply, S}.

handle_info({lookup_done, Dev, R}, S = #{in_flight := I}) ->
    case R of
        {ok, Fields} -> cache_set_known(Dev, Fields);
        not_found    -> cache_set_unknown(Dev);
        {error, _}   -> cache_clear_in_flight(Dev)
    end,
    {noreply, S#{in_flight := sets:del_element(Dev, I)}};
handle_info(_, S) ->
    {noreply, S}.

terminate(_, _) ->
    ok.

code_change(_, S, _) ->
    {ok, S}.

%%====================================================================
%% HTTP lookup (called in spawned process)
%%====================================================================
%%
%% PROD-DEV (refusal-vs-timeout backoff): the POC collapses every
%% non-success into `{error, Reason}` and clears the in_flight marker,
%% so the next message for that device will retry immediately. For
%% product, split classify/1's outcomes into two buckets with different
%% backoff windows:
%%
%%   {ok, {{_, 200, _}, _, _}}        → {ok, Fields}        (success)
%%   {ok, {{_, 422, _}, _, _}}        → not_found           (settled: 422 = unknown)
%%   {ok, {{Status, _, _}, _, _}} when Status >= 500
%%                                     → {refused, Status}  (backoff_refused_ms)
%%   {error, econnrefused}            → {refused, econnrefused}
%%   {error, timeout}                 → {unresolved, timeout}
%%                                     (backoff_timeout_ms)
%%   {error, Other}                   → {unresolved, Other}
%%
%% Then `handle_info({lookup_done, ...})` writes an "Unresolved until backoff
%% elapses" entry instead of clearing in_flight. Subsequent messages for
%% that device will look up the entry, see the deadline is in the future,
%% and return {ok, Msg} without firing HTTP. After the deadline elapses,
%% the next message retries.
%%
%% PROD-DEV (HTTP client): `inets/httpc` is portable but adds an erlang:now
%% indirection. If product needs lower cold-cache latency, consider
%% `ehttpc` (EMQX's internal client — API not stable) or `gun` (well-
%% maintained, slightly higher overhead). Stick with `httpc` if portability
%% across EMQX minor versions matters more than ~200 µs per call.
%%
%% PROD-DEV (return semantics from hook): `register_amqp/0` returns
%% {ok, Msg}; anything else leaves the original message published
%% untouched (this is how a blip is expressed). Don't return `{stop,
%%, _}` for blips — that would cause the message.publish path to fail
%% rather than pass through.

do_lookup(Dev, Parent) ->
    Url = <<?REGISTRY_URL_PREFIX/binary, Dev/binary>>,
    HttpResult =
        httpc:request(get,
                      {binary_to_list(Url), []},
                      [{connect_timeout, ?CONNECT_TIMEOUT},
                       {timeout, ?REQUEST_TIMEOUT},
                       {autoredirect, false}],
                      []),
    Parent ! {lookup_done, Dev, classify(HttpResult)}.

classify({ok, {{_, 200, _}, _, Body}}) ->
    try
        {ok, emqx_utils_json:decode(list_to_binary(Body), [return_maps])}
    catch
        _:_ -> {error, bad_json}
    end;
classify({ok, {{_, 404, _}, _, _}}) ->
    not_found;
classify({ok, {{Status, _, _}, _, _}}) when Status >= 500 ->
    {error, {status, Status}};
classify({error, Reason}) ->
    {error, Reason};
classify(Other) ->
    {error, Other}.