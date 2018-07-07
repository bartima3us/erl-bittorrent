%%%-------------------------------------------------------------------
%%% @author $author
%%% @copyright (C) $year, $company
%%% @doc
%%%
%%% @end
%%% Created : $fulldate
%%%-------------------------------------------------------------------
-module(erltorrent_server).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

-behaviour(gen_server).

-include("erltorrent.hrl").

%% API
-export([
    start_link/0,
    download/0,
    download/1,
    piece_peers/1
]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
]).

-define(SERVER, ?MODULE).

-record(downloading_piece, {
    ip,
    port,
    peace_id :: piece_id_int()
}).

-record(state, {
    pieces_peers       = dict:new(),
    downloading_pieces = []          :: [{reference(), #downloading_piece{}}], % Key is monitor ref
    pieces_amount                    :: integer()
}).

%%%===================================================================
%%% API
%%%===================================================================


%% make start
%% application:start(erltorrent).
%% erltorrent_server:download().
%% erltorrent_server:piece_peers(4).
%%
download() ->
    gen_server:call(?MODULE, {download, inverse}).

download(r) ->
    gen_server:call(?MODULE, {download, reverse}).

piece_peers(Id) ->
    gen_server:call(?MODULE, {peace_peers, Id}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start({local, ?SERVER}, ?MODULE, [], []).

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
init([]) ->
    {ok, #state{}}.

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

handle_call({download, Type}, _From, State = #state{pieces_peers = PiecesPeers}) ->
    File = filename:join(["torrents", "[Commie] Banana Fish - 01 [3600C7D5].mkv.torrent"]),
    {ok, Bin} = file:read_file(File),
    {ok, {dict, MetaInfo}} = erltorrent_bencoding:decode(Bin),

    {dict, Info} = dict:fetch(<<"info">>, MetaInfo),
    FileName = dict:fetch(<<"name">>, Info),
    Pieces = dict:fetch(<<"pieces">>, Info), % @todo verifikuoti kiekvieno piece parsiuntimą
    FullSize = dict:fetch(<<"length">>, Info),
    PieceSize = dict:fetch(<<"piece length">>, Info),
    TrackerLink = binary_to_list(dict:fetch(<<"announce">>, MetaInfo)),
    PiecesAmount = list_to_integer(float_to_list(math:ceil(FullSize / PieceSize), [{decimals, 0}])),
    lager:info("File name = ~p", [FileName]),
    lager:info("Piece size = ~p bytes", [PieceSize]),
    lager:info("Full file size = ~p", [FullSize]),
    lager:info("Pieces amount = ~p", [PiecesAmount]),

    PeerId = "-ER0000-45AF6T-NM81-", % @todo make random

%%    <<FirstHash:20/binary, _Rest/binary>> = Pieces,
%%    io:format("First piece hash=~p~n", [erltorrent_bin_to_hex:bin_to_hex(FirstHash)]),

    BencodedInfo = binary_to_list(erltorrent_bencoding:encode(dict:fetch(<<"info">>, MetaInfo))),
    HashBinString = erltorrent_sha1:binstring(BencodedInfo),
    Hash = erltorrent_helper:urlencode(HashBinString),

    {ok, {dict, Result}} = connect_to_tracker(TrackerLink, Hash, PeerId, FullSize),
    PeersIP = case Type of % @todo vėliau pašalinti
        inverse -> get_peers(dict:fetch(<<"peers">>, Result), []);
        reverse -> lists:reverse(get_peers(dict:fetch(<<"peers">>, Result), []))
    end,
    lager:info("All peers = ~p", [PeersIP]),

    [OnePeer|_] = PeersIP,
    lists:map(
        fun (Peer) ->
            erltorrent_peer:start(Peer, PeerId, HashBinString, FileName, FullSize, PieceSize, self())
        end,
        [OnePeer]
    ),
    % Fill empty peaces peers
    NewPiecesPeers = lists:foldl(
        fun (Id, Acc) ->
            dict:store(Id, [], Acc)
        end,
        PiecesPeers,
        lists:seq(0, PiecesAmount - 1)
    ),
    {reply, ok, State#state{pieces_amount = PiecesAmount, pieces_peers = NewPiecesPeers}};

%%
%%
handle_call({peace_peers, Id}, _From, State = #state{pieces_peers = PiecesPeers}) ->
    {reply, dict:fetch(Id, PiecesPeers), State};

%%
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
handle_info({bitfield, ParsedBitfield, Ip}, State = #state{pieces_peers = PiecesPeers}) ->
    NewPiecesPeers = dict:map(
        fun (Id, Peers) ->
            case proplists:get_value(Id, ParsedBitfield) of
                Val when Val =:= true ->
                    [Ip|Peers];
                _    ->
                    Peers
            end
        end,
        PiecesPeers
    ),
    {noreply, State#state{pieces_peers = NewPiecesPeers}};

handle_info({have, PieceId, Ip}, State) ->

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


%%
%%
%%
connect_to_tracker(TrackerLink, Hash, PeerId, FullSize) ->
    inets:start(),
    Separator = case string:str(TrackerLink, "?") of 0 -> "?"; _ -> "&" end,
    FullLink = TrackerLink ++ Separator ++ "info_hash=" ++ Hash ++ "&peer_id=" ++ PeerId ++ "&port=61940&uploaded=0&downloaded=0&left=" ++ erltorrent_helper:convert_to_list(FullSize) ++ "&corrupt=0&key=4ACCCA00&event=started&numwant=200&compact=1&no_peer_id=1&supportcrypto=1&redundant=0",
    {ok, {{_Version, _Code, _ReasonPhrase}, _Headers, Body}} = httpc:request(get, {FullLink, []}, [], [{body_format, binary}]),
    erltorrent_bencoding:decode(Body).


%%
%%
%%
get_peers(<<>>, Result) ->
    lists:reverse(Result);

get_peers(PeersList, Result) ->
    <<Byte1:8, Byte2:8, Byte3:8, Byte4:8, Port:16, Rest/binary>> = PeersList,
    get_peers(Rest, [{{Byte1, Byte2, Byte3, Byte4}, Port} | Result]).


