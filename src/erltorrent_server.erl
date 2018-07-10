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
    download/1,
    piece_peers/1,
    downloading_piece/1,
    is_end/0
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

-define(SOCKETS_FOR_DOWNLOADING_LIMIT, 30).

-record(downloading_piece, {
    piece_id            :: piece_id_int(),
    ip_port             :: {tuple(), integer()},
    monitor_ref         :: reference(),
    status      = false :: false | downloading | completed
}).

-record(state, {
    torrent_name                     :: string(), % @todo rename to file_name
    pieces_peers       = dict:new(),
    downloading_pieces = []          :: [#downloading_piece{}],
    pieces_amount                    :: integer(),
    peer_id,
    hash,
    piece_length                     :: integer(),
    last_piece_length                :: integer(),
    last_piece_id                    :: integer()
}).

% make start
% application:start(erltorrent).
% erltorrent_server:download("[Commie] Banana Fish - 01 [3600C7D5].mkv.torrent").
% erltorrent_server:piece_peers(4).
% erltorrent_server:downloading_piece(0).



%%%===================================================================
%%% API
%%%===================================================================

%% @doc
%% Start download
%%
download(TorrentName) when is_binary(TorrentName) ->
    download(binary_to_list(TorrentName));

download(TorrentName) when is_list(TorrentName) ->
    gen_server:call(?SERVER, {download, TorrentName}).


%% @doc
%% Get piece peers
%%
piece_peers(Id) ->
    gen_server:call(?SERVER, {piece_peers, Id}).


%% @doc
%% Get downloading piece data
%%
downloading_piece(Id) ->
    gen_server:call(?SERVER, {downloading_piece, Id}).


%% @doc
%% Check is all pieces are downloaded
%%
is_end() ->
    gen_server:call(?SERVER, is_end).


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
handle_call({download, TorrentName}, _From, State = #state{pieces_peers = PiecesPeers}) ->
    % @todo need to scrap data from tracker and update state constantly
    File = filename:join(["torrents", TorrentName]),
    {ok, Bin} = file:read_file(File),
    {ok, {dict, MetaInfo}} = erltorrent_bencoding:decode(Bin),
    {dict, Info} = dict:fetch(<<"info">>, MetaInfo),
    FileName = dict:fetch(<<"name">>, Info),
    Pieces = dict:fetch(<<"pieces">>, Info), % @todo verify pieces with hash
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
    HashBinString = crypto:hash(sha, BencodedInfo),
    Hash = erltorrent_helper:urlencode(HashBinString),
    {ok, {dict, Result}} = connect_to_tracker(TrackerLink, Hash, PeerId, FullSize),
    PeersIP = get_peers(dict:fetch(<<"peers">>, Result)),
    lists:map(
        fun (Peer) ->
            erltorrent_peer:start(Peer, PeerId, HashBinString, FileName, FullSize, PieceSize, self())
        end,
        PeersIP
    ),
    LastPieceLength = FullSize - (PiecesAmount - 1) * PieceSize,
    LastPieceId = PiecesAmount - 1,
    % Fill empty peaces peers and downloading pieces
    IdsList = lists:seq(0, LastPieceId),
    NewPiecesPeers = lists:foldl(fun (Id, Acc) -> dict:store(Id, [], Acc) end, PiecesPeers, IdsList),
    NewDownloadingPieces = lists:map(fun (Id) -> #downloading_piece{piece_id = Id} end, IdsList),
    NewState = State#state{
        torrent_name = FileName,
        pieces_amount = PiecesAmount,
        pieces_peers = NewPiecesPeers,
        downloading_pieces = NewDownloadingPieces,
        peer_id = PeerId,
        hash = HashBinString,
        piece_length = PieceSize,
        last_piece_length = LastPieceLength,
        last_piece_id = LastPieceId
    },
    {reply, ok, NewState};

%% @doc
%% Handle piece peers call
%%
handle_call({piece_peers, Id}, _From, State = #state{pieces_peers = PiecesPeers}) ->
    Result = case dict:is_key(Id, PiecesPeers) of
        true  -> dict:fetch(Id, PiecesPeers);
        false -> {error, piece_id_not_exist}
    end,
    {reply, Result, State};

%% @doc
%% Handle downloading piece call
%%
handle_call({downloading_piece, Id}, _From, State = #state{downloading_pieces = DownloadingPieces}) ->
    Result = case lists:keysearch(Id, #downloading_piece.piece_id, DownloadingPieces) of
        {value, Value}  -> Value;
        false           -> {error, piece_id_not_exist}
    end,
    {reply, Result, State};

%% @doc
%% Handle is end checking call
%%
handle_call(is_end, _From, State = #state{downloading_pieces = DownloadingPieces}) ->
    {reply, is_end(DownloadingPieces), State};

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
%% Handle async bitfield message from peer and assign new peers if needed
%%
handle_info({bitfield, ParsedBitfield, Ip, Port}, State = #state{pieces_peers = PiecesPeers}) ->
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
    self() ! assign_downloading_pieces,
    {noreply, State#state{pieces_peers = NewPiecesPeers}};

%% @doc
%% Handle async have message from peer and assign new peers if needed
%%
handle_info({have, PieceId, Ip, Port}, State = #state{pieces_peers = PiecesPeers}) ->
    Peers = dict:fetch(PieceId, PiecesPeers),
    NewPeers = case lists:member({Ip, Port}, Peers) of
        false -> [{Ip, Port}|Peers];
        true  -> Peers
    end,
    NewPiecesPeers = dict:store(PieceId, NewPeers, PiecesPeers),
    self() ! assign_downloading_pieces,
    {noreply, State#state{pieces_peers = NewPiecesPeers}};

%% @doc
%% Async check is end
%% @todo need test
handle_info(is_end, State = #state{torrent_name = TorrentName, downloading_pieces = DownloadingPieces}) ->
    case is_end(DownloadingPieces) of
        [_|_] ->
            ok;
        []    ->
            ok = erltorrent_helper:concat_file(TorrentName),
            lager:info("File has been downloaded successfully!"),
            exit(self(), completed)
    end,
    {noreply, State};

%% @doc
%% Assign pieces for peers to download
%% @todo need test
handle_info(assign_downloading_pieces, State = #state{}) ->
    NewDownloadingPieces = assign_downloading_pieces(State),
    self() ! is_end,
    {noreply, State#state{downloading_pieces = NewDownloadingPieces}};

%% @doc
%% Remove process from downloading pieces if it completes downloading.
%%
handle_info({'DOWN', MonitorRef, process, _Pid, completed}, State = #state{downloading_pieces = DownloadingPieces}) ->
    {value, OldDownloadingPiece} = lists:keysearch(MonitorRef, #downloading_piece.monitor_ref, DownloadingPieces),
    #downloading_piece{
        piece_id = PieceId
    } = OldDownloadingPiece,
    NewDownloadingPieces = lists:keyreplace(MonitorRef, #downloading_piece.monitor_ref, DownloadingPieces, #downloading_piece{piece_id = PieceId, status = completed}),
    self() ! assign_downloading_pieces,
    {noreply, State#state{downloading_pieces = NewDownloadingPieces}};

%% @doc
%% Remove process from downloading pieces if it crashes. Move that peer into end of queue.
%%
handle_info({'DOWN', MonitorRef, process, _Pid, _Reason}, State = #state{downloading_pieces = DownloadingPieces, pieces_peers = PiecesPeers}) ->
    % Remove peer from downloading list
    {value, OldDownloadingPiece} = lists:keysearch(MonitorRef, #downloading_piece.monitor_ref, DownloadingPieces),
    #downloading_piece{
        piece_id = PieceId,
        ip_port = {Ip, Port}
    } = OldDownloadingPiece,
    NewDownloadingPieces = lists:keyreplace(MonitorRef, #downloading_piece.monitor_ref, DownloadingPieces, #downloading_piece{piece_id = PieceId}),
    % Move peer to the end of the queue
    NewPiecesPeers = case dict:fetch(PieceId, PiecesPeers) of
        Peers when length(Peers) > 0 ->
            NewPeers = lists:append(lists:delete({Ip, Port}, Peers), [{Ip, Port}]),
            dict:store(PieceId, NewPeers, PiecesPeers);
        _ ->
            PiecesPeers
    end,
    self() ! assign_downloading_pieces,
    {noreply, State#state{downloading_pieces = NewDownloadingPieces, pieces_peers = NewPiecesPeers}};

%% @doc
%% Unknown messages
%%
handle_info(_Info, State) ->
    {noreply, State}.


%% @doc
%% Assign free peers to download pieces
%%
assign_downloading_pieces(State = #state{downloading_pieces = DownloadingPieces}) ->
    assign_downloading_pieces(DownloadingPieces, [], [], State).

assign_downloading_pieces([], Acc, _AlreadyAssigned, _State) ->
    Acc;

assign_downloading_pieces([#downloading_piece{piece_id = Id, status = false}|T], Acc, AlreadyAssigned, State) ->
    #state{
        torrent_name = TorrentName,
        pieces_peers = PiecesPeers,
        downloading_pieces = DownloadingPieces,
        peer_id = PeerId,
        hash = Hash,
        piece_length = PieceLength,
        last_piece_length = LastPieceLength,
        last_piece_id = LastPieceId
    } = State,
    Peers = dict:fetch(Id, PiecesPeers),
    % Get available peers. Available means that peer isn't assigned in this iteration yet and isn't assigned in the past. If current opened sockets for downloading is ?SOCKETS_FOR_DOWNLOADING_LIMIT, all peers aren't allowed at the moment.
    AvailablePeers = lists:filter(
        fun (Peer) ->
            AlreadyDownloading = case lists:keysearch(Peer, #downloading_piece.ip_port, DownloadingPieces) of
                false -> false;
                _     -> true
            end,
            SocketsForDownloading = length(AlreadyAssigned) + count_downloading(DownloadingPieces),
            not(lists:member(Peer, AlreadyAssigned)) and not(AlreadyDownloading) and not(SocketsForDownloading >= ?SOCKETS_FOR_DOWNLOADING_LIMIT)
        end,
        Peers
    ),
    % Assign peers to pieces if there are available peers
    DownloadingPiece = case AvailablePeers of
        [{Ip, Port}|_] ->
            CurrentPieceLength = case Id =:= LastPieceId of
                 true  -> LastPieceLength;
                 false -> PieceLength
            end,
            {ok, Pid} = erltorrent_downloader:start(TorrentName, Id, Ip, Port, self(), PeerId, Hash, CurrentPieceLength),
            Ref = erlang:monitor(process, Pid),
            NewAlreadyAssigned = [{Ip, Port}|AlreadyAssigned],
            #downloading_piece{piece_id = Id, ip_port = {Ip, Port}, monitor_ref = Ref, status = downloading};
        _ ->
            NewAlreadyAssigned = AlreadyAssigned,
            #downloading_piece{piece_id = Id}
    end,
    assign_downloading_pieces(T, [DownloadingPiece|Acc], NewAlreadyAssigned, State);

% Skip pieces with other status than `false`
assign_downloading_pieces([Other = #downloading_piece{}|T], Acc, AlreadyAssigned, State) ->
    assign_downloading_pieces(T, [Other|Acc], AlreadyAssigned, State).


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
terminate(Reason, _State) ->
    lager:info("Server terminated! Reason: ~p", [Reason]),
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
%% Make HTTP connect to tracker to get information
%%
connect_to_tracker(TrackerLink, Hash, PeerId, FullSize) ->
    inets:start(),
    Separator = case string:str(TrackerLink, "?") of 0 -> "?"; _ -> "&" end,
    FullLink = TrackerLink ++ Separator ++ "info_hash=" ++ Hash ++ "&peer_id=" ++ PeerId ++ "&port=61940&uploaded=0&downloaded=0&left=" ++ erltorrent_helper:convert_to_list(FullSize) ++ "&corrupt=0&key=4ACCCA00&event=started&numwant=200&compact=1&no_peer_id=1&supportcrypto=1&redundant=0",
    {ok, {{_Version, _Code, _ReasonPhrase}, _Headers, Body}} = httpc:request(get, {FullLink, []}, [], [{body_format, binary}]),
    erltorrent_bencoding:decode(Body).


%% @doc
%% Parse peers list
%%
get_peers(PeersList) ->
    get_peers(PeersList, []).

get_peers(<<>>, Result) ->
    lists:reverse(Result);

get_peers(PeersList, Result) ->
    <<Byte1:8, Byte2:8, Byte3:8, Byte4:8, Port:16, Rest/binary>> = PeersList,
    get_peers(Rest, [{{Byte1, Byte2, Byte3, Byte4}, Port} | Result]).


%% @doc
%% Check is all pieces downloaded
%%
is_end(DownloadingPieces) ->
    lists:filter(
        fun
            (#downloading_piece{status = completed}) -> false;
            (#downloading_piece{status = _})         -> true
        end,
        DownloadingPieces
    ).


%% @doc
%% Count how many pieces are downloading at the moment
%%
count_downloading(DownloadingPieces) ->
    lists:foldl(
        fun
            (#downloading_piece{status = downloading}, Acc) -> Acc + 1;
            (#downloading_piece{status = _}, Acc)           -> Acc
        end,
        0,
        DownloadingPieces
    ).


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
        #downloading_piece{piece_id = 1, monitor_ref = Ref1, ip_port = {{127,0,0,7}, 9874}, status = downloading},
        #downloading_piece{piece_id = 2, monitor_ref = Ref2, ip_port = {{127,0,0,2}, 9614}, status = downloading}
    ],
    NewDownloadingPieces = [
        #downloading_piece{piece_id = 0, status = false},
        #downloading_piece{piece_id = 1, monitor_ref = Ref1, ip_port = {{127,0,0,7}, 9874}, status = downloading},
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


change_downloading_piece_status_to_completed_test_() ->
    Ref1 = make_ref(),
    Ref2 = make_ref(),
    DownloadingPieces = [
        #downloading_piece{piece_id = 0, status = false},
        #downloading_piece{piece_id = 1, monitor_ref = Ref1, ip_port = {{127,0,0,7}, 9874}, status = downloading},
        #downloading_piece{piece_id = 2, monitor_ref = Ref2, ip_port = {{127,0,0,2}, 9614}, status = downloading}
    ],
    NewDownloadingPieces = [
        #downloading_piece{piece_id = 0, status = false},
        #downloading_piece{piece_id = 1, monitor_ref = Ref1, ip_port = {{127,0,0,7}, 9874}, status = downloading},
        #downloading_piece{piece_id = 2, status = completed}
    ],
    State = #state{downloading_pieces = DownloadingPieces},
    [
        ?_assertEqual(
            {noreply, State#state{downloading_pieces = NewDownloadingPieces}},
            handle_info({'DOWN', Ref2, process, pid, completed}, State)
        )
    ].


get_piece_peers_test_() ->
    PiecesPeers1 = dict:store(0, [], dict:new()),
    PiecesPeers2 = dict:store(1, [{127,0,0,3}, {127,0,0,2}], PiecesPeers1),
    State = #state{pieces_peers = PiecesPeers2},
    [
        ?_assertEqual(
            {reply, [], State},
            handle_call({piece_peers, 0}, from, State)
        ),
        ?_assertEqual(
            {reply, [{127,0,0,3}, {127,0,0,2}], State},
            handle_call({piece_peers, 1}, from, State)
        ),
        ?_assertEqual(
            {reply, {error, piece_id_not_exist}, State},
            handle_call({piece_peers, 2}, from, State)
        )
    ].


get_downloading_piece_test_() ->
    Piece1 = #downloading_piece{piece_id = 0, status = false},
    Piece2 = #downloading_piece{piece_id = 1, ip_port = {{127,0,0,7}, 9874}, status = downloading},
    Piece3 = #downloading_piece{piece_id = 2, ip_port = {{127,0,0,2}, 9614}, status = downloading},
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


