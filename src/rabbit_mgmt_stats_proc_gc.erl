%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developer of the Original Code is Pivotal Software, Inc.
%%   Copyright (c) 2010-2015 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_mgmt_stats_proc_gc).

-include_lib("rabbit_common/include/rabbit.hrl").
-include("rabbit_mgmt_metrics.hrl").

-behaviour(gen_server2).

-export([start_link/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3, handle_pre_hibernate/1]).

-export([name/1]).

-import(rabbit_misc, [pget/3]).
-import(rabbit_mgmt_db, [pget/2, id_name/1, id/2, lookup_element/2]).

-record(state, {
          interval,
          gc_timer,
          gc_table,
          gc_index,
          gc_next_key
         }).

-define(GC_INTERVAL, 5000).
-define(GC_MIN_ROWS, 50).
-define(GC_MIN_RATIO, 0.001).

-define(PROCESS_ALIVENESS_TIMEOUT, 5000).

%%----------------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------------

start_link(Table) ->
    case gen_server2:start_link({global, name(Table)}, ?MODULE, [Table], []) of
        {ok, Pid} -> register(name(Table), Pid), %% [1]
                     {ok, Pid};
        Else      -> Else
    end.
%% [1] For debugging it's helpful to locally register the name too
%% since that shows up in places global names don't.

%%----------------------------------------------------------------------------
%% Internal, gen_server2 callbacks
%%----------------------------------------------------------------------------

init([Table]) ->
    {ok, Interval} = application:get_env(rabbit, collect_statistics_interval),
    rabbit_log:info("Statistics garbage collector started for table ~p.~n", [{Table, Interval}]),
    {ok, set_gc_timer(#state{interval = Interval,
                             gc_table = Table,
                             gc_index = rabbit_mgmt_stats_tables:key_index(Table)}),
     hibernate,
     {backoff, ?HIBERNATE_AFTER_MIN, ?HIBERNATE_AFTER_MIN, ?DESIRED_HIBERNATE}}.

handle_call(_Request, _From, State) ->
    reply(not_understood, State).

handle_cast(_Request, State) ->
    noreply(State).

handle_info(gc, State) ->
    noreply(set_gc_timer(gc_batch(State)));

handle_info(_Info, State) ->
    noreply(State).

terminate(_Arg, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

reply(Reply, NewState) -> {reply, Reply, NewState, hibernate}.
noreply(NewState) -> {noreply, NewState, hibernate}.

set_gc_timer(State) ->
    TRef = erlang:send_after(?GC_INTERVAL, self(), gc),
    State#state{gc_timer = TRef}.

handle_pre_hibernate(State) ->
    {hibernate, State}.

%%----------------------------------------------------------------------------
%% Internal, utilities
%%----------------------------------------------------------------------------

floor(TS, #state{interval = Interval}) ->
    rabbit_mgmt_util:floor(TS, Interval).

%%----------------------------------------------------------------------------
%% Internal, event-GCing
%%----------------------------------------------------------------------------

gc_batch(#state{gc_index = Index} = State) ->
    {ok, Timeout} = application:get_env(rabbitmq_management,
                                        process_stats_gc_timeout),
    Total = ets:info(Index, size),
    Rows = erlang:max(erlang:min(Total, ?GC_MIN_ROWS), round(?GC_MIN_RATIO * Total)),
    gc_batch(Rows, Timeout, State).

gc_batch(0, _Timeout, State) ->
    State;
gc_batch(Rows, Timeout, State = #state{gc_next_key = Cont,
                                        gc_table = Table,
                                        gc_index = Index}) ->
    Select = case Cont of
                 undefined ->
                     ets:first(Index);
                 _ ->
                     ets:next(Index, Cont)
             end,
    NewCont = case Select of
                  '$end_of_table' ->
                      undefined;
                  Key ->
                      Now = floor(
                              time_compat:os_system_time(milli_seconds),
                              State),
                      gc(Key, Table, Timeout, Now),
                      Key
              end,
    gc_batch(Rows - 1, Timeout, State#state{gc_next_key = NewCont}).


gc(Key, Table, Timeout, Now) ->
    case ets:lookup(Table, {Key, stats}) of
        %% Key is already cleared. Skipping
        []                           -> ok;
        [{{Key, stats}, _Stats, TS}] -> maybe_gc_process(Key, Table,
                                                         TS, Now, Timeout)
    end.

maybe_gc_process(Pid, Table, LastStatsTS, Now, Timeout) ->
    rabbit_log:error("Maybe GC process ~p~n", [{Table, LastStatsTS, Now, Timeout, Pid}]),
    case Now - LastStatsTS < Timeout of
        true  -> ok;
        false ->
            case process_status(Pid) of
                %% Process doesn't exist on remote node
                undefined -> rabbit_log:error("GC process ~p~n", [{Table, Pid}]),
                             rabbit_event:notify(deleted_event(Table),
                                                 [{pid, Pid}]);
                %% Remote node is unreachable or process is alive
                _        -> ok
            end
    end.

process_status(Pid) when node(Pid) =:= node() ->
    process_info(Pid, status);
process_status(Pid) ->
    rpc:block_call(node(Pid), erlang, process_info, [Pid, status],
                   ?PROCESS_ALIVENESS_TIMEOUT).

deleted_event(channel_stats)    -> channel_closed;
deleted_event(connection_stats) -> connection_closed.

name(Atom) ->
    list_to_atom((atom_to_list(Atom) ++ "_gc")).
