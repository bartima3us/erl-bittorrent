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

-behaviour(gen_bittorrent).

-include_lib("gen_bittorrent/include/gen_bittorrent.hrl").
-include("erltorrent.hrl").
-include("erltorrent_store.hrl").

-define(STOPPED_PEER_MULTIPLIER, 4).
-define(SLOW_PEER_MULTIPLIER, 4).

%% API
-export([
    start_link/6,
    switch_piece/2,
    get_speed/1
]).

%% gen_bittorrent callbacks
-export([
    init/1,
    peer_handshaked/2,
    peer_unchoked/2,
    peer_choked/2,
    block_requested/4,
    block_downloaded/5,
    piece_completed/2,
    handle_call/3,
    handle_info/2,
    code_change/3,
    terminate/1
]).

-record(state, {
    files, % @todo make a proper type
    peer_ip                     :: inet:ip_address(),
    port                        :: inet:port_number(),
    piece_data                  :: #piece{},
    give_up_limit   = 3         :: integer(),           % @todo NEED TO IMPLEMENT. How much tries to get unchoke before giveup
    peer_id                     :: binary(),
    torrent_hash                :: binary(),
    started_at                  :: integer(),                   % When piece downloading started in milliseconds timestamp
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
start_link(Files, PeerIp, Port, PeerId, Hash, PieceData) ->
    #piece{
        piece_id    = PieceId,
        piece_size  = PieceSize
    } = PieceData,
    Args = [Files, PeerIp, Port, PeerId, Hash, PieceData],
    gen_bittorrent:start_link(?MODULE, PeerIp, Port, PeerId, Hash, PieceId, PieceSize, Args, []).


%%
%%
%%
switch_piece(Pid, Piece) ->
    Pid ! {switch_piece, Piece},
    ok.


%%
%%  @todo temporary. Remove later
%%
get_speed(Pid) ->
    gen_server:call(Pid, get_speed).



%%%===================================================================
%%% gen_bittorrent callbacks
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
init([Files, PeerIp, Port, PeerId, Hash, PieceData]) ->
    #piece{piece_id = PieceId} = PieceData,
    State = #state{
        torrent_hash            = Hash,
        files                   = Files,
        piece_data              = PieceData,
        peer_ip                 = PeerIp,
        peer_id                 = PeerId,
        port                    = Port,
        started_at              = erltorrent_helper:get_milliseconds_timestamp()
    },
    % Don't match any result because process can either start or fail to start (in case it's already started)
    erltorrent_peer_events:start_link(PieceId),
    ok = erltorrent_peer_events:add_sup_handler(PieceId, {PeerIp, Port}, self()),
    {ok, State}.


%%
%%
%%
peer_handshaked(PieceId, State) ->
    #state{
        torrent_hash = TorrentHash,
        peer_ip      = PeerIp,
        port         = Port,
        piece_data   = PieceData
    } = State,
    #piece{
        last_block_id = LastBlockId
    } = PieceData,
    #erltorrent_store_piece{} = erltorrent_store:read_piece(TorrentHash, {PeerIp, Port}, PieceId, LastBlockId),
    {ok, State}.


%%
%%
%%
peer_unchoked(_PieceId, State) ->
    {ok, State}.


%%
%%
%%
peer_choked(_PieceId, State) ->
    {ok, State}.


%%
%%
%%
block_requested(PieceId, Offset, _Length, State) ->
    #state{
        torrent_hash = TorrentHash,
        peer_ip      = PeerIp,
        port         = Port
    } = State,
    OffsetInt = gen_bittorrent_helper:bin32_to_int(Offset),
    BlockId = trunc(OffsetInt / ?REQUEST_LENGTH),
    ok = erltorrent_store:update_blocks_time(TorrentHash, {PeerIp, Port}, PieceId, BlockId, erltorrent_helper:get_milliseconds_timestamp(), requested_at),
    {ok, State}.


%%
%%
%%
block_downloaded(PieceId, Payload, Offset, Length, State) ->
    #state{
        files        = Files,
        torrent_hash = TorrentHash,
        peer_ip      = PeerIp,
        port         = Port,
        piece_data   = PieceData
    } = State,
    #piece{
        std_piece_size  = StdPieceSize
    } = PieceData,
    OffsetInt = gen_bittorrent_helper:bin32_to_int(Offset),
    BlockId = trunc(OffsetInt / ?REQUEST_LENGTH),
    ok = erltorrent_store:update_piece(TorrentHash, {PeerIp, Port}, PieceId, 0, BlockId),
    ok = erltorrent_store:update_blocks_time(TorrentHash, {PeerIp, Port}, PieceId, BlockId, erltorrent_helper:get_milliseconds_timestamp(), received_at),
    LengthInt = gen_bittorrent_helper:bin32_to_int(Length),
    ok = write_payload(Files, StdPieceSize, PieceId, OffsetInt, Payload, LengthInt),
    {ok, State}.


%%
%%
%%
piece_completed(PieceId, State) ->
    #state{
        files        = Files,
        torrent_hash = TorrentHash,
        peer_ip      = PeerIp,
        port         = Port,
        piece_data   = PieceData,
        started_at   = StartedAt
    } = State,
    #piece{
        last_block_id  = LastBlockId
    } = PieceData,
    case confirm_piece_hash(Files, PieceData) of
        true ->
            ok = erltorrent_store:mark_piece_completed(TorrentHash, PieceId),
            CompletedAt = erltorrent_helper:get_milliseconds_timestamp(),
            ok = erltorrent_leech_server:piece_completed({PeerIp, Port}, PieceId, self(), CompletedAt - StartedAt),
            {ok, State};
        false ->
            % @todo: don't stop, but assign other piece after invalid_hash
            ok = erltorrent_store:mark_piece_new(TorrentHash, PieceId, LastBlockId),
            {stop, invalid_hash}
    end.


%%
%%
%%
handle_call(get_speed, _From, State) ->
    #state{
        torrent_hash  = TorrentHash,
        peer_ip       = PeerIp,
        port          = Port
    } = State,
    BlockTimes = erltorrent_store:read_blocks_time(TorrentHash, {PeerIp, Port}),
    {Time, Blocks} = lists:foldl(
        % @todo DRY - same fun in erltorrent_leech_server:get_avg_block_download_time/1
        % @todo need to do smarter algorithm. Must check last downloaded block time because some time ago it may was fast but now - not.
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
    {reply, Time / Blocks, State}.


%%
%%
%%
handle_info({switch_piece, NewPiece}, State) ->
    #state{
        peer_ip      = PeerIp,
        port         = PeerPort,
        piece_data   = OldPieceData,
        torrent_hash = TorrentHash
    } = State,
    #piece{
        piece_id      = NewPieceId,
        piece_size    = PieceSize,
        last_block_id = LastBlockId
    } = NewPiece,
    #piece{piece_id = OldPieceId} = OldPieceData,
    NewState = State#state{
        give_up_limit   = 3,
        started_at      = erltorrent_helper:get_milliseconds_timestamp(),
        parse_time      = 0,
        piece_data      = NewPiece
    },
    ok = erltorrent_peer_events:delete_handler(OldPieceId, self()),
    erltorrent_peer_events:start_link(NewPieceId),
    ok = erltorrent_peer_events:add_sup_handler(NewPieceId, {PeerIp, PeerPort}, self()),
    #erltorrent_store_piece{} = erltorrent_store:read_piece(TorrentHash, {PeerIp, PeerPort}, NewPieceId, LastBlockId),
    ok = gen_bittorrent:switch_piece(self(), NewPieceId, PieceSize),
    {ok, NewState};

handle_info(_Info, State) ->
    {ok, State}.


%%
%%
%%
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%
%%
%%
terminate(_State) ->
    ok.


%%%===================================================================
%%% Internal functions
%%%===================================================================


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


%%
%%
%%
get_file_name(_SizeFrom, _SizeTill, [File]) ->
    File;

get_file_name(SizeFrom, SizeTill, Files) ->
    FilterFrom = lists:reverse(lists:dropwhile(fun
        (#{from := FileSizeFrom, till := FileSizeTill}) ->
            not (SizeFrom >= FileSizeFrom andalso SizeFrom < FileSizeTill)
    end, Files)),
    [#{till := LastTill} | _] = FilterFrom,
    case SizeTill >= LastTill of
        true  ->
            lists:reverse(FilterFrom);
        false ->
            lists:reverse(lists:dropwhile(fun
                (#{from := FileSizeFrom, till := FileSizeTill}) ->
                    not (SizeTill > FileSizeFrom andalso SizeTill =< FileSizeTill)
            end, FilterFrom))
    end.


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


%%get_request_data_test_() ->
%%    [
%%        ?_assertEqual(
%%            {ok, {<<0, 0, 64, 0>>, ?DEFAULT_REQUEST_LENGTH}},
%%            get_request_data(1, 290006769)
%%        ),
%%        ?_assertEqual(
%%            {ok, {<<0, 1, 128, 0>>, ?DEFAULT_REQUEST_LENGTH}},
%%            get_request_data(6, 290006769)
%%        ),
%%        ?_assertEqual(
%%            {ok, {<<0, 1, 128, 0>>, 1696}},
%%            get_request_data(6, 100000)
%%        ),
%%        ?_assertEqual(
%%            {ok, {<<0, 1, 192, 0>>, -14688}},
%%            get_request_data(7, 100000)
%%        )
%%    ].


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



