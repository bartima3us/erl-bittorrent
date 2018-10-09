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
-include("erltorrent_store.hrl").

%% API
-export([
    start_link/0,
    download/1,
    piece_peers/1,
    downloading_piece/1,
    all_pieces_except_completed/0,
    get_completion_percentage/2,
    all_peers/0,
    count_downloading_pieces/0
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
-define(END_GAME_PIECES_LIMIT, 5).

-ifndef(TEST).
    -define(SOCKETS_FOR_DOWNLOADING_LIMIT, 100).
-endif.

-ifdef(TEST).
    -define(SOCKETS_FOR_DOWNLOADING_LIMIT, 8).
-endif.

-record(downloading_piece, {
    key                 :: {piece_id_int(), tuple()}, % PieceID and {Ip, Port}
    piece_id            :: piece_id_int(),
    peers               :: [tuple()],
    monitor_ref         :: reference(),
    pid                 :: pid(),
    status      = false :: false | downloading | completed
}).

-record(state, {
    file_name                        :: string(),
    piece_peers        = dict:new()  :: dict:type(), % [{PieceIdN, [Peer1, Peer2, ..., PeerN]}]
    peer_pieces        = dict:new()  :: dict:type(), % [{{Ip, Port}, [PieceId1, PieceId2, ..., PieceIdN]}]
    downloading_pieces = []          :: [#downloading_piece{}],
    downloading_peers  = []          :: list(),
    pieces_amount                    :: integer(),
    peer_id                          :: binary(),
    hash                             :: binary(),
    piece_length                     :: integer(),
    last_piece_length                :: integer(),
    last_piece_id                    :: integer(),
    pieces_hash                      :: binary(),
    % @todo maybe need to persist give up limit?
    give_up_limit      = 20          :: integer(),  % Give up all downloading limit if pieces hash is invalid
    end_game           = false       :: boolean()
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
%% Get all peers
%%
all_peers() ->
    gen_server:call(?SERVER, all_peers).


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
%% Count how many pieces are downloading now
%%
count_downloading_pieces() ->
    gen_server:call(?SERVER, count_downloading_pieces).


%% @doc
%% Get all pieces except completed
%%
all_pieces_except_completed() ->
    gen_server:call(?SERVER, all_pieces_except_completed).


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
% @todo check if such file not exist in Mnesia before start downloading
% @todo constantly delete file from Mnesia if it not exists in download folder anymore. Also check it on app start.
handle_call({download, TorrentName}, _From, State = #state{piece_peers = PiecePeers}) ->
    % @todo need to scrap data from tracker and update state constantly
    File = filename:join(["torrents", TorrentName]),
    {ok, Bin} = file:read_file(File),
    {ok, {dict, MetaInfo}} = erltorrent_bencoding:decode(Bin),
    {dict, Info} = dict:fetch(<<"info">>, MetaInfo),
    Pieces       = dict:fetch(<<"pieces">>, Info),
    FullSize     = dict:fetch(<<"length">>, Info),
    PieceSize    = dict:fetch(<<"piece length">>, Info),
    TrackerLink  = binary_to_list(dict:fetch(<<"announce">>, MetaInfo)),
    PiecesAmount = list_to_integer(float_to_list(math:ceil(FullSize / PieceSize), [{decimals, 0}])),
    PeerId = "-ER0000-45AF6T-NM81-", % @todo make random
    BencodedInfo = binary_to_list(erltorrent_bencoding:encode(dict:fetch(<<"info">>, MetaInfo))),
    HashBinString = crypto:hash(sha, BencodedInfo),
    Hash = erltorrent_helper:urlencode(HashBinString),
    FileName = case erltorrent_store:read_file(HashBinString) of
        false ->
            FName = dict:fetch(<<"name">>, Info),
            erltorrent_store:insert_file(HashBinString, FName),
            FName;
        #erltorrent_store_file{file_name = FName} ->
            FName
    end,
    lager:info("File name = ~p, Piece size = ~p bytes, full file size = ~p, Pieces amount = ~p", [FileName, PieceSize, FullSize, PiecesAmount]),
    {ok, {dict, Result}} = connect_to_tracker(TrackerLink, Hash, PeerId, FullSize),
    PeersIP = get_peers(dict:fetch(<<"peers">>, Result)),
    lager:info("Peers list = ~p", [PeersIP]),
    lists:map(
        fun (Peer) ->
            erltorrent_peer:start(Peer, PeerId, HashBinString, FileName, FullSize, PieceSize, self())
        end,
        PeersIP
    ),
    LastPieceLength = FullSize - (PiecesAmount - 1) * PieceSize,
    LastPieceId = PiecesAmount - 1,
    % Fill empty pieces peers and downloading pieces
    IdsList = lists:seq(0, LastPieceId),
    NewPiecesPeers = lists:foldl(fun (Id, Acc) -> dict:store(Id, [], Acc) end, PiecePeers, IdsList),
    NewState = State#state{
        file_name           = FileName,
        pieces_amount       = PiecesAmount,
        piece_peers         = NewPiecesPeers,
        peer_id             = PeerId,
        hash                = HashBinString,
        piece_length        = PieceSize,
        last_piece_length   = LastPieceLength,
        last_piece_id       = LastPieceId,
        pieces_hash         = Pieces
    },
    erlang:send_after(5000, self(), assign_peers),
    {reply, ok, NewState};

%% @doc
%% Handle piece peers call
%%
handle_call({piece_peers, Id}, _From, State = #state{piece_peers = PiecesPeers}) ->
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
handle_call(all_pieces_except_completed, _From, State = #state{downloading_pieces = DownloadingPieces}) ->
    {reply, get_all_except_completed_pieces(DownloadingPieces), State};

%% @doc
%% Handle is end checking call
%%
handle_call(count_downloading_pieces, _From, State = #state{downloading_pieces = DownloadingPieces}) ->
    {reply, length(get_downloading_pieces(DownloadingPieces)), State};

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
%% If give up limit is 0, kill the server
%%
handle_info(_Message, State = #state{give_up_limit = 0}) ->
    lager:info("Downloading was stopped because of too many invalid pieces."),
    erltorrent_helper:do_exit(self(), server_give_up),
    {noreply, State};


%% @doc
%% Handle async bitfield message from peer and assign new peers if needed
%%
handle_info({bitfield, ParsedBitfield, Ip, Port}, State = #state{piece_peers = PiecePeers, peer_pieces = PeerPieces}) ->
    %
    % Peer pieces
    Ids = lists:filtermap(
        fun
            ({Id, true})   -> {true, Id};
            ({_Id, false}) -> false
        end,
        ParsedBitfield
    ),
    NewPeerPieces = case dict:is_key({Ip, Port}, PeerPieces) of
        true  -> dict:append_list({Ip, Port}, Ids, PeerPieces);
        false -> dict:store({Ip, Port}, Ids, PeerPieces)
    end,
    %
    % Piece peers
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
        PiecePeers
    ),
    {noreply, State#state{piece_peers = NewPiecesPeers, peer_pieces = NewPeerPieces}};

%% @doc
%% Handle async have message from peer and assign new peers if needed
%%
handle_info({have, PieceId, Ip, Port}, State = #state{piece_peers = PiecePeers, peer_pieces = PeerPieces}) ->
    %
    % Peer pieces
    NewPeerPieces = case dict:is_key({Ip, Port}, PeerPieces) of
        true  -> dict:append({Ip, Port}, PieceId, PeerPieces);
        false -> dict:store({Ip, Port}, PieceId, PeerPieces)
    end,
    %
    % Piece peers
    Peers = dict:fetch(PieceId, PiecePeers),
    NewPeers = case lists:member({Ip, Port}, Peers) of
        false -> [{Ip, Port}|Peers];
        true  -> Peers
    end,
    NewPiecePeers = dict:store(PieceId, NewPeers, PiecePeers),
    {noreply, State#state{piece_peers = NewPiecePeers, peer_pieces = NewPeerPieces}};

%% @doc
%% Async check is end
%%
handle_info(is_end, State = #state{piece_peers = PiecePeers, file_name = FileName, downloading_pieces = DownloadingPieces, end_game = EndGame}) ->
    case dict:is_empty(PiecePeers) of
        true ->
            ok = erltorrent_helper:concat_file(FileName),
            ok = erltorrent_helper:delete_downloaded_pieces(FileName),
            lager:info("File has been downloaded successfully!"),
            erltorrent_helper:do_exit(self(), completed);
        false ->
            ok
    end,

%%    NewEndGame = case get_all_except_completed_pieces(DownloadingPieces) of
%%        Result when length(Result) > ?END_GAME_PIECES_LIMIT ->
%%            EndGame;
%%        Result when length(Result) =< ?END_GAME_PIECES_LIMIT andalso length(Result) > 0 ->
%%            lager:info("The end game has been started!"),
%%            lists:map(fun (#downloading_piece{pid = Pid}) -> erltorrent_helper:do_exit(Pid, kill) end, Result),
%%            true;
%%        []    ->
%%            ok = erltorrent_helper:concat_file(FileName),
%%            ok = erltorrent_helper:delete_downloaded_pieces(FileName),
%%            lager:info("File has been downloaded successfully!"),
%%            erltorrent_helper:do_exit(self(), completed),
%%            EndGame
%%    end,
    {noreply, State#state{end_game = false}};

%% @doc
%% Assign pieces for peers to download
%%
%%handle_info(assign_downloading_pieces, State = #state{}) ->
%%    NewDownloadingPieces = assign_downloading_pieces(State),
%%    check_is_end(State),
%%    erlang:send_after(1000, self(), assign_downloading_pieces),
%%    {noreply, State#state{downloading_pieces = NewDownloadingPieces}};

handle_info(assign_peers, State = #state{}) ->
    NewState = assign_peers(State),
    check_is_end(State),
    erlang:send_after(1000, self(), assign_peers),
    {noreply, NewState};

%% @doc
%% Remove process from downloading pieces if it completes downloading.
%%
handle_info({completed, PieceId, From}, State = #state{piece_peers = PiecePeers, downloading_pieces  = DownloadingPieces}) ->
    Peers = dict:fetch(PieceId, PiecePeers),
    lists:map(
        fun (Peer) ->
            case lists:keysearch({PieceId, Peer}, #downloading_piece.key, DownloadingPieces) of
                {value, #downloading_piece{pid = Pid}} ->
                    Pid ! {completed, PieceId};
                false ->
                    ok
            end
        end,
        Peers
    ),
    NewDownloadingPieces = lists:keyreplace(PieceId, #downloading_piece.piece_id, DownloadingPieces, #downloading_piece{piece_id = PieceId, status = completed}),
    check_is_end(State),
    {noreply, State#state{downloading_pieces = NewDownloadingPieces}};

%% @doc
%% Remove process from downloading pieces if it completes downloading.
%%
handle_info({continue, PieceId, Count, UpdatedCount}, State = #state{piece_peers = PiecePeers, downloading_pieces  = DownloadingPieces}) ->
    Peers = dict:fetch(PieceId, PiecePeers),
    lists:map(
        fun (Peer) ->
            case lists:keysearch({PieceId, Peer}, #downloading_piece.key, DownloadingPieces) of
                {value, #downloading_piece{pid = Pid}} ->
                    Pid ! {continue, PieceId, Count, UpdatedCount};
                false ->
                    ok
            end
        end,
        Peers
    ),
    {noreply, State};

%% @doc
%% If downloaded piece hash was invalid, update state pieces downloading state and reduce give up limit
%%
%%handle_info({'DOWN', MonitorRef, process, _Pid, invalid_hash}, State = #state{downloading_pieces = DownloadingPieces, pieces_peers = PiecesPeers, peers = Peers, give_up_limit = GiveUpLimit}) ->
%%    {value, #downloading_piece{piece_id = PieceId, ip_port = IpPort}} = lists:keysearch(MonitorRef, #downloading_piece.monitor_ref, DownloadingPieces),
%%    NewGiveUpLimit = GiveUpLimit - 1,
%%    lager:info("Piece (ID=~p) hash is invalid! Tries left = ~p.", [PieceId, NewGiveUpLimit]),
%%    {NewDownloadingPieces, NewPiecesPeers} = update_state_after_invalid_piece(MonitorRef, DownloadingPieces, PiecesPeers),
%%    % Penalty for invalid piece! Make peer rating undefined.
%%    {value, Peer} = lists:keysearch(IpPort, #peer.ip_port, Peers),
%%    NewPeers = lists:sort(lists:keyreplace(IpPort, #peer.ip_port, Peers, Peer#peer{rating = undefined, count_blocks = 0, time = 0})),
%%    {noreply, State#state{downloading_pieces = NewDownloadingPieces, pieces_peers = NewPiecesPeers, give_up_limit = NewGiveUpLimit, peers = NewPeers}};

handle_info({'DOWN', MonitorRef, process, _Pid, {full_complete, IpPort}}, State = #state{piece_peers = PiecePeers, peer_pieces = PeerPieces, downloading_peers = DownloadingPeers}) ->
    {Pieces, NewPeers} = dict:take(IpPort, PeerPieces),
    NewPiecesPeers = dict:filter(
        fun (Id, _) ->
            not(lists:member(Id, Pieces))
        end,
        PiecePeers
    ),
    {noreply, State#state{piece_peers = NewPiecesPeers, peer_pieces = NewPeers, downloading_peers = lists:delete(IpPort, DownloadingPeers)}};

%% @doc
%% Remove process from downloading pieces if it crashes. Move that peer into end of queue.
%%
handle_info({'DOWN', MonitorRef, process, _Pid, _Reason}, State = #state{downloading_pieces = DownloadingPieces, peer_pieces = PeerPieces, downloading_peers = DownloadingPeers}) ->
    {value, #downloading_piece{key = {_, IpPort}}} = lists:keysearch(MonitorRef, #downloading_piece.monitor_ref, DownloadingPieces),
    {_, NewPeerPieces} = dict:take(IpPort, PeerPieces),
%%    {NewDownloadingPieces, NewPiecesPeers} = update_state_after_invalid_piece(MonitorRef, DownloadingPieces, PiecesPeers),
    {noreply, State#state{peer_pieces = NewPeerPieces, downloading_peers = lists:delete(IpPort, DownloadingPeers)}};

%% @doc
%% Unknown messages
%%
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
%% Check is downloading ended
%%
check_is_end(#state{end_game = false}) ->
    self() ! is_end;

check_is_end(#state{end_game = true}) ->
    erlang:send_after(3000, self(), is_end).


%% @doc
%% Get still not started downloading pieces
%%
get_not_downloading_pieces(DownloadingPieces) ->
    lists:filter(
        fun
            (#downloading_piece{status = false}) -> true;
            (#downloading_piece{status = _})     -> false
        end,
        DownloadingPieces
    ).


%% @doc
%% Get currently downloading pieces
%%
get_downloading_pieces(DownloadingPieces) ->
    lists:filter(
        fun
            (#downloading_piece{status = downloading}) -> true;
            (#downloading_piece{status = _})     -> false
        end,
        DownloadingPieces
    ).


%% @doc
%% Get downloading pieces
%%
get_all_except_completed_pieces(DownloadingPieces) ->
    lists:filter(
        fun
            (#downloading_piece{status = completed}) -> false;
            (#downloading_piece{status = _})         -> true
        end,
        DownloadingPieces
    ).


%% @doc
%% Get completed pieces
%%
get_completed_pieces(DownloadingPieces) ->
    lists:filter(
        fun
            (#downloading_piece{status = completed}) -> true;
            (#downloading_piece{status = _})         -> false
        end,
        DownloadingPieces
    ).


%% @doc
%% Get downloading completion percentage
%%
get_completion_percentage(Pieces, PiecesAmount) ->
    DownloadingPiecesAmount = length(get_completed_pieces(Pieces)),
    DownloadingPiecesAmount * 100 / PiecesAmount.


%% @doc
%% If piece downloading was invalid, remove peer from downloading list and move it to the end of available peers.
%%
%%update_state_after_invalid_piece(MonitorRef, DownloadingPieces, PiecesPeers) ->
%%    % Remove peer from downloading list
%%    case lists:keysearch(MonitorRef, #downloading_piece.monitor_ref, DownloadingPieces) of
%%        {value, OldDownloadingPiece} ->
%%            #downloading_piece{
%%                piece_id = PieceId,
%%                ip_port = {Ip, Port}
%%            } = OldDownloadingPiece,
%%            NewDownloadingPieces = lists:keyreplace(MonitorRef, #downloading_piece.monitor_ref, DownloadingPieces, #downloading_piece{piece_id = PieceId}),
%%            % Move peer to the end of the queue
%%            NewPiecesPeers = case dict:fetch(PieceId, PiecesPeers) of
%%                Peers when length(Peers) > 0 ->
%%                    NewPeers = lists:append(lists:delete({Ip, Port}, Peers), [{Ip, Port}]),
%%                    dict:store(PieceId, NewPeers, PiecesPeers);
%%                _ ->
%%                    PiecesPeers
%%            end,
%%            {NewDownloadingPieces, NewPiecesPeers};
%%        false ->
%%            {DownloadingPieces, PiecesPeers}
%%    end.


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


%% @doc
%% Assign free peers to download pieces
%%
assign_peers(State = #state{peer_pieces = PeerPieces, downloading_peers = DownloadingPeers}) ->
    PeerPiecesList = dict:to_list(PeerPieces),
    assign_peers(PeerPiecesList, DownloadingPeers, State).

assign_peers([], _DownloadingPeers, State) ->
    State;

assign_peers([{IpPort, Ids}|T], DownloadingPeers, State) ->
%%    lager:info("Trying to assign! Ip=~p, DownloadingPeers=~p", [IpPort, DownloadingPeers]),
    #state{
        file_name           = FileName,
        downloading_pieces  = DownloadingPieces,
        peer_id             = PeerId,
        hash                = Hash,
        piece_length        = PieceLength,
        pieces_hash         = PiecesHash
    } = State,
    case lists:member(IpPort, DownloadingPeers) orelse length(DownloadingPeers) >= ?SOCKETS_FOR_DOWNLOADING_LIMIT of
        true ->
            NewDownloadingPeers = [],
            NewDownloadingPieces = [];
        false ->
            {Ip, Port} = IpPort,
%%            lager:info("Assigning IP=~p", [IpPort]),
            PieceData = lists:map(
                fun (Id) ->
                    CurrentPieceLength = get_current_piece_length(Id, PieceLength, State),
                    Exclude = Id * 20,
                    <<_:Exclude/binary, PieceHash:20/binary, _Rest/binary>> = PiecesHash,
                    #piece{
                        piece_id        = Id,
                        last_block_id   = trunc(math:ceil(CurrentPieceLength / ?DEFAULT_REQUEST_LENGTH)),
                        piece_length    = CurrentPieceLength,
                        piece_hash      = PieceHash
                    }
                end,
                Ids
            ),
            {ok, Pid} = erltorrent_downloader:start(FileName, Ip, Port, self(), PeerId, Hash, PieceData),
            Ref = erltorrent_helper:do_monitor(process, Pid),
            %
            % Make new downloading pieces
            NewDownloadingPieces = lists:map(
                fun (Id) ->
                    #downloading_piece{key = {Id, IpPort}, piece_id = Id, monitor_ref = Ref, pid = Pid, status = downloading}
                end,
                Ids
            ),
            NewDownloadingPeers = [IpPort]
    end,
    NewState = State#state{
        downloading_pieces = lists:append(DownloadingPieces, NewDownloadingPieces),
        downloading_peers  = lists:append(DownloadingPeers, NewDownloadingPeers)
    },
    assign_peers(T, lists:append(DownloadingPeers, NewDownloadingPeers), NewState).


%%assign_downloading_pieces(State = #state{downloading_pieces = DownloadingPieces}) ->
%%    assign_downloading_pieces(DownloadingPieces, [], [], State).
%%
%%assign_downloading_pieces([], Acc, _AlreadyAssigned, _State) ->
%%    lists:sort(Acc);
%%
%%assign_downloading_pieces([#downloading_piece{piece_id = Id, status = false}|T], Acc, AlreadyAssigned, State) ->
%%    #state{
%%        file_name           = FileName,
%%        pieces_peers        = PiecesPeers,
%%        downloading_pieces  = DownloadingPieces,
%%        peers               = AllPeers,
%%        peer_id             = PeerId,
%%        hash                = Hash,
%%        piece_length        = PieceLength,
%%        pieces_hash         = PiecesHash
%%    } = State,
%%    CurrentPiecesPeers = dict:fetch(Id, PiecesPeers),
%%    AvailablePeers = lists:filtermap(
%%        fun (#peer{ip_port = IpPort}) ->
%%            % Make new piece peers list from sorted all peers list by rating
%%            case lists:member(IpPort, CurrentPiecesPeers) of
%%                % Get available peers. Available means that peer isn't assigned in this iteration yet and isn't assigned in the past. If current opened sockets for downloading is ?SOCKETS_FOR_DOWNLOADING_LIMIT, all peers aren't allowed at the moment.
%%                true  ->
%%                    AlreadyDownloading = case lists:keysearch(IpPort, #downloading_piece.ip_port, DownloadingPieces) of
%%                        false -> false;
%%                        _     -> true
%%                    end,
%%                    SocketsForDownloading = length(AlreadyAssigned) + count_downloading(DownloadingPieces),
%%                    FilterResult = not(lists:member(IpPort, AlreadyAssigned)) and not(AlreadyDownloading) and not(SocketsForDownloading >= ?SOCKETS_FOR_DOWNLOADING_LIMIT),
%%                    case FilterResult of
%%                        true  -> {true, IpPort};
%%                        false -> false
%%                    end;
%%                false ->
%%                    false
%%            end
%%        end,
%%        AllPeers
%%    ),
%%    % Assign peers to pieces if there are available peers
%%    DownloadingPiece = case AvailablePeers of
%%        [{Ip, Port}|_] ->
%%            CurrentPieceLength = get_current_piece_length(Id, PieceLength, State),
%%            Exclude = Id * 20,
%%            <<_:Exclude/binary, PieceHash:20/binary, _Rest/binary>> = PiecesHash,
%%            {ok, Pid} = erltorrent_downloader:start(FileName, Id, Ip, Port, self(), PeerId, Hash, CurrentPieceLength, PieceHash),
%%            Ref = erltorrent_helper:do_monitor(process, Pid),
%%            NewAlreadyAssigned = [{Ip, Port}|AlreadyAssigned],
%%            #downloading_piece{piece_id = Id, ip_port = {Ip, Port}, monitor_ref = Ref, pid = Pid, status = downloading};
%%        _ ->
%%            NewAlreadyAssigned = AlreadyAssigned,
%%            #downloading_piece{piece_id = Id}
%%    end,
%%    assign_downloading_pieces(T, [DownloadingPiece|Acc], NewAlreadyAssigned, State);
%%
%%% Skip pieces with other status than `false`
%%assign_downloading_pieces([Other = #downloading_piece{}|T], Acc, AlreadyAssigned, State) ->
%%    assign_downloading_pieces(T, [Other|Acc], AlreadyAssigned, State).


%% @doc
%% Determine if piece is a last or not and get it's length
%%
get_current_piece_length(PieceId, PieceLength, #state{last_piece_id = LastPieceId, last_piece_length = LastPieceLength}) ->
    case PieceId =:= LastPieceId of
        true  -> LastPieceLength;
        false -> PieceLength
    end.


%% @doc
%% Make new downloading pieces state from persisted state if it exists.
%%
make_downloading_pieces(Hash, IdsList) ->
    PersistedPieces = erltorrent_store:read_pieces(Hash),
    lists:map(
        fun (Id) ->
            case lists:keysearch(Id, #erltorrent_store_piece.piece_id, PersistedPieces) of
                false ->
                    #downloading_piece{piece_id = Id};
                {value, #erltorrent_store_piece{status = downloading}} ->
                    #downloading_piece{piece_id = Id};
                {value, #erltorrent_store_piece{status = completed}} ->
                    #downloading_piece{piece_id = Id, status = completed}
            end
        end,
        IdsList
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
    PiecePeers1 = dict:store(0, [], dict:new()),
    PiecePeers2 = dict:store(1, [{{127,0,0,2}, 9874}], PiecePeers1),
    PiecePeers3 = dict:store(2, [{{127,0,0,3}, 9547}, {{127,0,0,2}, 9614}], PiecePeers2),
    PiecePeers4 = dict:store(3, [{Ip, Port}], PiecePeers3),
    PiecePeers5 = dict:store(0, [{Ip, Port}], PiecePeers4),
    PiecePeers6 = dict:store(2, [{Ip, Port}, {{127,0,0,3}, 9547}, {{127,0,0,2}, 9614}], PiecePeers5),
    PiecePeers7 = dict:store(3, [{Ip, Port}], PiecePeers6),
    State = #state{piece_peers = PiecePeers4, downloading_pieces = [], pieces_amount = 100},
    [
        ?_assertEqual(
            {noreply, #state{piece_peers = PiecePeers7, downloading_pieces = [], pieces_amount = 100}},
            handle_info({bitfield, ParsedBitfield, Ip, Port}, State)
        ),
        ?_assertEqual(
            {noreply, #state{piece_peers = PiecePeers4, downloading_pieces = [], pieces_amount = 100}},
            handle_info({have, 3, Ip, Port}, State)
        ),
        ?_assertEqual(
            {noreply, #state{piece_peers = PiecePeers5, downloading_pieces = [], pieces_amount = 100}},
            handle_info({have, 0, Ip, Port}, State)
        )
    ].


get_completion_percentage_test_() ->
    DownloadingPieces = [
        #downloading_piece{piece_id = 0, status = false},
        #downloading_piece{piece_id = 1, status = downloading},
        #downloading_piece{piece_id = 2, status = false},
        #downloading_piece{piece_id = 3, status = false},
        #downloading_piece{piece_id = 4, status = completed},
        #downloading_piece{piece_id = 5, status = completed}
    ],
    [
        ?_assertEqual(
            10.0,
            get_completion_percentage(DownloadingPieces, 20)
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
    State = #state{pieces_peers = PiecesPeers3, downloading_pieces = DownloadingPieces, pieces_amount = 100},
    [
        ?_assertEqual(
            {noreply, State#state{downloading_pieces = NewDownloadingPieces, pieces_peers = NewPiecesPeers}},
            handle_info({'DOWN', Ref2, process, pid, normal}, State)
        )
    ].


complete_piece_downloading_test_() ->
    Ref1 = make_ref(),
    Ref2 = make_ref(),
    PieceId = 2,
    Peers = [
        #peer{ip_port = {{127,0,0,7}, 9874}},
        #peer{ip_port = {{127,0,0,2}, 9614}},
        #peer{ip_port = {{127,0,0,7}, 9874}}
    ],
    NewPeers = [
        #peer{rating = 20.0, count_blocks = 10, time = 200, ip_port = {{127,0,0,2}, 9614}},
        #peer{ip_port = {{127,0,0,7}, 9874}},
        #peer{ip_port = {{127,0,0,7}, 9874}}
    ],
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
    PiecesPeers1 = dict:store(0, [], dict:new()),
    PiecesPeers2 = dict:store(1, [{{127,0,0,3}, 9614}, {{127,0,0,2}, 9614}], PiecesPeers1),
    State = #state{pieces_peers = PiecesPeers2, downloading_pieces = DownloadingPieces, peers = Peers, pieces_amount = 100},
    [
        ?_assertEqual(
            {noreply, State#state{downloading_pieces = NewDownloadingPieces, peers = NewPeers}},
            handle_info({completed, 10, 200, PieceId, list_to_pid("<0.0.1>")}, State)
        )
    ].


get_piece_peers_test_() ->
    PiecesPeers1 = dict:store(0, [], dict:new()),
    PiecesPeers2 = dict:store(1, [{127,0,0,3}, {127,0,0,2}], PiecesPeers1),
    State = #state{pieces_peers = PiecesPeers2, pieces_amount = 100},
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
    State = #state{downloading_pieces = DownloadingPieces, pieces_amount = 100},
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


check_if_all_pieces_downloaded_test_() ->
    {setup,
        fun() ->
            ok = meck:new(erltorrent_helper),
            ok = meck:expect(erltorrent_helper, concat_file, ['_'], ok),
            ok = meck:expect(erltorrent_helper, delete_downloaded_pieces, ['_'], ok),
            ok = meck:expect(erltorrent_helper, do_exit, ['_', '_'], ok)
        end,
        fun(_) ->
            true = meck:validate(erltorrent_helper),
            ok = meck:unload(erltorrent_helper)
        end,
        [{"Somes pieces aren't downloaded.",
            fun() ->
                State = #state{
                    file_name = "test.mkv",
                    downloading_pieces = [
                        #downloading_piece{status = completed},
                        #downloading_piece{status = downloading},
                        #downloading_piece{status = completed},
                        #downloading_piece{status = false},
                        #downloading_piece{status = false},
                        #downloading_piece{status = false},
                        #downloading_piece{status = false},
                        #downloading_piece{status = false}
                    ],
                    end_game = false
                },
                {noreply, State} = handle_info(is_end, State),
                0 = meck:num_calls(erltorrent_helper, concat_file, ['_']),
                0 = meck:num_calls(erltorrent_helper, delete_downloaded_pieces, ['_']),
                0 = meck:num_calls(erltorrent_helper, do_exit, ['_', '_'])
            end
        },
        {"Somes pieces aren't downloaded. Entering end game.",
            fun() ->
                State = #state{
                    file_name = "test.mkv",
                    downloading_pieces = [
                        #downloading_piece{status = completed},
                        #downloading_piece{status = downloading},
                        #downloading_piece{status = completed},
                        #downloading_piece{status = false},
                        #downloading_piece{status = false},
                        #downloading_piece{status = false},
                        #downloading_piece{status = false}
                    ],
                    end_game = false
                },
                NewState = State#state{end_game = true},
                {noreply, NewState} = handle_info(is_end, State),
                0 = meck:num_calls(erltorrent_helper, concat_file, ['_']),
                0 = meck:num_calls(erltorrent_helper, delete_downloaded_pieces, ['_']),
                5 = meck:num_calls(erltorrent_helper, do_exit, ['_', kill])
            end
        },
        {"All pieces are downloaded.",
            fun() ->
                State = #state{
                    file_name = "test.mkv",
                    downloading_pieces = [
                        #downloading_piece{status = completed},
                        #downloading_piece{status = completed},
                        #downloading_piece{status = completed}
                    ],
                    end_game = false
                },
                {noreply, State} = handle_info(is_end, State),
                1 = meck:num_calls(erltorrent_helper, concat_file, ['_']),
                1 = meck:num_calls(erltorrent_helper, delete_downloaded_pieces, ['_']),
                1 = meck:num_calls(erltorrent_helper, do_exit, ['_', completed])
            end
        }]
    }.


assign_downloading_pieces_test_() ->
    Ref = make_ref(),
    % 200 bytes
    PiecesHash = <<230, 119, 162, 11, 8, 38, 192, 0, 15, 0, 16, 17, 24, 9, 166, 181, 210, 167, 176,
        191, 216, 91, 239, 57, 17, 13, 169, 12, 200, 230, 119, 162, 11, 8, 38, 192, 0, 15, 0, 16, 17,
        24, 9, 166, 181, 210, 167, 176, 191, 216, 91, 239, 57, 17, 13, 169, 12, 200, 230, 119, 162,
        11, 8, 38, 192, 0, 15, 0, 16, 17, 24, 9, 166, 181, 210, 167, 176, 191, 216, 91, 239, 57, 17, 13,
        169, 12, 200, 230, 119, 162, 11, 8, 38, 192, 0, 15, 0, 16, 17, 24, 9, 166, 181, 210, 167, 176,
        191, 216, 91, 239, 57, 17, 13, 169, 12, 200, 230, 119, 162, 11, 8, 38, 192, 0, 15, 0, 16, 17,
        24, 9, 166, 181, 210, 167, 176, 191, 216, 91, 239, 57, 17, 13, 169, 12, 200, 230, 119, 162,
        11, 8, 38, 192, 0, 15, 0, 16, 17, 24, 9, 166, 181, 210, 167, 176, 191, 216, 91, 239, 57, 17, 13,
        169, 12, 200, 57, 17, 13, 169, 12, 200, 57, 17, 13, 169, 12, 200, 57, 17, 13, 169, 12, 200, 57,
        17, 13, 169, 12, 200, 12, 200>>,
    Peers = [
        #peer{ip_port = {{127,0,0,1}, 8901}},
        #peer{ip_port = {{127,0,0,3}, 8903}},
        #peer{ip_port = {{127,0,0,33}, 8933}},
        #peer{ip_port = {{127,0,0,2}, 8902}},
        #peer{ip_port = {{127,0,0,4}, 8904}},
        #peer{ip_port = {{127,0,0,5}, 8905}},
        #peer{ip_port = {{127,0,0,6}, 8906}},
        #peer{ip_port = {{127,0,0,7}, 8907}},
        #peer{ip_port = {{127,0,0,8}, 8908}},
        #peer{ip_port = {{127,0,0,9}, 8909}},
        #peer{ip_port = {{127,0,0,11}, 8911}},
        #peer{ip_port = {{127,0,0,22}, 8922}},
        #peer{ip_port = {{127,0,0,33}, 8933}},
        #peer{ip_port = {{127,0,0,44}, 8944}},
        #peer{ip_port = {{127,0,0,55}, 8955}},
        #peer{ip_port = {{127,0,0,66}, 8966}},
        #peer{ip_port = {{127,0,0,77}, 8977}}
    ],
    BaseState = #state{
        file_name           = "test.mkv",
        peer_id             = <<"P33rId">>,
        peers               = Peers,
        hash                = <<"h4sh">>,
        piece_length        = 16384,
        last_piece_length   = 4200,
        last_piece_id       = 10,
        pieces_hash         = PiecesHash,
        pieces_amount       = 100
    },
    Pid = list_to_pid("<0.0.8>"),
    {setup,
        fun() ->
            ok = meck:new([erltorrent_helper, erltorrent_downloader]),
            ok = meck:expect(erltorrent_helper, concat_file, ['_'], ok),
            ok = meck:expect(erltorrent_helper, do_exit, ['_', '_'], ok),
            ok = meck:expect(erltorrent_helper, do_monitor, [process, '_'], Ref),
            ok = meck:expect(erltorrent_downloader, start, ['_', '_', '_', '_', '_', '_', '_', '_', '_'], {ok, Pid})
        end,
        fun(_) ->
            true = meck:validate([erltorrent_helper, erltorrent_downloader]),
            ok = meck:unload([erltorrent_helper, erltorrent_downloader])
        end,
        [{"Can't assign new peer because all appropriate are busy.",
            fun() ->
                PiecesPeers = dict:store(0, [], dict:new()),
                PiecesPeers1 = dict:store(1, [{{127,0,0,1}, 8901}], PiecesPeers),
                PiecesPeers2 = dict:store(2, [{{127,0,0,3}, 8903}], PiecesPeers1),
                PiecesPeers3 = dict:store(3, [{{127,0,0,3}, 8903}, {{127,0,0,33}, 8933}], PiecesPeers2),
                State = BaseState#state{
                    pieces_peers = PiecesPeers3,
                    downloading_pieces = [
                        #downloading_piece{piece_id = 1, status = completed},
                        #downloading_piece{piece_id = 2, status = false},
                        #downloading_piece{piece_id = 3, monitor_ref = Ref, ip_port = {{127,0,0,3}, 8903}, status = downloading}
                    ]
                },
                % State is the same
                {noreply, State} = handle_info(assign_downloading_pieces, State),
                0 = meck:num_calls(erltorrent_downloader, start, ['_', '_', '_', '_', '_', '_', '_', '_']),
                0 = meck:num_calls(erltorrent_helper, do_monitor, [process, '_'])
            end
        },
        {"Can't assign new peer because socket limit is exceeded.",
            fun() ->
                PiecesPeers = dict:store(0, [], dict:new()),
                PiecesPeers1 = dict:store(1, [{{127,0,0,1}, 8901}], PiecesPeers),
                PiecesPeers2 = dict:store(2, [{{127,0,0,2}, 8902}, {{127,0,0,22}, 8922}], PiecesPeers1),
                PiecesPeers3 = dict:store(3, [{{127,0,0,3}, 8903}, {{127,0,0,33}, 8933}], PiecesPeers2),
                PiecesPeers4 = dict:store(4, [{{127,0,0,4}, 8904}, {{127,0,0,44}, 8944}], PiecesPeers3),
                PiecesPeers5 = dict:store(5, [{{127,0,0,5}, 8905}], PiecesPeers4),
                PiecesPeers6 = dict:store(6, [{{127,0,0,6}, 8906}, {{127,0,0,66}, 8966}], PiecesPeers5),
                PiecesPeers7 = dict:store(7, [{{127,0,0,7}, 8907}, {{127,0,0,77}, 8977}], PiecesPeers6),
                PiecesPeers8 = dict:store(8, [{{127,0,0,8}, 8908}], PiecesPeers7),
                PiecesPeers9 = dict:store(9, [{{127,0,0,9}, 8909}], PiecesPeers8),
                State = BaseState#state{
                    pieces_peers = PiecesPeers9,
                    downloading_pieces = [
                        #downloading_piece{piece_id = 1, monitor_ref = Ref, ip_port = {{127,0,0,1}, 8901}, status = downloading},
                        #downloading_piece{piece_id = 2, monitor_ref = Ref, ip_port = {{127,0,0,2}, 8902}, status = downloading},
                        #downloading_piece{piece_id = 3, monitor_ref = Ref, ip_port = {{127,0,0,3}, 8903}, status = downloading},
                        #downloading_piece{piece_id = 4, monitor_ref = Ref, ip_port = {{127,0,0,3}, 8903}, status = downloading},
                        #downloading_piece{piece_id = 5, monitor_ref = Ref, ip_port = {{127,0,0,3}, 8903}, status = downloading},
                        #downloading_piece{piece_id = 6, monitor_ref = Ref, ip_port = {{127,0,0,3}, 8903}, status = downloading},
                        #downloading_piece{piece_id = 7, monitor_ref = Ref, ip_port = {{127,0,0,3}, 8903}, status = downloading},
                        #downloading_piece{piece_id = 8, monitor_ref = Ref, ip_port = {{127,0,0,3}, 8903}, status = downloading},
                        #downloading_piece{piece_id = 9, status = false}
                    ]
                },
                % State is the same
                {noreply, State} = handle_info(assign_downloading_pieces, State),
                0 = meck:num_calls(erltorrent_downloader, start, ['_', '_', '_', '_', '_', '_', '_', '_']),
                0 = meck:num_calls(erltorrent_helper, do_monitor, [process, '_'])
            end
        },
        {"Can't assign new peer because the only available becomes already assigned.",
            fun() ->
                PiecesPeers = dict:store(0, [], dict:new()),
                PiecesPeers1 = dict:store(1, [{{127,0,0,1}, 8901}], PiecesPeers),
                PiecesPeers2 = dict:store(2, [{{127,0,0,3}, 8903}], PiecesPeers1),
                PiecesPeers3 = dict:store(3, [{{127,0,0,3}, 8903}], PiecesPeers2),
                State = BaseState#state{
                    pieces_peers = PiecesPeers3,
                    downloading_pieces = [
                        #downloading_piece{piece_id = 1, status = completed},
                        #downloading_piece{piece_id = 2, status = false},
                        #downloading_piece{piece_id = 3, status = false}
                    ]
                },
                NewState = State#state{
                    downloading_pieces = [
                        #downloading_piece{piece_id = 1, status = completed},
                        #downloading_piece{piece_id = 2, pid = Pid, monitor_ref = Ref, ip_port = {{127,0,0,3}, 8903}, status = downloading},
                        #downloading_piece{piece_id = 3, status = false}
                    ]
                },
                {noreply, NewState} = handle_info(assign_downloading_pieces, State),
                1 = meck:num_calls(erltorrent_downloader, start, ['_', '_', '_', '_', '_', '_', '_', '_', '_']),
                1 = meck:num_calls(erltorrent_helper, do_monitor, [process, '_'])
            end
        },
        {"New peers assigned successfully.",
            fun() ->
                PiecesPeers = dict:store(0, [], dict:new()),
                PiecesPeers1 = dict:store(1, [{{127,0,0,1}, 8901}], PiecesPeers),
                PiecesPeers2 = dict:store(2, [{{127,0,0,2}, 8902}, {{127,0,0,22}, 8922}], PiecesPeers1),
                PiecesPeers3 = dict:store(3, [{{127,0,0,3}, 8903}, {{127,0,0,33}, 8933}], PiecesPeers2),
                PiecesPeers4 = dict:store(4, [{{127,0,0,4}, 8904}, {{127,0,0,44}, 8944}], PiecesPeers3),
                PiecesPeers5 = dict:store(5, [{{127,0,0,5}, 8905}], PiecesPeers4),
                PiecesPeers6 = dict:store(6, [{{127,0,0,6}, 8906}, {{127,0,0,66}, 8966}], PiecesPeers5),
                PiecesPeers7 = dict:store(7, [{{127,0,0,7}, 8907}, {{127,0,0,77}, 8977}], PiecesPeers6),
                PiecesPeers8 = dict:store(8, [{{127,0,0,8}, 8908}], PiecesPeers7),
                State = BaseState#state{
                    pieces_peers = PiecesPeers8,
                    downloading_pieces = [
                        #downloading_piece{piece_id = 1, status = completed},
                        #downloading_piece{piece_id = 2, status = false},
                        #downloading_piece{piece_id = 3, status = false},
                        #downloading_piece{piece_id = 4, pid = Pid, monitor_ref = Ref, ip_port = {{127,0,0,4}, 8904}, status = downloading},
                        #downloading_piece{piece_id = 5, status = completed},
                        #downloading_piece{piece_id = 6, status = false},
                        #downloading_piece{piece_id = 7, status = false},
                        #downloading_piece{piece_id = 8, status = false}
                    ],
                    pieces_amount = 100
                },
                NewState = State#state{
                    downloading_pieces = [
                        #downloading_piece{piece_id = 1, status = completed},
                        #downloading_piece{piece_id = 2, pid = Pid, monitor_ref = Ref, ip_port = {{127,0,0,2}, 8902}, status = downloading},
                        #downloading_piece{piece_id = 3, pid = Pid, monitor_ref = Ref, ip_port = {{127,0,0,3}, 8903}, status = downloading},
                        #downloading_piece{piece_id = 4, pid = Pid, monitor_ref = Ref, ip_port = {{127,0,0,4}, 8904}, status = downloading},
                        #downloading_piece{piece_id = 5, status = completed},
                        #downloading_piece{piece_id = 6, pid = Pid, monitor_ref = Ref, ip_port = {{127,0,0,6}, 8906}, status = downloading},
                        #downloading_piece{piece_id = 7, pid = Pid, monitor_ref = Ref, ip_port = {{127,0,0,7}, 8907}, status = downloading},
                        #downloading_piece{piece_id = 8, pid = Pid, monitor_ref = Ref, ip_port = {{127,0,0,8}, 8908}, status = downloading}
                    ]
                },
                {noreply, NewState} = handle_info(assign_downloading_pieces, State),
                % 5 + 1 = 6 (5 from this case and 1 from one before)
                6 = meck:num_calls(erltorrent_downloader, start, ['_', '_', '_', '_', '_', '_', '_', '_', '_']),
                6 = meck:num_calls(erltorrent_helper, do_monitor, [process, '_'])
            end
        }]
    }.


make_downloading_pieces_test_() ->
    {setup,
        fun() ->
            PersistedPieces = [
                #erltorrent_store_piece{piece_id = 1, status = completed},
                #erltorrent_store_piece{piece_id = 3, status = downloading}
            ],
            ok = meck:new(erltorrent_store),
            ok = meck:expect(
                erltorrent_store,
                read_pieces,
                fun
                    (<<60, 10>>) ->
                        [];
                    (<<14, 52>>) ->
                        PersistedPieces
                end
            )
        end,
        fun(_) ->
            true = meck:validate(erltorrent_store),
            ok = meck:unload(erltorrent_store)
        end,
        [{"Without persisted pieces.",
            fun() ->
                Result = [
                    #downloading_piece{piece_id = 0},
                    #downloading_piece{piece_id = 1},
                    #downloading_piece{piece_id = 2},
                    #downloading_piece{piece_id = 3},
                    #downloading_piece{piece_id = 4}
                ],
                Result = make_downloading_pieces(<<60, 10>>, [0, 1, 2, 3, 4])
            end
        },
        {"With persisted pieces.",
            fun() ->
                Result = [
                    #downloading_piece{piece_id = 0},
                    #downloading_piece{piece_id = 1, status = completed},
                    #downloading_piece{piece_id = 2},
                    #downloading_piece{piece_id = 3},
                    #downloading_piece{piece_id = 4}
                ],
                Result = make_downloading_pieces(<<14, 52>>, [0, 1, 2, 3, 4])
            end
        }]
    }.


-endif.


