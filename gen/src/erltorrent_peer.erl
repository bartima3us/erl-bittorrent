%%%-------------------------------------------------------------------
%%% @author $author
%%% @copyright (C) $year, $company
%%% @doc
%%%
%%% @end
%%% Created : $fulldate
%%%-------------------------------------------------------------------
-module(erltorrent_peer).

-behaviour(gen_server).

%% API
-export([start_link/6]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
    torrent_name                         :: string(),
    full_size                            :: integer(),
    piece_size                           :: integer(),
    peer_ip                              :: tuple(),
    port                                 :: integer(),
    peer_id                              :: string(),
    hash                                 :: string(),
    socket                               :: port(),
    rest        = <<>>                   :: binary(),
    last_packet = {undefined, undefined} :: tuple(),
    bitfield                             :: binary()
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
start_link(Peer, PeerId, Hash, FileName, FullSize, PieceSize) ->
        gen_server:start_link({local, ?SERVER}, ?MODULE, [Peer, PeerId, Hash, FileName, FullSize, PieceSize], []).

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
init([{PeerIp, Port}, PeerId, Hash, TorrentName, FullSize, PieceSize]) ->
    State = #state{
        torrent_name = TorrentName,
        full_size    = FullSize,
        piece_size   = PieceSize,
        peer_ip      = PeerIp,
        port         = Port,
        peer_id      = PeerId,
        hash         = Hash
    },
    {ok, Socket} = connect(State),
    ok = erltorrent_message:handshake(Socket, PeerId, Hash),
    ok = get_packet(Socket),
    {ok, State#state{socket = Socket}}.

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
handle_info(connect, State) ->
    {noreply, State};

handle_info({tcp, _Port, Packet}, State) ->
    #state{
        torrent_name = TorrentName,
        full_size    = FullSize,
        piece_size   = PieceSize,
        socket       = Socket,
        rest         = Rest,
        last_packet  = {LastPacket, LastPacketLength},
        bitfield     = Bitfield
    } = State,
    io:format("------------------------~n"),
%%    io:format("Got message!~n"),
    %% Jei yra baitų likutis iš anksčiau, tai prijungiame prie tik ką gauto paketo
    FullPacket = <<Rest/binary, Packet/binary>>,

    TakeBitfieldFun = fun(Acc) ->
        case proplists:get_value(bitfield, Acc) of
            undefined ->
                Bitfield;
            TrueBitfield ->
                ok = erltorrent_message:interested(Socket),
                download_proc(Socket, TrueBitfield),
                TrueBitfield
        end
    end,

    KeepAliveFun = fun(Acc) ->
        case proplists:get_value(keep_alive, Acc) of
            undefined ->
                ok;
            _KA ->
                ok = erltorrent_message:keep_alive(Socket),
                ok
        end
    end,

%%    ok = case Bitfield of
%%        undefined -> ok;
%%        _ -> request_piece(Socket)
%%    end,

    case LastPacket of
        undefined ->
            NewState = case erltorrent_packet:identify(FullPacket, []) of
                {ok, NewRest, Acc} ->
                    ok = KeepAliveFun(Acc),
                    State#state{rest = NewRest, last_packet = {undefined, undefined}, bitfield = TakeBitfieldFun(Acc)};
                {ok, NewRest, Acc, NewLastPacket} ->
                    ok = KeepAliveFun(Acc),
                    State#state{rest = NewRest, last_packet = NewLastPacket, bitfield = TakeBitfieldFun(Acc)}
            end;
        %% Gali būti taip, jog turime gavę paskutinio paketo ilgį ir tipą, bet neturime paties paketo turinio, kuris ateis dabar.
        %% Tokiu atveju gavę naują žinutę, jau iškart paduodame, kad tai bus konkretus paketus (ką žinome iš praeitos žinutės)
        LP ->
            NewState = case erltorrent_packet:identify(FullPacket, LP, LastPacketLength) of
                {ok, NewRest, Acc} ->
                    ok = KeepAliveFun(Acc),
                    State#state{rest = NewRest, last_packet = {undefined, undefined}, bitfield = TakeBitfieldFun(Acc)};
                {ok, NewRest, Acc, {NewLastPacket, NewTrueLength}} ->
                    ok = KeepAliveFun(Acc),
                    State#state{rest = NewRest, last_packet = {NewLastPacket, NewTrueLength}, bitfield = TakeBitfieldFun(Acc)}
            end
    end,
    ok = get_packet(Socket),
    io:format("------------------------~n"),
    {noreply, NewState};

handle_info(Info, State) ->
    io:format("Got message! Info=~p, State=~p~n", [Info, State]),
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
connect(State) ->
    #state{
        peer_ip = PeerIp,
        port    = Port
    } = State,
    io:format("Trying to connect ~p:~p~n", [PeerIp, Port]),
    {ok, Socket} = gen_tcp:connect(PeerIp, Port, [{active, false}, binary], 5000),
    io:format("Connection successful. Socket=~p~n", [Socket]),
    {ok, Socket}.


%%
%%
%%
get_packet(Socket) ->
    inet:setopts(Socket, [{active, once}]).


%%
%%
%%
download_proc(Socket, TrueBitfield) ->
    download_proc(Socket, TrueBitfield, 0).

download_proc(Socket, <<>>, Id) ->
    ok;

download_proc(Socket, Bitfield, Id) ->
    DownloadProcFun = fun
        (0) ->
            ok;
        (1) ->
%%            {ok, Pid} = erltorrent_download:start_link(Peer, PeerId, HashBinString),
%%            Pid ! connect,
            ok
    end,
    <<B1:1, B2:1, B3:1, B4:1, B5:1, B6:1, B7:1, B8:1, Rest/binary>> = Bitfield,
    DownloadProcFun(B1),
    DownloadProcFun(B2),
    DownloadProcFun(B3),
    DownloadProcFun(B4),
    DownloadProcFun(B5),
    DownloadProcFun(B6),
    DownloadProcFun(B7),
    DownloadProcFun(B8),
    download_proc(Socket, Rest, Id + 1).



