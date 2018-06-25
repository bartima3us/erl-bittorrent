%%%-------------------------------------------------------------------
%%% @author sarunas
%%% @copyright (C) 2018, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 23. Jun 2018 08.33
%%%-------------------------------------------------------------------
-module(erltorrent_downloader).
-author("sarunas").

-behaviour(gen_server).

%% API
-export([
    start_link/4
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
    torrent_id                     :: integer(), % Unique torrent ID in Mnesia
    peer_ip                        :: tuple(),
    port                           :: integer(),
    socket                         :: port(),
    piece_id                       :: binary(),
    piece_length                   :: integer(), % Full length of piece
    count        = 0               :: integer(),
    parser_pid                     :: pid()
}).

% @todo išhardkodinti, nes visas failas gali būti mažesnis už šitą skaičių
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
start_link(TorrentId, PieceId, PeerIp, Port) ->
    gen_server:start_link(?MODULE, [TorrentId, PieceId, PeerIp, Port], []).

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
init([TorrentId, PieceId, PeerIp, Port]) ->
    {ok, Socket} = do_connect(PeerIp, Port),
    {ok, ParserPid} = erltorrent_packet:start_link(),
    State = #state{
        torrent_id  = TorrentId,
        peer_ip     = PeerIp,
        port        = Port,
        socket      = Socket,
        piece_id    = PieceId,
        parser_pid  = ParserPid
    },
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
handle_cast(download, State) ->
    #state{
        socket       = Socket,
        piece_id     = PieceId,
        piece_length = PieceLength,
        count        = Count
    } = State,
    {ok, {NextLength, OffsetBin}} = get_request_data(Count, PieceLength),
    % Check if file isn't downloaded yet
    case NextLength > 0 of
        true ->
            ok = erltorrent_message:request_piece(Socket, PieceId, OffsetBin, NextLength),
            ok = erltorrent_helper:get_packet(Socket);
        false ->
            exit(self(), shutdown)
    end,
    {noreply, State};

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
handle_info({tcp, Port, Packet}, State = #state{port = Port}) ->
    #state{
        torrent_id  = TorrentId,
        port        = Port,
        count       = Count,
        parser_pid  = ParserPid
    } = State,
    % @todo mapfilter from Data only piece packets
    % @todo jei nieko negrąžina parse/2, kviesti erltorrent_helper:get_packet(Socket), kol grąžins
    {ok, Data} = erltorrent_packet:parse(ParserPid, Packet),
    PieceId = 0,    % @todo fill in mapfilter
    PieceBegin = 0, % @todo fill in mapfilter
    file:write_file(
        filename:join(["temp", TorrentId, integer_to_list(PieceId), integer_to_list(PieceBegin)]),
        Packet,
        [append]
    ),
    start_download(),
    {noreply, State#state{count = Count + 1}};

handle_info({tcp, Port, _Packet}, State) ->
    io:format("Packet from unknown port = ~p~n", [Port]),
    {noreply, State};

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
    io:format("Trying to connect ~p:~p~n", [PeerIp, Port]),
    {ok, Socket} = gen_tcp:connect(PeerIp, Port, [{active, false}, binary], 5000),
    io:format("Connection successful. Socket=~p~n", [Socket]),
    {ok, Socket}.


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
%% Start parsing data (sync. call)
%%
start_download() ->
    gen_server:cast(self(), download).



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
        )
    ].


-endif.


