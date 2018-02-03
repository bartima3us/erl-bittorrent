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
-export([start/4, data/0]).



%%
%%
%%
start([], _Hash, _PeerId, _FileName) ->
  io:format("There aren't any active peer at the moment!~n");

start(Ips, Hash, PeerId, FileName) ->
  [{Ip, Port} | RestIps] = Ips,
  case connect(Ip, Port, Hash, PeerId, FileName) of
    handshake_not_received  -> start(RestIps, Hash, PeerId, FileName);
    econnrefused            -> start(RestIps, Hash, PeerId, FileName);
    timeout                 -> start(RestIps, Hash, PeerId, FileName);
    Data -> Data
  end.


%%
%%
%%
connect(Ip, Port, Hash, PeerId, FileName) ->
  case gen_tcp:connect(Ip, Port, [{active, true}, binary], 5000) of
    {ok, Socket} ->
      io:format("Opened socket. Peer IP=~p:~p, Socket=~p~n", [Ip, Port, Socket]),
      handshake(Socket, Hash, PeerId, FileName);
    {error, econnrefused} ->
      econnrefused;
    {error, timeout} ->
      timeout
  end.


%%
%%
%%
handshake(Socket, Hash, PeerId, FileName) ->
  Request = [
      19,
      "BitTorrent protocol",
      0,0,0,0,0,0,0,0,
      Hash,
      PeerId
  ],
  io:format("Request=~p", [Request]),
  gen_tcp:send(Socket, list_to_binary(Request)),
  receive
    {tcp, Socket, _Data} ->
      %% @todo patikrinti, ar atitinka handshake responsas mano requestą
      io:format("Received handshake from socket ~p~n", [Socket]),
      interested(Socket, FileName),
      ok
  after
    5000 -> handshake_not_received
  end.


%%
%% Big endian! "Interested"
%%
interested(Socket, FileName) ->
  % Reikia handlinti tiek po unchoke bitfield, tiek po bitfield - unchoke, nes jų tvarka neprognozuojama.
  % @todo Taip pat reikia handlinti kartu su bitfield galimai krūvą have pranešimų.
  io:format("Interested! ~p~n", [Socket]),
  gen_tcp:send(Socket, <<00, 00, 00, 01, 2>>), % Interested!
  receive
    % unchoke
    {tcp, _Port, <<0, 0, 0, 1, 1>>} ->
      io:format("Received unchoke from socket~n"),
      receive
        {tcp, Port2, Data2}
          -> io:format("Received bitfield from socket ~p~nSize=~p~nHex=~p~nData=~p~n", [Port2, bit_size(Data2), bin_to_hex:bin_to_hex(Data2), Data2]),
          ok
        after
          5000 -> bitfield_not_received
      end,
      ok;
    % bitfield
    {tcp, Port, Data} ->
      io:format("Received bitfield2 from socket ~p~nSize=~p~nHex=~p~nData=~p~n", [Port, bit_size(Data), bin_to_hex:bin_to_hex(Data), Data]),
      receive
        {tcp, _Port, <<0, 0, 0, 1, 1>>} ->
          io:format("Received unchoke2 from socket~n"),
          request_piece(Socket, FileName),
          ok
        after
          5000 -> unchoke_not_received
      end,
      ok
  after
    5000 -> interested_not_received
  end.


%%
%% Big endian! "Not interested"
%%
not_interested(Socket) ->
  io:format("Not interested! ~p~n", [Socket]),
  gen_tcp:send(Socket, <<00, 00, 00, 01, 3>>).


%%
%%
%%
request_piece(Socket, FileName) ->
  io:format("Request piece! ~p~n", [Socket]),
  gen_tcp:send(
    Socket,
    <<
      00, 00, 00, 16#13, % Message length
      06, % Message type
      00, 00, 00, 00, % Piece index
      00, 00, 00, 00, % Begin offset of piece
      00, 00, 16#80, 00 % Piece length
    >>
  ),
  receive
    {tcp, Port, Data} ->
        case bit_size(Data) of
          104 -> % 13 * 8
            receive
              {tcp, Port2, Data2} ->
                io:format("Received actual piece from socket ~p~nSize=~p~nHex=~p~nData=~p~n", [Port2, bit_size(Data2), bin_to_hex:bin_to_hex(Data2), Data2]),
                ok
              after
                5000 -> piece_not_received
            end;
          _Other ->
            file:write_file(FileName, Data, [append]),
            io:format("Writed to file=~p~n", [FileName]),
            io:format("Received piece data from socket ~p~nSize=~p~nHex=~p~nData=~p~n", [Port, bit_size(Data), bin_to_hex:bin_to_hex(Data), Data])
        end,
        ok
    after
      5000 -> piece_data_not_received
  end.


%%
%% Big endian! "Have, Piece 0x202"
%%
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
      >>,
    gen_tcp:send(Socket, Msg).


data() ->
  Packet = <<"13426974546F7272656E742070726F746F636F6C0000000000100005E195B041F8F4DA3EE61EE0F0AA76754B949442CF2D425437313030308DAB1CDAC15CBC3380638F2100000007057858F55004C000000005040000000000000005040000002200000005040000001A0000000504000000">>,
  case Packet of
      <<"13", _Label:19/binary, Hash:20/binary, PeerId:20/binary, Rest/binary>> -> {ok, PeerId};
      _Other                -> not_ok
  end.
