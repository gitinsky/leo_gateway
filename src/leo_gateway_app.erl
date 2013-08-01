%%======================================================================
%%
%% Leo Gateway
%%
%% Copyright (c) 2012 Rakuten, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% ---------------------------------------------------------------------
%% Leo Gateway - Application
%% @doc
%% @end
%%======================================================================
-module(leo_gateway_app).

-author('Yosuke Hara').

-include("leo_gateway.hrl").
-include("leo_http.hrl").
-include_lib("leo_commons/include/leo_commons.hrl").
-include_lib("leo_logger/include/leo_logger.hrl").
-include_lib("leo_redundant_manager/include/leo_redundant_manager.hrl").
-include_lib("leo_statistics/include/leo_statistics.hrl").
-include_lib("eunit/include/eunit.hrl").

-behaviour(application).
-export([start/2, stop/1,
         inspect_cluster_status/2, profile_output/0, get_options/0]).

-define(CHECK_INTERVAL, 3000).

-ifdef(TEST).
-define(get_several_info_from_manager(_Args),
        fun() ->
                _ = get_system_config_from_manager([]),
                _ = get_members_from_manager([]),

                [{ok, [#system_conf{n = 1,
                                    w = 1,
                                    r = 1,
                                    d = 1}]},
                 {ok, [#member{node  = 'node_0',
                               state = 'running'}]}]
        end).
-else.
-define(get_several_info_from_manager(X),  {get_system_config_from_manager(X),
                                            get_members_from_manager(X)}).
-endif.


%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------
%% @spec start(_Type, _StartArgs) -> ServerRet
%% @doc application start callback for leo_gateway.
start(_Type, _StartArgs) ->
    consider_profiling(),
    App = leo_gateway,

    %% Launch Logger(s)
    DefLogDir = "./log/",
    LogDir    = case application:get_env(App, log_appender) of
                    {ok, [{file, Options}|_]} ->
                        leo_misc:get_value(path, Options,  DefLogDir);
                    _ ->
                        DefLogDir
                end,
    ok = leo_logger_client_message:new(LogDir, ?env_log_level(App), log_file_appender()),

    %% Launch Supervisor
    Res = leo_gateway_sup:start_link(),
    after_process_0(Res).


%% @spec stop(_State) -> ServerRet
%% @doc application stop callback for leo_gateway.
stop(_State) ->
    ok.

-spec profile_output() -> ok.
profile_output() ->
    eprof:stop_profiling(),
    eprof:log("leo_gateway.procs.profile"),
    eprof:analyze(procs),
    eprof:log("leo_gateway.total.profile"),
    eprof:analyze(total).

-spec consider_profiling() -> profiling | not_profiling | {error, any()}.
consider_profiling() ->
    case application:get_env(profile) of
        {ok, true} ->
            {ok, _Pid} = eprof:start(),
            eprof:start_profiling([self()]);
        _ ->
            not_profiling
    end.

%% @doc Inspect the cluster-status
%%
-spec(inspect_cluster_status(any(), list()) ->
             pid()).
inspect_cluster_status(Res, ManagerNodes) ->
    case ?get_several_info_from_manager(ManagerNodes) of
        {{ok, SystemConf}, {ok, Members}} ->
            case get_cluster_state(Members) of
                ?STATE_STOP ->
                    timer:apply_after(?CHECK_INTERVAL, ?MODULE, inspect_cluster_status,
                                      [ok, ManagerNodes]);
                ?STATE_RUNNING ->
                    ok = after_process_1(SystemConf, Members)
            end;
        {{ok,_SystemConf}, {error,_Cause}} ->
            timer:apply_after(?CHECK_INTERVAL, ?MODULE, inspect_cluster_status,
                              [ok, ManagerNodes]);
        Error ->
            timer:apply_after(?CHECK_INTERVAL, ?MODULE, inspect_cluster_status,
                              [ok, ManagerNodes]),
            io:format("~p:~s,~w - cause:~p~n", [?MODULE, "after_process/1", ?LINE, Error]),
            Error
    end,
    Res.


%%--------------------------------------------------------------------
%% Internal Functions.
%%--------------------------------------------------------------------
%% @doc After process of start_link
%% @private
-spec(after_process_0({ok, pid()} | {error, any()}) ->
             {ok, pid()} | {error, any()}).
after_process_0({ok, _Pid} = Res) ->
    ok = leo_misc:init_env(),

    ManagerNodes0  = ?env_manager_nodes(leo_gateway),
    ManagerNodes1 = lists:map(fun(X) -> list_to_atom(X) end, ManagerNodes0),

    %% Launch S3Libs:Auth/Bucket/EndPoint
    ok = leo_s3_libs:start(slave, [{'provider', ManagerNodes1}]),
    _ = leo_s3_endpoint:get_endpoints(),

    %% Launch http-handler(s)
    {ok, HttpOptions} = get_options(),
    Handler = HttpOptions#http_options.handler,
    ok = Handler:start(leo_gateway_sup, HttpOptions),

    %% Check status of the storage-cluster
    inspect_cluster_status(Res, ManagerNodes1);

after_process_0(Error) ->
    io:format("~p:~s,~w - cause:~p~n", [?MODULE, "after_process/1", ?LINE, Error]),
    Error.


%% @doc After process of start_link
%% @private
-spec(after_process_1(#system_conf{}, list(#member{})) ->
             ok).
after_process_1(SystemConf, Members) ->
    %% Launch Redundant-manager#2
    ManagerNodes    = ?env_manager_nodes(leo_gateway),
    NewManagerNodes = lists:map(fun(X) -> list_to_atom(X) end, ManagerNodes),

    RefSup = whereis(leo_gateway_sup),
    case whereis(leo_redundant_manager_sup) of
        undefined ->
            ChildSpec = {leo_redundant_manager_sup,
                         {leo_redundant_manager_sup, start_link,
                          [gateway, NewManagerNodes, ?env_queue_dir(leo_gateway)]},
                         permanent, 2000, supervisor, [leo_redundant_manager_sup]},
            {ok, _} = supervisor:start_child(RefSup, ChildSpec);
        _ ->
            {ok, _} = leo_redundant_manager_sup:start_link(
                        gateway, NewManagerNodes, ?env_queue_dir(leo_gateway))
    end,

    %% Launch SNMPA
    ok = leo_statistics_api:start_link(leo_gateway),
    ok = leo_statistics_metrics_vm:start_link(?STATISTICS_SYNC_INTERVAL),
    ok = leo_statistics_metrics_vm:start_link(?SNMP_SYNC_INTERVAL_S),
    ok = leo_statistics_metrics_vm:start_link(?SNMP_SYNC_INTERVAL_L),
    ok = leo_statistics_metrics_req:start_link(?SNMP_SYNC_INTERVAL_S),
    ok = leo_statistics_metrics_req:start_link(?SNMP_SYNC_INTERVAL_L),
    ok = leo_gateway_cache_statistics:start_link(?SNMP_SYNC_INTERVAL_S),
    ok = leo_gateway_cache_statistics:start_link(?SNMP_SYNC_INTERVAL_L),

    {ok,_,_} = leo_redundant_manager_api:create(
                 Members, [{n, SystemConf#system_conf.n},
                           {r, SystemConf#system_conf.r},
                           {w, SystemConf#system_conf.w},
                           {d, SystemConf#system_conf.d},
                           {bit_of_ring, SystemConf#system_conf.bit_of_ring},
                           {level_1, SystemConf#system_conf.level_1},
                           {level_2, SystemConf#system_conf.level_2}
                          ]),
    ok = leo_membership:set_proc_auditor(leo_gateway_api),

    application:start(leo_rpc),

    %% Register in THIS-Process
    ok = leo_gateway_api:register_in_monitor(first),
    lists:foldl(fun(N, false) ->
                        {ok, Checksums} = leo_redundant_manager_api:checksum(ring),
                        case rpc:call(N, leo_manager_api, notify,
                                      [launched, gateway, node(), Checksums], ?DEF_TIMEOUT) of
                            ok -> true;
                            _  -> false
                        end;
                   (_, true) ->
                        void
                end, false, NewManagerNodes),
    ok.


%% @doc Retrieve system-configuration from manager-node(s)
%% @private
-spec(get_system_config_from_manager(list()) ->
             {ok, #system_conf{}} | {error, any()}).
get_system_config_from_manager([]) ->
    {error, 'could_not_get_system_config'};
get_system_config_from_manager([Manager|T]) ->
    case leo_misc:node_existence(Manager) of
        true ->
            case rpc:call(Manager, leo_manager_api, get_system_config, [], ?DEF_TIMEOUT) of
                {ok, SystemConf} ->
                    {ok, SystemConf};
                {badrpc, Why} ->
                    {error, Why};
                {error, Cause} ->
                    ?error("get_system_config_from_manager/1", "cause:~p", [Cause]),
                    get_system_config_from_manager(T)
            end;
        false ->
            get_system_config_from_manager(T)
    end.


%% @doc Retrieve members-list from manager-node(s)
%% @private
-spec(get_members_from_manager(list()) ->
             {ok, list()} | {error, any()}).
get_members_from_manager([]) ->
    {error, 'could_not_get_members'};
get_members_from_manager([Manager|T]) ->
    case rpc:call(Manager, leo_manager_api, get_members, [], ?DEF_TIMEOUT) of
        {ok, Members} ->
            {ok, Members};
        {badrpc, Why} ->
            {error, Why};
        {error, Cause} ->
            ?error("get_members_from_manager/1", "cause:~p", [Cause]),
            get_members_from_manager(T)
    end.


%% @doc
%% @private
-spec(get_cluster_state(list(#member{})) ->
             node_state()).
get_cluster_state([]) ->
    ?STATE_STOP;
get_cluster_state([#member{state = ?STATE_RUNNING}|_]) ->
    ?STATE_RUNNING;
get_cluster_state([_|T]) ->
    get_cluster_state(T).


%% @doc Retrieve log-appneder(s)
%% @private
-spec(log_file_appender() ->
             list()).
log_file_appender() ->
    case application:get_env(leo_gateway, log_appender) of
        undefined   -> log_file_appender([], []);
        {ok, Value} -> log_file_appender(Value, [])
    end.

log_file_appender([], []) ->
    [{?LOG_ID_FILE_INFO,  ?LOG_APPENDER_FILE},
     {?LOG_ID_FILE_ERROR, ?LOG_APPENDER_FILE}];
log_file_appender([], Acc) ->
    lists:reverse(Acc);
log_file_appender([{Type, _}|T], Acc) when Type == file ->
    log_file_appender(T, [{?LOG_ID_FILE_ERROR, ?LOG_APPENDER_FILE}|[{?LOG_ID_FILE_INFO, ?LOG_APPENDER_FILE}|Acc]]);
%% @TODO
log_file_appender([{Type, _}|T], Acc) when Type == zmq ->
    log_file_appender(T, [{?LOG_ID_ZMQ, ?LOG_APPENDER_ZMQ}|Acc]).


%% @doc Retrieve properties
%%
-spec(get_options() ->
             {ok, #http_options{}}).
get_options() ->
    %% Retrieve http-related properties:
    HttpProp = ?env_http_properties(),
    HttpHandler          = leo_misc:get_value('handler',             HttpProp, ?DEF_HTTTP_HANDLER),
    Port                 = leo_misc:get_value('port',                HttpProp, ?DEF_HTTP_PORT),
    SSLPort              = leo_misc:get_value('ssl_port',            HttpProp, ?DEF_HTTP_SSL_PORT),
    SSLCertFile          = leo_misc:get_value('ssl_certfile',        HttpProp, ?DEF_HTTP_SSL_C_FILE),
    SSLKeyFile           = leo_misc:get_value('ssl_keyfile',         HttpProp, ?DEF_HTTP_SSL_K_FILE),
    NumOfAcceptors       = leo_misc:get_value('num_of_acceptors',    HttpProp, ?DEF_HTTP_NUM_OF_ACCEPTORS),
    MaxKeepAlive         = leo_misc:get_value('max_keepalive',       HttpProp, ?DEF_HTTP_MAX_KEEPALIVE),

    %% Retrieve cache-related properties:
    CacheProp = ?env_cache_properties(),
    UserHttpCache         = leo_misc:get_value('http_cache',               CacheProp, ?DEF_HTTP_CACHE),
    CacheWorkers          = leo_misc:get_value('cache_workers',            CacheProp, ?DEF_CACHE_WORKERS),
    CacheRAMCapacity      = leo_misc:get_value('cache_ram_capacity',       CacheProp, ?DEF_CACHE_RAM_CAPACITY),
    CacheDiscCapacity     = leo_misc:get_value('cache_disc_capacity',      CacheProp, ?DEF_CACHE_DISC_CAPACITY),
    CacheDiscThresholdLen = leo_misc:get_value('cache_disc_threshold_len', CacheProp, ?DEF_CACHE_DISC_THRESHOLD_LEN),
    CacheDiscDirData      = leo_misc:get_value('cache_disc_dir_data',      CacheProp, ?DEF_CACHE_DISC_DIR_DATA),
    CacheDiscDirJournal   = leo_misc:get_value('cache_disc_dir_journal',   CacheProp, ?DEF_CACHE_DISC_DIR_JOURNAL),
    CacheExpire           = leo_misc:get_value('cache_expire',             CacheProp, ?DEF_CACHE_EXPIRE),
    CacheMaxContentLen    = leo_misc:get_value('cache_max_content_len',    CacheProp, ?DEF_CACHE_MAX_CONTENT_LEN),
    CachableContentTypes  = leo_misc:get_value('cachable_content_type',    CacheProp, []),
    CachablePathPatterns  = leo_misc:get_value('cachable_path_pattern',    CacheProp, []),

    CacheMethod = case UserHttpCache of
                      true  -> ?CACHE_HTTP;
                      false -> ?CACHE_INNER
                  end,
    CachableContentTypes1 = cast_type_list_to_binary(CachableContentTypes),
    CachablePathPatterns1 = case cast_type_list_to_binary(CachablePathPatterns) of
                                [] -> [];
                                List ->
                                    lists:foldl(
                                      fun(P, Acc) ->
                                              case re:compile(P) of
                                                  {ok, MP} -> [MP|Acc];
                                                  _        -> Acc
                                              end
                                      end, [], List)
                            end,

    %% Retrieve large-object-related properties:
    LargeObjectProp = ?env_large_object_properties(),
    MaxChunkedObjs  = leo_misc:get_value('max_chunked_objs',  LargeObjectProp, ?DEF_LOBJ_MAX_CHUNKED_OBJS),
    MaxObjLen       = leo_misc:get_value('max_len_for_obj',   LargeObjectProp, ?DEF_LOBJ_MAX_LEN_FOR_OBJ),
    ChunkedObjLen   = leo_misc:get_value('chunked_obj_len',   LargeObjectProp, ?DEF_LOBJ_CHUNK_OBJ_LEN),
    ThresholdObjLen = leo_misc:get_value('threshold_obj_len', LargeObjectProp, ?DEF_LOBJ_THRESHOLD_OBJ_LEN),

    %% Retrieve timeout-values
    lists:foreach(fun({K, T}) ->
                          leo_misc:set_env(leo_gateway, K, T)
                  end, ?env_timeout()),

    HttpOptions = #http_options{handler                  = ?convert_to_handler(HttpHandler),
                                port                     = Port,
                                ssl_port                 = SSLPort,
                                ssl_certfile             = SSLCertFile,
                                ssl_keyfile              = SSLKeyFile,
                                num_of_acceptors         = NumOfAcceptors,
                                max_keepalive            = MaxKeepAlive,
                                cache_method             = CacheMethod,
                                cache_workers            = CacheWorkers,
                                cache_ram_capacity       = CacheRAMCapacity,
                                cache_disc_capacity      = CacheDiscCapacity,
                                cache_disc_threshold_len = CacheDiscThresholdLen,
                                cache_disc_dir_data      = CacheDiscDirData,
                                cache_disc_dir_journal   = CacheDiscDirJournal,
                                cache_expire             = CacheExpire,
                                cache_max_content_len    = CacheMaxContentLen,
                                cachable_content_type    = CachableContentTypes1,
                                cachable_path_pattern    = CachablePathPatterns1,
                                max_chunked_objs         = MaxChunkedObjs,
                                max_len_for_obj          = MaxObjLen,
                                chunked_obj_len          = ChunkedObjLen,
                                threshold_obj_len        = ThresholdObjLen},
    ?info("start/3", "handler: ~p",                  [HttpHandler]),
    ?info("start/3", "port: ~p",                     [Port]),
    ?info("start/3", "ssl port: ~p",                 [SSLPort]),
    ?info("start/3", "ssl certfile: ~p",             [SSLCertFile]),
    ?info("start/3", "ssl keyfile: ~p",              [SSLKeyFile]),
    ?info("start/3", "num of acceptors: ~p",         [NumOfAcceptors]),
    ?info("start/3", "max keepalive: ~p",            [MaxKeepAlive]),
    ?info("start/3", "cache_method: ~p",             [CacheMethod]),
    ?info("start/3", "cache workers: ~p",            [CacheWorkers]),
    ?info("start/3", "cache ram capacity: ~p",       [CacheRAMCapacity]),
    ?info("start/3", "cache disc capacity: ~p",      [CacheDiscCapacity]),
    ?info("start/3", "cache disc threshold len: ~p", [CacheDiscThresholdLen]),
    ?info("start/3", "cache disc data-dir: ~p",      [CacheDiscDirData]),
    ?info("start/3", "cache disc journal-dir: ~p",   [CacheDiscDirJournal]),
    ?info("start/3", "cache expire: ~p",             [CacheExpire]),
    ?info("start/3", "cache_max_content_len: ~p",    [CacheMaxContentLen]),
    ?info("start/3", "cacheable_content_types: ~p",  [CachableContentTypes]),
    ?info("start/3", "cacheable_path_patterns: ~p",  [CachablePathPatterns]),
    ?info("start/3", "max_chunked_obj: ~p",          [MaxChunkedObjs]),
    ?info("start/3", "max_len_for_obj: ~p",          [MaxObjLen]),
    ?info("start/3", "chunked_obj_len: ~p",          [ChunkedObjLen]),
    ?info("start/3", "threshold_obj_len: ~p",        [ThresholdObjLen]),
    {ok, HttpOptions}.


%% @doc Data-type transmit from list to binary
%% @private
cast_type_list_to_binary([]) ->
    [];
cast_type_list_to_binary(List) ->
    lists:map(fun(I) ->
                      case catch list_to_binary(I) of
                          {'EXIT', _} -> I;
                          Bin         -> Bin
                      end
              end, List).
