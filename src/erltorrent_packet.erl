%%%-------------------------------------------------------------------
%%% @author bartimaeus
%%% @copyright (C) 2018, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 23. Jun 2018 08.33
%%%-------------------------------------------------------------------
-module(erltorrent_packet).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

-behaviour(gen_server).

-include("erltorrent.hrl").

%% API
-export([
    start_link/0,
    parse/2
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    parsed_data  :: [{message_type(), payload()}] | undefined, % @todo neaišku, ar reikia
    rest         :: payload() | undefined
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


%% @doc
%% Start parsing data (sync. call)
%%
parse(Pid, Data) ->
    gen_server:call(Pid, {parse, Data}).



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
%% Start packets parsing
%%
handle_call({parse, Data}, _From, State = #state{rest = Rest}) ->
    {FullData, MessageType, ExtraData} = case Rest of
        Rest when is_binary(Rest) ->
            {<<Rest/binary, Data/binary>>, undefined, undefined};
        undefined ->
            {Data, undefined, undefined}
    end,
    {ok, ParsedResult, ParsedRest} = case MessageType of
        undefined   -> identify(FullData);
        MessageType -> identify(MessageType, {FullData, ExtraData})
    end,
    {reply, {ok, ParsedResult}, State#state{parsed_data = ParsedResult, rest = ParsedRest}};

%% @doc
%% Handle unknown calls
%%
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

%% @doc
%% Identify and parse packets
%%
identify(Data) ->
    identify(Data, []).

identify(<<>>, Acc) ->
    {ok, lists:reverse(Acc), undefined};

%
% Handshake
identify(<<19, _Label:19/bytes, _ReservedBytes:8/bytes, _Hash:20/bytes, _PeerId:20/bytes, Rest/bytes>>, Acc) ->
    identify(Rest, [{handshake, true} | Acc]);

%
% Keep alive
identify(<<0, 0, 0, 0, Rest/bytes>>, Acc) ->
    identify(Rest, [{keep_alive, true} | Acc]);

%
% Choke
identify(<<0, 0, 0, 1, 0, Rest/bytes>>, Acc) ->
    identify(Rest, [{choke, true} | Acc]);

%
% Uncoke
identify(<<0, 0, 0, 1, 1, Rest/bytes>>, Acc) ->
    identify(Rest, [{unchoke, true} | Acc]);

%
% Interested
identify(<<0, 0, 0, 1, 2, Rest/bytes>>, Acc) ->
    identify(Rest, [{interested, true} | Acc]);

%
% Not interested
identify(<<0, 0, 0, 1, 3, Rest/bytes>>, Acc) ->
    identify(Rest, [{not_interested, true} | Acc]);

%
% Have (fixed length, always 0005)
identify(FullData = <<0, 0, 0, 5, 4, Data/bytes>>, Acc) ->
    PayloadLength = 4, % Because we've already matched Idx=4
    case Data of
        Data when byte_size(Data) < PayloadLength ->
            {ok, lists:reverse(Acc), FullData};
        Data ->
            <<Payload:PayloadLength/bytes, Rest/bytes>> = Data,
            identify(Rest, [{have, erltorrent_helper:bin_piece_id_to_int(Payload)} | Acc])
    end;

%
% Bitfield
identify(FullData = <<Length:4/bytes, 5, Data/bytes>>, Acc) ->
    <<FullLength:32>> = Length,     % Convert to integer (same as: <<FullLength:32/integer>> = Length)
    PayloadLength = FullLength - 1, % Because we've already matched Idx=5
    case Data of
        Data when byte_size(Data) < PayloadLength ->
            {ok, lists:reverse(Acc), FullData};
        Data ->
            <<Payload:PayloadLength/binary, Rest/binary>> = Data,
            BitField = #bitfield_data{
                parsed  = parse_bitfield(Payload),
                payload = Payload,
                length  = Length
            },
            identify(Rest, [{bitfield, BitField} | Acc])
    end;

%
% Request (length = 13)
identify(<<0, 0, 0, 13, 6, _PieceIndex:4/bytes, _BlockOffset:4/bytes, _BlockLength:4/bytes, Rest/bytes>>, Acc) ->
    identify(Rest, Acc);

%
% Piece (length = 16384 bytes (piece size) + 9 (piece: <len=0009+X><id=7><index><begin><block>))
identify(FullData = <<Length:4/bytes, 7, PieceIndex:4/bytes, BlockOffset:4/bytes, Data/bytes>>, Acc) ->
    <<FullLength:32>> = Length,      % Convert to integer
    PayloadLength = FullLength - 9,  % Because we've already matched Idx, PieceIndex and BlockOffset
    case Data of
        Data when byte_size(Data) < PayloadLength ->
            {ok, lists:reverse(Acc), FullData};
        Data ->
            <<Payload:PayloadLength/bytes, Rest/bytes>> = Data,
            Piece = #piece_data{
                payload      = Payload,
                length       = Length,
                piece_index  = erltorrent_helper:bin_piece_id_to_int(PieceIndex),
                block_offset = BlockOffset
            },
            identify(Rest, [{piece, Piece} | Acc])
    end;

identify(Data, Acc) ->
    {ok, lists:reverse(Acc), Data}.


%% @doc
%% Parse bitfield to bits ({PieceId, true | false}). True or false depends if peer has a piece or not.
%%
parse_bitfield(Bitfield) when is_list(Bitfield) ->
    parse_bitfield(Bitfield, 0, []);

parse_bitfield(Bitfield) when is_binary(Bitfield) ->
    parse_bitfield(binary_to_list(Bitfield), 0, []).

parse_bitfield([], _Iteration, Acc) ->
    lists:reverse(lists:flatten(Acc));

parse_bitfield([Byte|Bytes], Iteration, Acc) ->
    <<B1:1/bits, B2:1/bits, B3:1/bits, B4:1/bits, B5:1/bits, B6:1/bits, B7:1/bits, B8:1/bits>> = <<Byte>>,
    ConvertFun = fun
        (<<1:1>>) -> true;
        (<<0:1>>) -> false
    end,
    Result = [
        {7 + Iteration, ConvertFun(B8)},
        {6 + Iteration, ConvertFun(B7)},
        {5 + Iteration, ConvertFun(B6)},
        {4 + Iteration, ConvertFun(B5)},
        {3 + Iteration, ConvertFun(B4)},
        {2 + Iteration, ConvertFun(B3)},
        {1 + Iteration, ConvertFun(B2)},
        {0 + Iteration, ConvertFun(B1)}
    ],
    parse_bitfield(Bytes, Iteration + 8, [Result|Acc]).



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
        16#d4, 16#f3, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff,
        16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff,
        16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff,
        16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff,
        16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff,
        16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff
    >>,
    ParsedBitfieldPayload1 = [{0,true}, {1,true}, {2,false}, {3,true}, {4,false}, {5,true},
        {6,false}, {7,false}, {8,true}, {9,true}, {10,true}, {11,true}, {12,false},
        {13,false}, {14,true}, {15,true}, {16,true}, {17,true}, {18,true}, {19,true},
        {20,true}, {21,true}, {22,true}, {23,true}, {24,true}, {25,true}, {26,true},
        {27,true}, {28,true}, {29,true}, {30,true}, {31,true}, {32,true}, {33,true},
        {34,true}, {35,true}, {36,true}, {37,true}, {38,true}, {39,true}, {40,true},
        {41,true}, {42,true}, {43,true}, {44,true}, {45,true}, {46,true}, {47,true},
        {48,true}, {49,true}, {50,true}, {51,true}, {52,true}, {53,true}, {54,true},
        {55,true}, {56,true}, {57,true}, {58,true}, {59,true}, {60,true}, {61,true},
        {62,true}, {63,true}, {64,true}, {65,true}, {66,true}, {67,true}, {68,true},
        {69,true}, {70,true}, {71,true}, {72,true}, {73,true}, {74,true}, {75,true},
        {76,true}, {77,true}, {78,true}, {79,true}, {80,true}, {81,true}, {82,true},
        {83,true}, {84,true}, {85,true}, {86,true}, {87,true}, {88,true}, {89,true},
        {90,true}, {91,true}, {92,true}, {93,true}, {94,true}, {95,true}, {96,true},
        {97,true}, {98,true}, {99,true}, {100,true}, {101,true}, {102,true}, {103,true},
        {104,true}, {105,true}, {106,true}, {107,true}, {108,true}, {109,true}, {110,true},
        {111,true}, {112,true}, {113,true}, {114,true}, {115,true}, {116,true}, {117,true},
        {118,true}, {119,true}, {120,true}, {121,true}, {122,true}, {123,true}, {124,true},
        {125,true}, {126,true}, {127,true}, {128,true}, {129,true}, {130,true}, {131,true},
        {132,true}, {133,true}, {134,true}, {135,true}, {136,true}, {137,true}, {138,true},
        {139,true}, {140,true}, {141,true}, {142,true}, {143,true}, {144,true}, {145,true},
        {146,true}, {147,true}, {148,true}, {149,true}, {150,true}, {151,true}, {152,true},
        {153,true}, {154,true}, {155,true}, {156,true}, {157,true}, {158,true}, {159,true},
        {160,true}, {161,true}, {162,true}, {163,true}, {164,true}, {165,true}, {166,true},
        {167,true}, {168,true}, {169,true}, {170,true}, {171,true}, {172,true}, {173,true},
        {174,true}, {175,true}, {176,true}, {177,true}, {178,true}, {179,true}, {180,true},
        {181,true}, {182,true}, {183,true}, {184,true}, {185,true}, {186,true}, {187,true},
        {188,true}, {189,true}, {190,true}, {191,true}, {192,true}, {193,true}, {194,true},
        {195,true}, {196,true}, {197,true}, {198,true}, {199,true}, {200,true}, {201,true},
        {202,true}, {203,true}, {204,true}, {205,true}, {206,true}, {207,true}, {208,true},
        {209,true}, {210,true}, {211,true}, {212,true}, {213,true}, {214,true}, {215,true},
        {216,true}, {217,true}, {218,true}, {219,true}, {220,true}, {221,true}, {222,true},
        {223,true}, {224,true}, {225,true}, {226,true}, {227,true}, {228,true}, {229,true},
        {230,true}, {231,true}, {232,true}, {233,true}, {234,true}, {235,true}, {236,true},
        {237,true}, {238,true}, {239,true}, {240,true}, {241,true}, {242,true}, {243,true},
        {244,true}, {245,true}, {246,true}, {247,true}, {248,true}, {249,true}, {250,true},
        {251,true}, {252,true}, {253,true}, {254,true}, {255,true}, {256,true}, {257,true},
        {258,true}, {259,true}, {260,true}, {261,true}, {262,true}, {263,true}, {264,true},
        {265,true}, {266,true}, {267,true}, {268,true}, {269,true}, {270,true}, {271,true},
        {272,true}, {273,true}, {274,true}, {275,true}, {276,true}, {277,true}, {278,true},
        {279,true}, {280,true}, {281,true}, {282,true}, {283,true}, {284,true}, {285,true},
        {286,true}, {287,true}, {288,true}, {289,true}, {290,true}, {291,true}, {292,true},
        {293,true}, {294,true}, {295,true}, {296,true}, {297,true}, {298,true}, {299,true},
        {300,true}, {301,true}, {302,true}, {303,true}, {304,true}, {305,true}, {306,true},
        {307,true}, {308,true}, {309,true}, {310,true}, {311,true}, {312,true}, {313,true},
        {314,true}, {315,true}, {316,true}, {317,true}, {318,true}, {319,true}, {320,true},
        {321,true}, {322,true}, {323,true}, {324,true}, {325,true}, {326,true}, {327,true},
        {328,true}, {329,true}, {330,true}, {331,true}, {332,true}, {333,true}, {334,true},
        {335,true}, {336,true}, {337,true}, {338,true}, {339,true}, {340,true}, {341,true},
        {342,true}, {343,true}, {344,true}, {345,true}, {346,true}, {347,true}, {348,true},
        {349,true}, {350,true}, {351,true}, {352,true}, {353,true}, {354,true}, {355,true},
        {356,true}, {357,true}, {358,true}, {359,true}, {360,true}, {361,true}, {362,true},
        {363,true}, {364,true}, {365,true}, {366,true}, {367,true}, {368,true}, {369,true},
        {370,true}, {371,true}, {372,true}, {373,true}, {374,true}, {375,true}, {376,true},
        {377,true}, {378,true}, {379,true}, {380,true}, {381,true}, {382,true}, {383,true},
        {384,true}, {385,true}, {386,true}, {387,true}, {388,true}, {389,true}, {390,true},
        {391,true}, {392,true}, {393,true}, {394,true}, {395,true}, {396,true}, {397,true},
        {398,true}, {399,true}, {400,true}, {401,true}, {402,true}, {403,true}, {404,true},
        {405,true}, {406,true}, {407,true}, {408,true}, {409,true}, {410,true}, {411,true},
        {412,true}, {413,true}, {414,true}, {415,true}, {416,true}, {417,true}, {418,true},
        {419,true}, {420,true}, {421,true}, {422,true}, {423,true}, {424,true}, {425,true},
        {426,true}, {427,true}, {428,true}, {429,true}, {430,true}, {431,true}, {432,true},
        {433,true}, {434,true}, {435,true}, {436,true}, {437,true}, {438,true}, {439,true},
        {440,true}, {441,true}, {442,true}, {443,true}, {444,true}, {445,true}, {446,true},
        {447,true}, {448,true}, {449,true}, {450,true}, {451,true}, {452,true}, {453,true},
        {454,true}, {455,true}, {456,true}, {457,true}, {458,true}, {459,true}, {460,true},
        {461,true}, {462,true}, {463,true}, {464,true}, {465,true}, {466,true}, {467,true},
        {468,true}, {469,true}, {470,true}, {471,true}, {472,true}, {473,true}, {474,true},
        {475,true}, {476,true}, {477,true}, {478,true}, {479,true}, {480,true}, {481,true},
        {482,true}, {483,true}, {484,true}, {485,true}, {486,true}, {487,true}, {488,true},
        {489,true}, {490,true}, {491,true}, {492,true}, {493,true}, {494,true}, {495,true},
        {496,true}, {497,true}, {498,true}, {499,true}, {500,true}, {501,true}, {502,true},
        {503,true}, {504,true}, {505,true}, {506,true}, {507,true}, {508,true}, {509,true},
        {510,true}, {511,true}, {512,true}, {513,true}, {514,true}, {515,true}, {516,true},
        {517,true}, {518,true}, {519,true}, {520,true}, {521,true}, {522,true}, {523,true},
        {524,true}, {525,true}, {526,true}, {527,true}, {528,true}, {529,true}, {530,true},
        {531,true}, {532,true}, {533,true}, {534,true}, {535,true}, {536,true}, {537,true},
        {538,true}, {539,true}, {540,true}, {541,true}, {542,true}, {543,true}, {544,true},
        {545,true}, {546,true}, {547,true}, {548,true}, {549,true}, {550,true}, {551,true},
        {552,true}, {553,true}, {554,true}, {555,true}, {556,true}, {557,true}, {558,true},
        {559,true}, {560,true}, {561,true}, {562,true}, {563,true}, {564,true}, {565,true},
        {566,true}, {567,true}, {568,true}, {569,true}, {570,true}, {571,true}, {572,true},
        {573,true}, {574,true}, {575,true}, {576,true}, {577,true}, {578,true}, {579,true},
        {580,true}, {581,true}, {582,true}, {583,true}, {584,true}, {585,true}, {586,true},
        {587,true}, {588,true}, {589,true}, {590,true}, {591,true}, {592,true}, {593,true},
        {594,true}, {595,true}, {596,true}, {597,true}, {598,true}, {599,true}, {600,true},
        {601,true}, {602,true}, {603,true}, {604,true}, {605,true}, {606,true}, {607,true},
        {608,true}, {609,true}, {610,true}, {611,true}, {612,true}, {613,true}, {614,true},
        {615,true}, {616,true}, {617,true}, {618,true}, {619,true}, {620,true}, {621,true},
        {622,true}, {623,true}, {624,true}, {625,true}, {626,true}, {627,true}, {628,true},
        {629,true}, {630,true}, {631,true}, {632,true}, {633,true}, {634,true}, {635,true},
        {636,true}, {637,true}, {638,true}, {639,true}, {640,true}, {641,true}, {642,true},
        {643,true}, {644,true}, {645,true}, {646,true}, {647,true}, {648,true}, {649,true},
        {650,true}, {651,true}, {652,true}, {653,true}, {654,true}, {655,true}, {656,true},
        {657,true}, {658,true}, {659,true}, {660,true}, {661,true}, {662,true}, {663,true},
        {664,true}, {665,true}, {666,true}, {667,true}, {668,true}, {669,true}, {670,true},
        {671,true}],
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
    BitFieldRecord = #bitfield_data{
        parsed  = ParsedBitfieldPayload1,
        payload = BitFieldPayload1,
        length  =  <<00, 00, 00, 16#55>>
    },
    % @todo "request" message test
    % FullLength = 96 bytes
    Piece1 = <<16#00, 16#00, 16#00, 16#5c, 16#07, 16#00, 16#00, 16#01, 16#c8, 16#00, 16#00, 16#00, 16#00, PiecePayload1/binary>>,
    PieceRecord = #piece_data{
        payload      = PiecePayload1,
        length       = <<16#00, 16#00, 16#00, 16#5c>>,
        piece_index  = erltorrent_helper:bin_piece_id_to_int(<<16#00, 16#00, 16#01, 16#c8>>),
        block_offset = <<16#00, 16#00, 16#00, 16#00>>
    },
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
    <<PartPiecePayload1:1/bytes, PartPiecePayload2:3/bytes, PartPiecePayload3:92/bytes>> = Piece1,
    RainyData1 = <<
        Handshake1/binary,
        00, 00, 00, 16#55, 05, PartBitfieldPayload1/binary
    >>,
    [
        %
        % Bitfield parser
        ?_assertEqual(
            [
                {0, true}, {1, true}, {2, false}, {3, true}, {4, false}, {5, true}, {6, false}, {7, false},
                {8, true}, {9, true}, {10, true}, {11, true}, {12, false}, {13, false}, {14, true}, {15, true}
            ],
            parse_bitfield(<<16#d4, 16#f3>>)
        ),
        ?_assertEqual(
            [
                {0, true}, {1, true}, {2, false}, {3, true}, {4, false}, {5, true}, {6, false}, {7, false},
                {8, true}, {9, true}, {10, true}, {11, true}, {12, false}, {13, false}, {14, true}, {15, true}
            ],
            parse_bitfield([212, 243])
        ),
        %
        % Happy day each message scenario
        ?_assertEqual(
            {ok, [{handshake, true}], undefined}, identify(Handshake1)
        ),
        ?_assertEqual(
            {ok, [{keep_alive, true}], undefined}, identify(KeepAlive1)
        ),
        ?_assertEqual(
            {ok, [{choke, true}], undefined}, identify(Choke1)
        ),
        ?_assertEqual(
            {ok, [{unchoke, true}], undefined}, identify(Unchoke1)
        ),
        ?_assertEqual(
            {ok, [{interested, true}], undefined}, identify(Interested1)
        ),
        ?_assertEqual(
            {ok, [{not_interested, true}], undefined}, identify(NotInterested1)
        ),
        ?_assertEqual(
            {ok, [{piece, PieceRecord}], undefined}, identify(Piece1)
        ),
        ?_assertEqual(
            {ok, [{have, 3}], undefined}, identify(Have1)
        ),
        ?_assertEqual(
            {ok, [{bitfield, BitFieldRecord}], undefined}, identify(BitField)
        ),
        %
        % Happy day packet (many messages) scenario
        ?_assertEqual(
            {ok, [
                    {handshake, true},
                    {bitfield, BitFieldRecord},
                    {unchoke, true},
                    {piece, PieceRecord},
                    {have, 3},
                    {piece, PieceRecord},
                    {have, 3}
                 ]
            },
            parse(Pid, Data1)
        ),
        ?_assertEqual(
            {ok, [
                    {piece, PieceRecord},
                    {have, 3}
                 ]
            },
            parse(Pid, Data2)
        ),
        %
        % Rainy day scenario:
        % * full handshake message
        % * bitfield message splitted in 3 packets (possible to identify message from first packet)
        % * piece message splitted in 3 packets (possible to identify message only from third packet)
        ?_assertEqual(
            {ok, [{handshake, true}]},
            parse(Pid, RainyData1)
        ),
        ?_assertEqual(
            {ok, []},
            parse(Pid, PartBitfieldPayload2)
        ),
        ?_assertEqual(
            {ok, [{bitfield, BitFieldRecord}]},
            parse(Pid, PartBitfieldPayload3)
        ),
        ?_assertEqual(
            {ok, []},
            parse(Pid, PartPiecePayload1)
        ),
        ?_assertEqual(
            {ok, []},
            parse(Pid, PartPiecePayload2)
        ),
        ?_assertEqual(
            {ok, [{piece, PieceRecord}]},
            parse(Pid, PartPiecePayload3)
        )
    ].


-endif.


