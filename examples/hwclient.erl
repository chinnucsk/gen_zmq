-module(hwclient).

-export([main/0]).

main() ->
	application:start(sasl),
	application:start(gen_listener_tcp),
	application:start(gen_zmq),

	{ok, Socket} = gen_zmq:start([{type, req}]),
	gen_zmq:connect(Socket, {127,0,0,1}, 5555, []),
	loop(Socket, 0).

loop(_Socket, 10) ->
	ok;
loop(Socket, N) ->
	io:format("Sending Hello ~w ...~n",[N]),
	gen_zmq:send(Socket, [<<"Hello",0>>]),
	{ok, R} = gen_zmq:recv(Socket),
	io:format("Received '~s' ~w~n", [R, N]),
	loop(Socket, N+1).
