%%%-------------------------------------------------------------------
%%% @author Alexander Hudich (alttagil@gmail.com)
%%% @copyright (C) 2015, Alexander Hudich
%%% @doc
%%% mongoc internal module for handling server's connection pool and monitoring
%%% @end
%%%-------------------------------------------------------------------
-module(mc_server).
-author("alttagil@gmail.com").

-behaviour(gen_server).

-include("mongoc.hrl").

%% API
-export([start_link/4, start/4, get_pool/1, update_ismaster/2, update_unknown/1]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state,
{
  host, port,
  rs = undefined,
  type = undefined,
  me,
  size :: integer(),
  max_overflow :: integer(),
  connect_to,
  socket_to,
  topology,
  topology_mref,
  topology_opts = [],
  worker_opts = [],
  ismaster = undefined,
  monitor = undefined,
  pool = undefined
}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Topology, HostPort, Topts, Wopts) ->
  gen_server:start_link(?MODULE, [Topology, HostPort, Topts, Wopts], []).

start(Topology, HostPort, Topts, Wopts) ->
  gen_server:start(?MODULE, [Topology, HostPort, Topts, Wopts], []).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Topology, Addr, TopologyOptions, Wopts]) ->
  process_flag(trap_exit, true),
  {Host, Port} = parse_seed(Addr),
  PoolSize = mc_utils:get_value(pool_size, TopologyOptions, 10),
  Overflow = mc_utils:get_value(max_overflow, TopologyOptions, 10),
  ConnectTimeoutMS = mc_utils:get_value(connectTimeoutMS, TopologyOptions, 20000),
  SocketTimeoutMS = mc_utils:get_value(socketTimeoutMS, TopologyOptions, 100),
  ReplicaSet = mc_utils:get_value(rs, TopologyOptions, undefined),
  MRef = erlang:monitor(process, Topology),
  gen_server:cast(self(), init_monitor),
  {ok, #state{
    topology = Topology,
    topology_mref = MRef,
    host = Host,
    port = Port,
    rs = ReplicaSet,
    size = PoolSize,
    max_overflow = Overflow,
    connect_to = ConnectTimeoutMS,
    socket_to = SocketTimeoutMS,
    topology_opts = TopologyOptions,
    worker_opts = Wopts
  }}.


terminate(_Reason, #state{topology = Topology}) ->
  mc_topology:drop_server(Topology, self()),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


%%%===================================================================
%%% External functions
%%%===================================================================

get_pool(Pid) ->
  gen_server:call(Pid, get_pool).

update_ismaster(Pid, {Type, IsMaster}) ->
  gen_server:cast(Pid, {update_ismaster, Type, IsMaster}).

update_unknown(Pid) ->
  gen_server:cast(Pid, {update_unknown}).

%%%===================================================================
%%% Handlers
%%%===================================================================

handle_call(get_pool, _From, State = #state{type = unknown}) ->
  error_logger:info_msg("mongo ~p server get pool error", [self()]),
  {reply, {error, server_unknown}, State};
handle_call(get_pool, _From, State = #state{ismaster = undefined}) ->
  error_logger:info_msg("mongo ~p server get pool unknown", [self()]),
  {reply, {error, server_unknown}, State};
handle_call(get_pool, _From, State = #state{pool = undefined}) ->
  error_logger:info_msg("mongo ~p server init pool", [self()]),
  Pid = init_pool(State),
  {reply, Pid, State#state{pool = Pid}};
handle_call(get_pool, _From, State = #state{pool = Pid}) ->
  error_logger:info_msg("mongo ~p server get pool return", [self()]),
  {reply, Pid, State};
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast(init_monitor, State) ->
  {ok, Pid} = init_monitor(State),
  {noreply, State#state{monitor = Pid}};
handle_cast(start_pool, State = #state{pool = undefined}) ->
  Pid = init_pool(State),
  {noreply, State#state{pool = Pid}};
handle_cast({update_ismaster, Type, IsMaster}, State = #state{monitor = undefined}) ->
  {noreply, State#state{type = Type, ismaster = IsMaster}};
handle_cast({update_ismaster, Type, IsMaster}, State = #state{monitor = Monitor}) ->
  mc_monitor:update_type(Monitor, Type),
  {noreply, State#state{type = Type, ismaster = IsMaster}};
handle_cast({update_unknown}, State = #state{monitor = Monitor, pool = undefined}) ->
  mc_monitor:update_type(Monitor, unknown),
  {noreply, State#state{pool = undefined, type = unknown, ismaster = undefined}};
handle_cast({update_unknown}, State = #state{monitor = Monitor, pool = Pool}) ->
  erlang:unlink(Pool),
  erlang:exit(Pool, kill),
  mc_monitor:update_type(Monitor, unknown),
  {noreply, State#state{pool = undefined, type = unknown, ismaster = undefined}};
handle_cast(_Request, State) ->
  {noreply, State}.

handle_info({'DOWN', MRef, _, _, Reason}, State = #state{topology_mref = MRef, monitor = Pid, pool = Pool}) ->
  mc_pool_sup:stop_pool(Pool),
  mc_monitor:stop(Pid),
  {stop, Reason, State};
handle_info({'EXIT', Pid, _Reason}, State = #state{topology = Topology, pool = Pid}) ->
  gen_server:cast(Topology, {server_to_unknown, self()}),
  {noreply, State#state{pool = undefined}};
handle_info({'EXIT', Pid, _Reason}, State = #state{monitor = Pid, pool = Pool}) ->
  mc_pool_sup:stop_pool(Pool),
  mc_monitor:stop(Pid),
  {stop, normal, State};
handle_info(_Info, State) ->
  {noreply, State}.


%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private
init_monitor(#state{topology = Topology, host = Host, port = Port, topology_opts = Topts, worker_opts = Wopts}) ->
  mc_monitor:start_link(Topology, self(), {Host, Port}, Topts, Wopts).

%% @private
init_pool(#state{host = Host, port = Port, size = Size, max_overflow = Overflow, worker_opts = Wopts}) ->
  WO = lists:append([{host, Host}, {port, Port}], Wopts),
  {ok, Child} = mc_pool_sup:start_pool([{size, Size}, {max_overflow, Overflow}], WO),
  link(Child),
  Child.

%% @private
parse_seed(Addr) when is_binary(Addr) ->
  parse_seed(binary_to_list(Addr));
parse_seed(Addr) when is_list(Addr) ->
  [Host, Port] = string:tokens(Addr, ":"),
  {Host, list_to_integer(Port)}.