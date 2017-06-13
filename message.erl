%%%-------------------------------------------------------------------
%%% @author sarunas
%%% @copyright (C) 2017, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 01. Jun 2017 19.36
%%%-------------------------------------------------------------------
-module(message).
-author("sarunas").

%% API
-export([handshake/4, interested/1, not_interested/1, have/1]).


handshake(Ip, Port, Hash, PeerId) ->
  {ok, Socket} = gen_tcp:connect(Ip, Port, [{active,true}, binary], 5000),
  io:format("Opened socket ~p~n", [Socket]),

  gen_tcp:send(Socket, list_to_binary(
    [
      19,
      "BitTorrent protocol",
      0,0,0,0,0,0,0,0,
      Hash,
      PeerId
    ])
  ),
  receive
    {tcp,Socket,Data} ->
      %% @todo patikrinti, ar atitinka handshake responsas mano requestą
      io:format("Received handshake from socket ~p~n", [Socket]),
      interested(Socket),
      {ok, Data}
  after
    5000 -> handshake_not_received
  end.

%% Big endian! "Interested"
interested(Socket) ->
  %% @todo handlinti unchoke
  gen_tcp:send(Socket, <<01, 00, 00, 00, 2>>)
.

%% Big endian! "Not interested"
not_interested(Socket) ->
  gen_tcp:send(Socket, <<01, 00, 00, 00, 3>>)
.

%% Big endian! "Have, Piece 0x202"
have(Socket) ->
    Msg =
      <<
        00, 00, 00, 13,
        6,
        00, 00, 00, 16#64,
        00, 16#28, 16#80, 00,
        00, 00, 16#40, 00,

        00, 00, 00, 13,
        6,
        00, 00, 00, 16#64,
        00, 16#28, 16#c0, 00,
        00, 00, 16#40, 00
      >>
    ,
    gen_tcp:send(Socket, Msg)
.