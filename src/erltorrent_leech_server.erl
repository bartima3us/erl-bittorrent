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

-include("erltorrent.hrl").
-include("erltorrent_store.hrl").

%% API
-export([
    start_link/1,
    piece_peers/1,
    downloading_piece/1,
    all_pieces_except_completed/0,
    get_completion_percentage/1,
    all_peers/0,
    count_downloading_pieces/0,
    avg_block_download_time/0
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
    monitor_ref         :: reference(), % @todo remove
    pid                 :: pid(),   % Downloader pid
    status      = false :: false | downloading | completed
}).

-record(peer_power, {
    peer                :: ip_port(),
    time                :: integer(), % The lower is the better! (Block1 received_at - requested_at) + ... + (BlockN received_at - requested_at)
    blocks_count        :: integer()  % How many blocks have already downloaded
}).

-record(state, {
    torrent_name                     :: string(),
    files                            :: string(), % @todo make a proper type
    piece_peers        = dict:new()  :: dict:type(), % [{PieceIdN, [Peer1, Peer2, ..., PeerN]}]
    peer_pieces        = dict:new()  :: dict:type(), % [{{Ip, Port}, [PieceId1, PieceId2, ..., PieceIdN]}]
    downloading_pieces = []          :: [#downloading_piece{}],
    peers_power        = []          :: [#peer_power{}],
    pieces_amount                    :: integer(),
    peer_id                          :: binary(),
    hash                             :: binary(),
    piece_size                       :: integer(), % @todo rename to piece_size
    last_piece_size                  :: integer(),
    last_piece_id                    :: integer(),
    pieces_hash                      :: binary(),
    % @todo maybe need to persist give up limit?
    give_up_limit      = 20          :: integer(),  % Give up all downloading limit if pieces hash is invalid
    end_game           = false       :: boolean(),
    pieces_left        = []          :: [integer()],
    avg_block_download_time = 1000   :: integer(),
    assign_peers_timer      = false,
    blocks_in_piece                  :: integer() % How many blocks are in piece (not the last one which is shorter)
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
%% Start download
%%
download() ->
    gen_server:cast(?SERVER, download).


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


%%
%%
%%
avg_block_download_time() ->
    gen_server:call(?SERVER, avg_block_download_time).


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
start_link(TorrentName) ->
    gen_server:start({local, ?SERVER}, ?MODULE, [TorrentName], []).



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
handle_call(all_pieces_except_completed, _From, State = #state{pieces_left = PiecesLeft}) ->
    {reply, PiecesLeft, State};

%% @doc
%% Handle is end checking call
%%
handle_call(count_downloading_pieces, _From, State = #state{}) ->
    {reply, length(get_downloading_pieces(State)), State};


%%
%%
%%
handle_call(avg_block_download_time, _From, State = #state{hash = Hash}) ->
    {reply, get_avg_block_download_time(Hash), State};


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
    PeerId = "-ER0000-45AF6T-NM81-", % @todo make random
    lager:info("File name = ~p, Piece size = ~p bytes, full file size = ~p, Pieces amount = ~p, Hash=~p", [FileName, PieceSize, FullSize, PiecesAmount, erltorrent_bin_to_hex:bin_to_hex(HashBinString)]),
    {ok, _} = erltorrent_peers_crawler_sup:start_child(AnnounceLink, HashBinString, PeerId, FullSize),
    NewPiecesPeers = lists:foldl(fun (Id, Acc) -> dict:store(Id, [], Acc) end, PiecePeers, IdsList),
    {ok, _MgrPid} = erltorrent_peer_events:start_link(),
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
        blocks_in_piece      = trunc(math:ceil(PieceSize / ?DEFAULT_REQUEST_LENGTH))
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
    NewState = assign_peers(State),
    {noreply, NewState#state{assign_peers_timer = false}};

%% @doc
%% If downloaded piece hash was invalid, update state pieces downloading state and reduce give up limit
%%
handle_info({completed, IpPort, PieceId, DownloaderPid, ParseTime, OverallTime}, State) ->
    #state{
        peer_pieces             = PeerPieces,
        avg_block_download_time = AvgBlockDownloadTime,
        blocks_in_piece         = BlocksInPiece,
        end_game                = CurrEndGame
    } = State,
    NewState0 = remove_piece_from_piece_peers(State, PieceId),
    NewState1 = case dict:is_key(IpPort, PeerPieces) of
        true  ->
            {ok, Ids} = dict:find(IpPort, PeerPieces),
            {Pieces, EndGame} = find_not_downloading_piece(NewState0, Ids),
            Timeout = case EndGame of
                false -> undefined;
                true  -> AvgBlockDownloadTime * BlocksInPiece * 20 % @todo think about constant
            end,
            % If end game just enabled, stop slow leechers
            ok = case {CurrEndGame, EndGame} of
                {false, true} -> do_speed_checking(NewState0);
                _             -> ok
            end,
            lists:foldl(
                fun (Piece = #piece{piece_id = NewPieceId}, StateAcc) ->
                    DownloaderPid ! {switch_piece, Piece, Timeout},
                    StateAcc0 = change_downloading_piece_status(StateAcc, {PieceId, IpPort}, completed),
                    add_to_downloading_piece(StateAcc0, PieceId, NewPieceId, IpPort)
                end,
                NewState0#state{end_game = EndGame},
                Pieces
            );
        false ->
            NewState0
    end,
    NewState2 = update_avg_block_download_time(NewState1),
    Progress = get_completion_percentage(NewState2),
    [Completion] = io_lib:format("~.2f", [Progress]),
    lager:info("Completed! PieceId = ~p, IpPort=~p, parse time=~p s, completion=~p%, overall time=~p s~n", [PieceId, IpPort, (ParseTime / 1000000), list_to_float(Completion), (OverallTime / 1000)]),
    is_end(NewState2),
    self() ! assign_peers,
    {noreply, NewState2};

%% @doc
%% Remove process from downloading pieces if it crashes.
%%
handle_info({'EXIT', Pid, Reason}, State) when
    Reason =:= socket_error;
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
                    % Completely remove slow peers from available peers list
                    remove_peer_from_peer_pieces(StateAcc0, IpPort);
                invalid_hash ->
                    lager:info("Stopped because invalid hash! PieceId=~p, IpPort=~p", [PieceId, IpPort]),
                    remove_peer_from_peer_pieces(StateAcc0, IpPort); % @todo change to move to end
                _        ->
                    StateAcc0
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
            StateAcc0 = remove_from_downloading_pieces(State, {PieceId, IpPort}),
            StateAcc0;
        false ->
            State
    end,
    % @todo need to make smarter algorithm
%%    {_, NewPeerPieces} = case dict:is_key(IpPort, PeerPieces) of
%%        true  -> dict:take(IpPort, PeerPieces);
%%        false -> {ok, PeerPieces}
%%    end,
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
    NewPeerPieces = case dict:is_key({Ip, Port}, PeerPieces) of
        true  -> dict:append_list({Ip, Port}, Ids, PeerPieces);
        false -> dict:store({Ip, Port}, Ids, PeerPieces)
    end,
    State#state{peer_pieces = NewPeerPieces}.


%%
%%
%%
add_to_piece_peers(State = #state{piece_peers = PiecePeers}, Ip, Port, Bitfield) ->
    NewPiecesPeers = dict:map(
        fun (Id, Peers) ->
            % Check if this IP has an iterating piece
            case proplists:get_value(Id, Bitfield) of
                true ->
                    % If there are not this IP in list yet, add it
                    case lists:member({Ip, Port}, Peers) of
                        false -> [{Ip, Port} | Peers];
                        true  -> Peers
                    end;
                _ ->
                    Peers
            end
        end,
        PiecePeers
    ),
    State#state{piece_peers = NewPiecesPeers}.


%%
%%
%%
remove_piece_from_piece_peers(State = #state{piece_peers = PiecePeers, pieces_left = PiecesLeft}, PieceId) ->
    {_Peers, NewPiecePeers} = case dict:is_key(PieceId, PiecePeers) of
        true  -> dict:take(PieceId, PiecePeers);
        false -> {[], PiecePeers}
    end,
    State#state{piece_peers = NewPiecePeers, pieces_left = PiecesLeft -- [PieceId]}.


%%
%%
%%
remove_peer_from_peer_pieces(State = #state{peer_pieces = PeerPieces}, IpPort) ->
    {_, NewPeerPieces} = case dict:is_key(IpPort, PeerPieces) of
        true  -> dict:take(IpPort, PeerPieces);
        false -> {ok, PeerPieces}
    end,
    State#state{peer_pieces = NewPeerPieces}.


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


%%
%%
%%
update_avg_block_download_time(State = #state{hash = Hash, end_game = EndGame, avg_block_download_time = AvgBlockDownloadTime}) ->
    NewAvgBlockDownloadTime = case {EndGame, AvgBlockDownloadTime} of
       {true, false} -> trunc(get_avg_block_download_time(Hash));
       {true, _}     -> AvgBlockDownloadTime;
       _             -> 0
    end,
    State#state{avg_block_download_time = NewAvgBlockDownloadTime}.


%%
%%
%%
do_speed_checking(State) ->
    #state{
        hash                = Hash,
        downloading_pieces  = DownloadingPieces
    } = State,
    AvgDownloadingTime = get_avg_block_download_time(Hash),
    % @todo don't stop such peers which has unique pieces
    spawn(
        fun () ->
            ok = lists:foreach(
                fun
                    (#downloading_piece{pid = Pid, status = downloading}) ->
                        Pid ! {check_speed, AvgDownloadingTime};
                    (_) ->
                        ok
                end,
                DownloadingPieces
            )
        end
    ),
    ok.



%%%===================================================================
%%% Other internal functions
%%%===================================================================

%% @private
%% Assign free peers to download pieces
%%
assign_peers(State = #state{peer_pieces = PeerPieces}) ->
    assign_peers(dict:to_list(PeerPieces), State).

assign_peers([], State) ->
    State;

assign_peers([{IpPort, Ids} | T], State) ->
    #state{
        files                   = Files,
        peer_id                 = PeerId,
        hash                    = Hash,
        end_game                = CurrEndGame,
        avg_block_download_time = AvgBlockDownloadTime,
        blocks_in_piece         = BlocksInPiece
    } = State,
    % @todo maybe move this from fun because currently it is used only once
    StartPieceDownloadingFun = fun (Pieces, Ip, Port, EndGame) ->
        ST0 = lists:foldl(
            fun (Piece = #piece{piece_id = PieceId}, AccState) ->
                #state{
                    downloading_pieces = AccDownloadingPieces
                } = AccState,
                Timeout = case EndGame of
                    true  -> AvgBlockDownloadTime * BlocksInPiece;
                    false -> undefined
                end,
                {ok, Pid} = erltorrent_leecher:start_link(Files, Ip, Port, PeerId, Hash, Piece, Timeout),
                lager:info("Starting leecher. PieceId=~p, IpPort=~p", [PieceId, {Ip, Port}]),
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
    PeerDownloadingPieces = length(get_downloading_pieces(State, IpPort)),
    SocketsLimitReached = length(get_downloading_pieces(State)) >= ?SOCKETS_FOR_DOWNLOADING_LIMIT,
    % @todo maybe fix this (I think limit is needed even in end game)
    NewState = case {CurrEndGame, (PeerDownloadingPieces > 0 orelse SocketsLimitReached)} of
        Res when Res =:= {true, false}; % If `end game` is on - limit doesn't matter.
                 Res =:= {true, true};  % If `end game` is on - limit doesn't matter.
                 Res =:= {false, false} % If `end game` is off - limit can't be exhausted.
        ->
            {Ip, Port} = IpPort,
            {Pieces, EndGame} = find_not_downloading_piece(State, Ids),
            % If end game just enabled, stop slow leechers
            ok = case {CurrEndGame, EndGame} of
                {false, true} -> do_speed_checking(State);
                _             -> ok
            end,
            StartPieceDownloadingFun(Pieces, Ip, Port, EndGame);
       {false, true} ->
            State
    end,
    assign_peers(T, NewState).


%%
%%
%%
is_end(#state{pieces_left = [_|_]}) ->
    ok;

is_end(#state{torrent_name = TorrentName, pieces_left = []}) ->
    lager:info("Torrent=~p download completed!", [TorrentName]),
    ok = erltorrent_sup:stop_child(TorrentName). % @todo is it a proper way to stop? Match will never happen


%%
%%
%%
get_avg_block_download_time(Hash) ->
    BlockTimes = erltorrent_store:read_blocks_time(Hash),
    % @todo Maybe don't recount from beginning every time?
    {Time, Blocks} = lists:foldl(
        fun (BlockTime, {AccTime, AccBlocks}) ->
            #erltorrent_store_block_time{
                requested_at = RequestedAt,
                received_at  = ReceivedAt
            } = BlockTime,
            case ReceivedAt of
                ReceivedAt when is_integer(RequestedAt),
                    is_integer(ReceivedAt),
                    is_integer(AccBlocks)
                    ->
                    {AccTime + (ReceivedAt - RequestedAt), AccBlocks + 1};
                undefined  ->
                    {AccTime, AccBlocks}; % @todo Need to add some fake ReceivedAt if it was requested long time ago
                _          ->
                    {AccTime, AccBlocks}
            end
        end,
        {0, 0},
        BlockTimes
    ),
    Time / Blocks.


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
    State :: #state{},
    Ids   :: [piece_id_int()]
) ->
    {[#piece{}], EndGame :: boolean()}. % @todo remove list (#piece{} wrapper) ?

find_not_downloading_piece(State = #state{}, Ids) ->
    #state{
        downloading_pieces = DownloadingPieces,
        piece_size         = PieceSize,
        pieces_hash        = PiecesHash
    } = State,
    {Pieces, EndGame} = lists:foldl(
        fun
            (_Id, Acc = {_AccPiece, false}) ->
                Acc;
            (Id, {AccPiece, true}) ->
                case lists:keysearch(Id, #downloading_piece.piece_id, DownloadingPieces) of
                    false ->
                        CurrentPieceSize = get_current_piece_size(Id, PieceSize, State),
                        Exclude = Id * 20,
                        <<_:Exclude/binary, PieceHash:20/binary, _Rest/binary>> = PiecesHash,
                        NewAccPiece = [#piece{
                            piece_id        = Id,
                            last_block_id   = trunc(math:ceil(CurrentPieceSize / ?DEFAULT_REQUEST_LENGTH)),
                            piece_size      = CurrentPieceSize,
                            piece_hash      = PieceHash,
                            std_piece_size  = PieceSize
                        } | AccPiece],
                        {NewAccPiece, (length(NewAccPiece) < 2)};
                    {value, _} ->
                        {AccPiece, true}
                end
        end,
        {[], true},
        Ids
    ),
    case Pieces of
        [Piece | _] -> {[Piece], EndGame};
        []          -> {[], EndGame}
    end.


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

%%find_end_game_piece_test_() ->
%%    DownloadingPieces = [
%%        #downloading_piece{piece_id = 1, status = downloading},
%%        #downloading_piece{piece_id = 2, status = downloading},
%%        #downloading_piece{piece_id = 3, status = downloading},
%%        #downloading_piece{piece_id = 4, status = completed},
%%        #downloading_piece{piece_id = 5, status = completed},
%%        #downloading_piece{piece_id = 6, status = downloading}
%%    ],
%%    PiecesHash = <<"nuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQj">>,
%%    State = #state{
%%        downloading_pieces = DownloadingPieces,
%%        piece_size       = ?DEFAULT_REQUEST_LENGTH * 10,
%%        pieces_hash        = PiecesHash,
%%        last_piece_id      = 10
%%    },
%%    Ids = [1, 3, 6],
%%    Result = [
%%        #piece{piece_id = 6, last_block_id = 10, piece_size = ?DEFAULT_REQUEST_LENGTH * 10, piece_hash = <<"nuYwPf0y1gILAuVAGsQj">>},
%%        #piece{piece_id = 3, last_block_id = 10, piece_size = ?DEFAULT_REQUEST_LENGTH * 10, piece_hash = <<"nuYwPf0y1gILAuVAGsQj">>},
%%        #piece{piece_id = 1, last_block_id = 10, piece_size = ?DEFAULT_REQUEST_LENGTH * 10, piece_hash = <<"nuYwPf0y1gILAuVAGsQj">>}
%%    ],
%%    [
%%        ?_assertEqual(
%%            Result,
%%            find_end_game_piece(State, Ids)
%%        )
%%    ].
%%
%%assign_peers_test_() ->
%%    Ref = make_ref(),
%%    Pid = list_to_pid("<0.0.1>"),
%%    {setup,
%%        fun() ->
%%            ok = meck:new([erltorrent_helper, erltorrent_leecher]),
%%            ok = meck:expect(erltorrent_leecher, start_link, ['_', '_', '_', '_', '_', '_', '_', '_'], {ok, Pid})
%%        end,
%%        fun(_) ->
%%            true = meck:validate([erltorrent_helper, erltorrent_leecher]),
%%            ok = meck:unload([erltorrent_helper, erltorrent_leecher])
%%        end,
%%        [{"End game mode is enabled.",
%%            fun() ->
%%                PeerPieces1 = dict:store({{127,0,0,2}, 9870}, [1, 2, 3, 4], dict:new()),
%%                PeerPieces2 = dict:store({{127,0,0,2}, 9871}, [3], PeerPieces1),
%%                PeerPieces3 = dict:store({{127,0,0,2}, 9872}, [1, 2, 3], PeerPieces2),
%%                PeerPieces4 = dict:store({{127,0,0,2}, 9873}, [2, 3], PeerPieces3),
%%                PiecePeers1 = dict:store(1, [{{127,0,0,2}, 9870}, {{127,0,0,2}, 9872}], dict:new()),
%%                PiecePeers2 = dict:store(2, [{{127,0,0,2}, 9870}, {{127,0,0,2}, 9872}, {{127,0,0,2}, 9873}], PiecePeers1),
%%                PiecePeers3 = dict:store(3, [{{127,0,0,2}, 9870}, {{127,0,0,2}, 9871}, {{127,0,0,2}, 9872}, {{127,0,0,2}, 9873}, {{127,0,0,2}, 9874}], PiecePeers2),
%%                PiecePeers4 = dict:store(4, [{{127,0,0,2}, 9870}], PiecePeers3),
%%                DownloadingPieces = [
%%                    #downloading_piece{piece_id = 1, status = downloading, key = {1, {{127,0,0,2},9872}}, peer = {{127,0,0,2},9872}, monitor_ref = Ref, pid = Pid},
%%                    #downloading_piece{piece_id = 2, status = downloading, key = {2, {{127,0,0,2},9873}}, peer = {{127,0,0,2},9873}, monitor_ref = Ref, pid = Pid},
%%                    #downloading_piece{piece_id = 3, status = completed},
%%                    #downloading_piece{piece_id = 4, status = completed}
%%                ],
%%                PiecesHash = <<"nuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQj">>,
%%                State = #state{
%%                    piece_peers        = PiecePeers4,
%%                    peer_pieces        = PeerPieces4,
%%                    downloading_pieces = DownloadingPieces,
%%                    piece_size       = ?DEFAULT_REQUEST_LENGTH * 10,
%%                    pieces_hash        = PiecesHash,
%%                    last_piece_id      = 10
%%                },
%%                NewState = State#state{
%%                    end_game = true
%%                },
%%                {noreply, NewState} = handle_info(assign_peers, State),
%%                3 = meck:num_calls(erltorrent_leecher, start_link, ['_', '_', '_', '_', '_', '_', '_', '_'])
%%            end
%%        }]
%%    }.
%%
%%add_new_peer_to_pieces_peers_test_() ->
%%    Ip = {127,0,0,1},
%%    Port = 9444,
%%    ParsedBitfield = [{0, true}, {1, false}, {2, true}, {3, true}],
%%    PiecePeers1 = dict:store(0, [], dict:new()),
%%    PiecePeers2 = dict:store(1, [{{127,0,0,2}, 9874}], PiecePeers1),
%%    PiecePeers3 = dict:store(2, [{{127,0,0,3}, 9547}, {{127,0,0,2}, 9614}], PiecePeers2),
%%    PiecePeers4 = dict:store(3, [{Ip, Port}], PiecePeers3),
%%    PiecePeers5 = dict:store(0, [{Ip, Port}], PiecePeers4),
%%    PiecePeers6 = dict:store(2, [{Ip, Port}, {{127,0,0,3}, 9547}, {{127,0,0,2}, 9614}], PiecePeers5),
%%    PiecePeers7 = dict:store(3, [{Ip, Port}], PiecePeers6),
%%    State = #state{piece_peers = PiecePeers4, downloading_pieces = [], pieces_amount = 100},
%%    [
%%        ?_assertEqual(
%%            {noreply, #state{piece_peers = PiecePeers7, downloading_pieces = [], pieces_amount = 100}},
%%            handle_info({bitfield, ParsedBitfield, Ip, Port}, State)
%%        ),
%%        ?_assertEqual(
%%            {noreply, #state{piece_peers = PiecePeers4, downloading_pieces = [], pieces_amount = 100}},
%%            handle_info({have, 3, Ip, Port}, State)
%%        ),
%%        ?_assertEqual(
%%            {noreply, #state{piece_peers = PiecePeers5, downloading_pieces = [], pieces_amount = 100}},
%%            handle_info({have, 0, Ip, Port}, State)
%%        )
%%    ].
%%
%%
%%get_completion_percentage_test_() ->
%%    DownloadingPieces = [
%%        #downloading_piece{piece_id = 0, status = false},
%%        #downloading_piece{piece_id = 1, status = downloading},
%%        #downloading_piece{piece_id = 2, status = false},
%%        #downloading_piece{piece_id = 3, status = false},
%%        #downloading_piece{piece_id = 4, status = completed},
%%        #downloading_piece{piece_id = 5, status = completed}
%%    ],
%%    [
%%        ?_assertEqual(
%%            10.0,
%%            get_completion_percentage(DownloadingPieces, 20)
%%        )
%%    ].
%%
%%
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
%%
%%
%%get_piece_peers_test_() ->
%%    PiecesPeers1 = dict:store(0, [], dict:new()),
%%    PiecesPeers2 = dict:store(1, [{127,0,0,3}, {127,0,0,2}], PiecesPeers1),
%%    State = #state{pieces_peers = PiecesPeers2, pieces_amount = 100},
%%    [
%%        ?_assertEqual(
%%            {reply, [], State},
%%            handle_call({piece_peers, 0}, from, State)
%%        ),
%%        ?_assertEqual(
%%            {reply, [{127,0,0,3}, {127,0,0,2}], State},
%%            handle_call({piece_peers, 1}, from, State)
%%        ),
%%        ?_assertEqual(
%%            {reply, {error, piece_id_not_exist}, State},
%%            handle_call({piece_peers, 2}, from, State)
%%        )
%%    ].
%%
%%
%%get_downloading_piece_test_() ->
%%    Piece1 = #downloading_piece{piece_id = 0, status = false},
%%    Piece2 = #downloading_piece{piece_id = 1, ip_port = {{127,0,0,7}, 9874}, status = downloading},
%%    Piece3 = #downloading_piece{piece_id = 2, ip_port = {{127,0,0,2}, 9614}, status = downloading},
%%    DownloadingPieces = [Piece1, Piece2, Piece3],
%%    State = #state{downloading_pieces = DownloadingPieces, pieces_amount = 100},
%%    [
%%        ?_assertEqual(
%%            {reply, Piece1, State},
%%            handle_call({downloading_piece, 0}, from, State)
%%        ),
%%        ?_assertEqual(
%%            {reply, Piece2, State},
%%            handle_call({downloading_piece, 1}, from, State)
%%        ),
%%        ?_assertEqual(
%%            {reply, {error, piece_id_not_exist}, State},
%%            handle_call({downloading_piece, 3}, from, State)
%%        )
%%    ].
%%
%%
%%check_if_all_pieces_downloaded_test_() ->
%%    {setup,
%%        fun() ->
%%            ok = meck:new(erltorrent_helper),
%%            ok = meck:expect(erltorrent_helper, concat_file, ['_'], ok),
%%            ok = meck:expect(erltorrent_helper, delete_downloaded_pieces, ['_'], ok),
%%            ok = meck:expect(erltorrent_helper, do_exit, ['_', '_'], ok)
%%        end,
%%        fun(_) ->
%%            true = meck:validate(erltorrent_helper),
%%            ok = meck:unload(erltorrent_helper)
%%        end,
%%        [{"Somes pieces aren't downloaded.",
%%            fun() ->
%%                State = #state{
%%                    file_name = "test.mkv",
%%                    downloading_pieces = [
%%                        #downloading_piece{status = completed},
%%                        #downloading_piece{status = downloading},
%%                        #downloading_piece{status = completed},
%%                        #downloading_piece{status = false},
%%                        #downloading_piece{status = false},
%%                        #downloading_piece{status = false},
%%                        #downloading_piece{status = false},
%%                        #downloading_piece{status = false}
%%                    ],
%%                    end_game = false
%%                },
%%                {noreply, State} = handle_info(is_end, State),
%%                0 = meck:num_calls(erltorrent_helper, concat_file, ['_']),
%%                0 = meck:num_calls(erltorrent_helper, delete_downloaded_pieces, ['_']),
%%                0 = meck:num_calls(erltorrent_helper, do_exit, ['_', '_'])
%%            end
%%        },
%%        {"Somes pieces aren't downloaded. Entering end game.",
%%            fun() ->
%%                State = #state{
%%                    file_name = "test.mkv",
%%                    downloading_pieces = [
%%                        #downloading_piece{status = completed},
%%                        #downloading_piece{status = downloading},
%%                        #downloading_piece{status = completed},
%%                        #downloading_piece{status = false},
%%                        #downloading_piece{status = false},
%%                        #downloading_piece{status = false},
%%                        #downloading_piece{status = false}
%%                    ],
%%                    end_game = false
%%                },
%%                NewState = State#state{end_game = true},
%%                {noreply, NewState} = handle_info(is_end, State),
%%                0 = meck:num_calls(erltorrent_helper, concat_file, ['_']),
%%                0 = meck:num_calls(erltorrent_helper, delete_downloaded_pieces, ['_']),
%%                5 = meck:num_calls(erltorrent_helper, do_exit, ['_', kill])
%%            end
%%        },
%%        {"All pieces are downloaded.",
%%            fun() ->
%%                State = #state{
%%                    file_name = "test.mkv",
%%                    downloading_pieces = [
%%                        #downloading_piece{status = completed},
%%                        #downloading_piece{status = completed},
%%                        #downloading_piece{status = completed}
%%                    ],
%%                    end_game = false
%%                },
%%                {noreply, State} = handle_info(is_end, State),
%%                1 = meck:num_calls(erltorrent_helper, concat_file, ['_']),
%%                1 = meck:num_calls(erltorrent_helper, delete_downloaded_pieces, ['_']),
%%                1 = meck:num_calls(erltorrent_helper, do_exit, ['_', completed])
%%            end
%%        }]
%%    }.
%%
%%
%%assign_downloading_pieces_test_() ->
%%    Ref = make_ref(),
%%    % 200 bytes
%%    PiecesHash = <<230, 119, 162, 11, 8, 38, 192, 0, 15, 0, 16, 17, 24, 9, 166, 181, 210, 167, 176,
%%        191, 216, 91, 239, 57, 17, 13, 169, 12, 200, 230, 119, 162, 11, 8, 38, 192, 0, 15, 0, 16, 17,
%%        24, 9, 166, 181, 210, 167, 176, 191, 216, 91, 239, 57, 17, 13, 169, 12, 200, 230, 119, 162,
%%        11, 8, 38, 192, 0, 15, 0, 16, 17, 24, 9, 166, 181, 210, 167, 176, 191, 216, 91, 239, 57, 17, 13,
%%        169, 12, 200, 230, 119, 162, 11, 8, 38, 192, 0, 15, 0, 16, 17, 24, 9, 166, 181, 210, 167, 176,
%%        191, 216, 91, 239, 57, 17, 13, 169, 12, 200, 230, 119, 162, 11, 8, 38, 192, 0, 15, 0, 16, 17,
%%        24, 9, 166, 181, 210, 167, 176, 191, 216, 91, 239, 57, 17, 13, 169, 12, 200, 230, 119, 162,
%%        11, 8, 38, 192, 0, 15, 0, 16, 17, 24, 9, 166, 181, 210, 167, 176, 191, 216, 91, 239, 57, 17, 13,
%%        169, 12, 200, 57, 17, 13, 169, 12, 200, 57, 17, 13, 169, 12, 200, 57, 17, 13, 169, 12, 200, 57,
%%        17, 13, 169, 12, 200, 12, 200>>,
%%    Peers = [
%%        #peer{ip_port = {{127,0,0,1}, 8901}},
%%        #peer{ip_port = {{127,0,0,3}, 8903}},
%%        #peer{ip_port = {{127,0,0,33}, 8933}},
%%        #peer{ip_port = {{127,0,0,2}, 8902}},
%%        #peer{ip_port = {{127,0,0,4}, 8904}},
%%        #peer{ip_port = {{127,0,0,5}, 8905}},
%%        #peer{ip_port = {{127,0,0,6}, 8906}},
%%        #peer{ip_port = {{127,0,0,7}, 8907}},
%%        #peer{ip_port = {{127,0,0,8}, 8908}},
%%        #peer{ip_port = {{127,0,0,9}, 8909}},
%%        #peer{ip_port = {{127,0,0,11}, 8911}},
%%        #peer{ip_port = {{127,0,0,22}, 8922}},
%%        #peer{ip_port = {{127,0,0,33}, 8933}},
%%        #peer{ip_port = {{127,0,0,44}, 8944}},
%%        #peer{ip_port = {{127,0,0,55}, 8955}},
%%        #peer{ip_port = {{127,0,0,66}, 8966}},
%%        #peer{ip_port = {{127,0,0,77}, 8977}}
%%    ],
%%    BaseState = #state{
%%        file_name           = "test.mkv",
%%        peer_id             = <<"P33rId">>,
%%        peers               = Peers,
%%        hash                = <<"h4sh">>,
%%        piece_size        = 16384,
%%        last_piece_size   = 4200,
%%        last_piece_id       = 10,
%%        pieces_hash         = PiecesHash,
%%        pieces_amount       = 100
%%    },
%%    Pid = list_to_pid("<0.0.8>"),
%%    {setup,
%%        fun() ->
%%            ok = meck:new([erltorrent_helper, erltorrent_downloader]),
%%            ok = meck:expect(erltorrent_helper, concat_file, ['_'], ok),
%%            ok = meck:expect(erltorrent_helper, do_exit, ['_', '_'], ok),
%%            ok = meck:expect(erltorrent_helper, do_monitor, [process, '_'], Ref),
%%            ok = meck:expect(erltorrent_downloader, start, ['_', '_', '_', '_', '_', '_', '_', '_', '_'], {ok, Pid})
%%        end,
%%        fun(_) ->
%%            true = meck:validate([erltorrent_helper, erltorrent_downloader]),
%%            ok = meck:unload([erltorrent_helper, erltorrent_downloader])
%%        end,
%%        [{"Can't assign new peer because all appropriate are busy.",
%%            fun() ->
%%                PiecesPeers = dict:store(0, [], dict:new()),
%%                PiecesPeers1 = dict:store(1, [{{127,0,0,1}, 8901}], PiecesPeers),
%%                PiecesPeers2 = dict:store(2, [{{127,0,0,3}, 8903}], PiecesPeers1),
%%                PiecesPeers3 = dict:store(3, [{{127,0,0,3}, 8903}, {{127,0,0,33}, 8933}], PiecesPeers2),
%%                State = BaseState#state{
%%                    pieces_peers = PiecesPeers3,
%%                    downloading_pieces = [
%%                        #downloading_piece{piece_id = 1, status = completed},
%%                        #downloading_piece{piece_id = 2, status = false},
%%                        #downloading_piece{piece_id = 3, monitor_ref = Ref, ip_port = {{127,0,0,3}, 8903}, status = downloading}
%%                    ]
%%                },
%%                % State is the same
%%                {noreply, State} = handle_info(assign_downloading_pieces, State),
%%                0 = meck:num_calls(erltorrent_downloader, start, ['_', '_', '_', '_', '_', '_', '_', '_']),
%%                0 = meck:num_calls(erltorrent_helper, do_monitor, [process, '_'])
%%            end
%%        },
%%        {"Can't assign new peer because socket limit is exceeded.",
%%            fun() ->
%%                PiecesPeers = dict:store(0, [], dict:new()),
%%                PiecesPeers1 = dict:store(1, [{{127,0,0,1}, 8901}], PiecesPeers),
%%                PiecesPeers2 = dict:store(2, [{{127,0,0,2}, 8902}, {{127,0,0,22}, 8922}], PiecesPeers1),
%%                PiecesPeers3 = dict:store(3, [{{127,0,0,3}, 8903}, {{127,0,0,33}, 8933}], PiecesPeers2),
%%                PiecesPeers4 = dict:store(4, [{{127,0,0,4}, 8904}, {{127,0,0,44}, 8944}], PiecesPeers3),
%%                PiecesPeers5 = dict:store(5, [{{127,0,0,5}, 8905}], PiecesPeers4),
%%                PiecesPeers6 = dict:store(6, [{{127,0,0,6}, 8906}, {{127,0,0,66}, 8966}], PiecesPeers5),
%%                PiecesPeers7 = dict:store(7, [{{127,0,0,7}, 8907}, {{127,0,0,77}, 8977}], PiecesPeers6),
%%                PiecesPeers8 = dict:store(8, [{{127,0,0,8}, 8908}], PiecesPeers7),
%%                PiecesPeers9 = dict:store(9, [{{127,0,0,9}, 8909}], PiecesPeers8),
%%                State = BaseState#state{
%%                    pieces_peers = PiecesPeers9,
%%                    downloading_pieces = [
%%                        #downloading_piece{piece_id = 1, monitor_ref = Ref, ip_port = {{127,0,0,1}, 8901}, status = downloading},
%%                        #downloading_piece{piece_id = 2, monitor_ref = Ref, ip_port = {{127,0,0,2}, 8902}, status = downloading},
%%                        #downloading_piece{piece_id = 3, monitor_ref = Ref, ip_port = {{127,0,0,3}, 8903}, status = downloading},
%%                        #downloading_piece{piece_id = 4, monitor_ref = Ref, ip_port = {{127,0,0,3}, 8903}, status = downloading},
%%                        #downloading_piece{piece_id = 5, monitor_ref = Ref, ip_port = {{127,0,0,3}, 8903}, status = downloading},
%%                        #downloading_piece{piece_id = 6, monitor_ref = Ref, ip_port = {{127,0,0,3}, 8903}, status = downloading},
%%                        #downloading_piece{piece_id = 7, monitor_ref = Ref, ip_port = {{127,0,0,3}, 8903}, status = downloading},
%%                        #downloading_piece{piece_id = 8, monitor_ref = Ref, ip_port = {{127,0,0,3}, 8903}, status = downloading},
%%                        #downloading_piece{piece_id = 9, status = false}
%%                    ]
%%                },
%%                % State is the same
%%                {noreply, State} = handle_info(assign_downloading_pieces, State),
%%                0 = meck:num_calls(erltorrent_downloader, start, ['_', '_', '_', '_', '_', '_', '_', '_']),
%%                0 = meck:num_calls(erltorrent_helper, do_monitor, [process, '_'])
%%            end
%%        },
%%        {"Can't assign new peer because the only available becomes already assigned.",
%%            fun() ->
%%                PiecesPeers = dict:store(0, [], dict:new()),
%%                PiecesPeers1 = dict:store(1, [{{127,0,0,1}, 8901}], PiecesPeers),
%%                PiecesPeers2 = dict:store(2, [{{127,0,0,3}, 8903}], PiecesPeers1),
%%                PiecesPeers3 = dict:store(3, [{{127,0,0,3}, 8903}], PiecesPeers2),
%%                State = BaseState#state{
%%                    pieces_peers = PiecesPeers3,
%%                    downloading_pieces = [
%%                        #downloading_piece{piece_id = 1, status = completed},
%%                        #downloading_piece{piece_id = 2, status = false},
%%                        #downloading_piece{piece_id = 3, status = false}
%%                    ]
%%                },
%%                NewState = State#state{
%%                    downloading_pieces = [
%%                        #downloading_piece{piece_id = 1, status = completed},
%%                        #downloading_piece{piece_id = 2, pid = Pid, monitor_ref = Ref, ip_port = {{127,0,0,3}, 8903}, status = downloading},
%%                        #downloading_piece{piece_id = 3, status = false}
%%                    ]
%%                },
%%                {noreply, NewState} = handle_info(assign_downloading_pieces, State),
%%                1 = meck:num_calls(erltorrent_downloader, start, ['_', '_', '_', '_', '_', '_', '_', '_', '_']),
%%                1 = meck:num_calls(erltorrent_helper, do_monitor, [process, '_'])
%%            end
%%        },
%%        {"New peers assigned successfully.",
%%            fun() ->
%%                PiecesPeers = dict:store(0, [], dict:new()),
%%                PiecesPeers1 = dict:store(1, [{{127,0,0,1}, 8901}], PiecesPeers),
%%                PiecesPeers2 = dict:store(2, [{{127,0,0,2}, 8902}, {{127,0,0,22}, 8922}], PiecesPeers1),
%%                PiecesPeers3 = dict:store(3, [{{127,0,0,3}, 8903}, {{127,0,0,33}, 8933}], PiecesPeers2),
%%                PiecesPeers4 = dict:store(4, [{{127,0,0,4}, 8904}, {{127,0,0,44}, 8944}], PiecesPeers3),
%%                PiecesPeers5 = dict:store(5, [{{127,0,0,5}, 8905}], PiecesPeers4),
%%                PiecesPeers6 = dict:store(6, [{{127,0,0,6}, 8906}, {{127,0,0,66}, 8966}], PiecesPeers5),
%%                PiecesPeers7 = dict:store(7, [{{127,0,0,7}, 8907}, {{127,0,0,77}, 8977}], PiecesPeers6),
%%                PiecesPeers8 = dict:store(8, [{{127,0,0,8}, 8908}], PiecesPeers7),
%%                State = BaseState#state{
%%                    pieces_peers = PiecesPeers8,
%%                    downloading_pieces = [
%%                        #downloading_piece{piece_id = 1, status = completed},
%%                        #downloading_piece{piece_id = 2, status = false},
%%                        #downloading_piece{piece_id = 3, status = false},
%%                        #downloading_piece{piece_id = 4, pid = Pid, monitor_ref = Ref, ip_port = {{127,0,0,4}, 8904}, status = downloading},
%%                        #downloading_piece{piece_id = 5, status = completed},
%%                        #downloading_piece{piece_id = 6, status = false},
%%                        #downloading_piece{piece_id = 7, status = false},
%%                        #downloading_piece{piece_id = 8, status = false}
%%                    ],
%%                    pieces_amount = 100
%%                },
%%                NewState = State#state{
%%                    downloading_pieces = [
%%                        #downloading_piece{piece_id = 1, status = completed},
%%                        #downloading_piece{piece_id = 2, pid = Pid, monitor_ref = Ref, ip_port = {{127,0,0,2}, 8902}, status = downloading},
%%                        #downloading_piece{piece_id = 3, pid = Pid, monitor_ref = Ref, ip_port = {{127,0,0,3}, 8903}, status = downloading},
%%                        #downloading_piece{piece_id = 4, pid = Pid, monitor_ref = Ref, ip_port = {{127,0,0,4}, 8904}, status = downloading},
%%                        #downloading_piece{piece_id = 5, status = completed},
%%                        #downloading_piece{piece_id = 6, pid = Pid, monitor_ref = Ref, ip_port = {{127,0,0,6}, 8906}, status = downloading},
%%                        #downloading_piece{piece_id = 7, pid = Pid, monitor_ref = Ref, ip_port = {{127,0,0,7}, 8907}, status = downloading},
%%                        #downloading_piece{piece_id = 8, pid = Pid, monitor_ref = Ref, ip_port = {{127,0,0,8}, 8908}, status = downloading}
%%                    ]
%%                },
%%                {noreply, NewState} = handle_info(assign_downloading_pieces, State),
%%                % 5 + 1 = 6 (5 from this case and 1 from one before)
%%                6 = meck:num_calls(erltorrent_downloader, start, ['_', '_', '_', '_', '_', '_', '_', '_', '_']),
%%                6 = meck:num_calls(erltorrent_helper, do_monitor, [process, '_'])
%%            end
%%        }]
%%    }.
%%
%%
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


