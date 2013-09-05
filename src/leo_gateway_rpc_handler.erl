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
%% Leo Gateway - RPC-Handler
%% @doc
%% @end
%%======================================================================
-module(leo_gateway_rpc_handler).

-author('Yosuke Hara').
-author('Yoshiyuki Kanno').

-export([head/1,
         get/1,
         get/2,
         get/3,
         delete/1,
         put/3, put/4, put/6, put/7,
         invoke/5
        ]).

-include("leo_gateway.hrl").
-include_lib("leo_logger/include/leo_logger.hrl").
-include_lib("leo_object_storage/include/leo_object_storage.hrl").
-include_lib("leo_redundant_manager/include/leo_redundant_manager.hrl").
-include_lib("leo_statistics/include/leo_statistics.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(ERR_TYPE_INTERNAL_ERROR, internal_server_error).

-type(method() :: get | put | delete | head).

-record(req_params, {
          req_id       = 0  :: integer(),
          timestamp    = 0  :: integer(),
          addr_id      = 0  :: integer(),
          redundancies = [] :: list()
         }).


%% @doc Retrieve a metadata from the storage-cluster
%%
-spec(head(binary()) ->
             {ok, #metadata{}}|{error, any()}).
head(Key) ->
    ReqParams = get_request_parameters(head, Key),
    invoke(ReqParams#req_params.redundancies,
           leo_storage_handler_object,
           head,
           [ReqParams#req_params.addr_id, Key],
           []).

%% @doc Retrieve an object from the storage-cluster
%%
-spec(get(binary()) ->
             {ok, #metadata{}, binary()}|{error, any()}).
get(Key) ->
    _ = leo_statistics_req_counter:increment(?STAT_REQ_GET),
    ReqParams = get_request_parameters(get, Key),
    invoke(ReqParams#req_params.redundancies,
           leo_storage_handler_object,
           get,
           [ReqParams#req_params.addr_id, Key, ReqParams#req_params.req_id],
           []).
-spec(get(binary(), integer()) ->
             {ok, match}|{ok, #metadata{}, binary()}|{error, any()}).
get(Key, ETag) ->
    _ = leo_statistics_req_counter:increment(?STAT_REQ_GET),
    ReqParams = get_request_parameters(get, Key),
    invoke(ReqParams#req_params.redundancies,
           leo_storage_handler_object,
           get,
           [ReqParams#req_params.addr_id, Key, ETag, ReqParams#req_params.req_id],
           []).

-spec(get(binary(), integer(), integer()) ->
             {ok, #metadata{}, binary()}|{error, any()}).
get(Key, StartPos, EndPos) ->
    _ = leo_statistics_req_counter:increment(?STAT_REQ_GET),
    ReqParams = get_request_parameters(get, Key),
    invoke(ReqParams#req_params.redundancies,
           leo_storage_handler_object,
           get,
           [ReqParams#req_params.addr_id,
            Key, StartPos, EndPos,
            ReqParams#req_params.req_id],
           []).


%% @doc Remove an object from storage-cluster
%%
-spec(delete(binary()) ->
             ok|{error, any()}).
delete(Key) ->
    _ = leo_statistics_req_counter:increment(?STAT_REQ_DEL),
    ReqParams = get_request_parameters(delete, Key),
    invoke(ReqParams#req_params.redundancies,
           leo_storage_handler_object,
           delete,
           [#object{addr_id   = ReqParams#req_params.addr_id,
                    key       = Key,
                    timestamp = ReqParams#req_params.timestamp},
            ReqParams#req_params.req_id],
           []).


%% @doc Insert an object into the storage-cluster (regular-case)
%%
-spec(put(binary(), binary(), integer()) ->
             ok|{error, any()}).
put(Key, Body, Size) ->
    put(Key, Body, Size, 0, 0, 0, 0).

%% @doc Insert an object into the storage-cluster (child of chunked-object)
%%
-spec(put(binary(), binary(), integer(), integer()) ->
             ok|{error, any()}).
put(Key, Body, Size, Index) ->
    put(Key, Body, Size, 0, 0, Index, 0).

%% @doc Insert an object into the storage-cluster (parent of chunked-object)
%%
-spec(put(binary(), binary(), integer(), integer(), integer(), integer()) ->
             ok|{error, any()}).
put(Key, Body, Size, ChunkedSize, TotalOfChunks, Digest) ->
    put(Key, Body, Size, ChunkedSize, TotalOfChunks, 0, Digest).

%% @doc Insert an object into the storage-cluster
%%
-spec(put(binary(), binary(), integer(), integer(), integer(), integer(), integer()) ->
             ok|{error, any()}).
put(Key, Body, Size, ChunkedSize, TotalOfChunks, ChunkIndex, Digest) ->
    _ = leo_statistics_req_counter:increment(?STAT_REQ_PUT),
    ReqParams = get_request_parameters(put, Key),

    invoke(ReqParams#req_params.redundancies,
           leo_storage_handler_object,
           put,
           [#object{addr_id   = ReqParams#req_params.addr_id,
                    key       = Key,
                    data      = Body,
                    dsize     = Size,
                    timestamp = ReqParams#req_params.timestamp,
                    csize     = ChunkedSize,
                    cnumber   = TotalOfChunks,
                    cindex    = ChunkIndex,
                    checksum  = Digest
                   },
            ReqParams#req_params.req_id],
           []).


%% @doc Do invoke rpc calls with handling retries
%%
-spec(invoke(list(), atom(), atom(), list(), list()) ->
             ok|{ok, any()}|{error, any()}).
invoke([], _Mod, _Method, _Args, Errors) ->
    {error, error_filter(Errors)};
invoke([{_, false}|T], Mod, Method, Args, Errors) ->
    invoke(T, Mod, Method, Args, [?ERR_TYPE_INTERNAL_ERROR|Errors]);
invoke([{Node, true}|T], Mod, Method, Args, Errors) ->
    Timeout = timeout(Method, Args),
    case leo_rpc:call(Node, Mod, Method, Args, Timeout) of
        %% delete
        ok ->
            ok;
        %% put
        {ok, {etag, ETag}} ->
            {ok, ETag};
        %% get-1
        {ok, Meta, Bin} ->
            {ok, Meta, Bin};
        %% get-2
        {ok, match} ->
            {ok, match};
        %% head
        {ok, Meta} ->
            {ok, Meta};
        %% error
        Error ->
            E = handle_error(Node, Mod, Method, Args, Error),
            invoke(T, Mod, Method, Args, [E|Errors])
    end.


%% @doc Get request parameters
%%
-spec(get_request_parameters(method(), string()) ->
             #req_params{}).
get_request_parameters(Method, Key) ->
    {ok, #redundancies{id = Id, nodes = Redundancies}} =
        leo_redundant_manager_api:get_redundancies_by_key(Method, Key),

    UnivDateTime = erlang:universaltime(),
    {_,_,NowPart} = erlang:now(),
    {{Y,MO,D},{H,MI,S}} = UnivDateTime,

    ReqId = erlang:phash2([Y,MO,D,H,MI,S, erlang:node(), Key, NowPart]),
    Timestamp = calendar:datetime_to_gregorian_seconds(UnivDateTime),

    #req_params{addr_id      = Id,
                redundancies = Redundancies,
                req_id       = ReqId,
                timestamp    = Timestamp}.


%% @doc Error messeage filtering
%%
error_filter([not_found = Error|_T])       -> Error;
error_filter([H|T])                        -> error_filter(T, H).
error_filter([],                     Prev) -> Prev;
error_filter([not_found = Error|_T],_Prev) -> Error;
error_filter([_H|T],                 Prev) -> error_filter(T, Prev).


%% @doc Handle an error response
%%
handle_error(_Node, _Mod, _Method, _Args, {error, not_found = Error}) ->
    Error;
handle_error(Node, Mod, Method, _Args, {error, Cause}) ->
    ?warn("handle_error/5", "node:~w, mod:~w, method:~w, cause:~p",
          [Node, Mod, Method, Cause]),
    ?ERR_TYPE_INTERNAL_ERROR;
handle_error(Node, Mod, Method, _Args, {badrpc, timeout}) ->
    ?warn("handle_error/5", "node:~w, mod:~w, method:~w, cause:~p",
          [Node, Mod, Method, timeout]),
    timeout;
handle_error(Node, Mod, Method, _Args, {badrpc, Cause}) ->
    ?warn("handle_error/5", "node:~w, mod:~w, method:~w, cause:~p",
          [Node, Mod, Method, Cause]),
    ?ERR_TYPE_INTERNAL_ERROR.


%% @doc Timeout depends on length of an object
%%
timeout(Len) when ?TIMEOUT_L1_LEN > Len -> ?env_timeout_level_1();
timeout(Len) when ?TIMEOUT_L2_LEN > Len -> ?env_timeout_level_2();
timeout(Len) when ?TIMEOUT_L3_LEN > Len -> ?env_timeout_level_3();
timeout(Len) when ?TIMEOUT_L4_LEN > Len -> ?env_timeout_level_4();
timeout(_)                              -> ?env_timeout_level_5().

timeout(put, [#object{dsize = DSize}, _]) ->
    timeout(DSize);
timeout(get, _) ->
    ?DEF_REQ_TIMEOUT;
timeout(_, _) ->
    ?DEF_REQ_TIMEOUT.
