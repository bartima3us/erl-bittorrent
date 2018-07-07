%%%-------------------------------------------------------------------
%%% @author $author
%%% @copyright (C) $year, $company
%%% @doc
%%%
%%% @end
%%% Created : $fulldate
%%%-------------------------------------------------------------------
-module(erltorrent_peer).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

-behaviour(gen_server).

-include("erltorrent.hrl").

%% API
-export([start/7]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
    torrent_name    :: string(),
    full_size       :: integer(),
    piece_size      :: integer(),
    peer_ip         :: tuple(),
    port            :: integer(),
    peer_id         :: string(),
    hash            :: string(),
    socket          :: port(),
    bitfield        :: binary(),
    parser_pid      :: pid(),
    server_pid      :: pid()
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
start(Peer, PeerId, Hash, FileName, FullSize, PieceSize, ServerPid) ->
    gen_server:start(?MODULE, [Peer, PeerId, Hash, FileName, FullSize, PieceSize, ServerPid], []).

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
init([{PeerIp, Port}, PeerId, Hash, TorrentName, FullSize, PieceSize, ServerPid]) ->
    {ok, ParserPid} = erltorrent_packet:start_link(),
    State = #state{
        torrent_name = TorrentName,
        full_size    = FullSize,
        piece_size   = PieceSize,
        peer_ip      = PeerIp,
        port         = Port,
        peer_id      = PeerId,
        hash         = Hash,
        parser_pid   = ParserPid,
        server_pid   = ServerPid
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

handle_info(start, State = #state{peer_id = PeerId, hash = Hash}) ->
    {ok, Socket} = do_connect(State),
    ok = erltorrent_message:handshake(Socket, PeerId, Hash),
    ok = erltorrent_helper:get_packet(Socket),
    {noreply, State#state{socket = Socket}};

handle_info({tcp, _Port, Packet}, State) ->
    #state{
        torrent_name = TorrentName,
        full_size    = FullSize,
        piece_size   = PieceSize,
        socket       = Socket,
        bitfield     = Bitfield,
        peer_ip      = PeerIp,
        port         = Port,
        peer_id      = PeerId,
        hash         = Hash,
        parser_pid   = ParserPid,
        server_pid   = ServerPid
    } = State,
    {ok, Data} = erltorrent_packet:parse(ParserPid, Packet),
    ok = case proplists:get_value(handshake, Data) of
        true ->
%%            lager:info("Received handshake from ~p:~p for file: ~p", [PeerIp, Port, TorrentName]),
            erltorrent_message:handshake(Socket, PeerId, Hash);
        _    ->
            ok
    end,
    ok = case proplists:get_value(keep_alive, Data) of
        true ->
%%            lager:info("Received keep alive from ~p:~p for file: ~p", [PeerIp, Port, TorrentName]),
            erltorrent_message:keep_alive(Socket);
        _    ->
            ok
    end,
    ok = case proplists:get_value(bitfield, Data) of
        undefined ->
            ok;
        BitField = #bitfield_data{parsed = ParsedBitfield} ->
%%            lager:info("Received bitfield: ~p from ~p:~p for file: ~p", [BitField, PeerIp, Port, TorrentName]),
            ServerPid ! {bitfield, ParsedBitfield, PeerIp, Port},
            ok
    end,
    ok = case proplists:get_value(have, Data) of
        undefined ->
            ok;
        PeaceId  ->
%%            lager:info("Received have: ~p from ~p:~p for file: ~p", [PeaceId, PeerIp, Port, TorrentName]),
            ServerPid ! {have, PeaceId, PeerIp, Port},
            ok
    end,
    ok = erltorrent_helper:get_packet(Socket),
    {noreply, State};

handle_info({tcp_closed, Socket}, State = #state{socket = Socket}) ->
    lager:info("Socket closed! State=~p", [State]),
    exit(normal),
    {noreply, State};

handle_info(Info, State) ->
    lager:info("Got unknown message! Info=~p, State=~p", [Info, State]),
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


%%
%%
%%
do_connect(State) ->
    #state{
        peer_ip = PeerIp,
        port    = Port
    } = State,
%%    io:format("Trying to connect ~p:~p~n", [PeerIp, Port]),
    {ok, Socket} = gen_tcp:connect(PeerIp, Port, [{active, false}, binary], 5000),
%%    io:format("Connection successful. Socket=~p~n", [Socket]),
    {ok, Socket}.


