%%%-------------------------------------------------------------------
%%% @author $author
%%% @copyright (C) $year, $company
%%% @doc
%%%
%%% @end
%%% Created : $fulldate
%%%-------------------------------------------------------------------
-module(erltorrent_server).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

-behaviour(gen_server).

-include("erltorrent.hrl").

%% API
-export([
    start_link/0,
    download/0,
    download/1,
    piece_peers/1,
    downloading_piece/1
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

-define(SERVER, ?MODULE).

-record(downloading_piece, {
    piece_id            :: piece_id_int(),
    ip                  :: tuple(),
    port                :: integer(),
    monitor_ref         :: reference(),
    status      = false :: downloading | completed | false
}).

-record(state, {
    pieces_peers       = dict:new(),
    downloading_pieces = []          :: [#downloading_piece{}],
    pieces_amount                    :: integer(),
    peer_id,
    hash
}).

%%%===================================================================
%%% API
%%%===================================================================


%% make start
%% application:start(erltorrent).
%% erltorrent_server:download().
%% erltorrent_server:piece_peers(4).
%% erltorrent_server:downloading_piece(0).
%%
download() ->
    gen_server:call(?SERVER, {download, inverse}).

download(r) ->
    gen_server:call(?SERVER, {download, reverse}).

piece_peers(Id) ->
    gen_server:call(?SERVER, {peace_peers, Id}).

downloading_piece(Id) ->
    gen_server:call(?SERVER, {downloading_piece, Id}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start({local, ?SERVER}, ?MODULE, [], []).

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
    {ok, #state{}}.

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

handle_call({download, Type}, _From, State = #state{pieces_peers = PiecesPeers}) ->
    File = filename:join(["torrents", "[Commie] Banana Fish - 01 [3600C7D5].mkv.torrent"]),
    {ok, Bin} = file:read_file(File),
    {ok, {dict, MetaInfo}} = erltorrent_bencoding:decode(Bin),

    {dict, Info} = dict:fetch(<<"info">>, MetaInfo),
    FileName = dict:fetch(<<"name">>, Info),
    Pieces = dict:fetch(<<"pieces">>, Info), % @todo verifikuoti kiekvieno piece parsiuntimą
    FullSize = dict:fetch(<<"length">>, Info),
    PieceSize = dict:fetch(<<"piece length">>, Info),
    TrackerLink = binary_to_list(dict:fetch(<<"announce">>, MetaInfo)),
    PiecesAmount = list_to_integer(float_to_list(math:ceil(FullSize / PieceSize), [{decimals, 0}])),
    lager:info("File name = ~p", [FileName]),
    lager:info("Piece size = ~p bytes", [PieceSize]),
    lager:info("Full file size = ~p", [FullSize]),
    lager:info("Pieces amount = ~p", [PiecesAmount]),

    PeerId = "-ER0000-45AF6T-NM81-", % @todo make random

%%    <<FirstHash:20/binary, _Rest/binary>> = Pieces,
%%    io:format("First piece hash=~p~n", [erltorrent_bin_to_hex:bin_to_hex(FirstHash)]),

    BencodedInfo = binary_to_list(erltorrent_bencoding:encode(dict:fetch(<<"info">>, MetaInfo))),
    HashBinString = erltorrent_sha1:binstring(BencodedInfo),
    Hash = erltorrent_helper:urlencode(HashBinString),

    {ok, {dict, Result}} = connect_to_tracker(TrackerLink, Hash, PeerId, FullSize),
    PeersIP = case Type of % @todo vėliau pašalinti
        inverse -> get_peers(dict:fetch(<<"peers">>, Result), []);
        reverse -> lists:reverse(get_peers(dict:fetch(<<"peers">>, Result), []))
    end,
    lager:info("All peers = ~p", [PeersIP]),

    [OnePeer|_] = PeersIP,
    lists:map(
        fun (Peer) ->
            erltorrent_peer:start(Peer, PeerId, HashBinString, FileName, FullSize, PieceSize, self())
        end,
        PeersIP
    ),
    % Fill empty peaces peers and downloading pieces
    IdsList = lists:seq(0, PiecesAmount - 1),
    NewPiecesPeers = lists:foldl(fun (Id, Acc) -> dict:store(Id, [], Acc) end, PiecesPeers, IdsList),
    NewDownloadingPieces = lists:map(fun (Id) -> #downloading_piece{piece_id = Id} end, IdsList),
    {reply, ok, State#state{pieces_amount = PiecesAmount, pieces_peers = NewPiecesPeers, downloading_pieces = NewDownloadingPieces, peer_id = PeerId, hash = HashBinString}};

%%
%%
handle_call({peace_peers, Id}, _From, State = #state{pieces_peers = PiecesPeers}) ->
    Result = case dict:is_key(Id, PiecesPeers) of
        true  -> dict:fetch(Id, PiecesPeers);
        false -> {error, piece_id_not_exist}
    end,
    {reply, Result, State};

%%
%%
handle_call({downloading_piece, Id}, _From, State = #state{downloading_pieces = DownloadingPieces}) ->
    Result = case lists:keysearch(Id, #downloading_piece.piece_id, DownloadingPieces) of
        {value, Value}  -> Value;
        false           -> {error, piece_id_not_exist}
    end,
    {reply, Result, State};

%%
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
handle_info({bitfield, ParsedBitfield, Ip, Port}, State = #state{pieces_peers = PiecesPeers, downloading_pieces = DownloadingPieces}) ->
    NewPiecesPeers = dict:map(
        fun (Id, Peers) ->
            % Check if this IP has an iterating piece
            case proplists:get_value(Id, ParsedBitfield) of
                Val when Val =:= true ->
                    % If there are not this IP in list yet, add it
                    case lists:member({Ip, Port}, Peers) of
                        false -> [{Ip, Port}|Peers];
                        true  -> Peers
                    end;
                _ ->
                    Peers
            end
        end,
        PiecesPeers
    ),
    self() ! refresh_downloading_pieces,
    {noreply, State#state{pieces_peers = NewPiecesPeers}};

%%
%%
handle_info({have, PieceId, Ip, Port}, State = #state{pieces_peers = PiecesPeers}) ->
    Peers = dict:fetch(PieceId, PiecesPeers),
    NewPeers = case lists:member({Ip, Port}, Peers) of
        false -> [{Ip, Port}|Peers];
        true  -> Peers
    end,
    NewPiecesPeers = dict:store(PieceId, NewPeers, PiecesPeers),
    self() ! refresh_downloading_pieces,
    {noreply, State#state{pieces_peers = NewPiecesPeers}};

%% @todo reikia handlinti {error,emfile} bandant atidaryt socketą. Ši klaida reiškia, jog OS atsisako atidaryti daugiau socketų
%% @todo need test
handle_info(refresh_downloading_pieces, State = #state{pieces_peers = PiecesPeers, downloading_pieces = DownloadingPieces, peer_id = PeerId, hash = Hash}) ->
    NewDownloadingPieces = lists:map(
        fun
            (#downloading_piece{piece_id = Id, status = false}) ->
                case dict:fetch(Id, PiecesPeers) of
                    [{Ip, Port}|_] ->
                        {ok, Pid} = erltorrent_downloader:start("0", Id, Ip, Port, self(), PeerId, Hash),
                        Ref = erlang:monitor(process, Pid),
                        #downloading_piece{piece_id = Id, ip = Ip, port = Port, monitor_ref = Ref, status = downloading};
                    _     ->
                        #downloading_piece{piece_id = Id}
                end;
            (Other) ->
                Other
        end,
        DownloadingPieces
    ),
    {noreply, State#state{downloading_pieces = NewDownloadingPieces}};

%% @doc
%% Remove process from downloading pieces if it crashes and move that peer into end of queue.
%% @todo handle Reason (can be normal, killed, etc.)
handle_info({'DOWN', MonitorRef, process, _Pid, _Reason}, State = #state{downloading_pieces = DownloadingPieces, pieces_peers = PiecesPeers}) ->
    lager:info("xxxxxxxx DOWN"),
    % Remove peer from downloading list
    {value, OldDownloadingPiece} = lists:keysearch(MonitorRef, #downloading_piece.monitor_ref, DownloadingPieces),
    #downloading_piece{piece_id = PieceId, ip = Ip, port = Port} = OldDownloadingPiece,
    NewDownloadingPieces = lists:keyreplace(MonitorRef, #downloading_piece.monitor_ref, DownloadingPieces, #downloading_piece{piece_id = PieceId}),
    % Move peer to the end of the queue
    NewPiecesPeers = case dict:fetch(PieceId, PiecesPeers) of
        Peers when length(Peers) > 0 ->
            NewPeers = lists:append(lists:delete({Ip, Port}, Peers), [{Ip, Port}]),
            dict:store(PieceId, NewPeers, PiecesPeers);
        _ ->
            PiecesPeers
    end,
    self() ! refresh_downloading_pieces,
    {noreply, State#state{downloading_pieces = NewDownloadingPieces, pieces_peers = NewPiecesPeers}};

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
    lager:info("xxxxxxxx Server terminate=~p", [_Reason]),
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


%%
%%
%%
connect_to_tracker(TrackerLink, Hash, PeerId, FullSize) ->
    inets:start(),
    Separator = case string:str(TrackerLink, "?") of 0 -> "?"; _ -> "&" end,
    FullLink = TrackerLink ++ Separator ++ "info_hash=" ++ Hash ++ "&peer_id=" ++ PeerId ++ "&port=61940&uploaded=0&downloaded=0&left=" ++ erltorrent_helper:convert_to_list(FullSize) ++ "&corrupt=0&key=4ACCCA00&event=started&numwant=200&compact=1&no_peer_id=1&supportcrypto=1&redundant=0",
    {ok, {{_Version, _Code, _ReasonPhrase}, _Headers, Body}} = httpc:request(get, {FullLink, []}, [], [{body_format, binary}]),
    erltorrent_bencoding:decode(Body).


%%
%%
%%
get_peers(<<>>, Result) ->
    lists:reverse(Result);

get_peers(PeersList, Result) ->
    <<Byte1:8, Byte2:8, Byte3:8, Byte4:8, Port:16, Rest/binary>> = PeersList,
    get_peers(Rest, [{{Byte1, Byte2, Byte3, Byte4}, Port} | Result]).



%%%===================================================================
%%% EUnit tests
%%%===================================================================


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

add_new_peer_to_pieces_peers_test_() ->
    Ip = {127,0,0,1},
    Port = 9444,
    ParsedBitfield = [{0, true}, {1, false}, {2, true}, {3, true}],
    PiecesPeers1 = dict:store(0, [], dict:new()),
    PiecesPeers2 = dict:store(1, [{{127,0,0,2}, 9874}], PiecesPeers1),
    PiecesPeers3 = dict:store(2, [{{127,0,0,3}, 9547}, {{127,0,0,2}, 9614}], PiecesPeers2),
    PiecesPeers4 = dict:store(3, [{Ip, Port}], PiecesPeers3),
    PiecesPeers5 = dict:store(0, [{Ip, Port}], PiecesPeers4),
    PiecesPeers6 = dict:store(2, [{Ip, Port}, {{127,0,0,3}, 9547}, {{127,0,0,2}, 9614}], PiecesPeers5),
    PiecesPeers7 = dict:store(3, [{Ip, Port}], PiecesPeers6),
    State = #state{pieces_peers = PiecesPeers4},
    [
        ?_assertEqual(
            {noreply, #state{pieces_peers = PiecesPeers7}},
            handle_info({bitfield, ParsedBitfield, Ip, Port}, State)
        ),
        ?_assertEqual(
            {noreply, #state{pieces_peers = PiecesPeers4}},
            handle_info({have, 3, Ip, Port}, State)
        ),
        ?_assertEqual(
            {noreply, #state{pieces_peers = PiecesPeers5}},
            handle_info({have, 0, Ip, Port}, State)
        )
    ].


remove_process_from_downloading_piece_test_() ->
    PiecesPeers1 = dict:store(0, [], dict:new()),
    PiecesPeers2 = dict:store(1, [{{127,0,0,7}, 9874}], PiecesPeers1),
    PiecesPeers3 = dict:store(2, [{{127,0,0,3}, 9547}, {{127,0,0,2}, 9614}, {{127,0,0,1}, 9612}], PiecesPeers2),
    Ref1 = make_ref(),
    Ref2 = make_ref(),
    DownloadingPieces = [
        #downloading_piece{piece_id = 0, status = false},
        #downloading_piece{piece_id = 1, monitor_ref = Ref1, ip = {127,0,0,7}, port = 9874, status = downloading},
        #downloading_piece{piece_id = 2, monitor_ref = Ref2, ip = {127,0,0,2}, port = 9614, status = downloading}
    ],
    NewDownloadingPieces = [
        #downloading_piece{piece_id = 0, status = false},
        #downloading_piece{piece_id = 1, monitor_ref = Ref1, ip = {127,0,0,7}, port = 9874, status = downloading},
        #downloading_piece{piece_id = 2, status = false}
    ],
    NewPiecesPeers = dict:store(2, [{{127,0,0,3}, 9547}, {{127,0,0,1}, 9612}, {{127,0,0,2}, 9614}], PiecesPeers3),
    State = #state{pieces_peers = PiecesPeers3, downloading_pieces = DownloadingPieces},
    [
        ?_assertEqual(
            {noreply, State#state{downloading_pieces = NewDownloadingPieces, pieces_peers = NewPiecesPeers}},
            handle_info({'DOWN', Ref2, process, pid, normal}, State)
        )
    ].


get_piece_peers_test_() ->
    PiecesPeers1 = dict:store(0, [], dict:new()),
    PiecesPeers2 = dict:store(1, [{127,0,0,3}, {127,0,0,2}], PiecesPeers1),
    State = #state{pieces_peers = PiecesPeers2},
    [
        ?_assertEqual(
            {reply, [], State},
            handle_call({peace_peers, 0}, from, State)
        ),
        ?_assertEqual(
            {reply, [{127,0,0,3}, {127,0,0,2}], State},
            handle_call({peace_peers, 1}, from, State)
        ),
        ?_assertEqual(
            {reply, {error, piece_id_not_exist}, State},
            handle_call({peace_peers, 2}, from, State)
        )
    ].


get_downloading_piece_test_() ->
    Piece1 = #downloading_piece{piece_id = 0, status = false},
    Piece2 = #downloading_piece{piece_id = 1, ip = {127,0,0,7}, port = 9874, status = downloading},
    Piece3 = #downloading_piece{piece_id = 2, ip = {127,0,0,2}, port = 9614, status = downloading},
    DownloadingPieces = [Piece1, Piece2, Piece3],
    State = #state{downloading_pieces = DownloadingPieces},
    [
        ?_assertEqual(
            {reply, Piece1, State},
            handle_call({downloading_piece, 0}, from, State)
        ),
        ?_assertEqual(
            {reply, Piece2, State},
            handle_call({downloading_piece, 1}, from, State)
        ),
        ?_assertEqual(
            {reply, {error, piece_id_not_exist}, State},
            handle_call({downloading_piece, 3}, from, State)
        )
    ].

-endif.