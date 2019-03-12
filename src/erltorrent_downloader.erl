%%%-------------------------------------------------------------------
%%% @author bartimaeus
%%% @copyright (C) 2018, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 23. Jun 2018 08.33
%%%-------------------------------------------------------------------
-module(erltorrent_downloader).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

-behaviour(gen_server).

-include("erltorrent.hrl").
-include("erltorrent_store.hrl").

%% API
-export([
    start/6
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
    torrent_id                  :: integer(), % Unique torrent ID in Mnesia
    peer_ip                     :: tuple(),
    port                        :: integer(),
    socket                      :: port(),
    piece_data                  :: #piece{},
    parser_pid                  :: pid(),
    peer_state      = choke     :: choke | unchoke,
    give_up_limit   = 3         :: integer(), % How much tries to get unchoke before giveup
    peer_id                     :: binary(),
    hash                        :: binary(),
    last_action                 :: integer(), % Gregorian seconds when last packet was received
    started_at                  :: integer(), % When piece downloading started in milliseconds timestamp
    updated_at                  :: integer(),  % When last update took place in milliseconds timestamp
    parse_time      = 0         :: integer()
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
start(TorrentId, PeerIp, Port, PeerId, Hash, PieceData) ->
    gen_server:start(?MODULE, [TorrentId, PeerIp, Port, PeerId, Hash, PieceData], []).



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
init([TorrentId, PeerIp, Port, PeerId, Hash, PieceData]) ->
    State = #state{
        torrent_id      = TorrentId,
        peer_ip         = PeerIp,
        port            = Port,
        peer_id         = PeerId,
        hash            = Hash,
        piece_data      = PieceData,
        last_action     = calendar:datetime_to_gregorian_seconds(calendar:local_time()),
        started_at      = erltorrent_helper:get_milliseconds_timestamp()
    },
    self() ! start,
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
handle_info(start, State = #state{peer_ip = PeerIp, port = Port, peer_id = PeerId, hash = Hash, piece_data = PieceData}) ->
    #piece{piece_id = PieceId, last_block_id = LastBlockId, status = not_requested} = PieceData,
    #erltorrent_store_piece{blocks = Blocks} = erltorrent_store:read_piece(Hash, PieceId, LastBlockId, 0, read),
    {ok, Socket} = do_connect(PeerIp, Port),
    {ok, ParserPid} = erltorrent_packet:start_link(),
    ok = erltorrent_message:handshake(Socket, PeerId, Hash),
    ok = erltorrent_helper:get_packet(Socket),
    {noreply, State#state{socket = Socket, parser_pid = ParserPid, piece_data = PieceData#piece{blocks = Blocks}}};

%% @doc
%% Request for a blocks from peer
%%
handle_info(request_piece, State) ->
    #state{
        torrent_id   = TorrentId,
        peer_ip      = Ip,
        port         = Port,
        socket       = Socket,
        hash         = Hash,
        piece_data   = PieceData,
        parse_time   = ParseTime
    } = State,
    #piece{
        piece_id      = PieceId,
        piece_length  = PieceLength,
        last_block_id = LastBlockId,
        blocks        = Blocks,
        piece_hash    = PieceHash
    } = PieceData,
    %
    % Maybe PieceData process downloaded all pieces?
    case Blocks of
        [NextBlockId | _] ->
            % @todo make a request for 5 blocks at once (UPDATE: strange, it's not effective)
            % If not, make requests for blocks
            {ok, {NextLength, OffsetBin}} = get_request_data(NextBlockId, PieceLength),
            ok = erltorrent_message:request_piece(Socket, PieceId, OffsetBin, NextLength),
            erltorrent_store:update_blocks_time(Hash, {Ip, Port}, PieceId, NextBlockId, erltorrent_helper:get_milliseconds_timestamp(), requested_at),
            ok = erltorrent_helper:get_packet(Socket);
        []    ->
            %
            % If yes, check a hash
            case confirm_piece_hash(TorrentId, PieceHash, PieceId) of
                true ->
                    ok = erltorrent_store:mark_piece_completed(Hash, PieceId),
                    erltorrent_server ! {completed, {Ip, Port}, PieceId, self(), ParseTime},
                    false;
                false ->
                    ok = erltorrent_store:mark_piece_new(Hash, PieceId, LastBlockId),
                    ok = erltorrent_helper:delete_downloaded_piece(TorrentId, PieceId),
                    erltorrent_server ! {invalid_hash, PieceId, {Ip, Port}, self()},
                    false
            end
    end,
    {noreply, State};

%% @doc
%% If `unchoke` tries limit exceeded - kill that process
%% @todo need to implement give_up
handle_info({tcp, _Port, _Packet}, State = #state{give_up_limit = 0}) ->
    erltorrent_helper:do_exit(self(), give_up),
    {noreply, State};

%% @doc
%% Handle incoming packets.
%% @todo need a test
handle_info({tcp, _Port, Packet}, State) ->
    #state{
        peer_ip         = Ip,
        port            = Port,
        torrent_id      = TorrentId,
        parser_pid      = ParserPid,
        piece_data      = PieceData,
        socket          = Socket,
        peer_state      = PeerState,
        hash            = Hash,
        parse_time      = OldParseTime
    } = State,
    #piece{
        piece_id = PieceId
    } = PieceData,
%%    {ok, Data} = erltorrent_packet:parse(ParserPid, Packet),
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
    spawn_link(
        fun () ->
            ok = lists:foreach(
                fun
                    ({piece, #piece_data{payload = Payload, piece_index = GotPieceId, block_offset = BlockOffset}}) ->
                        <<PieceBegin:32>> = BlockOffset,
                        FileName = filename:join(["temp", TorrentId, integer_to_list(GotPieceId), integer_to_list(PieceBegin) ++ ".block"]),
                        filelib:ensure_dir(FileName),
                        file:write_file(FileName, Payload),
                        ok;
                   (_Else) ->
                       ok
                end,
                Data
            )
        end
    ),
    UpdateFun = fun
        ({piece, Piece = #piece_data{block_offset = BlockOffset}}) ->
            <<PieceBegin:32>> = BlockOffset,
            BlockId = trunc(PieceBegin / ?DEFAULT_REQUEST_LENGTH),
            erltorrent_store:read_piece(Hash, PieceId, 0, BlockId, update),
            erltorrent_store:update_blocks_time(Hash, {Ip, Port}, PieceId, BlockId, erltorrent_helper:get_milliseconds_timestamp(), received_at),
            {true, Piece};
       (_Else) ->
           false
    end,
    % Check current my peer state. If it's unchoke - request for piece. If it's choke - try to get unchoke by sending interested.
    UpdatedPieceData = case NewPeerState of
        unchoke ->
            case lists:filtermap(UpdateFun, Data) of
                [_|_]  ->
                    self() ! request_piece,
                    #erltorrent_store_piece{blocks = UpdatedBlocks} = erltorrent_store:read_piece(Hash, PieceId, 0, 0, read),
                    PieceData#piece{blocks = UpdatedBlocks, status = not_requested};
                _      ->
                    erltorrent_helper:get_packet(Socket), % If we haven't received any piece, take more from socket
                    PieceData
            end;
        choke ->
            ok = erltorrent_message:interested(Socket),
            ok = erltorrent_helper:get_packet(Socket),
            PieceData
    end,
    NewState = State#state{
        piece_data = UpdatedPieceData,
        peer_state = NewPeerState,
        parse_time = OldParseTime + ParseTime
    },
    {noreply, NewState};


%%
%%
%%
%%handle_info({completed, PieceId}, State = #state{piece_data = PieceData}) ->
%%    UpdatedPieceData = case lists:keysearch(PieceId, #piece.piece_id, PieceData) of
%%        {value, Piece = #piece{}} ->
%%            lists:delete(Piece, PieceData);
%%        false ->
%%            PieceData
%%    end,
%%    self() ! request_piece,
%%    {noreply, State#state{piece_data = UpdatedPieceData}};


%% @doc
%% Switch peace to new one
%%
handle_info({switch_piece, Piece}, State = #state{hash = Hash}) ->
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
        last_action     = calendar:datetime_to_gregorian_seconds(calendar:local_time()),
        started_at      = erltorrent_helper:get_milliseconds_timestamp(),
        updated_at      = undefined
    },
    self() ! request_piece,
    {noreply, NewState};

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
    {ok, _Socket} = gen_tcp:connect(PeerIp, Port, [{active, false}, binary], 1000).


%% @doc
%% Get increased `length` and `offset`
%%
get_request_data(BlockId, PieceLength) ->
    OffsetBin = <<(?DEFAULT_REQUEST_LENGTH * BlockId):32>>,
    <<OffsetInt:32>> = OffsetBin,
    % Last chunk of piece would be shorter than default length so we need to check if next chunk isn't a last
    NextLength = case (OffsetInt + ?DEFAULT_REQUEST_LENGTH) =< PieceLength of
        true  -> ?DEFAULT_REQUEST_LENGTH;
        false -> PieceLength - OffsetInt
    end,
    {ok, {NextLength, OffsetBin}}.

%% @doc
%% Get increased `length` and `offset` of several blocks
%%
get_batch_request_data(Count, PieceLength) ->
    Result = lists:filtermap(
        fun (CountOffset) ->
            RealCount = Count + CountOffset,
            OffsetBin = <<(?DEFAULT_REQUEST_LENGTH * RealCount):32>>,
            <<OffsetInt:32>> = OffsetBin,
            % Last chunk of piece would be shorter than default length so we need to check if next chunk isn't a last
            case (OffsetInt + ?DEFAULT_REQUEST_LENGTH) =< PieceLength of
                true  ->
                    {true, {?DEFAULT_REQUEST_LENGTH, OffsetBin}};
                false -> case CountOffset of
                    0 -> {true, {PieceLength - OffsetInt, OffsetBin}};
                    _ -> false
                end
            end
        end,
        lists:seq(0, 4)
    ),
    {ok, Result}.


%% @doc
%% Confirm if piece hash is valid
%%
confirm_piece_hash(TorrentId, PieceHash, PieceId) ->
    {ok, DownloadedPieceHash} = erltorrent_helper:get_concated_piece(TorrentId, PieceId),
    crypto:hash(sha, DownloadedPieceHash) =:= PieceHash.



%%%===================================================================
%%% EUnit tests
%%%===================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

get_request_data_test_() ->
    [
        ?_assertEqual(
            {ok, {?DEFAULT_REQUEST_LENGTH, <<0, 0, 64, 0>>}},
            get_request_data(1, 290006769)
        ),
        ?_assertEqual(
            {ok, {?DEFAULT_REQUEST_LENGTH, <<0, 1, 128, 0>>}},
            get_request_data(6, 290006769)
        ),
        ?_assertEqual(
            {ok, {1696, <<0, 1, 128, 0>>}},
            get_request_data(6, 100000)
        ),
        ?_assertEqual(
            {ok, {-14688, <<0, 1, 192, 0>>}},
            get_request_data(7, 100000)
        )
    ].


request_piece_test_() ->
    {setup,
        fun() ->
            ok = meck:new([erltorrent_message, erltorrent_helper, erltorrent_store]),
            ok = meck:expect(erltorrent_message, request_piece, ['_', '_', '_', '_'], ok),
            ok = meck:expect(erltorrent_helper, get_packet, ['_'], ok),
            ok = meck:expect(erltorrent_helper, do_exit, ['_', '_'], true),
            ok = meck:expect(erltorrent_helper, delete_downloaded_piece, ['_', '_'], ok),
            ok = meck:expect(erltorrent_helper, get_concated_piece, ['_', '_'], {ok, <<44,54,155>>}),
            ok = meck:expect(erltorrent_store, mark_piece_completed, ['_', '_'], ok),
            ok = meck:expect(erltorrent_store, mark_piece_new, ['_', '_'], ok)
        end,
        fun(_) ->
            true = meck:validate([erltorrent_message, erltorrent_helper, erltorrent_store]),
            ok = meck:unload([erltorrent_message, erltorrent_helper, erltorrent_store])
        end,
        [{"File isn't downloaded yet.",
            fun() ->
                State = #state{
                },
                {noreply, State} = handle_info(request_piece, State),
                1 = meck:num_calls(erltorrent_message, request_piece, ['_', '_', '_', '_']),
                1 = meck:num_calls(erltorrent_helper, get_packet, ['_']),
                0 = meck:num_calls(erltorrent_store, mark_piece_completed, ['_', '_']),
                0 = meck:num_calls(erltorrent_helper, do_exit, ['_', completed]),
                0 = meck:num_calls(erltorrent_store, mark_piece_new, ['_', '_']),
                0 = meck:num_calls(erltorrent_helper, delete_downloaded_piece, ['_', '_']),
                0 = meck:num_calls(erltorrent_helper, do_exit, ['_', invalid_hash]),
                0 = meck:num_calls(erltorrent_helper, get_concated_piece, ['_', '_'])
            end
        },
        {"File is downloaded. Hash is valid.",
            fun() ->
                State = #state{
                    started_at   = 5,
                    updated_at   = 10
                },
                {noreply, State} = handle_info(request_piece, State),
                1 = meck:num_calls(erltorrent_message, request_piece, ['_', '_', '_', '_']),
                1 = meck:num_calls(erltorrent_helper, get_packet, ['_']),
                1 = meck:num_calls(erltorrent_store, mark_piece_completed, ['_', '_']),
                1 = meck:num_calls(erltorrent_helper, do_exit, ['_', kill]),
                0 = meck:num_calls(erltorrent_store, mark_piece_new, ['_', '_']),
                0 = meck:num_calls(erltorrent_helper, delete_downloaded_piece, ['_', '_']),
                0 = meck:num_calls(erltorrent_helper, do_exit, ['_', invalid_hash]),
                1 = meck:num_calls(erltorrent_helper, get_concated_piece, ['_', '_'])
            end
        },
        {"File is downloaded. Hash is invalid.",
            fun() ->
                State = #state{
                    started_at   = 5,
                    updated_at   = 10
                },
                {noreply, State} = handle_info(request_piece, State),
                1 = meck:num_calls(erltorrent_message, request_piece, ['_', '_', '_', '_']),
                1 = meck:num_calls(erltorrent_helper, get_packet, ['_']),
                1 = meck:num_calls(erltorrent_store, mark_piece_completed, ['_', '_']),
                1 = meck:num_calls(erltorrent_helper, do_exit, ['_', kill]),
                1 = meck:num_calls(erltorrent_store, mark_piece_new, ['_', '_']),
                1 = meck:num_calls(erltorrent_helper, delete_downloaded_piece, ['_', '_']),
                1 = meck:num_calls(erltorrent_helper, do_exit, ['_', invalid_hash]),
                2 = meck:num_calls(erltorrent_helper, get_concated_piece, ['_', '_'])
            end
        }]
    }.


-endif.


