% Copyright 2010-2011, Travelping GmbH <info@travelping.com>

% Permission is hereby granted, free of charge, to any person obtaining a
% copy of this software and associated documentation files (the "Software"),
% to deal in the Software without restriction, including without limitation
% the rights to use, copy, modify, merge, publish, distribute, sublicense,
% and/or sell copies of the Software, and to permit persons to whom the
% Software is furnished to do so, subject to the following conditions:

% The above copyright notice and this permission notice shall be included in
% all copies or substantial portions of the Software.

% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
% DEALINGS IN THE SOFTWARE.

-module(gen_zmq).

-behaviour(gen_server).

%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------
-include("gen_zmq_debug.hrl").
-include("gen_zmq_internal.hrl").

%% API scheduler
-export([start_link/1, start/1, socket_link/1, socket/1]).
-export([bind/4, connect/4, connect/5, close/1]).
-export([recv/1, recv/2]).
-export([send/2]).
-export([setopts/2]).

%% Internal exports
-export([deliver_recv/2, deliver_accept/2, deliver_connect/2, deliver_close/1]).
-export([simple_encap_msg/1, simple_decap_msg/1, lb/2]).
-export([remote_id_assign/1, remote_id_exists/2, transports_get/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
		 terminate/2, code_change/3]).

-define(SERVER, ?MODULE). 
-define(port(P), (((P) band bnot 16#ffff) =:= 0)).
-record(cargs, {family, address, port, tcpopts, timeout, failcnt}).

-ifdef(debug).
-define(SERVER_OPTS,{debug,[trace]}).
-else.
-define(SERVER_OPTS,).
-endif.

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------

start_link(Opts) when is_list(Opts) ->
	gen_server:start_link(?MODULE, {self(), Opts}, [?SERVER_OPTS]).
start(Opts) when is_list(Opts) ->
	gen_server:start(?MODULE, {self(), Opts}, [?SERVER_OPTS]).

socket_link(Opts) when is_list(Opts) ->
	start_link(Opts).
socket(Opts) when is_list(Opts) ->
	start(Opts).

bind(Socket, tcp, Port, Opts) when ?port(Port) ->
	Valid = case proplists:get_value(ip, Opts) of
				undefined -> {ok, undef};
				Address   -> validate_address(Address)
			end,

	%%TODO: socket options
	case Valid of
		{ok, _} -> gen_server:call(Socket, {bind, tcp, Port, Opts});
		Res     -> Res
	end;

bind(Socket, unix, Path, Opts) ->
	%%TODO: socket options
	gen_server:call(Socket, {bind, unix, Path, Opts}).

connect(Socket, tcp, Address, Port, Opts) when ?port(Port) ->
	Valid = validate_address(Address),
	case Valid of
		{ok, _} -> gen_server:call(Socket, {connect, tcp, Address, Port, Opts});
		Res     -> Res
	end.

connect(Socket, unix, Path, Opts) ->
	gen_server:call(Socket, {connect, unix, Path, Opts}).

close(Socket) ->
	gen_server:call(Socket, close).

send(Socket, Msg) when is_pid(Socket), is_list(Msg) ->
	gen_server:call(Socket, {send, Msg}, infinity);

send(Socket, Msg = {_Identity, Parts})
  when is_pid(Socket), is_list(Parts) ->
	gen_server:call(Socket, {send, Msg}, infinity).

recv(Socket) ->
	gen_server:call(Socket, {recv, infinity}, infinity).

recv(Socket, Timeout) ->
	gen_server:call(Socket, {recv, Timeout}, infinity).

setopts(Socket, Opts) ->
	gen_server:call(Socket, {setopts, Opts}).

deliver_recv(Socket, IdMsg) ->
	gen_server:cast(Socket, {deliver_recv, self(), IdMsg}).

deliver_accept(Socket, RemoteId) ->
	gen_server:cast(Socket, {deliver_accept, self(), RemoteId}).

deliver_connect(Socket, Reply) ->
	gen_server:cast(Socket, {deliver_connect, self(), Reply}).

deliver_close(Socket) ->
	gen_server:cast(Socket, {deliver_close, self()}).

%%
%% load balance sending sockets
%% - simple round robin 
%%
%% CHECK: is 0MQ actually doing anything else?
%%
lb(Transports, MqSState = #gen_zmq_socket{transports = Trans}) when is_list(Transports) ->
	Trans1 = lists:subtract(Trans, Transports) ++ Transports,
	MqSState#gen_zmq_socket{transports = Trans1};

lb(Transport, MqSState = #gen_zmq_socket{transports = Trans}) ->
	Trans1 = lists:delete(Transport, Trans) ++ [Transport],
	MqSState#gen_zmq_socket{transports = Trans1}.

%% transport helpers
transports_get(Pid, _) when is_pid(Pid) ->
	Pid;
transports_get(RemoteId, #gen_zmq_socket{remote_ids = RemIds}) ->
	case orddict:find(RemoteId, RemIds) of
		{ok, Pid} -> Pid;
		_        -> none
	end.

remote_id_assign(<<>>) ->
	make_ref();
remote_id_assign(Id) when is_binary(Id) ->
	Id.

remote_id_exists(<<>>, #gen_zmq_socket{}) ->
	false;
remote_id_exists(RemoteId, #gen_zmq_socket{remote_ids = RemIds}) ->
	orddict:is_key(RemoteId, RemIds).

remote_id_add(Transport, RemoteId, MqSState = #gen_zmq_socket{remote_ids = RemIds}) ->
	MqSState#gen_zmq_socket{remote_ids = orddict:store(RemoteId, Transport, RemIds)}.

remote_id_del(Transport, MqSState = #gen_zmq_socket{remote_ids = RemIds}) when is_pid(Transport) ->
	MqSState#gen_zmq_socket{remote_ids = orddict:filter(fun(_Key, Value) -> Value /= Transport end, RemIds)};
remote_id_del(RemoteId, MqSState = #gen_zmq_socket{remote_ids = RemIds}) ->
	MqSState#gen_zmq_socket{remote_ids = orddict:erase(RemoteId, RemIds)}.

transports_is_active(Transport, #gen_zmq_socket{transports = Transports}) ->
	lists:member(Transport, Transports).

transports_activate(Transport, RemoteId, MqSState = #gen_zmq_socket{transports = Transports}) ->
	MqSState1 = remote_id_add(Transport, RemoteId, MqSState),
	MqSState1#gen_zmq_socket{transports = [Transport|Transports]}.

transports_deactivate(Transport, MqSState = #gen_zmq_socket{transports = Transports}) ->
	MqSState1 = remote_id_del(Transport, MqSState),
	MqSState1#gen_zmq_socket{transports = lists:delete(Transport, Transports)}.

transports_while(Fun, Data, Default, #gen_zmq_socket{transports = Transports}) ->
	do_transports_while(Fun, Data, Transports, Default).

transports_connected(#gen_zmq_socket{transports = Transports}) ->
	Transports /= [].

%% walk the list of transports
%% this is intended to hide the details of the transports impl.
do_transports_while(_Fun, _Data, [], Default) ->
	Default;
do_transports_while(Fun, Data, [Head|Rest], Default) ->
	case Fun(Head, Data) of
		continue -> do_transports_while(Fun, Data, Rest, Default);
		Resp     -> Resp
	end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
socket_types(Type) ->
	SupMod = [{req, gen_zmq_socket_req}, {rep, gen_zmq_socket_rep},
			  {dealer, gen_zmq_socket_dealer}, {router, gen_zmq_socket_router},
			  {pub, gen_zmq_socket_pub}, {sub, gen_zmq_socket_sub}],
	proplists:get_value(Type, SupMod).
			
init({Owner, Opts}) ->
	case socket_types(proplists:get_value(type, Opts, req)) of
		undefined ->
			{stop, invalid_opts};
		Type ->
			init_socket(Owner, Type, Opts)
	end.

init_socket(Owner, Type, Opts) ->
	process_flag(trap_exit, true),
	MqSState0 = #gen_zmq_socket{owner = Owner, mode = passive, recv_q = orddict:new(),
								connecting = orddict:new(), listen_trans = orddict:new(), transports = [], remote_ids = orddict:new()},
	MqSState1 = lists:foldl(fun do_setopts/2, MqSState0, proplists:unfold(Opts)),
	gen_zmq_socket_fsm:init(Type, Opts, MqSState1).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({bind, tcp, Port, Opts}, _From, MqSState = #gen_zmq_socket{identity = Identity}) ->
	TcpOpts0 = [binary,inet, {active,false}, {send_timeout,5000}, {backlog,10}, {nodelay,true}, {packet,raw}, {reuseaddr,true}],
	TcpOpts1 = case proplists:get_value(ip, Opts) of
				   undefined -> TcpOpts0;
				   I -> [{ip, I}|TcpOpts0]
			   end,
	?DEBUG("bind: ~p~n", [TcpOpts1]),
	case gen_zmq_tcp_socket:start_link(Identity, Port, TcpOpts1) of
		{ok, Pid} ->
			Listen = orddict:append(Pid, {tcp, Port, Opts}, MqSState#gen_zmq_socket.listen_trans),
			{reply, ok, MqSState#gen_zmq_socket{listen_trans = Listen}};
		Reply ->
			{reply, Reply, MqSState}
	end;

handle_call({bind, unix, Path, Opts}, _From, MqSState = #gen_zmq_socket{identity = Identity}) ->
	TcpOpts0 = [binary, {active,false}, {send_timeout,5000}, {backlog,10}, {nodelay,true}, {packet,raw}, {reuseaddr,true}],
	?DEBUG("bind: ~p~n", [TcpOpts0]),

    {ok, Fd} = gen_socket:socket(unix, stream, 0),
    case gen_socket:bind(Fd, gen_socket:sockaddr_unix(Path)) of
		ok -> case gen_zmq_tcp_socket:start_link(Identity, 0, [{fd, Fd}|TcpOpts0]) of
				  {ok, Pid} ->
					  Listen = orddict:append(Pid, {unix, Path, Opts}, MqSState#gen_zmq_socket.listen_trans),
					  {reply, ok, MqSState#gen_zmq_socket{listen_trans = Listen}};
				  Reply ->
					  {reply, Reply, MqSState}
			  end;
		Reply ->
			{reply, Reply, MqSState}
	end;

handle_call({connect, tcp, Address, Port, Opts}, _From, State) ->
	TcpOpts = [binary, inet, {active,false}, {send_timeout,5000}, {nodelay,true}, {packet,raw}, {reuseaddr,true}],
	Timeout = proplists:get_value(timeout, Opts, 5000),
	ConnectArgs = #cargs{family = tcp, address = Address, port = Port, tcpopts = TcpOpts,
						 timeout = Timeout, failcnt = 0},
	NewState = do_connect(ConnectArgs, State),
	{reply, ok, NewState};

handle_call({connect, unix, Path, Opts}, _From, State) ->
	TcpOpts = [binary, {active,false}, {send_timeout,5000}, {nodelay,true}, {packet,raw}, {reuseaddr,true}],
	Timeout = proplists:get_value(timeout, Opts, 5000),
	ConnectArgs = #cargs{family = unix, address = Path, tcpopts = TcpOpts,
						 timeout = Timeout, failcnt = 0},
	NewState = do_connect(ConnectArgs, State),
	{reply, ok, NewState};

handle_call(close, _From, State) ->
	{stop, normal, ok, State};

handle_call({recv, _Timeout}, _From, #gen_zmq_socket{mode = Mode} = State)
  when Mode /= passive ->
	{reply, {error, active}, State};
handle_call({recv, _Timeout}, _From, #gen_zmq_socket{pending_recv = PendingRecv} = State)
  when PendingRecv /= none ->
	Reply = {error, already_recv},
	{reply, Reply, State};
handle_call({recv, Timeout}, From, State) ->
	handle_recv(Timeout, From, State);

handle_call({send, Msg}, From, State) ->
	case gen_zmq_socket_fsm:check({send, Msg}, State) of
		{queue, Action} ->
			%%TODO: HWM and swap to disk....
			State1 = State#gen_zmq_socket{send_q = State#gen_zmq_socket.send_q ++ [Msg]},
			State2 = gen_zmq_socket_fsm:do(queue_send, State1),
			case Action of
				return ->
					State3 = check_send_queue(State2),
					{reply, ok, State3};
				block  ->
					State3 = State2#gen_zmq_socket{pending_send = From},
					State4 = check_send_queue(State3),
					{noreply, State4}
			end;
		{drop, Reply} ->
			{reply, Reply, State};
		{error, Reason} ->
			{reply, {error, Reason}, State};
		{ok, Transports} ->
			gen_zmq_link_send({Transports, Msg}, State),
			State1 = gen_zmq_socket_fsm:do({deliver_send, Transports}, State),
			State2 = queue_run(State1),
			{reply, ok, State2}
	end;

handle_call({setopts, Opts}, _From, State) ->
	NewState = lists:foldl(fun do_setopts/2, State, proplists:unfold(Opts)),
	{reply, ok, NewState}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_cast({deliver_accept, Transport, RemoteId}, State) ->
	link(Transport),
	State1 = transports_activate(Transport, RemoteId, State),
	?DEBUG("DELIVER_ACCPET: ~p~n", [State1]),
	State2 = send_queue_run(State1),
	{noreply, State2};

handle_cast({deliver_connect, Transport, {ok, RemoteId}}, State) ->
	State1 = transports_activate(Transport, RemoteId, State),
	State2 = send_queue_run(State1),
	{noreply, State2};

handle_cast({deliver_connect, Transport, Reply}, State = #gen_zmq_socket{connecting = Connecting}) ->
	case Reply of
		%% transient errors
		{error, Reason} when Reason == eagain; Reason == ealready;
							 Reason == econnrefused; Reason == econnreset ->
			ConnectArgs = orddict:fetch(Transport, Connecting),
			?DEBUG("CArgs: ~w~n", [ConnectArgs]),
			erlang:send_after(3000, self(), {reconnect, ConnectArgs#cargs{failcnt = ConnectArgs#cargs.failcnt + 1}}),
			State2 = State#gen_zmq_socket{connecting = orddict:erase(Transport, Connecting)},
			{noreply, State2};
		_ ->
			State1 = State#gen_zmq_socket{connecting = orddict:erase(Transport, Connecting)},
			State2 = check_send_queue(State1),
			{noreply, State2}
	end;

handle_cast({deliver_close, Transport}, State = #gen_zmq_socket{connecting = Connecting}) ->
	unlink(Transport),
	State0 = transports_deactivate(Transport, State),
	State1 = queue_close(Transport, State0),
	State2 = gen_zmq_socket_fsm:close(Transport, State1),
	State3 = case orddict:find(Transport, Connecting) of 
				 {ok, ConnectArgs} ->
					 erlang:send_after(3000, self(), {reconnect, ConnectArgs#cargs{failcnt = 0}}),
					 State2#gen_zmq_socket{connecting =orddict:erase(Transport, Connecting)};
				 _ ->
					 check_send_queue(State2)
			 end,
	State4 = queue_run(State3),
	?DEBUG("DELIVER_CLOSE: ~p~n", [State4]),
	{noreply, State3};

handle_cast({deliver_recv, Transport, IdMsg}, State) ->
	handle_deliver_recv(Transport, IdMsg, State);

handle_cast(_Msg, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(recv_timeout, #gen_zmq_socket{pending_recv = {From, _}} = State) ->
	gen_server:reply(From, {error, timeout}),
	State1 = State#gen_zmq_socket{pending_recv = none},
	{noreply, State1};

handle_info({reconnect, ConnectArgs}, #gen_zmq_socket{} = State) ->
	NewState = do_connect(ConnectArgs, State),
	{noreply, NewState};

handle_info({'EXIT', Pid, _Reason}, MqSState) ->
	case transports_is_active(Pid, MqSState) of
		true ->
			handle_cast({deliver_close, Pid}, MqSState);
		_ ->
			{noreply, MqSState}
	end;

handle_info(_Info, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
	ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

do_connect(ConnectArgs = #cargs{family = tcp}, MqSState = #gen_zmq_socket{identity = Identity}) ->
	?DEBUG("starting connect: ~w~n", [ConnectArgs]),
	#cargs{address = Address, port = Port, tcpopts = TcpOpts,
		   timeout = Timeout, failcnt = _FailCnt} = ConnectArgs,
	{ok, Transport} = gen_zmq_link:start_connection(),
	gen_zmq_link:connect(Identity, Transport, tcp, Address, Port, TcpOpts, Timeout),
	Connecting = orddict:store(Transport, ConnectArgs, MqSState#gen_zmq_socket.connecting),
	MqSState#gen_zmq_socket{connecting = Connecting};

do_connect(ConnectArgs = #cargs{family = unix}, MqSState = #gen_zmq_socket{identity = Identity}) ->
	?DEBUG("starting connect: ~w~n", [ConnectArgs]),
	#cargs{address = Path, tcpopts = TcpOpts,
		   timeout = Timeout, failcnt = _FailCnt} = ConnectArgs,
	{ok, Transport} = gen_zmq_link:start_connection(),
	gen_zmq_link:connect(Identity, Transport, unix, Path, TcpOpts, Timeout),
	Connecting = orddict:store(Transport, ConnectArgs, MqSState#gen_zmq_socket.connecting),
	MqSState#gen_zmq_socket{connecting = Connecting}.

check_send_queue(MqSState = #gen_zmq_socket{send_q = []}) ->
	MqSState;
check_send_queue(MqSState = #gen_zmq_socket{connecting = Connecting, listen_trans = Listen}) ->
	case {transports_connected(MqSState), orddict:size(Connecting), orddict:size(Listen)} of
		{false, 0, 0} -> clear_send_queue(MqSState);
		_             -> MqSState
	end.

clear_send_queue(State = #gen_zmq_socket{send_q = []}) ->
	State;
clear_send_queue(State = #gen_zmq_socket{send_q = [_Msg], pending_send = From})
  when From /= none ->
	gen_server:reply(From, {error, no_connection}),
	State1 = gen_zmq_socket_fsm:do({deliver_send, abort}, State),
	State1#gen_zmq_socket{send_q = [], pending_send = none};

clear_send_queue(State = #gen_zmq_socket{send_q = [_Msg|Rest]}) ->
	State1 = gen_zmq_socket_fsm:do({deliver_send, abort}, State),
	clear_send_queue(State1#gen_zmq_socket{send_q = Rest}).

send_queue_run(State = #gen_zmq_socket{send_q = []}) ->
	State;
send_queue_run(State = #gen_zmq_socket{send_q = [Msg], pending_send = From})
  when From /= none ->
	case gen_zmq_socket_fsm:check(dequeue_send, State) of
		{ok, Transports} ->
			gen_zmq_link_send({Transports, Msg}, State),
			State1 = gen_zmq_socket_fsm:do({deliver_send, Transports}, State),
			gen_server:reply(From, ok),
			State1#gen_zmq_socket{send_q = [], pending_send = none};
		_ ->
			State
	end;
send_queue_run(State = #gen_zmq_socket{send_q = [Msg|Rest]}) ->
	case gen_zmq_socket_fsm:check(dequeue_send, State) of
		{ok, Transports} ->
			gen_zmq_link_send({Transports, Msg}, State),
			State1 = gen_zmq_socket_fsm:do({deliver_send, Transports}, State),
			send_queue_run(State1#gen_zmq_socket{send_q = Rest});
		_ ->
			State
	end.
	
%% check if should deliver the 'top of queue' message
queue_run(State) ->
	case gen_zmq_socket_fsm:check(deliver, State) of
		ok -> queue_run_2(State);
		_ -> State
	end.
queue_run_2(#gen_zmq_socket{mode = Mode} = State)
  when Mode == active; Mode == active_once ->
	run_recv_q(State);
queue_run_2(#gen_zmq_socket{pending_recv = {_From, _Ref}} = State) ->
	run_recv_q(State);
queue_run_2(#gen_zmq_socket{mode = passive} = State) ->
	State.

run_recv_q(State) ->
	case dequeue(State) of
		{{Transport, IdMsg}, State0} ->
			send_owner(Transport, IdMsg, State0);
		_ ->
			State
	end.

%% send a specific message to the owner
send_owner(Transport, IdMsg, #gen_zmq_socket{pending_recv = {From, Ref}} = State) ->
	case Ref of
		none -> ok;
		_ -> erlang:cancel_timer(Ref)
	end,
	State1 = State#gen_zmq_socket{pending_recv = none},
	gen_server:reply(From, {ok, gen_zmq_socket_fsm:decap_msg(Transport, IdMsg, State)}),
	gen_zmq_socket_fsm:do({deliver, Transport}, State1);
send_owner(Transport, IdMsg, #gen_zmq_socket{owner = Owner, mode = Mode} = State)
  when Mode == active; Mode == active_once ->
	Owner ! {zmq, self(), gen_zmq_socket_fsm:decap_msg(Transport, IdMsg, State)},
	NewState = gen_zmq_socket_fsm:do({deliver, Transport}, State),
	next_mode(NewState).

next_mode(#gen_zmq_socket{mode = active} = State) ->
	queue_run(State);
next_mode(#gen_zmq_socket{mode = active_once} = State) ->
	State#gen_zmq_socket{mode = passive}.

handle_deliver_recv(Transport, IdMsg, MqSState) ->
	?DEBUG("deliver_recv: ~w, ~w~n", [Transport, IdMsg]),
	case gen_zmq_socket_fsm:check({deliver_recv, Transport}, MqSState) of
		ok ->
			MqSState0 = handle_deliver_recv_2(Transport, IdMsg, queue_size(MqSState), MqSState),
			{noreply, MqSState0};
		{error, _Reason} ->
			{noreply, MqSState}
	end.

handle_deliver_recv_2(Transport, IdMsg, 0, #gen_zmq_socket{mode = Mode} = MqSState)
  when Mode == active; Mode == active_once ->
	case gen_zmq_socket_fsm:check(deliver, MqSState) of
		ok -> send_owner(Transport, IdMsg, MqSState);
		_ -> queue(Transport, IdMsg, MqSState)
	end;

handle_deliver_recv_2(Transport, IdMsg, 0, #gen_zmq_socket{pending_recv = {_From, _Ref}} = MqSState) ->
	case gen_zmq_socket_fsm:check(deliver, MqSState) of
		ok -> send_owner(Transport, IdMsg, MqSState);
		_ -> queue(Transport, IdMsg, MqSState)
	end;

handle_deliver_recv_2(Transport, IdMsg, _, MqSState) ->
	queue(Transport, IdMsg, MqSState).

handle_recv(Timeout, From, MqSState) ->
	case gen_zmq_socket_fsm:check(recv, MqSState) of
		{error, Reason} ->
			{reply, {error, Reason}, MqSState};
		ok ->
			handle_recv_2(Timeout, From, queue_size(MqSState), MqSState)
	end.

handle_recv_2(Timeout, From, 0, State) ->
	Ref = case Timeout of
			  infinity -> none;
			  _ -> erlang:send_after(Timeout, self(), recv_timeout)
		  end,
	State1 = State#gen_zmq_socket{pending_recv = {From, Ref}},
	{noreply, State1};

handle_recv_2(_Timeout, _From, _, State) ->
	case dequeue(State) of
		{{Transport, IdMsg}, State0} ->
			State2 = gen_zmq_socket_fsm:do({deliver, Transport}, State0),
			{reply, {ok, gen_zmq_socket_fsm:decap_msg(Transport, IdMsg, State)}, State2};
		_ ->
			{reply, {error, internal}, State}
	end.

simple_encap_msg(Msg) when is_list(Msg) ->
	lists:map(fun(M) -> {normal, M} end, Msg).
simple_decap_msg(Msg) when is_list(Msg) ->
	lists:reverse(lists:foldl(fun({normal, M}, Acc) -> [M|Acc]; (_, Acc) -> Acc end, [], Msg)).
					   
gen_zmq_link_send({Transports, Msg}, State)
  when is_list(Transports) ->
	lists:foreach(fun(T) ->
						  Msg1 = gen_zmq_socket_fsm:encap_msg({T, Msg}, State),
						  gen_zmq_link:send(T, Msg1)
				  end, Transports);
gen_zmq_link_send({Transport, Msg}, State) ->
	gen_zmq_link:send(Transport, gen_zmq_socket_fsm:encap_msg({Transport, Msg}, State)).

%%
%% round robin queue
%%

queue_size(#gen_zmq_socket{recv_q = Q}) ->
	orddict:size(Q).

queue(Transport, Value, MqSState = #gen_zmq_socket{recv_q = Q}) ->
	Q1 = orddict:update(Transport, fun(V) -> queue:in(Value, V) end,
						queue:from_list([Value]), Q),
	MqSState1 = MqSState#gen_zmq_socket{recv_q = Q1},
	gen_zmq_socket_fsm:do({queue, Transport}, MqSState1).

queue_close(Transport, MqSState = #gen_zmq_socket{recv_q = Q}) ->
	Q1 = orddict:erase(Transport, Q),
	MqSState#gen_zmq_socket{recv_q = Q1}.
	
dequeue(MqSState = #gen_zmq_socket{recv_q = Q}) ->
	?DEBUG("TRANS: ~p, PENDING: ~p~n", [MqSState#gen_zmq_socket.transports, Q]),
	case transports_while(fun do_dequeue/2, Q, empty, MqSState) of
		{{Transport, Value}, Q1} ->
			MqSState0 = MqSState#gen_zmq_socket{recv_q = Q1},
			MqSState1 = gen_zmq_socket_fsm:do({dequeue, Transport}, MqSState0),
			MqSState2 = lb(Transport, MqSState1),
			{{Transport, Value}, MqSState2};
		Reply ->
			Reply
	end.

do_dequeue(Transport, Q) ->
	case orddict:find(Transport, Q) of
		{ok, V} ->
			{{value, Value}, V1} = queue:out(V),
			Q1 = case queue:is_empty(V1) of
					 true -> orddict:erase(Transport, Q);
					 false -> orddict:store(Transport, V1, Q)
				 end,
				{{Transport, Value}, Q1};
		_ ->
			continue
	end.

do_setopts({identity, Id}, MqSState) ->
	MqSState#gen_zmq_socket{identity = iolist_to_binary(Id)};
do_setopts({active, once}, MqSState) ->
	run_recv_q(MqSState#gen_zmq_socket{mode = active_once});
do_setopts({active, true}, MqSState) ->
	run_recv_q(MqSState#gen_zmq_socket{mode = active});
do_setopts({active, false}, MqSState) ->
	MqSState#gen_zmq_socket{mode = passive};

do_setopts(_, MqSState) ->
	MqSState.

validate_address(Address) when is_list(Address)  -> inet:gethostbyname(Address);
validate_address(Address) when is_tuple(Address) -> inet:gethostbyaddr(Address);
validate_address(_Address) -> exit(badarg).

