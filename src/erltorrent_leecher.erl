%%%-------------------------------------------------------------------
%%% @author bartimaeus
%%% @copyright (C) 2018, sarunas.bartusevicius@gmail.com
%%% @doc
%%%
%%% @end
%%% Created : 23. Jun 2018 08.33
%%%-------------------------------------------------------------------
-module(erltorrent_leecher).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

-behaviour(gen_server).

-include("erltorrent.hrl").
-include("erltorrent_store.hrl").

-define(STOPPED_PEER_MULTIPLIER, 5).
-define(SLOW_PEER_MULTIPLIER, 3).

%% API
-export([
    start_link/7,
    get_speed/1,
    get_speed_blocks/1,
    get_blocks/1
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
    files                       :: integer(), % @todo make a proper type
    peer_ip                     :: tuple(),
    port                        :: integer(),
    socket                      :: port(),
    piece_data                  :: #piece{},
    parser_pid                  :: pid(),
    peer_state      = choke     :: choke | unchoke,
    give_up_limit   = 3         :: integer(),           % @todo NEED TO IMPLEMENT. How much tries to get unchoke before giveup
    peer_id                     :: binary(),
    hash                        :: binary(),
    started_at                  :: integer(),                   % When piece downloading started in milliseconds timestamp
    parse_time      = 0         :: integer(),
    timeout                     :: integer(),                   % Needed for end game mode
    timeout_ref                 :: reference() | undefined      % Needed for end game mode
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
start_link(Files, PeerIp, Port, PeerId, Hash, PieceData, AvgBlockDownloadTime) ->
    gen_server:start_link(?MODULE, [Files, PeerIp, Port, PeerId, Hash, PieceData, AvgBlockDownloadTime], []).



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
init([Files, PeerIp, Port, PeerId, Hash, PieceData, Timeout]) ->
    State0 = #state{
        files                   = Files,
        peer_ip                 = PeerIp,
        port                    = Port,
        peer_id                 = PeerId,
        hash                    = Hash,
        piece_data              = PieceData,
        started_at              = erltorrent_helper:get_milliseconds_timestamp(),
        timeout                 = Timeout,
        timeout_ref             = undefined
    },
    State1 = update_timeout(State0),
    self() ! start,
    {ok, State1}.


%%
%%
%%
get_speed_blocks(Pid) ->
    gen_server:call(Pid, get_speed_blocks).


get_speed(Pid) ->
    gen_server:call(Pid, get_speed).

get_blocks(Pid) ->
    gen_server:call(Pid, get_blocks).


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
handle_call(get_blocks, _From, State) ->
    #state{
        piece_data = PieceData
    } = State,
    #piece{
        blocks = Blocks
    } = PieceData,
    {reply, Blocks, State};

handle_call(get_speed_blocks, _From, State) ->
    #state{
        hash    = Hash,
        peer_ip = PeerIp,
        port    = Port
    } = State,
    BlockTimes = erltorrent_store:read_blocks_time(Hash, {PeerIp, Port}),
    {reply, BlockTimes, State};

handle_call(get_speed, _From, State) ->
    #state{
        hash    = Hash,
        peer_ip = PeerIp,
        port    = Port
    } = State,
    BlockTimes = erltorrent_store:read_blocks_time(Hash, {PeerIp, Port}),
    {Time, Blocks} = lists:foldl(
        % @todo DRY - same fun in erltorrent_leech_server:get_avg_block_download_time/1
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
                    {AccTime, AccBlocks};
                _          ->
                    {AccTime, AccBlocks}
            end
        end,
        {0, 0},
        BlockTimes
    ),
    {reply, Time / Blocks, State};

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
%% Start downloading from peer: open socket, make a handshake, start is alive checking timer.
%%
handle_info(start, State) ->
    #state{
        peer_ip     = PeerIp,
        port        = Port,
        peer_id     = PeerId,
        hash        = Hash,
        piece_data  = PieceData
    } = State,
    #piece{
        piece_id = PieceId,
        last_block_id = LastBlockId,
        status = not_requested
    } = PieceData,
    #erltorrent_store_piece{blocks = Blocks} = erltorrent_store:read_piece(Hash, PieceId, LastBlockId, 0, read),
    case do_connect(PeerIp, Port) of
        {ok, Socket} ->
            {ok, ParserPid} = erltorrent_packet:start_link(),
            ok = erltorrent_message:handshake(Socket, PeerId, Hash),
            ok = erltorrent_helper:get_packet(Socket),
            NewState = State#state{
                socket = Socket,
                parser_pid = ParserPid,
                piece_data = PieceData#piece{blocks = Blocks}
            },
            ok = erltorrent_peer_events:add_sup_handler({PieceId, PeerIp, Port}, [self(), PieceId]),
            {noreply, NewState};
        {error, Reason} ->
            {stop, Reason, State}
    end;

%% @doc
%% Request for a blocks from peer
%%
handle_info(request_piece, State) ->
    #state{
        peer_ip      = Ip,
        port         = Port,
        socket       = Socket,
        hash         = Hash,
        piece_data   = PieceData
    } = State,
    #piece{
        piece_id    = PieceId,
        piece_size  = PieceSize,
        blocks      = Blocks
    } = PieceData,
    %
    % Maybe PieceData process downloaded all pieces?
    case Blocks of
        [_|_] ->
            % If not, make requests for blocks
            RequestMessage = lists:foldl(
                fun (NextBlockId, MsgAcc) ->
                    {ok, {OffsetBin, NextLength}} = get_request_data(NextBlockId, PieceSize),
                    PieceIdBin = erltorrent_helper:int_piece_id_to_bin(PieceId),
                    PieceSizeBin = <<NextLength:32>>,
                    erltorrent_store:update_blocks_time(Hash, {Ip, Port}, PieceId, NextBlockId, erltorrent_helper:get_milliseconds_timestamp(), requested_at),
                    erltorrent_message:pipeline_request_piece(MsgAcc, PieceIdBin, OffsetBin, PieceSizeBin)
                end,
                <<"">>,
                Blocks
            ),
            case erltorrent_message:request_piece(Socket, RequestMessage) of
                {error, closed} ->
                    {stop, socket_error, State};
                ok ->
                    erltorrent_helper:get_packet(Socket),
                    {noreply, State}
            end;
        []    ->
            erltorrent_helper:get_packet(Socket),
            {noreply, State}
    end;

%% @doc
%% If `unchoke` tries limit exceeded - kill that process
%% @todo need to implement give_up
handle_info({tcp, _Port, _Packet}, State = #state{give_up_limit = 0}) ->
    {stop, give_up, State};

%% @doc
%% Handle incoming packets.
%% @todo need a test
handle_info({tcp, _Port, Packet}, State) ->
    #state{
        peer_ip          = Ip,
        port             = Port,
        files            = Files,
        parser_pid       = ParserPid,
        piece_data       = PieceData,
        socket           = Socket,
        peer_state       = PeerState,
        hash             = Hash,
        parse_time       = OldParseTime,
        started_at       = StartedAt
    } = State,
    #piece{
        piece_id        = PieceId,
        blocks          = Blocks,
        last_block_id   = LastBlockId,
        std_piece_size  = StdPieceSize,
        piece_size      = PieceSize
    } = PieceData,
    {ParseTime, {ok, Data}} = timer:tc(fun () ->
         erltorrent_packet:parse(ParserPid, Packet)
    end),
    ok = case proplists:get_value(handshake, Data) of
        true -> erltorrent_message:interested(Socket);
        _    -> ok
    end,
    % Identify new my peer state
    NewPeerState = lists:foldl(
        fun
            ({unchoke, true}, _Acc) -> unchoke;
            ({choke, true},   _Acc) -> choke;
            (_,                Acc) -> Acc
        end,
        PeerState,
        Data
    ),
    % If my peer state changed and new my peer state is unchoke, request for a piece
    ok = case {NewPeerState =:= PeerState, NewPeerState} of
        {false, unchoke} ->
            self() ! request_piece,
            ok;
        _                ->
            ok
    end,
    % We need to loop because we can receive more than 1 piece at the same time
    % Write payload to file
    % @todo move writing to file under supervisor
    ok = lists:foreach(
        fun
            ({piece, #piece_data{payload = Payload, piece_index = GotPieceId, block_offset = BlockOffset}}) ->
                <<BlockBegin:32>> = BlockOffset,
                BlockId = trunc(BlockBegin / ?DEFAULT_REQUEST_LENGTH),
                case lists:member(BlockId, Blocks) of
                    true  ->
                        {ok, {_, RequestLength}} = get_request_data(BlockId, PieceSize),
                        write_payload(Files, StdPieceSize, GotPieceId, BlockBegin, Payload, RequestLength);
                    false ->
                        ok
                end;
           (_Else) ->
               ok
        end,
        Data
    ),
    UpdateFun = fun
        ({piece, Piece = #piece_data{block_offset = BlockOffset}}) ->
            <<BlockBegin:32>> = BlockOffset,
            BlockId = trunc(BlockBegin / ?DEFAULT_REQUEST_LENGTH),
            case lists:member(BlockId, Blocks) of
                true ->
                    erltorrent_store:read_piece(Hash, PieceId, 0, BlockId, update),
                    % @todo maybe change to piece download time?
                    erltorrent_store:update_blocks_time(Hash, {Ip, Port}, PieceId, BlockId, erltorrent_helper:get_milliseconds_timestamp(), received_at),
                    erltorrent_peer_events:block_downloaded(PieceId, BlockId, self()),
                    {true, Piece};
                false ->
                    {true, Piece}
            end;
       (_Else) ->
           false
    end,
    % Check current my peer state. If it's unchoke - request for piece. If it's choke - try to get unchoke by sending interested.
    UpdatedPieceData = #piece{blocks = NewBlocks} = case NewPeerState of
        unchoke ->
            case lists:filtermap(UpdateFun, Data) of
                [_|_]  ->
                    #erltorrent_store_piece{blocks = UpdatedBlocks} = erltorrent_store:read_piece(Hash, PieceId, 0, 0, read),
                    PieceData#piece{blocks = UpdatedBlocks, status = not_requested};
                _      ->
                    PieceData
            end;
        choke ->
            ok = erltorrent_message:interested(Socket),
            PieceData
    end,
    NewState = State#state{
        piece_data          = UpdatedPieceData,
        peer_state          = NewPeerState,
        parse_time          = OldParseTime + ParseTime
    },
    case NewBlocks of
        [] ->
            case confirm_piece_hash(Files, PieceData) of
                true ->
                    ok = erltorrent_store:mark_piece_completed(Hash, PieceId),
                    CompletedAt = erltorrent_helper:get_milliseconds_timestamp(),
                    erltorrent_leech_server ! {completed, {Ip, Port}, PieceId, self(), CompletedAt - StartedAt},
                    cancel_timeout_timer(NewState),
                    {noreply, NewState#state{timeout_ref = undefined}};
                false ->
                    ok = erltorrent_store:mark_piece_new(Hash, PieceId, LastBlockId),
                    {stop, invalid_hash, NewState}
            end;
        [_|_] ->
            ok = erltorrent_helper:get_packet(Socket),
            {noreply, NewState}
    end;


%% @doc
%% Switch peace to new one
%%  @todo check handle_info(start, State) and do a bit of DRY
handle_info({switch_piece, Piece, Timeout}, State) ->
    #state{
        peer_ip     = PeerIp,
        port        = Port,
        hash        = Hash,
        piece_data  = OldPieceData
    } = State,
    #piece{
        piece_id      = OldPieceId
    } = OldPieceData,
    #piece{
        piece_id      = PieceId,
        last_block_id = LastBlockId,
        status        = not_requested
    } = Piece,
    #erltorrent_store_piece{blocks = Blocks} = erltorrent_store:read_piece(Hash, PieceId, LastBlockId, 0, read),
    {ok, ParserPid} = erltorrent_packet:start_link(),
    NewState = State#state{
        piece_data      = Piece#piece{blocks = Blocks},
        give_up_limit   = 3,
        parser_pid      = ParserPid,
        started_at      = erltorrent_helper:get_milliseconds_timestamp(),
        parse_time      = 0,
        timeout         = Timeout
    },
    NewState2 = update_timeout(NewState),
    erltorrent_peer_events:swap_sup_handler({OldPieceId, PeerIp, Port}, {PieceId, PeerIp, Port}, PieceId),
    self() ! request_piece,
    {noreply, NewState2};

%%  @doc
%%  Event from other downloaders (erltorrent_peer_events handler)
%%
handle_info({block_downloaded, BlockId}, State) ->
    #state{
        peer_ip     = Ip,
        port        = Port,
        hash        = Hash,
        piece_data  = Piece,
        socket      = Socket
    } = State,
    #piece{
        piece_id    = PieceId,
        blocks      = Blocks,
        piece_size  = PieceSize
    } = Piece,
    erltorrent_store:read_piece(Hash, PieceId, 0, BlockId, update),
    erltorrent_store:update_blocks_time(Hash, {Ip, Port}, PieceId, BlockId, erltorrent_helper:get_milliseconds_timestamp(), received_at),
    NewState = State#state{
        piece_data  = Piece#piece{
            blocks = Blocks -- [BlockId],
            status = not_requested
        }
    },
    {ok, {OffsetBin, Length}} = get_request_data(BlockId, PieceSize),
    erltorrent_message:cancel(Socket, PieceId, OffsetBin, Length),
    self() ! request_piece,
    {noreply, NewState};


%%
%%
%%
handle_info({check_speed, AvgSpeed}, State) ->
    case get_speed_status(State, AvgSpeed) of
        too_slow -> {stop, too_slow, State};
        ok       -> {noreply, State}
    end;

%%
%%
%%
handle_info(cancel, State) ->
    {stop, too_slow, State};


%% @doc
%% Handle unknown messages.
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
%% Connect to peer
%%
do_connect(PeerIp, Port) ->
    case gen_tcp:connect(PeerIp, Port, [{active, false}, binary], 2000) of
        {error, emfile} ->
            lager:info("File descriptor is exhausted. Can't open new a socket for leecher."),
            {error, shutdown};
        {error, _Error} ->
            % @todo what todo on timeout? Especially if it becomes constantly? Maybe freeze such peer
            {error, socket_error};
        Result ->
            Result
    end.


%%
%%
%%
get_file_name(_SizeFrom, _SizeTill, [File]) ->
    File;

get_file_name(SizeFrom, SizeTill, Files) ->
    FilterFrom = lists:reverse(lists:dropwhile(
        fun
            (#{from := FileSizeFrom, till := FileSizeTill}) ->
                not (SizeFrom >= FileSizeFrom andalso SizeFrom < FileSizeTill)
        end,
        Files
    )),
    [#{till := LastTill} | _] = FilterFrom,
    case SizeTill >= LastTill of
        true  ->
            lists:reverse(FilterFrom);
        false ->
            lists:reverse(lists:dropwhile(
                fun
                    (#{from := FileSizeFrom, till := FileSizeTill}) ->
                        not (SizeTill > FileSizeFrom andalso SizeTill =< FileSizeTill)
                end,
                FilterFrom
            ))
    end.


%%
%%
%%
write_payload(Files, StdPieceSize, GotPieceId, BlockBegin, FullPayload, RequestLength) ->
    SizeFrom = StdPieceSize * GotPieceId + BlockBegin,
    SizeTill = SizeFrom + RequestLength,
    WriteFun = fun (FileName, Payload, Offset) ->
        FilePath = filename:join(["downloads", FileName]),
        filelib:ensure_dir(FilePath),
        {ok, IoDevice} = file:open(FilePath, [write, read, binary]), % @todo move open to init and switch file
        ok = file:pwrite(IoDevice, [{{bof, Offset}, Payload}]),
        ok = file:close(IoDevice) % @todo move along with file:open/2
    end,
    case get_file_name(SizeFrom, SizeTill, Files) of
        % Downloading one file torrent
        #{filename := FileName} ->
            ok = WriteFun(FileName, FullPayload, SizeFrom);
        % Downloading multiple files torrent
        FileNames when is_list(FileNames) ->
            lists:foldl(
                fun (#{from := From, till := Till, filename := FileName}, {RestPayload, GlobalOffset}) ->
                    Size = Till - GlobalOffset,
                    % Global offset is offset in the concated payload of all torrent files
                    % while file offset starts from zero in every individual file
                    FileOffset = GlobalOffset - From,
                    case Size < byte_size(RestPayload) of
                        true ->
                            <<Payload:Size/binary, Rest/binary>> = RestPayload,
                            ok = WriteFun(FileName, Payload, FileOffset);
                        false ->
                            ok = WriteFun(FileName, RestPayload, FileOffset), % Offset - From
                            Rest = <<>>
                    end,
                    {Rest, Till}
                end,
                {FullPayload, SizeFrom},
                FileNames
            ),
            ok
    end.


%% @doc
%% Get increased `length` and `offset`
%%
get_request_data(BlockId, PieceSize) ->
    OffsetBin = <<(?DEFAULT_REQUEST_LENGTH * BlockId):32>>,
    <<OffsetInt:32>> = OffsetBin,
    % Last chunk of piece would be shorter than default length so we need to check if next chunk isn't a last
    NextLength = case (OffsetInt + ?DEFAULT_REQUEST_LENGTH) =< PieceSize of
        true  -> ?DEFAULT_REQUEST_LENGTH;
        false -> PieceSize - OffsetInt
    end,
    {ok, {OffsetBin, NextLength}}.


%% @doc
%% Confirm if piece hash is valid
%%
confirm_piece_hash(Files, PieceData) ->
    #piece{
        piece_id        = PieceId,
        std_piece_size  = StdPieceSize,
        piece_size      = PieceSize,
        piece_hash      = PieceHash
    } = PieceData,
    SizeFrom = StdPieceSize * PieceId,
    SizeTill = SizeFrom + PieceSize,
    ReadFun = fun (FileName, Offset, Size) ->
        FilePath = filename:join(["downloads", FileName]),
        {ok, IoDevice} = file:open(FilePath, [read, binary]), % @todo move open to init and switch file
        {ok, Data} = file:pread(IoDevice, [{{bof, Offset}, Size}]),
        FullData = lists:foldl(fun (Chunk, Chunks) -> <<Chunks/binary, Chunk/binary>> end, <<>>, Data),
        ok = file:close(IoDevice), % @todo move along with file:open/2
        FullData
    end,
    PiecePayload = case get_file_name(SizeFrom, SizeTill, Files) of
        % Downloading one file torrent
        #{filename := FileName} ->
            ReadFun(FileName, SizeFrom, PieceSize);
        % Downloading multiple files torrent
        FileNames when is_list(FileNames) ->
            {_, _, PP} = lists:foldl(
                fun (#{from := From, till := Till, filename := FileName}, {FullSize, GlobalOffset, CurrPayload}) ->
                    Size = Till - GlobalOffset,
                    % Global offset is offset in the concated payload of all torrent files
                    % while file offset starts from zero in every individual file
                    FileOffset = GlobalOffset - From,
                    case Size < FullSize of
                        true ->
                            Payload = ReadFun(FileName, FileOffset, Size),
                            {FullSize - Size, Till, <<CurrPayload/binary, Payload/binary>>};
                        false ->
                            Payload = ReadFun(FileName, FileOffset, FullSize),
                            {0, Till, <<CurrPayload/binary, Payload/binary>>}
                    end
                end,
                {PieceSize, SizeFrom, <<>>},
                FileNames
            ),
            PP
    end,
    case crypto:hash(sha, PiecePayload) =:= PieceHash of
        true ->
            true;
        false ->
            lager:info("Bad piece=~p checksum!", [PieceId]),
            false
    end.


%%
%%
%%
get_speed_status(State, AvgSpeed) ->
    #state{
        hash    = Hash,
        peer_ip = PeerIp,
        port    = Port
    } = State,
    BlockTimes = erltorrent_store:read_blocks_time(Hash, {PeerIp, Port}),
    CurrentTime = erltorrent_helper:get_milliseconds_timestamp(),
    case BlockTimes of
        [_|_] ->
            SpeedStatus = lists:foldl(
                % @todo DRY - same fun in erltorrent_server:get_avg_block_download_time/1
                fun
                    (BlockTime, {AccTime, AccBlocks}) ->
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
                                case (CurrentTime - RequestedAt) > (AvgSpeed * ?STOPPED_PEER_MULTIPLIER) of
                                    true  -> too_slow;
                                    false -> {AccTime, AccBlocks}
                                end;
                            _          ->
                                {AccTime, AccBlocks}
                        end;
                    (_BlockTime, too_slow) ->
                        too_slow
                end,
                {0, 0},
                BlockTimes
            ),
            case SpeedStatus of
                too_slow ->
                    too_slow;
                {Time, Blocks} ->
                    case (Time / Blocks) > (AvgSpeed * ?SLOW_PEER_MULTIPLIER) of
                        true  -> too_slow;
                        false -> ok
                    end
            end;
        []  ->
            too_slow;
        _   ->
            ok
    end.


%%
%%
%%
cancel_timeout_timer(#state{timeout_ref = TimeoutRef}) ->
    case is_reference(TimeoutRef) of
        true  -> erlang:cancel_timer(TimeoutRef);
        false -> ok
    end.


%%
%%
%%
update_timeout(State = #state{timeout = Timeout}) ->
    cancel_timeout_timer(State),
    Ref = case Timeout of
        undefined   -> undefined;
        Timeout     -> erlang:send_after(Timeout, self(), cancel)
    end,
    State#state{timeout_ref = Ref}.



%%%===================================================================
%%% EUnit tests
%%%===================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

get_file_name_test_() ->
    Files = [
        #{from => 0, till => 10,  filename => "f1"},
        #{from => 10, till => 15, filename => "f2"},
        #{from => 15, till => 20, filename => "f3"},
        #{from => 20, till => 30, filename => "f4"}
    ],
    [
        ?_assertEqual(
            [#{filename => "f1", from => 0, till => 10}],
            get_file_name(0, 10, Files)
        ),
        ?_assertEqual(
            [#{filename => "f1", from => 0, till => 10}],
            get_file_name(0, 3, Files)
        ),
        ?_assertEqual(
            [#{filename => "f1", from => 0, till => 10}],
            get_file_name(9, 10, Files)
        ),
        ?_assertEqual(
            [#{filename => "f2", from => 10, till => 15}],
            get_file_name(10, 15, Files)
        ),
        ?_assertEqual(
            [#{filename => "f3", from => 15, till => 20}],
            get_file_name(15, 20, Files)
        ),
        ?_assertEqual(
            [
                #{filename => "f2", from => 10, till => 15},
                #{filename => "f3", from => 15, till => 20}
            ],
            get_file_name(10, 20, Files)
        ),
        ?_assertEqual(
            [
                #{filename => "f1", from => 0,  till => 10},
                #{filename => "f2", from => 10, till => 15},
                #{filename => "f3", from => 15, till => 20}
            ],
            get_file_name(0, 19, Files)
        ),
        ?_assertEqual(
            [
                #{filename => "f1", from => 0,  till => 10},
                #{filename => "f2", from => 10, till => 15},
                #{filename => "f3", from => 15, till => 20}
            ],
            get_file_name(7, 19, Files)
        ),
        ?_assertEqual(
            [
                #{filename => "f3", from => 15, till => 20}
            ],
            get_file_name(18, 20, Files)
        ),
        ?_assertEqual(
            [
                #{filename => "f3", from => 15, till => 20},
                #{filename => "f4", from => 20, till => 30}
            ],
            get_file_name(15, 30, Files)
        ),
        ?_assertEqual(
            [
                #{filename => "f3", from => 15, till => 20},
                #{filename => "f4", from => 20, till => 30}
            ],
            get_file_name(15, 31, Files)
        ),
        ?_assertEqual(
            [
                #{filename => "f1", from => 0,  till => 10},
                #{filename => "f2", from => 10, till => 15},
                #{filename => "f3", from => 15, till => 20},
                #{filename => "f4", from => 20, till => 30}
            ],
            get_file_name(0, 30, Files)
        ),
        ?_assertEqual(
            #{filename => "f1", from => 0, till => 20},
            get_file_name(0, 5, [#{filename => "f1", from => 0, till => 20}])
        )
    ].


get_request_data_test_() ->
    [
        ?_assertEqual(
            {ok, {<<0, 0, 64, 0>>, ?DEFAULT_REQUEST_LENGTH}},
            get_request_data(1, 290006769)
        ),
        ?_assertEqual(
            {ok, {<<0, 1, 128, 0>>, ?DEFAULT_REQUEST_LENGTH}},
            get_request_data(6, 290006769)
        ),
        ?_assertEqual(
            {ok, {<<0, 1, 128, 0>>, 1696}},
            get_request_data(6, 100000)
        ),
        ?_assertEqual(
            {ok, {<<0, 1, 192, 0>>, -14688}},
            get_request_data(7, 100000)
        )
    ].


%%request_piece_test_() ->
%%    {setup,
%%        fun() ->
%%            ok = meck:new([erltorrent_message, erltorrent_helper, erltorrent_store]),
%%            ok = meck:expect(erltorrent_message, request_piece, ['_', '_', '_', '_'], ok),
%%            ok = meck:expect(erltorrent_helper, get_packet, ['_'], ok),
%%            ok = meck:expect(erltorrent_helper, do_exit, ['_', '_'], true),
%%            ok = meck:expect(erltorrent_helper, delete_downloaded_piece, ['_', '_'], ok),
%%            ok = meck:expect(erltorrent_helper, get_concated_piece, ['_', '_'], {ok, <<44,54,155>>}),
%%            ok = meck:expect(erltorrent_store, mark_piece_completed, ['_', '_'], ok),
%%            ok = meck:expect(erltorrent_store, mark_piece_new, ['_', '_'], ok)
%%        end,
%%        fun(_) ->
%%            true = meck:validate([erltorrent_message, erltorrent_helper, erltorrent_store]),
%%            ok = meck:unload([erltorrent_message, erltorrent_helper, erltorrent_store])
%%        end,
%%        [{"File isn't downloaded yet.",
%%            fun() ->
%%                State = #state{
%%                },
%%                {noreply, State} = handle_info(request_piece, State),
%%                1 = meck:num_calls(erltorrent_message, request_piece, ['_', '_', '_', '_']),
%%                1 = meck:num_calls(erltorrent_helper, get_packet, ['_']),
%%                0 = meck:num_calls(erltorrent_store, mark_piece_completed, ['_', '_']),
%%                0 = meck:num_calls(erltorrent_helper, do_exit, ['_', completed]),
%%                0 = meck:num_calls(erltorrent_store, mark_piece_new, ['_', '_']),
%%                0 = meck:num_calls(erltorrent_helper, delete_downloaded_piece, ['_', '_']),
%%                0 = meck:num_calls(erltorrent_helper, do_exit, ['_', invalid_hash]),
%%                0 = meck:num_calls(erltorrent_helper, get_concated_piece, ['_', '_'])
%%            end
%%        },
%%        {"File is downloaded. Hash is valid.",
%%            fun() ->
%%                State = #state{
%%                    started_at   = 5
%%                },
%%                {noreply, State} = handle_info(request_piece, State),
%%                1 = meck:num_calls(erltorrent_message, request_piece, ['_', '_', '_', '_']),
%%                1 = meck:num_calls(erltorrent_helper, get_packet, ['_']),
%%                1 = meck:num_calls(erltorrent_store, mark_piece_completed, ['_', '_']),
%%                1 = meck:num_calls(erltorrent_helper, do_exit, ['_', kill]),
%%                0 = meck:num_calls(erltorrent_store, mark_piece_new, ['_', '_']),
%%                0 = meck:num_calls(erltorrent_helper, delete_downloaded_piece, ['_', '_']),
%%                0 = meck:num_calls(erltorrent_helper, do_exit, ['_', invalid_hash]),
%%                1 = meck:num_calls(erltorrent_helper, get_concated_piece, ['_', '_'])
%%            end
%%        },
%%        {"File is downloaded. Hash is invalid.",
%%            fun() ->
%%                State = #state{
%%                    started_at   = 5
%%                },
%%                {noreply, State} = handle_info(request_piece, State),
%%                1 = meck:num_calls(erltorrent_message, request_piece, ['_', '_', '_', '_']),
%%                1 = meck:num_calls(erltorrent_helper, get_packet, ['_']),
%%                1 = meck:num_calls(erltorrent_store, mark_piece_completed, ['_', '_']),
%%                1 = meck:num_calls(erltorrent_helper, do_exit, ['_', kill]),
%%                1 = meck:num_calls(erltorrent_store, mark_piece_new, ['_', '_']),
%%                1 = meck:num_calls(erltorrent_helper, delete_downloaded_piece, ['_', '_']),
%%                1 = meck:num_calls(erltorrent_helper, do_exit, ['_', invalid_hash]),
%%                2 = meck:num_calls(erltorrent_helper, get_concated_piece, ['_', '_'])
%%            end
%%        }]
%%    }.


-endif.


