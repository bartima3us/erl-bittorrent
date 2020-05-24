%%%-------------------------------------------------------------------
%%% @author bartimaeus
%%% @copyright (C) 2019, sarunas.bartusevicius@gmail.com
%%% @doc
%%%
%%% @end
%%% Created : 18. Feb 2018 14.04
%%%-------------------------------------------------------------------
-module(erltorrent_leech_server).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

-behaviour(gen_server).

-include_lib("gen_bittorrent/include/gen_bittorrent.hrl").
-include("erltorrent.hrl").
-include("erltorrent_store.hrl").

%% API
-export([
    start_link/1,
    piece_completed/4
]).

%% API mostly for debugging purposes
-export([
    piece_peers/1,
    peer_pieces/1,
    peer_pieces/2,
    downloading_piece/1,
    count_downloading_pieces/0,
    all_pieces_except_completed/0,
    get_completion_percentage/1,
    avg_piece_download_time/0,
    failing_peers/0
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
-define(SLOW_PEERS_FAILS_LIMIT, 20).
-define(FAIL_PEERS_TTL(Fails), Fails * 15000). % ms

-ifndef(TEST).
    -define(SOCKETS_FOR_DOWNLOADING_LIMIT, 100).
-endif.

-ifdef(TEST).
    -define(SOCKETS_FOR_DOWNLOADING_LIMIT, 8).
-endif.

-record(downloading_piece, {
    key                 :: {piece_id_int(), ip_port()}, % PieceID and {Ip, Port}
    piece_id            :: piece_id_int(),
    peer                :: ip_port(),   % Currently downloading peer
    pid                 :: pid(),   % Downloader pid
    status      = false :: false | downloading | completed
}).

-record(failing_peer, {
    peer                :: ip_port(),
    fails               :: pos_integer(),   % Count
    last_fail_time      :: integer(),       % Time
    last_fail_reason    :: term()
}).

-record(state, {
    torrent_name                        :: string(),
    files                               :: string(), % @todo make a proper type
    piece_peers        = []             :: [], % [{PieceIdN, [Peer1, Peer2, ..., PeerN]}]
    peer_pieces        = []             :: [], % [{{Ip, Port}, [PieceId1, PieceId2, ..., PieceIdN]}]
    downloading_pieces = []             :: [#downloading_piece{}],
    pieces_amount                       :: integer(),
    peer_id                             :: binary(),
    hash                                :: binary(),
    piece_size                          :: integer(),
    last_piece_size                     :: integer(),
    last_piece_id                       :: integer(),
    pieces_hash                         :: binary(),
    % @todo maybe need to persist give up limit?
    give_up_limit      = 20             :: integer(),  % Give up all downloading limit if pieces hash is invalid
    end_game           = false          :: boolean(),
    pieces_left        = []             :: [integer()],
    assign_peers_timer      = false,
    blocks_in_piece                     :: integer(), % How many blocks are in piece (not the last one which is shorter)
    slow_peers         = []             :: [{ip_port(), integer()}], % @todo don't need anymore?       Slow peers and how many times each of if have failed
    failing_peers      = []             :: [#failing_peer{}] % @todo don't need anymore?
}).

% make start
% application:start(erltorrent).
% erltorrent_leech_server:download("[Commie] Banana Fish - 01 [3600C7D5].mkv.torrent").
% erltorrent_leech_server:piece_peers(4).
% erltorrent_leech_server:downloading_piece(0).

%%%===================================================================
%%% API
%%%===================================================================



%% @doc
%% Get piece peers
%%
piece_peers(Id) ->
    gen_server:call(?SERVER, {piece_peers, Id}).


%% @doc
%% Get peer pieces
%%
peer_pieces(IpPort) ->
    gen_server:call(?SERVER, {peer_pieces, IpPort}).


%% @doc
%% Get peer pieces
%%
peer_pieces(IpPort, PieceId) ->
    gen_server:call(?SERVER, {peer_pieces, IpPort, PieceId}).


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


%%
%%
%%
avg_piece_download_time() ->
    gen_server:call(?SERVER, avg_piece_download_time).


%% @doc
%% Get all pieces except completed
%%
all_pieces_except_completed() ->
    gen_server:call(?SERVER, all_pieces_except_completed).


%% @doc
%% Get all failing peers.
%%
failing_peers() ->
    gen_server:call(?SERVER, failing_peers).


%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(TorrentName) ->
    gen_server:start({local, ?SERVER}, ?MODULE, [TorrentName], []).


%%
%%
%%
piece_completed(Peer, PieceId, Sender, Time) ->
    ?SERVER ! {completed, Peer, PieceId, Sender, Time},
    ok.


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
init([TorrentName]) ->
    process_flag(trap_exit, true),
    ok = download(),
    {ok, #state{torrent_name = TorrentName}}.


%%--------------------------------------------------------------------

%% @doc
%% Handle piece peers call
%%
handle_call({piece_peers, Id}, _From, State = #state{piece_peers = PiecesPeers}) ->
    Result = case proplists:is_defined(Id, PiecesPeers) of
        true  -> proplists:get_value(Id, PiecesPeers);
        false -> {error, piece_id_not_exist}
    end,
    {reply, Result, State};

%% @doc
%% Handle peer pieces call
%%
handle_call({peer_pieces, IpPort}, _From, State = #state{peer_pieces = PeerPieces}) ->
    Result = case proplists:is_defined(IpPort, PeerPieces) of
        true  -> proplists:get_value(IpPort, PeerPieces);
        false -> {error, peer_not_exist}
    end,
    {reply, Result, State};

%% @doc
%% Handle peer pieces call
%%
handle_call({peer_pieces, IpPort, PieceId}, _From, State = #state{peer_pieces = PeerPieces}) ->
    Result = case proplists:is_defined(IpPort, PeerPieces) of
        true  ->
            lists:member(PieceId, proplists:get_value(IpPort, PeerPieces));
        false ->
            {error, peer_not_exist}
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
handle_call(all_pieces_except_completed, _From, State = #state{pieces_left = PiecesLeft}) ->
    {reply, PiecesLeft, State};

%% @doc
%% All failing peers.
%%
handle_call(failing_peers, _From, State = #state{failing_peers = FailingPeers}) ->
    {reply, FailingPeers, State};

%% @doc
%% Handle is end checking call
%%
handle_call(count_downloading_pieces, _From, State = #state{}) ->
    {reply, length(get_downloading_pieces(State)), State};


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
% @todo check if such file not exist in Mnesia before start downloading
% @todo constantly delete file from Mnesia if it not exists in download folder anymore. Also check it on app start.
handle_cast(download, State = #state{torrent_name = TorrentName, piece_peers = PiecePeers}) ->
    % @todo need to scrap data from tracker and update state constantly
    File = filename:join(["torrents", TorrentName]),
    {ok, Bin} = file:read_file(File),
    {ok, {dict, MetaInfo}} = erltorrent_bencoding:decode(Bin),
    {dict, Info} = dict:fetch(<<"info">>, MetaInfo),
    Pieces       = dict:fetch(<<"pieces">>, Info),
    PieceSize    = dict:fetch(<<"piece length">>, Info),
    BencodedInfo = binary_to_list(erltorrent_bencoding:encode(dict:fetch(<<"info">>, MetaInfo))),
    HashBinString = crypto:hash(sha, BencodedInfo),
    FileName = case erltorrent_store:read_file(HashBinString) of
        false ->
            FName = dict:fetch(<<"name">>, Info),
            erltorrent_store:insert_file(HashBinString, FName),
            FName;
        #erltorrent_store_file{file_name = FName} ->
            FName
    end,
    {FullSize, Files} = case dict:is_key(<<"length">>, Info) of
        true  ->
            TorrentFullSize = dict:fetch(<<"length">>, Info),
            {TorrentFullSize, [#{from => 0, till => TorrentFullSize, filename => FileName}]};
        false ->
            {list, TorrentFiles} = dict:fetch(<<"files">>, Info),
            lists:foldl(
                fun ({dict, Dict}, {SizeAcc, FileAcc}) ->
                    {list, FilePath} = dict:fetch(<<"path">>, Dict),
                    TorrentFileSize = dict:fetch(<<"length">>, Dict),
                    TorrentFile = filename:join([FileName] ++ FilePath),
                    NewFileAcc = case FileAcc of
                        [] ->
                            [#{from => 0, till => TorrentFileSize, filename => TorrentFile} | FileAcc];
                        [#{till := LastFileTill} | _]  ->
                            [#{from => LastFileTill, till => LastFileTill + TorrentFileSize, filename => TorrentFile} | FileAcc]
                    end,
                    {SizeAcc + TorrentFileSize, NewFileAcc}
                end,
                {0, []},
                TorrentFiles
            )
    end,
    PiecesAmount = list_to_integer(float_to_list(math:ceil(FullSize / PieceSize), [{decimals, 0}])),
    LastPieceSize = FullSize - (PiecesAmount - 1) * PieceSize,
    LastPieceId = PiecesAmount - 1,
    IdsList = lists:seq(0, LastPieceId),
    AnnounceLink  = binary_to_list(dict:fetch(<<"announce">>, MetaInfo)),
    PeerId = "-ER0000-45AF6T-NM81-", % @todo make by http://www.bittorrent.org/beps/bep_0020.html
    lager:info("File name = ~p, Piece size = ~p bytes, full file size = ~p, Pieces amount = ~p, Hash representation=~p, Hash real=~p", [FileName, PieceSize, FullSize, PiecesAmount, erltorrent_bin_to_hex:bin_to_hex(HashBinString), HashBinString]),
    {ok, _} = erltorrent_peers_crawler_sup:start_child(AnnounceLink, HashBinString, PeerId, FullSize),
    NewPiecesPeers = lists:foldl(fun (Id, Acc) -> [{Id, []} | Acc] end, PiecePeers, IdsList),
    NewState = State#state{
        files                = lists:reverse(Files),
        pieces_amount        = PiecesAmount,
        piece_peers          = NewPiecesPeers,
        peer_id              = PeerId,
        hash                 = HashBinString,
        piece_size           = PieceSize,
        last_piece_size      = LastPieceSize,
        last_piece_id        = LastPieceId,
        pieces_hash          = Pieces,
        pieces_left          = IdsList,
        blocks_in_piece      = trunc(math:ceil(PieceSize / ?REQUEST_LENGTH))
    },
    {noreply, NewState}.

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
handle_info({bitfield, ParsedBitfield, Ip, Port}, State = #state{}) ->
    Ids = lists:filtermap(
        fun
            ({Id, true})   -> {true, Id};
            ({_Id, false}) -> false
        end,
        ParsedBitfield
    ),
    State0 = add_to_peer_pieces(State, Ip, Port, Ids),
    State1 = add_to_piece_peers(State0, Ip, Port, Ids),
    self() ! assign_peers,
    {noreply, State1};

%% @doc
%% Handle async have message from peer and assign new peers if needed
%%
handle_info({have, PieceId, Ip, Port}, State = #state{}) ->
    State0 = add_to_peer_pieces(State, Ip, Port, [PieceId]),
    State1 = add_to_piece_peers(State0, Ip, Port, [PieceId]),
    {noreply, State1};

%% @doc
%% Assign pieces for peers to download
%%
handle_info(assign_peers, State = #state{}) ->
    NewState1 = assign_peers(State),
    {noreply, NewState1#state{assign_peers_timer = false}};

%% @doc
%% Piece downloaded successfully
%%
handle_info({completed, IpPort, PieceId, DownloaderPid, OverallTime}, State) ->
    #state{peer_pieces = PeerPieces} = State,
    NewState0 = remove_piece_from_piece_peers(State, PieceId),
    NewState1 = case proplists:is_defined(IpPort, PeerPieces) of
        true  ->
            Ids = proplists:get_value(IpPort, PeerPieces),
            {Pieces, EndGame} = find_not_downloading_piece(NewState0, Ids),
            lists:foldl(
                fun (Piece = #piece{piece_id = NewPieceId}, StateAcc) ->
                    ok = erltorrent_leecher:switch_piece(DownloaderPid, Piece),
                    StateAcc0 = change_downloading_piece_status(StateAcc, {PieceId, IpPort}, completed),
                    add_to_downloading_piece(StateAcc0, PieceId, NewPieceId, IpPort)
                end,
                NewState0#state{end_game = EndGame},
                Pieces
            );
        false ->
            NewState0
    end,
    Progress = get_completion_percentage(NewState1),
    [Completion] = io_lib:format("~.2f", [Progress]),
    lager:info("Completed! PieceId = ~p, IpPort=~p, completion=~p%, overall time=~p s~n", [PieceId, IpPort, list_to_float(Completion), (OverallTime / 1000)]),
    is_end(NewState1),
    self() ! assign_peers,
    {noreply, NewState1};

%% @doc
%% Remove process from downloading pieces if it crashes.
%%
handle_info({'EXIT', Pid, Reason}, State) when
    element(1, Reason) =:= socket_error;
    Reason =:= too_slow;
    Reason =:= invalid_hash ->
    #state{
        downloading_pieces = DownloadingPieces,
        assign_peers_timer = AssignPeersTimer
    } = State,
    NewState0 = case lists:keysearch(Pid, #downloading_piece.pid, DownloadingPieces) of
        {value, #downloading_piece{piece_id = PieceId, key = {_, IpPort}}} ->
            StateAcc0 = remove_from_downloading_pieces(State, {PieceId, IpPort}),
            case Reason of
                too_slow ->
                    lager:info("Stopped because too slow! PieceId=~p, IpPort=~p", [PieceId, IpPort]),
                    State1 = move_peer_to_the_end(StateAcc0, IpPort),
                    add_to_slow_peers(State1, IpPort);
                invalid_hash ->
                    lager:info("Stopped because invalid hash! PieceId=~p, IpPort=~p", [PieceId, IpPort]),
                    move_peer_to_the_end(StateAcc0, IpPort);
                {socket_error, SocketError} ->
                    StateAcc1 = move_peer_to_the_end(StateAcc0, IpPort),
                    add_peer_to_failing_peers(StateAcc1, IpPort, SocketError)
            end;
        false ->
            State
    end,
    TimerRef = case AssignPeersTimer of
        false -> erlang:send_after(1000, self(), assign_peers);
        Ref   -> Ref
    end,
    {noreply, NewState0#state{assign_peers_timer = TimerRef}};

% @todo need to think about that clause Reasons
handle_info({'EXIT', Pid, _Reason}, State = #state{downloading_pieces = DownloadingPieces}) ->
    NewState = case lists:keysearch(Pid, #downloading_piece.pid, DownloadingPieces) of
        {value, #downloading_piece{piece_id = PieceId, key = {_, IpPort}}} ->
            remove_from_downloading_pieces(State, {PieceId, IpPort});
        false ->
            State
    end,
    self() ! assign_peers,
    {noreply, NewState};

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
%%% Internal functions for state transformations
%%% All functions above always returns changed or same state
%%%===================================================================

%%
%%
%%
add_to_peer_pieces(State = #state{peer_pieces = PeerPieces}, Ip, Port, Ids) ->
    NewPeerPieces = case proplists:get_value({Ip, Port}, PeerPieces) of
        undefined -> [{{Ip, Port}, Ids} | PeerPieces];
        Pieces    -> [{{Ip, Port}, lists:usort(Pieces ++ Ids)} | proplists:delete({Ip, Port}, PeerPieces)]
    end,
    State#state{peer_pieces = NewPeerPieces}.


%%
%%
%%
add_to_piece_peers(State = #state{piece_peers = PiecePeers}, Ip, Port, Bitfield) ->
    NewPiecePeers = lists:foldl(
        fun (Id, AccPiecePeers) ->
            case proplists:get_value(Id, AccPiecePeers) of
                undefined ->
                    [{Id, [{Ip, Port}]} | AccPiecePeers];
                Peers  ->
                    case lists:member({Ip, Port}, Peers) of
                        true  -> AccPiecePeers;
                        false -> [{Id, [{Ip, Port} | Peers]} | proplists:delete(Id, AccPiecePeers)]
                    end
            end
        end,
        PiecePeers,
        Bitfield
    ),
    % Rarest first!
    State#state{piece_peers = sort_pieces_by_rarity(NewPiecePeers)}.


%%  @private
%%  Sort pieces making the rarest ones be in the beginning of the list
%%
sort_pieces_by_rarity(PiecePeers) ->
    Positions = lists:usort([ {length(Peers), Id} || {Id, Peers} <- PiecePeers ]),
    [ {Id, proplists:get_value(Id, PiecePeers)} || {_, Id} <- Positions ].


%%
%%
%%
remove_piece_from_piece_peers(State = #state{piece_peers = PiecePeers, pieces_left = PiecesLeft}, PieceId) ->
    NewPiecePeers = case proplists:is_defined(PieceId, PiecePeers) of
        true  -> proplists:delete(PieceId, PiecePeers);
        false -> PiecePeers
    end,
    State#state{piece_peers = NewPiecePeers, pieces_left = PiecesLeft -- [PieceId]}.


%%
%%
%%
%%remove_peer_from_peer_pieces(State = #state{peer_pieces = PeerPieces}, IpPort) ->
%%    NewPeerPieces = case proplists:is_defined(IpPort, PeerPieces) of
%%        true  -> proplists:delete(IpPort, PeerPieces);
%%        false -> PeerPieces
%%    end,
%%    State#state{peer_pieces = NewPeerPieces}.


%%
%%
%%
move_peer_to_the_end(State = #state{peer_pieces = PeerPieces0}, IpPort) ->
    NewPeerPieces = case proplists:is_defined(IpPort, PeerPieces0) of
        true  ->
            PeerPieces1 = proplists:get_value(IpPort, PeerPieces0),
            proplists:delete(IpPort, PeerPieces0) ++ [{IpPort, PeerPieces1}];
        false ->
            PeerPieces0
    end,
    State#state{peer_pieces = NewPeerPieces}.


%%  @todo Add a test
%%
%%
add_peer_to_failing_peers(State = #state{failing_peers = FailingPeers}, IpPort, Reason) ->
    case lists:keysearch(IpPort, #failing_peer.peer, FailingPeers) of
        {value, CurrFailingPeer = #failing_peer{fails = CurrFails}} ->
            NewFailingPeer = CurrFailingPeer#failing_peer{
                fails            = CurrFails + 1,
                last_fail_reason = Reason,
                last_fail_time   = erltorrent_helper:get_milliseconds_timestamp()
            },
            NewFailingPeers = lists:keyreplace(IpPort, #failing_peer.peer, FailingPeers, NewFailingPeer),
            State#state{failing_peers = NewFailingPeers};
        false ->
            NewFailingPeer = #failing_peer{
                peer             = IpPort,
                fails            = 1,
                last_fail_reason = Reason,
                last_fail_time   = erltorrent_helper:get_milliseconds_timestamp()
            },
            State#state{failing_peers = [NewFailingPeer | FailingPeers]}
    end.


%%  @todo Add a test
%%
%%
get_fail_peer_status(#state{failing_peers = FailingPeers}, IpPort) ->
    case lists:keysearch(IpPort, #failing_peer.peer, FailingPeers) of
        % Because it means that connection was established but for some reason it was closed.
        {value, #failing_peer{fails = 1, last_fail_reason = tcp_closed}} ->
            true;
        {value, #failing_peer{fails = Fails, last_fail_time = LastFailTime}} ->
            CurrTime = erltorrent_helper:get_milliseconds_timestamp(),
            CurrTime - LastFailTime >= ?FAIL_PEERS_TTL(Fails);
        false ->
            true
    end.


%%
%%
%%
add_to_slow_peers(State = #state{slow_peers = SlowPeers}, IpPort) ->
    NewSlowPeers = case proplists:get_value(IpPort, SlowPeers) of
        undefined               -> [{IpPort, 1} | SlowPeers];
        ?SLOW_PEERS_FAILS_LIMIT -> SlowPeers;
        Fails                   -> [{IpPort, Fails + 1} | proplists:delete(IpPort, SlowPeers)]
    end,
    State#state{slow_peers = NewSlowPeers}.


%%
%%
%%
remove_from_downloading_pieces(State = #state{downloading_pieces = DownloadingPieces}, Key) ->
    NewDownloadingPieces = lists:keydelete(Key, #downloading_piece.key, DownloadingPieces),
    State#state{downloading_pieces = NewDownloadingPieces}.


%%
%%
%%
change_downloading_piece_status(State = #state{downloading_pieces = DownloadingPieces}, Key, Status) ->
    {value, OldDP} = lists:keysearch(Key, #downloading_piece.key, DownloadingPieces),
    NewDownloadingPieces = lists:keyreplace(Key, #downloading_piece.key, DownloadingPieces, OldDP#downloading_piece{status = Status}),
    State#state{downloading_pieces = NewDownloadingPieces}.


%%
%%
%%
add_to_downloading_piece(State = #state{downloading_pieces = DownloadingPieces}, PieceId, NewPieceId, IpPort) ->
    {value, OldDP} = lists:keysearch({PieceId, IpPort}, #downloading_piece.key, DownloadingPieces),
    NewDownloadingPieces = [OldDP#downloading_piece{key = {NewPieceId, IpPort}, piece_id = NewPieceId, status = downloading} | DownloadingPieces],
    State#state{downloading_pieces = NewDownloadingPieces}.


%%%===================================================================
%%% Other internal functions
%%%===================================================================


%% @private
%% Start download
%%
download() ->
    gen_server:cast(?SERVER, download).


%%
%%
%%
is_end(#state{pieces_left = [_|_]}) ->
    ok;

is_end(#state{torrent_name = TorrentName, pieces_left = []}) ->
    lager:info("Torrent=~p download completed!", [TorrentName]),
    ok = erltorrent_sup:stop_child(TorrentName). % @todo is it a proper way to stop? Match will never happen


%% @private
%% Get currently downloading pieces
%%
get_downloading_pieces(#state{downloading_pieces = DownloadingPieces}) ->
    lists:filter(
        fun
            (#downloading_piece{status = downloading}) -> true;
            (#downloading_piece{status = _})           -> false
        end,
        DownloadingPieces
    ).


%% @private
%% Get currently downloading piece of peer
%%
get_downloading_pieces(#state{downloading_pieces = DownloadingPieces}, CheckingIpPort) ->
    lists:filter(
        fun
            (#downloading_piece{status = downloading, peer = IpPort}) when CheckingIpPort =:= IpPort -> true;
            (#downloading_piece{status = _}) -> false
        end,
        DownloadingPieces
    ).


%% @private
%% Get downloading completion percentage
%%
get_completion_percentage(State) ->
    #state{
        pieces_left        = Pieces,
        pieces_amount      = PiecesAmount
    } = State,
    DownloadingPiecesAmount = PiecesAmount - length(Pieces),
    DownloadingPiecesAmount * 100 / PiecesAmount.


%% @private
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


%%
%%  Find still not downloading piece. Constantly for next downloading.
%%  And return if end game need to be enabled.
%%
-spec find_not_downloading_piece(
    State       :: #state{},
    Ids         :: [piece_id_int()]
) ->
    {[#piece{}], EndGame :: boolean()}. % @todo remove list (#piece{} wrapper) ?

find_not_downloading_piece(State = #state{}, Ids) ->
    #state{
        downloading_pieces = DownloadingPieces,
        piece_size         = PieceSize,
        pieces_hash        = PiecesHash,
        end_game           = CurrEndGame
    } = State,
    case CurrEndGame of
        false ->
            Pieces = lists:foldl(
                fun
                    (Id, AccPieces) ->
                        case lists:keysearch(Id, #downloading_piece.piece_id, DownloadingPieces) of
                            false ->
                                CurrentPieceSize = get_current_piece_size(Id, PieceSize, State),
                                Exclude = Id * 20,
                                <<_:Exclude/binary, PieceHash:20/binary, _Rest/binary>> = PiecesHash,
                                [#piece{
                                    piece_id        = Id,
                                    last_block_id   = erlang:trunc(math:ceil(CurrentPieceSize / ?REQUEST_LENGTH)),
                                    piece_size      = CurrentPieceSize,
                                    piece_hash      = PieceHash,
                                    std_piece_size  = PieceSize
                                } | AccPieces];
                            {value, _} ->
                                AccPieces
                        end
                end,
                [],
                Ids
            ),
%%            lager:info("xxxxxxxxxx Ids=~p", [Ids]),
%%            lager:info("xxxxxxxxxx Pieces=~p", [Pieces]),
            case (erlang:length(Pieces) =< 1) of
                true  -> % End game
                    {[find_piece_under_end_game(State)], true};
                false ->
                    case lists:reverse(Pieces) of
                        [Piece | _] -> {[Piece], false};
                        []          -> {[], false}
                    end
            end;
        true -> % End game
            {[find_piece_under_end_game(State)], true}
    end.


%%
%%
%%
find_piece_under_end_game(State) ->
    lager:info("find_piece_under_end_game!"),
    #state{
        downloading_pieces = DownloadingPieces,
        piece_size         = PieceSize,
        pieces_hash        = PiecesHash
    } = State,
    AggregatedPieces = lists:foldl(fun
        (#downloading_piece{piece_id = PieceId, status = downloading}, AccRes) ->
            case proplists:get_value(PieceId, AccRes) of
                undefined -> [{PieceId, 1} | AccRes];
                CurrCount -> [{PieceId, CurrCount + 1} | proplists:delete(PieceId, AccRes)]
            end;
        (_, AccRes) -> AccRes
    end, [], DownloadingPieces),
    [{ResPieceId, _} | _] = lists:sort(fun ({_, Amt1}, {_, Amt2}) ->
        Amt1 < Amt2
    end, AggregatedPieces),
    CurrentPieceSize = get_current_piece_size(ResPieceId, PieceSize, State),
    Exclude = ResPieceId * 20,
    <<_:Exclude/binary, PieceHash:20/binary, _Rest/binary>> = PiecesHash,
    #piece{
        piece_id        = ResPieceId,
        last_block_id   = erlang:trunc(math:ceil(CurrentPieceSize / ?REQUEST_LENGTH)),
        piece_size      = CurrentPieceSize,
        piece_hash      = PieceHash,
        std_piece_size  = PieceSize
    }.


%% @private
%% Determine if piece is a last or not and get it's length
%%
get_current_piece_size(PieceId, PieceLength, #state{last_piece_id = LastPieceId, last_piece_size = LastPieceLength}) ->
    case PieceId =:= LastPieceId of
        true  -> LastPieceLength;
        false -> PieceLength
    end.


%% @private
%% Make new downloading pieces state from persisted state if it exists.
%%
%%make_downloading_pieces(Hash, IdsList) ->
%%    PersistedPieces = erltorrent_store:read_pieces(Hash),
%%    lists:map(
%%        fun (Id) ->
%%            case lists:keysearch(Id, #erltorrent_store_piece.piece_id, PersistedPieces) of
%%                false ->
%%                    #downloading_piece{piece_id = Id};
%%                {value, #erltorrent_store_piece{status = downloading}} ->
%%                    #downloading_piece{piece_id = Id};
%%                {value, #erltorrent_store_piece{status = completed}} ->
%%                    #downloading_piece{piece_id = Id, status = completed}
%%            end
%%        end,
%%        IdsList
%%    ).


%% @private
%% Assign free peers to download pieces
%%
assign_peers(State = #state{peer_pieces = PeerPieces0}) ->
    % Filter failing peers
    FilteredPeerPieces = lists:filter(
        fun ({IpPort, _}) ->
            get_fail_peer_status(State, IpPort)
        end,
        PeerPieces0
    ),
    PeerPieces1 = case FilteredPeerPieces of
        [_|_] -> FilteredPeerPieces;
        []    -> PeerPieces0
    end,
    assign_peers(PeerPieces1, State).

assign_peers([], State) ->
    State;

assign_peers([{IpPort, Ids} | T], State) ->
    #state{
        files           = Files,
        peer_id         = PeerId,
        hash            = Hash,
        end_game        = CurrEndGame
    } = State,
    % @todo maybe move this from fun because currently it is used only once
    StartPieceDownloadingFun = fun (Pieces, Ip, Port, EndGame) ->
        ST0 = lists:foldl(
            fun (Piece = #piece{piece_id = PieceId}, AccState) ->
                #state{
                    downloading_pieces = AccDownloadingPieces
                } = AccState,
                case EndGame of
                    true  -> lager:info("Starting leecher under end game. PieceId=~p, IpPort=~p", [PieceId, {Ip, Port}]);
                    false -> lager:info("Starting leecher. PieceId=~p, IpPort=~p", [PieceId, {Ip, Port}])
                end,
                {ok, Pid} = erltorrent_leecher:start_link(Files, Ip, Port, PeerId, Hash, Piece),
                % Add new downloading pieces
                AccState#state{
                    downloading_pieces = [
                        #downloading_piece{
                            key         = {PieceId, IpPort},
                            peer        = IpPort,
                            piece_id    = PieceId,
                            pid         = Pid,
                            status      = downloading
                        } | AccDownloadingPieces
                    ]
                }
            end,
            State,
            Pieces
        ),
        ST0#state{end_game = EndGame}
    end,
    PeerDownloadingPieces = erlang:length(get_downloading_pieces(State, IpPort)),
    SocketsLimitReached = erlang:length(get_downloading_pieces(State)) >= ?SOCKETS_FOR_DOWNLOADING_LIMIT,
    % @todo maybe fix this (I think limit is needed even in end game)
    NewState = case {CurrEndGame, (PeerDownloadingPieces > 0 orelse SocketsLimitReached)} of
        Res when Res =:= {true, false}; % If `end game` is on - limit doesn't matter.
                 Res =:= {true, true};  % If `end game` is on - limit doesn't matter.
                 Res =:= {false, false} % If `end game` is off - limit can't be exhausted.
        ->
            {Ip, Port} = IpPort,
            {Pieces, EndGame} = find_not_downloading_piece(State, Ids),
            StartPieceDownloadingFun(Pieces, Ip, Port, EndGame);
       {false, true} ->
            State
    end,
    assign_peers(T, NewState).


%%%===================================================================
%%% EUnit tests
%%%===================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

assign_peers_test_() ->
    Pid = list_to_pid("<0.0.1>"),
    PieceTimes = [
        [10, 12]
    ],
    PeerPieces = [
        {{{127,0,0,2}, 9870}, [1, 2, 3, 4]},
        {{{127,0,0,2}, 9871}, [3]},
        {{{127,0,0,2}, 9872}, [1, 2, 3]},
        {{{127,0,0,2}, 9873}, [2, 3]}
    ],
    PiecePeers = [
        {4, [{{127,0,0,2}, 9870}]},
        {1, [{{127,0,0,2}, 9870}, {{127,0,0,2}, 9872}]},
        {2, [{{127,0,0,2}, 9870}, {{127,0,0,2}, 9872}, {{127,0,0,2}, 9873}]},
        {3, [{{127,0,0,2}, 9870}, {{127,0,0,2}, 9871}, {{127,0,0,2}, 9872}, {{127,0,0,2}, 9873}]}
    ],
    DownloadingPieces = [
        #downloading_piece{piece_id = 1, status = downloading, key = {1, {{127,0,0,2},9872}}, peer = {{127,0,0,2},9872}, pid = Pid},
        #downloading_piece{piece_id = 2, status = downloading, key = {2, {{127,0,0,2},9873}}, peer = {{127,0,0,2},9873}, pid = Pid},
        #downloading_piece{piece_id = 3, status = completed},
        #downloading_piece{piece_id = 4, status = completed}
    ],
    PiecesHash = <<"nuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQj">>,
    State = #state{
        piece_peers             = PiecePeers,
        peer_pieces             = PeerPieces,
        downloading_pieces      = DownloadingPieces,
        piece_size              = ?REQUEST_LENGTH * 10,
        pieces_hash             = PiecesHash,
        last_piece_id           = 10,
        blocks_in_piece         = 20,
        end_game                = false
    },
    {setup,
        fun() ->
            ok = meck:new([erltorrent_leecher, erltorrent_store]),
            ok = meck:expect(erltorrent_leecher, start_link, ['_', '_', '_', '_', '_', '_', '_'], {ok, Pid}),
            ok = meck:expect(erltorrent_store, read_completed_pieces_time, ['_'], PieceTimes)
        end,
        fun(_) ->
            true = meck:validate([erltorrent_leecher, erltorrent_store]),
            ok = meck:unload([erltorrent_leecher, erltorrent_store])
        end,
        [{"No peers to assign. End game mode is enabled.",
            fun() ->
                ?assertEqual(
                    {noreply, State#state{end_game = true}},
                    handle_info(assign_peers, State#state{end_game = true})
                ),
                0 = meck:num_calls(erltorrent_leecher, start_link, ['_', '_', '_', '_', '_', '_', '_'])
            end
        },
        {"Assign new pieces to peers. Enable end game mode.",
            fun() ->
                NewState = State#state{
                    end_game            = true,
                    downloading_pieces  = [
                        #downloading_piece{piece_id = 2, status = downloading, key = {2, {{127,0,0,2},9872}}, peer = {{127,0,0,2},9872}, pid = Pid},
                        #downloading_piece{piece_id = 3, status = downloading, key = {3, {{127,0,0,2},9871}}, peer = {{127,0,0,2},9871}, pid = Pid},
                        #downloading_piece{piece_id = 1, status = downloading, key = {1, {{127,0,0,2},9870}}, peer = {{127,0,0,2},9870}, pid = Pid}
                    ]
                },
                ?assertEqual(
                    {noreply, NewState},
                    handle_info(assign_peers, State#state{downloading_pieces = []})
                ),
                3 = meck:num_calls(erltorrent_leecher, start_link, ['_', '_', '_', '_', '_', '_', '_'])
            end
        }]
    }.


add_to_peer_pieces_test_() ->
    PeerPieces1 = [{{{127,0,0,1}, 9444}, [1, 2]}],
    PeerPieces2 = [{{{127,0,0,1}, 9444}, [1, 2, 3]}],
    PeerPieces3 = [
        {{{127,0,0,1}, 8888}, [1, 2]},
        {{{127,0,0,1}, 9444}, [1, 2, 3]}
    ],
    [
        ?_assertEqual(
            #state{peer_pieces = PeerPieces1},
            add_to_peer_pieces(#state{peer_pieces = PeerPieces1}, {127,0,0,1}, 9444, [1, 2])
        ),
        ?_assertEqual(
            #state{peer_pieces = PeerPieces1},
            add_to_peer_pieces(#state{}, {127,0,0,1}, 9444, [1, 2])
        ),
        ?_assertEqual(
            #state{peer_pieces = PeerPieces2},
            add_to_peer_pieces(#state{peer_pieces = PeerPieces1}, {127,0,0,1}, 9444, [2, 3])
        ),
        ?_assertEqual(
            #state{peer_pieces = PeerPieces3},
            add_to_peer_pieces(#state{peer_pieces = PeerPieces2}, {127,0,0,1}, 8888, [1, 2])
        )
    ].


add_to_piece_peers_test_() ->
    PiecePeers1 = [{1, [{{127,0,0,1}, 9444}]}],
    PiecePeers2 = [{1, [{{127,0,0,1}, 9444}]}, {2, [{{127,0,0,1}, 9444}]}],
    PiecePeers3 = [{3, [{{127,0,0,1}, 9444}, {{127,0,0,1}, 8888}]} | PiecePeers2],
    PiecePeers4 = [{4, [{{127,0,0,1}, 9444}]} | PiecePeers3],
    [
        ?_assertEqual(
            #state{piece_peers = PiecePeers1},
            add_to_piece_peers(#state{piece_peers = PiecePeers1}, {127,0,0,1}, 9444, [1])
        ),
        ?_assertEqual(
            #state{piece_peers = PiecePeers1},
            add_to_piece_peers(#state{}, {127,0,0,1}, 9444, [1])
        ),
        ?_assertEqual(
            #state{piece_peers = PiecePeers2},
            add_to_piece_peers(#state{piece_peers = PiecePeers1}, {127,0,0,1}, 9444, [2])
        ),
        ?_assertEqual(
            #state{piece_peers = sort_pieces_by_rarity(PiecePeers4)},
            add_to_piece_peers(#state{piece_peers = PiecePeers3}, {127,0,0,1}, 9444, [2, 3, 4])
        )
    ].


add_new_peer_to_pieces_peers_test_() ->
    ParsedBitfield = [{0, true}, {1, true}, {2, true}, {3, false}],
    PiecePeers = [
        {0, [{{127,0,0,1}, 9444}]},
        {1, [{{127,0,0,1}, 9444}]},
        {2, [{{127,0,0,1}, 9444}]}
    ],
    PeerPieces = [{{{127,0,0,1}, 9444}, [0, 1, 2]}],
    State = #state{piece_peers = PiecePeers, peer_pieces = PeerPieces},
    UpdatedPeerPieces = [{{{127,0,0,1}, 8888}, [1]} | PeerPieces],
    UpdatedPiecePeers = [
        {2, [{{127,0,0,1}, 9444}]},
        {1, [{{127,0,0,1}, 8888}, {{127,0,0,1}, 9444}]},
        {0, [{{127,0,0,1}, 9444}]}
    ],
    [
        ?_assertEqual(
            {noreply, #state{piece_peers = PiecePeers, peer_pieces = PeerPieces}},
            handle_info({bitfield, ParsedBitfield, {127,0,0,1}, 9444}, #state{})
        ),
        ?_assertEqual(
            {noreply, #state{piece_peers = sort_pieces_by_rarity(UpdatedPiecePeers), peer_pieces = UpdatedPeerPieces}},
            handle_info({have, 1, {127,0,0,1}, 8888}, State)
        )
    ].


sort_pieces_by_rarity_test_() ->
    PiecePeers = [
        {0, [{{127,0,0,1}, 9444}, {{127,0,0,1}, 9445}]},
        {1, [{{127,0,0,1}, 9444}, {{127,0,0,1}, 9445}, {{127,0,0,1}, 9446}]},
        {2, [{{127,0,0,1}, 9444}, {{127,0,0,1}, 9447}]},
        {3, [{{127,0,0,1}, 9447}]}
    ],
    Result = [
        {3, [{{127,0,0,1}, 9447}]},
        {0, [{{127,0,0,1}, 9444}, {{127,0,0,1}, 9445}]},
        {2, [{{127,0,0,1}, 9444}, {{127,0,0,1}, 9447}]},
        {1, [{{127,0,0,1}, 9444}, {{127,0,0,1}, 9445}, {{127,0,0,1}, 9446}]}
    ],
    [
        ?_assertEqual(
            Result,
            sort_pieces_by_rarity(PiecePeers)
        )
    ].


move_peer_to_the_end_test_() ->
    PeerPieces = [
        {{{127,0,0,2}, 9870}, [1, 2, 3, 4]},
        {{{127,0,0,2}, 9871}, [3]},
        {{{127,0,0,2}, 9872}, [1, 2, 3]},
        {{{127,0,0,2}, 9873}, [2, 3]}
    ],
    Result = [
        {{{127,0,0,2}, 9870}, [1, 2, 3, 4]},
        {{{127,0,0,2}, 9872}, [1, 2, 3]},
        {{{127,0,0,2}, 9873}, [2, 3]},
        {{{127,0,0,2}, 9871}, [3]}
    ],
    [
        ?_assertEqual(
            #state{peer_pieces = Result},
            move_peer_to_the_end(#state{peer_pieces = PeerPieces}, {{127,0,0,2}, 9871})
        )
    ].


add_to_slow_peers_test_() ->
    [
        {"Add new slow peer.",
            fun() ->
                SlowPeers = [{{{127,0,0,2}, 9872}, 2}],
                ?assertEqual(
                    #state{slow_peers = [{{{127,0,0,2}, 9871}, 1}, {{{127,0,0,2}, 9872}, 2}]},
                    add_to_slow_peers(#state{slow_peers = SlowPeers}, {{127,0,0,2}, 9871})
                )
            end
        },
        {"Increase existing slow peer fails.",
            fun() ->
                SlowPeers = [{{{127,0,0,2}, 9872}, 2}, {{{127,0,0,2}, 9874}, 4}],
                ?assertEqual(
                    #state{slow_peers = [{{{127,0,0,2}, 9874}, 5}, {{{127,0,0,2}, 9872}, 2}]},
                    add_to_slow_peers(#state{slow_peers = SlowPeers}, {{127,0,0,2}, 9874})
                )
            end
        },
        {"Slow peer fails limit has reached.",
            fun() ->
                SlowPeers = [{{{127,0,0,2}, 9872}, 2}, {{{127,0,0,2}, 9874}, ?SLOW_PEERS_FAILS_LIMIT}],
                ?assertEqual(
                    #state{slow_peers = SlowPeers},
                    add_to_slow_peers(#state{slow_peers = SlowPeers}, {{127,0,0,2}, 9874})
                )
            end
        }
    ].


get_completion_percentage_test_() ->
    State = #state{
        pieces_left   = [1, 2],
        pieces_amount = 10
    },
    [
        ?_assertEqual(
            80.0,
            get_completion_percentage(State)
        )
    ].


%%remove_process_from_downloading_piece_test_() ->
%%    PiecesPeers1 = dict:store(0, [], dict:new()),
%%    PiecesPeers2 = dict:store(1, [{{127,0,0,7}, 9874}], PiecesPeers1),
%%    PiecesPeers3 = dict:store(2, [{{127,0,0,3}, 9547}, {{127,0,0,2}, 9614}, {{127,0,0,1}, 9612}], PiecesPeers2),
%%    Ref1 = make_ref(),
%%    Ref2 = make_ref(),
%%    DownloadingPieces = [
%%        #downloading_piece{piece_id = 0, status = false},
%%        #downloading_piece{piece_id = 1, monitor_ref = Ref1, ip_port = {{127,0,0,7}, 9874}, status = downloading},
%%        #downloading_piece{piece_id = 2, monitor_ref = Ref2, ip_port = {{127,0,0,2}, 9614}, status = downloading}
%%    ],
%%    NewDownloadingPieces = [
%%        #downloading_piece{piece_id = 0, status = false},
%%        #downloading_piece{piece_id = 1, monitor_ref = Ref1, ip_port = {{127,0,0,7}, 9874}, status = downloading},
%%        #downloading_piece{piece_id = 2, status = false}
%%    ],
%%    NewPiecesPeers = dict:store(2, [{{127,0,0,3}, 9547}, {{127,0,0,1}, 9612}, {{127,0,0,2}, 9614}], PiecesPeers3),
%%    State = #state{pieces_peers = PiecesPeers3, downloading_pieces = DownloadingPieces, pieces_amount = 100},
%%    [
%%        ?_assertEqual(
%%            {noreply, State#state{downloading_pieces = NewDownloadingPieces, pieces_peers = NewPiecesPeers}},
%%            handle_info({'DOWN', Ref2, process, pid, normal}, State)
%%        )
%%    ].
%%
%%
%%complete_piece_downloading_test_() ->
%%    Ref1 = make_ref(),
%%    Ref2 = make_ref(),
%%    PieceId = 2,
%%    Peers = [
%%        #peer{ip_port = {{127,0,0,7}, 9874}},
%%        #peer{ip_port = {{127,0,0,2}, 9614}},
%%        #peer{ip_port = {{127,0,0,7}, 9874}}
%%    ],
%%    NewPeers = [
%%        #peer{rating = 20.0, count_blocks = 10, time = 200, ip_port = {{127,0,0,2}, 9614}},
%%        #peer{ip_port = {{127,0,0,7}, 9874}},
%%        #peer{ip_port = {{127,0,0,7}, 9874}}
%%    ],
%%    DownloadingPieces = [
%%        #downloading_piece{piece_id = 0, status = false},
%%        #downloading_piece{piece_id = 1, monitor_ref = Ref1, ip_port = {{127,0,0,7}, 9874}, status = downloading},
%%        #downloading_piece{piece_id = 2, monitor_ref = Ref2, ip_port = {{127,0,0,2}, 9614}, status = downloading}
%%    ],
%%    NewDownloadingPieces = [
%%        #downloading_piece{piece_id = 0, status = false},
%%        #downloading_piece{piece_id = 1, monitor_ref = Ref1, ip_port = {{127,0,0,7}, 9874}, status = downloading},
%%        #downloading_piece{piece_id = 2, status = completed}
%%    ],
%%    PiecesPeers1 = dict:store(0, [], dict:new()),
%%    PiecesPeers2 = dict:store(1, [{{127,0,0,3}, 9614}, {{127,0,0,2}, 9614}], PiecesPeers1),
%%    State = #state{pieces_peers = PiecesPeers2, downloading_pieces = DownloadingPieces, peers = Peers, pieces_amount = 100},
%%    [
%%        ?_assertEqual(
%%            {noreply, State#state{downloading_pieces = NewDownloadingPieces, peers = NewPeers}},
%%            handle_info({completed, 10, 200, PieceId, list_to_pid("<0.0.1>")}, State)
%%        )
%%    ].


get_piece_peers_test_() ->
    PiecesPeers = [
        {0, []},
        {1, [{127,0,0,3}, {127,0,0,2}]}
    ],
    State = #state{piece_peers = PiecesPeers, pieces_amount = 100},
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
    Piece2 = #downloading_piece{piece_id = 1, status = downloading},
    Piece3 = #downloading_piece{piece_id = 2, status = downloading},
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
            ok = meck:new(erltorrent_sup),
            ok = meck:expect(erltorrent_sup, stop_child, ['_'], ok)
        end,
        fun(_) ->
            true = meck:validate(erltorrent_sup),
            ok = meck:unload(erltorrent_sup)
        end,
        [{"Somes pieces aren't downloaded.",
            fun() ->
                State = #state{
                    pieces_left = [1, 2]
                },
                ok = is_end(State),
                0 = meck:num_calls(erltorrent_sup, stop_child, ['_'])
            end
        },
        {"All pieces are downloaded.",
            fun() ->
                State = #state{
                    pieces_left = []
                },
                ok = is_end(State),
                1 = meck:num_calls(erltorrent_sup, stop_child, ['_'])
            end
        }]
    }.


%%make_downloading_pieces_test_() ->
%%    {setup,
%%        fun() ->
%%            PersistedPieces = [
%%                #erltorrent_store_piece{piece_id = 1, status = completed},
%%                #erltorrent_store_piece{piece_id = 3, status = downloading}
%%            ],
%%            ok = meck:new(erltorrent_store),
%%            ok = meck:expect(
%%                erltorrent_store,
%%                read_pieces,
%%                fun
%%                    (<<60, 10>>) ->
%%                        [];
%%                    (<<14, 52>>) ->
%%                        PersistedPieces
%%                end
%%            )
%%        end,
%%        fun(_) ->
%%            true = meck:validate(erltorrent_store),
%%            ok = meck:unload(erltorrent_store)
%%        end,
%%        [{"Without persisted pieces.",
%%            fun() ->
%%                Result = [
%%                    #downloading_piece{piece_id = 0},
%%                    #downloading_piece{piece_id = 1},
%%                    #downloading_piece{piece_id = 2},
%%                    #downloading_piece{piece_id = 3},
%%                    #downloading_piece{piece_id = 4}
%%                ],
%%                Result = make_downloading_pieces(<<60, 10>>, [0, 1, 2, 3, 4])
%%            end
%%        },
%%        {"With persisted pieces.",
%%            fun() ->
%%                Result = [
%%                    #downloading_piece{piece_id = 0},
%%                    #downloading_piece{piece_id = 1, status = completed},
%%                    #downloading_piece{piece_id = 2},
%%                    #downloading_piece{piece_id = 3},
%%                    #downloading_piece{piece_id = 4}
%%                ],
%%                Result = make_downloading_pieces(<<14, 52>>, [0, 1, 2, 3, 4])
%%            end
%%        }]
%%    }.


-endif.


