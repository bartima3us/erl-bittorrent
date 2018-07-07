%%%-------------------------------------------------------------------
%%% @author sarunas
%%% @copyright (C) 2018, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 03. Feb 2018 14.25
%%%-------------------------------------------------------------------
-module(erltorrent_message).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

%% API
-export([
    handshake/3,
    interested/1,
    keep_alive/1,
    request_piece/4
]).


%%
%%
%%
handshake(Socket, PeerId, Hash) ->
%%    io:format("Trying to handshake. Socket=~p~n", [Hash]),
    Request = [
        19,
        "BitTorrent protocol",
        0,0,0,0,0,0,0,0,
        Hash,
        PeerId
    ],
    gen_tcp:send(Socket, list_to_binary(Request)),
%%    io:format("Handshake successful. Socket=~p~n", [Socket]),
    ok.


%%
%%
%%
interested(Socket) ->
    % Reikia handlinti tiek po unchoke bitfield, tiek po bitfield - unchoke, nes jų tvarka neprognozuojama.
    gen_tcp:send(Socket, <<00, 00, 00, 01, 02>>),
%%    lager:info("Interested! Socket=~p", [Socket]),
    ok.


%%
%%
%%
keep_alive(Socket) ->
    io:format("Keep-alive! ~p~n", [Socket]),
%%    gen_tcp:send(Socket, <<00, 00, 00, 00>>),
    ok.


%%
%%
%%
request_piece(Socket, PieceId, PieceBegin, PieceLength) when is_integer(PieceId) ->
    PieceIdBin = erltorrent_helper:int_piece_id_to_bin(PieceId),
    request_piece(Socket, PieceIdBin, PieceBegin, PieceLength);

request_piece(Socket, PieceId, PieceBegin, PieceLength) when is_binary(PieceId) ->
    PieceLengthBin = <<PieceLength:32>>,
    gen_tcp:send(
        Socket,
        <<
            00, 00, 00, 16#0d,      % Message length
            06,                     % Message type
            PieceId/binary,         % Piece index
            PieceBegin/binary,      % Begin offset of piece
            PieceLengthBin/binary   % Piece length
        >>
    ),
    ok.


