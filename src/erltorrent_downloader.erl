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

%% API
-export([
    start/9
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
    piece_id                    :: binary(),
    piece_length                :: integer(), % Full length of piece
    count                       :: integer(), % Number of downloaded blocks
    parser_pid                  :: pid(),
    server_pid                  :: pid(),
    peer_state      = choke     :: choke | unchoke,
    give_up_limit   = 3         :: integer(), % How much tries to get unchoke before giveup
    peer_id                     :: binary(),
    hash                        :: binary(),
    last_action                 :: integer(), % Gregorian seconds when last packet was received
    piece_hash                  :: binary(),  % Piece confirm hash from torrent file
    started_at                  :: integer(), % When piece downloading started in milliseconds timestamp
    updated_at                  :: integer()  % When last update took place in milliseconds timestamp
}).

% @todo unhardcode because all piece can be smaller than this number
-define(DEFAULT_REQUEST_LENGTH, 16384).


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
start(TorrentId, PieceId, PeerIp, Port, ServerPid, PeerId, Hash, PieceLength, PieceHash) ->
    gen_server:start(?MODULE, [TorrentId, PieceId, PeerIp, Port, ServerPid, PeerId, Hash, PieceLength, PieceHash], []).



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
init([TorrentId, PieceId, PeerIp, Port, ServerPid, PeerId, Hash, PieceLength, PieceHash]) ->
    State = #state{
        torrent_id      = TorrentId,
        peer_ip         = PeerIp,
        port            = Port,
        piece_id        = PieceId,
        server_pid      = ServerPid,
        peer_id         = PeerId,
        hash            = Hash,
        piece_length    = PieceLength,
        last_action     = calendar:datetime_to_gregorian_seconds(calendar:local_time()),
        count           = erltorrent_store:read_piece(Hash, PieceId, read),
        piece_hash      = PieceHash,
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
handle_info(start, State = #state{peer_ip = PeerIp, port = Port, peer_id = PeerId, hash = Hash}) ->
    {ok, Socket} = do_connect(PeerIp, Port),
    {ok, ParserPid} = erltorrent_packet:start_link(),
    ok = erltorrent_message:handshake(Socket, PeerId, Hash),
    ok = erltorrent_helper:get_packet(Socket),
    erlang:send_after(15000, self(), is_alive),
    {noreply, State#state{socket = Socket, parser_pid = ParserPid}};

%% @doc
%% Request for a next piece from peer
%%
handle_info(request_piece, State) ->
    #state{
        torrent_id   = TorrentId,
        socket       = Socket,
        piece_id     = PieceId,
        piece_length = PieceLength,
        count        = Count,
        hash         = Hash,
        piece_hash   = PieceHash,
        started_at   = StartedAt,
        updated_at   = UpdatedAt
    } = State,
    {ok, {NextLength, OffsetBin}} = get_request_data(Count, PieceLength),
    % Check if file isn't downloaded yet
    case NextLength > 0 of
        true ->
            ok = erltorrent_message:request_piece(Socket, PieceId, OffsetBin, NextLength),
            ok = erltorrent_helper:get_packet(Socket);
        false ->
            % @todo need to send end game message
            case confirm_piece_hash(TorrentId, PieceHash, PieceId) of
                true ->
                    ok = erltorrent_store:mark_piece_completed(Hash, PieceId),
                    true = erltorrent_helper:do_exit(self(), {completed, Count, UpdatedAt - StartedAt});
                false ->
                    ok = erltorrent_store:mark_piece_new(Hash, PieceId),
                    ok = erltorrent_helper:delete_downloaded_piece(TorrentId, PieceId),
                    true = erltorrent_helper:do_exit(self(), invalid_hash)
            end
    end,
    {noreply, State};

%% @doc
%% If `unchoke` tries limit exceeded - kill that process
%%
handle_info({tcp, _Port, _Packet}, State = #state{give_up_limit = 0}) ->
    erltorrent_helper:do_exit(self(), give_up),
    {noreply, State};

%% @doc
%% Handle incoming packets.
%% @todo need a test
handle_info({tcp, _Port, Packet}, State) ->
    #state{
        piece_id        = PieceId,
        torrent_id      = TorrentId,
        count           = Count,
        parser_pid      = ParserPid,
        socket          = Socket,
        peer_state      = PeerState,
        hash            = Hash,
        give_up_limit   = GiveUpLimit,
        updated_at      = UpdatedAt
    } = State,
    {ok, Data} = erltorrent_packet:parse(ParserPid, Packet),
    ok = case proplists:get_value(handshake, Data) of
        true -> erltorrent_message:interested(Socket);
        _    -> ok
    end,
    % Identify new my peer state
    NewPeerState = lists:foldl(
        fun
            ({unchoke, true}, _Acc) -> unchoke;
            ({choke, true}, _Acc) -> choke;
            (_, Acc) -> Acc
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
    WriteFun = fun
        ({piece, Piece = #piece_data{payload = Payload, piece_index = PieceId, block_offset = BlockOffset}}) ->
            <<PieceBegin:32>> = BlockOffset,
            FileName = filename:join(["temp", TorrentId, integer_to_list(PieceId), integer_to_list(PieceBegin) ++ ".block"]),
            filelib:ensure_dir(FileName),
            file:write_file(FileName, Payload),
            {true, Piece};
       (_Else) ->
           false
    end,
    % Check current my peer state. If it's unchoke - request for piece. If it's choke - try to get unchoke by sending interested.
    {NewCount, NewGiveUpLimit, NewUpdatedAt} = case NewPeerState of
        unchoke ->
            case lists:filtermap(WriteFun, Data) of
                [_|_]   ->
                    self() ! request_piece, % If we have received any piece, go to another one
                    {erltorrent_store:read_piece(Hash, PieceId, update), GiveUpLimit, erltorrent_helper:get_milliseconds_timestamp()};
                _       ->
                    erltorrent_helper:get_packet(Socket), % If we haven't received any piece, take more from socket
                    {Count, GiveUpLimit, UpdatedAt}
            end;
        choke ->
            ok = erltorrent_message:interested(Socket),
            ok = erltorrent_helper:get_packet(Socket),
            {Count, GiveUpLimit - 1, UpdatedAt}
    end,
    NewState = State#state{
        count           = NewCount,
        peer_state      = NewPeerState,
        last_action     = calendar:datetime_to_gregorian_seconds(calendar:local_time()),
        give_up_limit   = NewGiveUpLimit,
        updated_at      = NewUpdatedAt
    },
    {noreply, NewState};

%% @doc
%% Check is peer still alive every 15 seconds. If not - kill the process.
%%
handle_info(is_alive, State = #state{last_action = LastAction}) ->
    erlang:send_after(15000, self(), is_alive),
    CurrentTime = calendar:datetime_to_gregorian_seconds(calendar:local_time()),
    case CurrentTime - LastAction >= 15 of
        % @todo need to think if it's need to handle timeouted in server
        % @todo need to make smarter algorithm. If all peers internet is very slow, this process will crash without downloading any part.
        % @todo Also if internet from current peer is slow but not slow enough to exceed last_action limit, piece will be downloading too slow.
        % @todo An idea: store in Mnesia peers speed and check in DB for faster peers and if peer is too slow, kill that process and make a new one with another peer.
        true  -> erltorrent_helper:do_exit(self(), timeouted);
        false -> ok
    end,
    {noreply, State};

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
get_request_data(Count, PieceLength) ->
    OffsetBin = <<(?DEFAULT_REQUEST_LENGTH * Count):32>>,
    <<OffsetInt:32>> = OffsetBin,
    % Last chunk of piece would be shorter than default length so we need to check if next chunk isn't a last
    NextLength = case (OffsetInt + ?DEFAULT_REQUEST_LENGTH) =< PieceLength of
        true  -> ?DEFAULT_REQUEST_LENGTH;
        false -> PieceLength - OffsetInt
    end,
    {ok, {NextLength, OffsetBin}}.


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
                    piece_length = 100000,
                    count        = 6
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
                    piece_length = 100000,
                    count        = 7,
                    piece_hash   = <<163,87,117,131,175,37,165,111,6,9,63,88,101,126,235,79,238,138,19,154>>,
                    started_at   = 5,
                    updated_at   = 10
                },
                {noreply, State} = handle_info(request_piece, State),
                1 = meck:num_calls(erltorrent_message, request_piece, ['_', '_', '_', '_']),
                1 = meck:num_calls(erltorrent_helper, get_packet, ['_']),
                1 = meck:num_calls(erltorrent_store, mark_piece_completed, ['_', '_']),
                1 = meck:num_calls(erltorrent_helper, do_exit, ['_', {completed, '_', '_'}]),
                0 = meck:num_calls(erltorrent_store, mark_piece_new, ['_', '_']),
                0 = meck:num_calls(erltorrent_helper, delete_downloaded_piece, ['_', '_']),
                0 = meck:num_calls(erltorrent_helper, do_exit, ['_', invalid_hash]),
                1 = meck:num_calls(erltorrent_helper, get_concated_piece, ['_', '_'])
            end
        },
        {"File is downloaded. Hash is invalid.",
            fun() ->
                State = #state{
                    piece_length = 100000,
                    count        = 7,
                    piece_hash   = <<45,45,32,11,65,34,87>>,
                    started_at   = 5,
                    updated_at   = 10
                },
                {noreply, State} = handle_info(request_piece, State),
                1 = meck:num_calls(erltorrent_message, request_piece, ['_', '_', '_', '_']),
                1 = meck:num_calls(erltorrent_helper, get_packet, ['_']),
                1 = meck:num_calls(erltorrent_store, mark_piece_completed, ['_', '_']),
                1 = meck:num_calls(erltorrent_helper, do_exit, ['_', {completed, '_', '_'}]),
                1 = meck:num_calls(erltorrent_store, mark_piece_new, ['_', '_']),
                1 = meck:num_calls(erltorrent_helper, delete_downloaded_piece, ['_', '_']),
                1 = meck:num_calls(erltorrent_helper, do_exit, ['_', invalid_hash]),
                2 = meck:num_calls(erltorrent_helper, get_concated_piece, ['_', '_'])
            end
        }]
    }.


-endif.


