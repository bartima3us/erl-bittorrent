%%%-------------------------------------------------------------------
%%% @author sarunas
%%% @copyright (C) 2018, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 23. Jun 2018 08.33
%%%-------------------------------------------------------------------
-module(erltorrent_packet2).
-author("sarunas").

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).
%% API
-export([identify/2]).

-type message_type() :: choke | unchoke | interested | uninterested | have | bitfield | request | piece | cancel.
-type payload()      :: binary().

-record(piece_data, {
    length       :: binary(),
    piece_index  :: binary(),
    block_offset :: binary()
}).

-record(bitfield_data, {
    length  :: binary()
}).

-record(last_message, {
    type    :: message_type(),
    rest    :: payload() | undefined,
    extra   :: #piece_data{} | #bitfield_data{} | undefined % Field for extra information (only for piece at the moment)
}).

-record(state, {
    parsed_data  :: [{message_type(), payload()}] | undefined, % @todo neaišku, ar reikia
    rest         :: payload() | #last_message{} | undefined     % If there are even not enough bytes left to identify next message - payload(). If we had enough bytes to identified last message but lack of payload bytes - #last_message{}
}).


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
start_link() ->
    gen_server:start_link(?MODULE, [], []).

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
init([]) ->
    State = #state{},
    {ok, State}.


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
handle_call({parse, Data}, _From, State = #state{rest = Rest}) ->
    {FullData, MessageType, ExtraData} = case Rest of
        Rest when is_binary(Rest) ->
            {<<Rest/binary, Data/binary>>, undefined, undefined};
        Rest when is_record(Rest, last_message) ->
            #last_message{
                type  = LastMessageType,
                rest  = LastMessageRest,
                extra = Extra
            } = Rest,
            {<<LastMessageRest/binary, Data/binary>>, LastMessageType, Extra};
        undefined ->
            {Data, undefined, undefined}
    end,
    {ok, ParsedResult, ParsedRest} = case MessageType of
        undefined   -> identify(FullData);
        MessageType -> identify(MessageType, {FullData, ExtraData})
    end,
    {reply, {ok, ParsedResult}, State#state{parsed_data = ParsedResult, rest = ParsedRest}};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.


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

identify(Data) ->
    identify(Data, []).

identify(<<>>, Acc) ->
    io:format("All packets parsed!~n"),
    {ok, Acc, undefined};

%
% Handshake
identify(<<19, _Label:19/bytes, _ReservedBytes:8/bytes, _Hash:20/bytes, _PeerId:20/bytes, Rest/bytes>>, Acc) ->
    io:format("Got handshake!~n"),
    identify(Rest, [{handshake, true} | Acc]);

%
% Keep alive
identify(keep_alive, {Data, _Extra = undefined}) ->
    identify(<<0, 0, 0, 0, Data/bytes>>, []);

identify(<<0, 0, 0, 0, Rest/bytes>>, Acc) ->
    io:format("------------------------~n"),
    io:format("Got keep-alive!~n"),
    identify(Rest, [{keep_alive, true} | Acc]);

%
% Choke
identify(choke, {Data, _Extra = undefined}) ->
    identify(<<0, 0, 0, 1, 0, Data/bytes>>, []);

identify(<<0, 0, 0, 1, 0, Rest/bytes>>, Acc) ->
    io:format("------------------------~n"),
    io:format("Got choke!~n"),
    identify(Rest, [{choke, true} | Acc]);

%
% Uncoke
identify(unchoke, {Data, _Extra = undefined}) ->
    identify(<<0, 0, 0, 1, 1, Data/bytes>>, []);

identify(<<0, 0, 0, 1, 1, Rest/bytes>>, Acc) ->
    io:format("------------------------~n"),
    io:format("Got unchoke!~n"),
    identify(Rest, [{unchoke, true} | Acc]);

%
% Interested
identify(interested, {Data, _Extra = undefined}) ->
    identify(<<0, 0, 0, 1, 2, Data/bytes>>, []);

identify(<<0, 0, 0, 1, 2, Rest/bytes>>, Acc) ->
    io:format("------------------------~n"),
    io:format("Got interested!~n"),
    identify(Rest, [{interested, true} | Acc]);

%
% Not interested
identify(not_interested, {Data, _Extra = undefined}) ->
    identify(<<0, 0, 0, 1, 3, Data/bytes>>, []);

identify(<<0, 0, 0, 1, 3, Rest/bytes>>, Acc) ->
    io:format("------------------------~n"),
    io:format("Got not interested!~n"),
    identify(Rest, [{not_interested, true} | Acc]);

%
% Have (fixed length, always 0005)
identify(have, {Data, _Extra = undefined}) ->
    identify(<<0, 0, 0, 5, 4, Data/bytes>>, []);

identify(<<0, 0, 0, 5, 4, Data/bytes>>, Acc) ->
    io:format("------------------------~nGot have~n"),
    PayloadLength = 4, % Because we've already matched Idx=4
    <<Payload:PayloadLength/bytes, Rest/bytes>> = Data,
    identify(Rest, [{have, Payload} | Acc]);

%
% Bitfield
identify(bitfield, {Data, _Extra = #bitfield_data{length = Length}}) ->
    identify(<<Length/bytes, 5, Data/bytes>>, []);

identify(<<Length:4/bytes, 5, Data/bytes>>, Acc) ->
    io:format("------------------------~nGot bitfield!~n"),
    <<FullLength:32>> = Length,     % Convert to integer (same as: <<FullLength:32/integer>> = Length)
    PayloadLength = FullLength - 1, % Because we've already matched Idx=5
    case Data of
        Data when byte_size(Data) < PayloadLength ->
            LastMessage = #last_message{
                type = bitfield,
                rest = Data,
                extra = #bitfield_data{
                    length = Length
                }
            },
            {ok, Acc, LastMessage};
        Data ->
            <<Payload:PayloadLength/binary, Rest/binary>> = Data,
            identify(Rest, [{bitfield, Payload} | Acc])
    end;

%
% Request (length = 13)
identify(<<0, 0, 0, 13, 6, _PieceIndex:4/bytes, _BlockOffset:4/bytes, _BlockLength:4/bytes, Rest/bytes>>, Acc) ->
    io:format("------------------------~n"),
    io:format("Got request!~n"),
    identify(Rest, Acc);

%
% Piece (length = 16384 bytes (piece size) + 9 (piece: <len=0009+X><id=7><index><begin><block>))
identify(piece, {Data, _Extra = #piece_data{length = Length, piece_index = PieceIndex, block_offset = BlockOffset}}) ->
    identify(<<Length/bytes, 7, PieceIndex/bytes, BlockOffset/bytes, Data/bytes>>, []);

identify(<<Length:4/bytes, 7, PieceIndex:4/bytes, BlockOffset:4/bytes, Data/bytes>>, Acc) ->
    io:format("------------------------~n"),
    io:format("Got piece!~n"),
    <<FullLength:32>> = Length,      % Convert to integer
    PayloadLength = FullLength - 13, % Because we've already matched length, Idx, PieceIndex and BlockOffset (only piece length size includes itself size!)
    case Data of
        Data when byte_size(Data) < PayloadLength ->
            LastMessage = #last_message{
                type   = piece,
                rest   = Data,
                extra  = #piece_data{
                    length       = PayloadLength,
                    piece_index  = PieceIndex,
                    block_offset = BlockOffset
                }
            },
            {ok, Acc, LastMessage};
        Data ->
            <<Payload:PayloadLength/bytes, Rest/bytes>> = Data,
            identify(Rest, [{piece, Payload} | Acc])
    end;

identify(Data, Acc) ->
    io:format("------------------------~n"),
    io:format("Unidentified packet!~n"),
    {ok, Acc, Data}.

%%%===================================================================
%%% EUnit tests
%%%===================================================================



-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

parse_test_() ->
    {ok, Pid} = start_link(),
    %
    % Payloads
    Handshake1 = <<
        16#13, 16#42, 16#69, 16#74, 16#54, 16#6f, 16#72, 16#72, 16#65, 16#6e, 16#74, 16#20, 16#70, 16#72, 16#6f, 16#74,
        16#6f, 16#63, 16#6f, 16#6c, 16#00, 16#00, 16#00, 16#00, 16#00, 16#10, 16#00, 16#05, 16#0b, 16#c2, 16#18, 16#9f,
        16#30, 16#08, 16#4c, 16#4d, 16#63, 16#73, 16#01, 16#dc, 16#ca, 16#fc, 16#2c, 16#31, 16#e3, 16#ae, 16#94, 16#66,
        16#2d, 16#44, 16#45, 16#31, 16#33, 16#43, 16#30, 16#2d, 16#50, 16#77, 16#54, 16#6d, 16#5f, 16#70, 16#49, 16#79,
        16#67, 16#79, 16#44, 16#70
    >>,
    BitFieldPayload1 = <<
        16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff,
        16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff,
        16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff,
        16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff,
        16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff,
        16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff
    >>,
    PiecePayload1 = <<
        16#e6, 16#77, 16#a2,
        16#0b, 16#08, 16#26, 16#c0, 16#00, 16#0f, 16#00, 16#10, 16#11, 16#18, 16#09, 16#a6, 16#b5, 16#d2, 16#a7, 16#b0,
        16#bf, 16#d8, 16#5b, 16#ef, 16#39, 16#11, 16#0d, 16#a9, 16#0c, 16#c8, 16#f2, 16#98, 16#fc, 16#0f, 16#2e, 16#c0,
        16#82, 16#de, 16#a5, 16#98, 16#b6, 16#d7, 16#a7, 16#77, 16#70, 16#84, 16#74, 16#04, 16#84, 16#e4, 16#a6, 16#74,
        16#bf, 16#81, 16#a3, 16#40, 16#dc, 16#81, 16#03, 16#10, 16#01, 16#00, 16#00, 16#00, 16#d4, 16#41, 16#9f, 16#2f,
        16#64, 16#94, 16#44, 16#5c, 16#74, 16#e7, 16#22, 16#8f, 16#76, 16#41, 16#7a, 16#35, 16#22, 16#d0, 16#8e, 16#d5
    >>,
    HavePayload1 = <<00, 00, 00, 03>>,
    %
    % Messages
    KeepAlive1 = <<00, 00, 00, 00>>,
    Choke1 = <<00, 00, 00, 01, 00>>,
    Unchoke1 = <<00, 00, 00, 01, 01>>,
    Interested1 = <<00, 00, 00, 01, 02>>,
    NotInterested1 = <<00, 00, 00, 01, 03>>,
    Have1 = <<00, 00, 00, 05, 04, HavePayload1/binary>>,
    BitField = <<00, 00, 00, 16#55, 05, BitFieldPayload1/binary>>,
    % @todo "request" message test
    % FullLength = 96 bytes
    Piece1 = <<16#00, 16#00, 16#00, 16#60, 16#07, 16#00, 16#00, 16#01, 16#c8, 16#00, 16#00, 16#00, 16#00, PiecePayload1/binary>>,
    % Concated message (packet)
    Data1 = <<
        Handshake1/binary,
        BitField/binary,
        Unchoke1/binary,
        Piece1/binary,
        Have1/binary,
        Piece1/binary,
        Have1/binary
    >>,
    Data2 = <<Piece1/binary, Have1/binary>>,
    % Message for rainy day scenario
    <<PartBitfieldPayload1:18/bytes, PartBitfieldPayload2:44/bytes, PartBitfieldPayload3:22/bytes>> = BitFieldPayload1,
    RainyData1 = <<
        Handshake1/binary,
        00, 00, 00, 16#55, 05, PartBitfieldPayload1/binary
    >>,
    [
        %
        % Happy day each message scenario
        ?_assertEqual(
            identify(Handshake1), {ok, [{handshake, true}], undefined}
        ),
        ?_assertEqual(
            identify(KeepAlive1), {ok, [{keep_alive, true}], undefined}
        ),
        ?_assertEqual(
            identify(Choke1), {ok, [{choke, true}], undefined}
        ),
        ?_assertEqual(
            identify(Unchoke1), {ok, [{unchoke, true}], undefined}
        ),
        ?_assertEqual(
            identify(Interested1), {ok, [{interested, true}], undefined}
        ),
        ?_assertEqual(
            identify(NotInterested1), {ok, [{not_interested, true}], undefined}
        ),
        ?_assertEqual(
            identify(Piece1), {ok, [{piece, PiecePayload1}], undefined}
        ),
        ?_assertEqual(
            identify(Have1), {ok, [{have, HavePayload1}], undefined}
        ),
        ?_assertEqual(
            identify(BitField), {ok, [{bitfield, BitFieldPayload1}], undefined}
        ),
        %
        % Happy day each message in other format scenario
        ?_assertEqual(
            identify(keep_alive, {<<>>, undefined}), {ok, [{keep_alive, true}], undefined}
        ),
        ?_assertEqual(
            identify(choke, {<<>>, undefined}), {ok, [{choke, true}], undefined}
        ),
        ?_assertEqual(
            identify(unchoke, {<<>>, undefined}), {ok, [{unchoke, true}], undefined}
        ),
        ?_assertEqual(
            identify(interested, {<<>>, undefined}), {ok, [{interested, true}], undefined}
        ),
        ?_assertEqual(
            identify(not_interested, {<<>>, undefined}), {ok, [{not_interested, true}], undefined}
        ),
        ?_assertEqual(
            identify(piece, {
                PiecePayload1,
                #piece_data{
                    length       = <<00, 00, 00, 16#60>>,
                    piece_index  = <<00, 00, 01, 16#c8>>,
                    block_offset = <<00, 00, 00, 00>>
                }
            }),
            {ok, [{piece, PiecePayload1}], undefined}
        ),
        ?_assertEqual(
            identify(have, {HavePayload1, undefined}), {ok, [{have, HavePayload1}], undefined}
        ),
        ?_assertEqual(
            identify(bitfield, {
                BitFieldPayload1,
                #bitfield_data{
                    length = <<00, 00, 00, 16#55>>
                }
            }),
            {ok, [{bitfield, BitFieldPayload1}], undefined}
        ),
        %
        % Happy day packet (many messages) scenario
        ?_assertEqual(
            gen_server:call(Pid, {parse, Data1}),
            {ok, [
                    {have, HavePayload1},
                    {piece, PiecePayload1},
                    {have, HavePayload1},
                    {piece, PiecePayload1},
                    {unchoke, true},
                    {bitfield, BitFieldPayload1},
                    {handshake, true}
                 ]
            }
        ),
        ?_assertEqual(
            gen_server:call(Pid, {parse, Data2}),
            {ok, [
                    {have, HavePayload1},
                    {piece, PiecePayload1}
                 ]
            }
        ),
        %
        % Rainy day scenario (full handshake message and bitfield message splitted in 3 packets)
        ?_assertEqual(
            gen_server:call(Pid, {parse, RainyData1}),
            {ok, [{handshake, true}]}
        ),
        ?_assertEqual(
            gen_server:call(Pid, {parse, PartBitfieldPayload2}),
            {ok, []}
        ),
        ?_assertEqual(
            gen_server:call(Pid, {parse, PartBitfieldPayload3}),
            {ok, [{bitfield, BitFieldPayload1}]}
        )
    ].


-endif.


