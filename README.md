gen_zmq - ØMQ in pure Erlang
============================

gen_zmq implements the ØMQ protocol in 100% pure Erlang.

Motivation
----------

ØMQ is like Erlang message passing for the rest of the world without the
overhead of a C-Node. So using it to talk to rest of the World seems like
a good idea. Several Erlang wrappers for the C++ referenz implemention do
exist. So why reinvent the wheel in Erlang?
First, because we can ;-), secondly, when using the C++ implementation we
encountered several segfault taking down the entire Erlang VM and most
importantly, the whole concept is so erlangish, that it feels like it has
to be implemented in Erlang itself.

Main features
-------------

* ØMQ compatible
* 100% Erlang
* good fault isolation (a crash in the message decoder won't take down
  your Erlang VM)
* API very similar to other socket interfaces
* runs on non SMP and SMP VM

TODO:
-----

* documentation
* identity support
* send queue improvements
* high water marks for send queue
