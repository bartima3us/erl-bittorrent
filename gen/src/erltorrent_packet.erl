%%%-------------------------------------------------------------------
%%% @author sarunas
%%% @copyright (C) 2017, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 31. Oct 2017 23.08
%%%-------------------------------------------------------------------
-module(erltorrent_packet).
-author("sarunas").

%% API
-export([identify/2, identify/3]).


%%
%%
%%
identify(<<>>, Acc) ->
    io:format("------------------------~n"),
    io:format("All packets parsed!~n"),
    io:format("------------------------~n"),
    {ok, <<>>, Acc};

identify(<<19, _Label:19/binary, _ReservedBytes:8/binary, _Hash:20/binary, _PeerId:20/binary, Rest/binary>>, Acc) ->
    io:format("------------------------~n"),
    io:format("Got handshake!~n"),
    io:format("------------------------~n"),
    identify(Rest, Acc);

identify(<<Length:4/binary, 4, Data/binary>>, Acc) ->
    io:format("------------------------~n"),
    <<IntLength:32>> = Length,
    TrueLength = IntLength - 1, % Because we've already matched Idx=4
    <<Index:TrueLength/binary, Rest/binary>> = Data,
    IndexSize = bit_size(Index),
    <<TrueIndex:IndexSize>> = Index, % Convert Index to decimal
    io:format("Got have!~n
            Length=~p,~n
            Index=~p,~n
            Data=~p,~n
            RawData=~p,~n
            Rest=~p,~n
            RawRest=~p~n",
        [TrueLength, TrueIndex, Data, erltorrent_bin_to_hex:bin_to_hex(Data), Rest, erltorrent_bin_to_hex:bin_to_hex(Rest)]
    ),
    io:format("------------------------~n"),
    % @todo į Acc įdėti have duomenis
    identify(Rest, Acc);

identify(<<Length:4/binary, 5, Data/binary>>, Acc) ->
    io:format("------------------------~n"),
    <<IntLength:32>> = Length,
    TrueLength = IntLength - 1, % Because we've already matched Idx=5
    io:format("Bitfield Length=~p~n", [Length]),
    case Data of
        <<>> ->
            {ok, <<>>, Acc, {bitfield, TrueLength}};
        Other ->
            <<Bitfield:TrueLength/binary, Rest/binary>> = Other,
            io:format("Got bitfield! Length=~p, Bitfield=~p, RawBitfield=~p, Rest=~p~n", [IntLength, Bitfield, erltorrent_bin_to_hex:bin_to_hex(Bitfield), erltorrent_bin_to_hex:bin_to_hex(Rest)]),
            io:format("------------------------~n"),
            identify(Rest, [{bitfield, Bitfield}|Acc])
    end;

identify(<<0, 0, 0, 1, 1, Rest/binary>>, Acc) ->
    io:format("------------------------~n"),
    io:format("Got unchoke!~n"),
    io:format("------------------------~n"),
    identify(Rest, Acc);

identify(<<0, 0, 0, 0, Rest/binary>>, Acc) ->
    io:format("------------------------~n"),
    io:format("Got keep-alive!~n"),
    io:format("------------------------~n"),
    identify(Rest, [{keep_alive, 1}|Acc]);

identify(Packet, Acc) ->
    io:format("------------------------~n"),
    io:format("Unidentified packet! Packet=~p,~n RawPacket=~p~n", [Packet, erltorrent_bin_to_hex:bin_to_hex(Packet)]),
    io:format("------------------------~n"),
    {ok, Packet, Acc}.


%%
%%
%%
identify(<<Data/binary>>, bitfield, TrueLength) ->
    io:format("------------------------~n"),
    case Data of
        <<>> ->
            {ok, <<>>, {bitfield, TrueLength}};
        Other ->
            <<Bitfield:TrueLength/binary, Rest/binary>> = Other,
            io:format("Got bitfield 2! TrueLength=~p, Bitfield=~p, RawBitfield=~p, Rest=~p~n", [TrueLength, Bitfield, erltorrent_bin_to_hex:bin_to_hex(Bitfield), erltorrent_bin_to_hex:bin_to_hex(Rest)]),
            io:format("------------------------~n"),
            identify(Rest, [{bitfield, Bitfield}])
    end.
