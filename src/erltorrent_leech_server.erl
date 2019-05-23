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
-define(END_GAME_PIECES_LIMIT, 5).
-define(SUPER_SLOW, 1000).

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
    file_name                        :: string(),
    piece_peers        = dict:new()  :: dict:type(), % [{PieceIdN, [Peer1, Peer2, ..., PeerN]}]
    peer_pieces        = dict:new()  :: dict:type(), % [{{Ip, Port}, [PieceId1, PieceId2, ..., PieceIdN]}]
    downloading_pieces = []          :: [#downloading_piece{}],
    downloading_peers  = []          :: [ip_port()],
    peers_power        = []          :: [#peer_power{}],
    pieces_amount                    :: integer(),
    peer_id                          :: binary(),
    hash                             :: binary(),
    piece_length                     :: integer(),
    last_piece_length                :: integer(),
    last_piece_id                    :: integer(),
    pieces_hash                      :: binary(),
    % @todo maybe need to persist give up limit?
    give_up_limit      = 20          :: integer(),  % Give up all downloading limit if pieces hash is invalid
    end_game           = false       :: boolean(),
    pieces_left        = []          :: [integer()],
    avg_block_download_time = 0      :: integer(),
    assign_peers_timer      = false,
    speed_checking_steps    = []     :: [integer()]
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
init(TorrentName) ->
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
handle_call(count_downloading_pieces, _From, State = #state{downloading_pieces = DownloadingPieces}) ->
    {reply, length(get_downloading_pieces(DownloadingPieces)), State};


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
%%    {list, Files}     = dict:fetch(<<"files">>, Info),
%%    lager:info("xxxxxxxxx Files=~p", [Files]),
    FullSize     = dict:fetch(<<"length">>, Info),
    PieceSize    = dict:fetch(<<"piece length">>, Info),
    AnnounceLink  = binary_to_list(dict:fetch(<<"announce">>, MetaInfo)),
    PiecesAmount = list_to_integer(float_to_list(math:ceil(FullSize / PieceSize), [{decimals, 0}])),
    PeerId = "-ER0000-45AF6T-NM81-", % @todo make random
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
    lager:info("File name = ~p, Piece size = ~p bytes, full file size = ~p, Pieces amount = ~p", [FileName, PieceSize, FullSize, PiecesAmount]),
    {ok, _} = erltorrent_peers_crawler_sup:start_child(FileName, AnnounceLink, HashBinString, PeerId, FullSize, PieceSize),
    LastPieceLength = FullSize - (PiecesAmount - 1) * PieceSize,
    LastPieceId = PiecesAmount - 1,
    % Fill empty pieces peers and downloading pieces
    IdsList = lists:seq(0, LastPieceId),
    NewPiecesPeers = lists:foldl(fun (Id, Acc) -> dict:store(Id, [], Acc) end, PiecePeers, IdsList),
    {ok, _MgrPid} = erltorrent_peer_events:start_link(),
    NewState = State#state{
        file_name            = FileName,
        pieces_amount        = PiecesAmount,
        piece_peers          = NewPiecesPeers,
        peer_id              = PeerId,
        hash                 = HashBinString,
        piece_length         = PieceSize,
        last_piece_length    = LastPieceLength,
        last_piece_id        = LastPieceId,
        pieces_hash          = Pieces,
        pieces_left          = IdsList,
        speed_checking_steps = lists:seq(80, 95, 5)
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
    % Peer pieces
    Ids = lists:filtermap(
        fun
            ({Id, true})   -> {true, Id};
            ({_Id, false}) -> false
        end,
        ParsedBitfield
    ),
    State0 = add_to_peer_pieces(State, Ip, Port, Ids),
    % Piece peers
    State1 = add_to_piece_peers(State0, Ip, Port, Ids),
    self() ! assign_peers,
    {noreply, State1};

%% @doc
%% Handle async have message from peer and assign new peers if needed
%%
handle_info({have, PieceId, Ip, Port}, State = #state{}) ->
    % Peer pieces
    State0 = add_to_peer_pieces(State, Ip, Port, [PieceId]),
    % Piece peers
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
%%handle_info({'DOWN', MonitorRef, process, _Pid, invalid_hash}, State = #state{downloading_pieces = DownloadingPieces, pieces_peers = PiecesPeers, peers = Peers, give_up_limit = GiveUpLimit}) ->
%%    {value, #downloading_piece{piece_id = PieceId, ip_port = IpPort}} = lists:keysearch(MonitorRef, #downloading_piece.monitor_ref, DownloadingPieces),
%%    NewGiveUpLimit = GiveUpLimit - 1,
%%    lager:info("Piece (ID=~p) hash is invalid! Tries left = ~p.", [PieceId, NewGiveUpLimit]),
%%    {NewDownloadingPieces, NewPiecesPeers} = update_state_after_invalid_piece(MonitorRef, DownloadingPieces, PiecesPeers),
%%    % Penalty for invalid piece! Make peer rating undefined.
%%    {value, Peer} = lists:keysearch(IpPort, #peer.ip_port, Peers),
%%    NewPeers = lists:sort(lists:keyreplace(IpPort, #peer.ip_port, Peers, Peer#peer{rating = undefined, count_blocks = 0, time = 0})),
%%    {noreply, State#state{downloading_pieces = NewDownloadingPieces, pieces_peers = NewPiecesPeers, give_up_limit = NewGiveUpLimit, peers = NewPeers}};

handle_info({completed, IpPort, PieceId, DownloaderPid, ParseTime, _EndGame, OverallTime}, State) ->
    #state{
        peer_pieces = PeerPieces
    } = State,
    NewState0 = remove_piece_from_piece_peers(State, PieceId),
    % @todo check is end game enabled ant not call find_not_downloading_piece/2 if so
    NewState1 = case dict:is_key(IpPort, PeerPieces) of
        true  ->
            {ok, Ids} = dict:find(IpPort, PeerPieces),
            case find_not_downloading_piece(NewState0, Ids) of
                Pieces = [_|_] ->
                    lists:foldl(
                        fun (Piece = #piece{piece_id = NewPieceId}, StateAcc) ->
                            DownloaderPid ! {switch_piece, Piece, false},
                            StateAcc0 = change_downloading_piece_status(StateAcc, {PieceId, IpPort}, completed, fun (_, _) -> ok end),
                            StateAcc1 = add_to_downloading_piece(StateAcc0, PieceId, NewPieceId, IpPort),
                            StateAcc1
                        end,
                        NewState0#state{end_game = false},
                        Pieces
                    );
                % If it's the last one piece, enable end game
                [] ->
                    lager:info("End game mode is enabled"),
                    ExtraFun = fun (_State, #downloading_piece{pid = Pid}) ->
                        erlang:unlink(Pid),
                        erltorrent_helper:do_exit(DownloaderPid, kill)
                    end,
                    StateAcc0 = change_downloading_piece_status(NewState0, {PieceId, IpPort}, completed, ExtraFun()),
                    StateAcc1 = remove_from_downloading_peers(StateAcc0, IpPort),
                    StateAcc1#state{end_game = true}
            end;
        false ->
            NewState0
    end,
    NewState2 = update_avg_block_download_time(NewState1),
    Progress = get_completion_percentage(NewState2),
    [Completion] = io_lib:format("~.2f", [Progress]),
    lager:info("Completed! PieceId = ~p, IpPort=~p, parse time=~p s, completion=~p%, overall time=~p s~n", [PieceId, IpPort, (ParseTime / 1000000), list_to_float(Completion), (OverallTime / 1000)]),
    is_end(NewState2),
    NewState3 = do_speed_checking(NewState2, Progress),
    self() ! assign_peers,
    {noreply, NewState3};

%% @doc
%% Remove process from downloading pieces if it crashes.
%%
handle_info({'EXIT', Pid, Reason}, State) when Reason =:= socket_error; Reason =:= too_slow ->
    #state{
        downloading_pieces = DownloadingPieces,
        assign_peers_timer = AssignPeersTimer
    } = State,
    % @todo DRY all handle_info({'EXIT'...
    NewState0 = case lists:keysearch(Pid, #downloading_piece.pid, DownloadingPieces) of
        {value, #downloading_piece{piece_id = PieceId, key = {_, IpPort}}} ->
            StateAcc0 = remove_from_downloading_pieces(State, {PieceId, IpPort}),
            StateAcc1 = remove_from_downloading_peers(StateAcc0, IpPort),
            case Reason of
                too_slow ->
                    lager:info("Stopped because too slow! PieceId=~p, IpPort=~p", [PieceId, IpPort]),
                    % Completely remove slow peers from available peers list
                    StateAcc2 = remove_peer_from_peer_pieces(StateAcc1, IpPort),
                    StateAcc2;
                _        ->
                    StateAcc1
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
            StateAcc1 = remove_from_downloading_peers(StateAcc0, IpPort),
            StateAcc1;
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
%%% Internal functions for state transformation
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
remove_from_downloading_peers(State = #state{downloading_peers = DownloadingPeers}, IpPort) ->
    NewDownloadingPeers = lists:delete(IpPort, DownloadingPeers),
    State#state{downloading_peers = NewDownloadingPeers}.


%%
%%
%%
remove_from_downloading_pieces(State = #state{downloading_pieces = DownloadingPieces}, Key) ->
    NewDownloadingPieces = lists:keydelete(Key, #downloading_piece.key, DownloadingPieces),
    State#state{downloading_pieces = NewDownloadingPieces}.


%%
%%
%%
change_downloading_piece_status(State = #state{downloading_pieces = DownloadingPieces}, Key, Status, ExtraFun) ->
    {value, OldDP} = lists:keysearch(Key, #downloading_piece.key, DownloadingPieces),
    NewDownloadingPieces = lists:keyreplace(Key, #downloading_piece.key, DownloadingPieces, OldDP#downloading_piece{status = Status}),
    ok = ExtraFun(State, OldDP),
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
do_speed_checking(State = #state{speed_checking_steps = []}, _Progress) ->
    State;

do_speed_checking(State, Progress) ->
    #state{
        hash                 = Hash,
        downloading_pieces   = DownloadingPieces,
        speed_checking_steps = SpeedCheckingSteps
    } = State,
    [CurrentStep | OtherSteps] = SpeedCheckingSteps,
    case CurrentStep =< Progress of
        true ->
            AvgDownloadingTime = get_avg_block_download_time(Hash),
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
            State#state{speed_checking_steps = OtherSteps};
        false ->
            State
    end.



%%%===================================================================
%%% Other internal functions
%%%===================================================================

%% @private
%% Assign free peers to download pieces
%%
assign_peers(State = #state{peer_pieces = PeerPieces, downloading_peers = DownloadingPeers, downloading_pieces = DownloadingPieces, end_game = EndGame}) ->
    PeerPiecesList = case EndGame of
        false -> dict:to_list(PeerPieces);
        true  -> erltorrent_helper:shuffle_list(dict:to_list(PeerPieces))
    end,
    assign_peers(PeerPiecesList, DownloadingPeers, DownloadingPieces, State).

assign_peers([], _DownloadingPeers, _DownloadingPieces, State) ->
    State;

assign_peers([{IpPort, Ids} | T], DownloadingPeers, DownloadingPieces, State) ->
    #state{
        file_name               = FileName,
        downloading_pieces      = DownloadingPieces,
        downloading_peers       = DownloadingPeers,
        peer_id                 = PeerId,
        hash                    = Hash,
        end_game                = CurrentEndGame,
        avg_block_download_time = AvgBlockDownloadTime
    } = State,
    StartPieceDownloadingFun = fun (Pieces, Ip, Port, EndGame) ->
        lists:foldl(
            fun (Piece = #piece{piece_id = PieceId, last_block_id = LastBlockId}, AccState) ->
                #state{
                    downloading_pieces = AccDownloadingPieces,
                    downloading_peers  = AccDownloadingPeers
                } = AccState,
                {ok, Pid} = erltorrent_leecher:start_link(FileName, Ip, Port, PeerId, Hash, Piece, EndGame, AvgBlockDownloadTime * LastBlockId),
                lager:info("Starting leecher. PieceId=~p, IpPort=~p", [PieceId, {Ip, Port}]),
                %
                % Make new downloading pieces
                NewDownloadingPieces = [
                    #downloading_piece{
                        key         = {PieceId, IpPort},
                        peer        = IpPort,
                        piece_id    = PieceId,
                        pid         = Pid,
                        status      = downloading
                    }
                ],
                NewDownloadingPeers = [IpPort],
                AccState#state{
                    downloading_pieces = lists:append(AccDownloadingPieces, NewDownloadingPieces),
                    downloading_peers  = lists:usort(lists:append(AccDownloadingPeers, NewDownloadingPeers)),
                    end_game           = EndGame
                }
            end,
            State,
            Pieces
        )
    end,
    NewState = case {CurrentEndGame, (lists:member(IpPort, DownloadingPeers) orelse (length(DownloadingPeers) >= ?SOCKETS_FOR_DOWNLOADING_LIMIT))} of
       Res when Res =:= {true, false}; % If `end game` is on - limit doesn't matter.
                Res =:= {true, true};  % If `end game` is on - limit doesn't matter.
                Res =:= {false, false} % If `end game` is off - limit can't be exhausted.
           ->
            {Ip, Port} = IpPort,
            % @todo check is end game enabled ant not call find_not_downloading_piece/2 if so
            case find_not_downloading_piece(State, Ids) of
                Pieces = [_|_] ->
                    StartPieceDownloadingFun(Pieces, Ip, Port, false);
                [] ->
                    State#state{end_game = true}
            end;
       {false, true} ->
            State
    end,
    #state{
        downloading_peers  = UpdatedPeers,
        downloading_pieces = UpdatedPieces
    } = NewState,
    assign_peers(T, UpdatedPeers, UpdatedPieces, NewState).


%%
%%
%%
is_end(#state{pieces_left = [_|_]}) ->
    ok;

is_end(#state{torrent_name = TorrentName, file_name = FileName, pieces_left = []}) ->
    ok = erltorrent_helper:concat_file(FileName),
    ok = erltorrent_helper:delete_downloaded_pieces(FileName),
    lager:info("Download completed!"),
    erltorrent_sup:stop_child(TorrentName).


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


%% @doc
%% Get currently downloading pieces
%%
get_downloading_pieces(DownloadingPieces) ->
    lists:filter(
        fun
            (#downloading_piece{status = downloading}) -> true;
            (#downloading_piece{status = _})           -> false
        end,
        DownloadingPieces
    ).


%% @doc
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
%%
-spec find_not_downloading_piece(
    State :: #state{},
    Ids   :: [piece_id_int()]
) ->
    [#piece{}].

find_not_downloading_piece(State = #state{}, Ids) ->
    #state{
        downloading_pieces = DownloadingPieces,
        piece_length       = PieceLength,
        pieces_hash        = PiecesHash
    } = State,
    lists:foldl(
        fun
            (Id, []) ->
                case lists:keysearch(Id, #downloading_piece.piece_id, DownloadingPieces) of
                    false ->
                        CurrentPieceLength = get_current_piece_length(Id, PieceLength, State),
                        Exclude = Id * 20,
                        <<_:Exclude/binary, PieceHash:20/binary, _Rest/binary>> = PiecesHash,
                        [#piece{
                            piece_id        = Id,
                            last_block_id   = trunc(math:ceil(CurrentPieceLength / ?DEFAULT_REQUEST_LENGTH)),
                            piece_length    = CurrentPieceLength,
                            piece_hash      = PieceHash
                        }];
                    {value, _} ->
                        []
                end;
            (_Id, Acc = [#piece{}]) ->
                Acc
        end,
        [],
        Ids
    ).


%%
%%  Find piece under end game mode. This piece can be under downloading from several peers.
%%
-spec find_end_game_piece(
    State :: #state{},
    Ids   :: [piece_id_int()]
) ->
    [#piece{}] | [].

find_end_game_piece(State = #state{}, Ids) ->
    #state{
        downloading_pieces = DownloadingPieces,
        piece_length       = PieceLength,
        pieces_hash        = PiecesHash
    } = State,
    lists:foldl(
        fun
            (_Id, Acc) when length(Acc) >= 1 ->
                Acc;
            (Id, Acc) ->
                case lists:keysearch(Id, #downloading_piece.piece_id, DownloadingPieces) of
                    {value, #downloading_piece{status = downloading}} ->
                        CurrentPieceLength = get_current_piece_length(Id, PieceLength, State),
                        Exclude = Id * 20,
                        <<_:Exclude/binary, PieceHash:20/binary, _Rest/binary>> = PiecesHash,
                        [#piece{
                            piece_id        = Id,
                            last_block_id   = trunc(math:ceil(CurrentPieceLength / ?DEFAULT_REQUEST_LENGTH)),
                            piece_length    = CurrentPieceLength,
                            piece_hash      = PieceHash
                        } | Acc];
                    {value, _} ->
                        Acc;
                    false ->
                        Acc
                end
        end,
        [],
        erltorrent_helper:shuffle_list(Ids)
    ).


%% @private
%% Determine if piece is a last or not and get it's length
%%
get_current_piece_length(PieceId, PieceLength, #state{last_piece_id = LastPieceId, last_piece_length = LastPieceLength}) ->
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

find_end_game_piece_test_() ->
    DownloadingPieces = [
        #downloading_piece{piece_id = 1, status = downloading},
        #downloading_piece{piece_id = 2, status = downloading},
        #downloading_piece{piece_id = 3, status = downloading},
        #downloading_piece{piece_id = 4, status = completed},
        #downloading_piece{piece_id = 5, status = completed},
        #downloading_piece{piece_id = 6, status = downloading}
    ],
    PiecesHash = <<"nuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQj">>,
    State = #state{
        downloading_pieces = DownloadingPieces,
        piece_length       = ?DEFAULT_REQUEST_LENGTH * 10,
        pieces_hash        = PiecesHash,
        last_piece_id      = 10
    },
    Ids = [1, 3, 6],
    Result = [
        #piece{piece_id = 6, last_block_id = 10, piece_length = ?DEFAULT_REQUEST_LENGTH * 10, piece_hash = <<"nuYwPf0y1gILAuVAGsQj">>},
        #piece{piece_id = 3, last_block_id = 10, piece_length = ?DEFAULT_REQUEST_LENGTH * 10, piece_hash = <<"nuYwPf0y1gILAuVAGsQj">>},
        #piece{piece_id = 1, last_block_id = 10, piece_length = ?DEFAULT_REQUEST_LENGTH * 10, piece_hash = <<"nuYwPf0y1gILAuVAGsQj">>}
    ],
    [
        ?_assertEqual(
            Result,
            find_end_game_piece(State, Ids)
        )
    ].

assign_peers_test_() ->
    Ref = make_ref(),
    Pid = list_to_pid("<0.0.1>"),
    {setup,
        fun() ->
            ok = meck:new([erltorrent_helper, erltorrent_downloader]),
            ok = meck:expect(erltorrent_helper, do_monitor, ['_', '_'], Ref),
            ok = meck:expect(erltorrent_downloader, start, ['_', '_', '_', '_', '_', '_', '_'], {ok, Pid})
        end,
        fun(_) ->
            true = meck:validate([erltorrent_helper, erltorrent_downloader]),
            ok = meck:unload([erltorrent_helper, erltorrent_downloader])
        end,
        [{"End game mode is enabled.",
            fun() ->
                PeerPieces1 = dict:store({{127,0,0,2}, 9870}, [1, 2, 3, 4], dict:new()),
                PeerPieces2 = dict:store({{127,0,0,2}, 9871}, [3], PeerPieces1),
                PeerPieces3 = dict:store({{127,0,0,2}, 9872}, [1, 2, 3], PeerPieces2),
                PeerPieces4 = dict:store({{127,0,0,2}, 9873}, [2, 3], PeerPieces3),
                PiecePeers1 = dict:store(1, [{{127,0,0,2}, 9870}, {{127,0,0,2}, 9872}], dict:new()),
                PiecePeers2 = dict:store(2, [{{127,0,0,2}, 9870}, {{127,0,0,2}, 9872}, {{127,0,0,2}, 9873}], PiecePeers1),
                PiecePeers3 = dict:store(3, [{{127,0,0,2}, 9870}, {{127,0,0,2}, 9871}, {{127,0,0,2}, 9872}, {{127,0,0,2}, 9873}, {{127,0,0,2}, 9874}], PiecePeers2),
                PiecePeers4 = dict:store(4, [{{127,0,0,2}, 9870}], PiecePeers3),
                DownloadingPieces = [
                    #downloading_piece{piece_id = 1, status = downloading, key = {1, {{127,0,0,2},9872}}, peer = {{127,0,0,2},9872}, monitor_ref = Ref, pid = Pid},
                    #downloading_piece{piece_id = 2, status = downloading, key = {2, {{127,0,0,2},9873}}, peer = {{127,0,0,2},9873}, monitor_ref = Ref, pid = Pid},
                    #downloading_piece{piece_id = 3, status = completed},
                    #downloading_piece{piece_id = 4, status = completed}
                ],
                PiecesHash = <<"nuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQjnuYwPf0y1gILAuVAGsQj">>,
                State = #state{
                    piece_peers        = PiecePeers4,
                    peer_pieces        = PeerPieces4,
                    downloading_peers  = [],
                    downloading_pieces = DownloadingPieces,
                    piece_length       = ?DEFAULT_REQUEST_LENGTH * 10,
                    pieces_hash        = PiecesHash,
                    last_piece_id      = 10
                },
                NewState = State#state{
                    end_game = true
                },
                {noreply, NewState} = handle_info(assign_peers, State),
                3 = meck:num_calls(erltorrent_helper, do_monitor, ['_', '_']),
                3 = meck:num_calls(erltorrent_downloader, start, ['_', '_', '_', '_', '_', '_', '_'])
            end
        }]
    }.

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
%%        piece_length        = 16384,
%%        last_piece_length   = 4200,
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


