%%%-------------------------------------------------------------------
%%% @author bartimaeus
%%% @copyright (C) 2019, sarunas.bartusevicius@gmail.com
%%% @doc
%%%
%%% @end
%%% Created : 06. May 2019 19.35
%%%-------------------------------------------------------------------
-module(erltorrent_peer).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

-behaviour(gen_server).

-include_lib("gen_bittorrent/include/gen_bittorrent.hrl").
-include("erltorrent.hrl").

%% API
-export([start_link/4]).

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

-record(state, {
    full_size       :: integer(),
    peer_ip         :: inet:ip_address(),
    port            :: inet:port_number(),
    peer_id         :: string(),
    hash            :: string(),
    socket          :: port(),
    bitfield        :: binary(),
    rest_payload    :: payload(),
    try_after       :: integer()
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
start_link(Peer, PeerId, Hash, FullSize) ->
    gen_server:start_link(?MODULE, [Peer, PeerId, Hash, FullSize], []).



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
init([{PeerIp, Port}, PeerId, Hash, FullSize]) ->
    State = #state{
        full_size    = FullSize,
        peer_ip      = PeerIp,
        port         = Port,
        peer_id      = PeerId,
        hash         = Hash,
        try_after    = 1000
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
%% Connect to peer, make a handshake
%%
handle_info(start, State = #state{peer_id = PeerId, hash = Hash, try_after = TryAfter}) ->
    NewState = case do_connect(State) of
        {ok, Socket} ->
            % @todo Need to start Kademlia here
            ok = gen_bittorrent_message:handshake(Socket, PeerId, Hash),
            ok = erltorrent_helper:get_packet(Socket),
            State#state{socket = Socket};
        {error, emfile} ->
            lager:info("File descriptor is exhausted. Can't open a new socket for peer."),
            exit(shutdown);
        {error, Error} when Error =:= econnrefused;
                            Error =:= ehostunreach;
                            Error =:= etimedout;
                            Error =:= enetunreach;
                            Error =:= timeout -> % @todo maybe need particular behavior on particular error?
            NewTryAfter = case TryAfter < 10000 of
                true  -> TryAfter + 1000;
                false -> TryAfter
            end,
            erlang:send_after(TryAfter, self(), start),
            State#state{try_after = NewTryAfter}
    end,
    {noreply, NewState};

%% @doc
%% Handle and parse packets from peer
%%
handle_info({tcp, _Port, Packet}, State) ->
    #state{
        socket       = Socket,
        peer_ip      = PeerIp,
        port         = Port,
        peer_id      = PeerId,
        hash         = Hash,
        rest_payload = Rest
    } = State,
    {ok, Data, NewRestPayload} = gen_bittorrent_packet:parse(Packet, Rest),
    ok = case proplists:get_value(handshake, Data) of
        true -> gen_bittorrent_message:handshake(Socket, PeerId, Hash);
        _    -> ok
    end,
    ok = case proplists:get_value(keep_alive, Data) of
        true -> gen_bittorrent_message:keep_alive(Socket);
        _    -> ok
    end,
    case proplists:get_value(bitfield, Data) of
        undefined -> ok;
        #bitfield_data{parsed = ParsedBitfield} -> erltorrent_leech_server ! {bitfield, ParsedBitfield, PeerIp, Port}
    end,
    case proplists:get_value(have, Data) of
        undefined -> ok;
        PieceId  -> erltorrent_leech_server ! {have, PieceId, PeerIp, Port}
    end,
    ok = erltorrent_helper:get_packet(Socket),
    {noreply, State#state{rest_payload = NewRestPayload}};

%% @doc
%% Handle socket close
%%
handle_info({tcp_closed, Socket}, State = #state{socket = Socket}) ->
    lager:info("Socket closed! State=~p", [State]),
    % @todo still don't know if it's a normal error and should not be restarted...
%%    erltorrent_helper:do_exit(self(), normal),
    {stop, normal, State};

%% @doc
%% Handle unknown messages
%%
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

%% @doc
%% Open a socket with peer
%%
do_connect(State) ->
    #state{
        peer_ip = PeerIp,
        port    = Port
    } = State,
    gen_tcp:connect(PeerIp, Port, [{active, false}, binary], 5000).


