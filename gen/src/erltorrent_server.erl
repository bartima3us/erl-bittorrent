%%%-------------------------------------------------------------------
%%% @author $author
%%% @copyright (C) $year, $company
%%% @doc
%%%
%%% @end
%%% Created : $fulldate
%%%-------------------------------------------------------------------
-module(erltorrent_server).

-behaviour(gen_server).

%% API
-export([start_link/0, download/0, download/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================


%% application:start(erltorrent).
%% erltorrent_server:download().
%%
download() ->
    gen_server:call(?MODULE, {download, inverse}).

download(r) ->
    gen_server:call(?MODULE, {download, reverse}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
        gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

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

handle_call({download, Type}, _From, State) ->
    File = filename:join(["torrents", "Cyberwar.S02E03.HDTV.x264-W4F (2).torrent"]),
    {ok, Bin} = file:read_file(File),
    {ok, {dict, MetaInfo}} = erltorrent_bencoding:decode(Bin),

    {dict, Info} = dict:fetch(<<"info">>, MetaInfo),
    FileName = dict:fetch(<<"name">>, Info),
    Length = dict:fetch(<<"length">>, Info),
    Pieces = dict:fetch(<<"pieces">>, Info), % @todo verifikuoti kiekvieno piece parsiuntimą
    FullSize = dict:fetch(<<"length">>, Info),
    PieceSize = dict:fetch(<<"piece length">>, Info),
    TrackerLink = binary_to_list(dict:fetch(<<"announce">>, MetaInfo)),

    PeerId = "-ER0000-45AF6T-NM81-", % @todo make random

    io:format("Length=~p bytes~n", [Length]),
    io:format("Piece length=~p bytes~n", [PieceSize]),
    io:format("Name=~p~n", [FileName]),

    <<FirstHash:20/binary, _Rest/binary>> = Pieces,
    io:format("First piece hash=~p~n", [erltorrent_bin_to_hex:bin_to_hex(FirstHash)]),

    BencodedInfo = binary_to_list(erltorrent_bencoding:encode(dict:fetch(<<"info">>, MetaInfo))),
    HashBinString = erltorrent_sha1:binstring(BencodedInfo),
    Hash = erltorrent_helper:urlencode(HashBinString),

    {ok, {dict, Result}} = connect_to_tracker(TrackerLink, Hash, PeerId, FullSize),
    PeersIP = case Type of
        inverse -> get_peers(dict:fetch(<<"peers">>, Result), []);
        reverse -> lists:reverse(get_peers(dict:fetch(<<"peers">>, Result), []))
    end,

    io:format("All peers~p~n", [PeersIP]),
    [Peer|_] = PeersIP,
    {ok, Pid} = erltorrent_peer:start_link(Peer, PeerId, HashBinString, FileName, FullSize, PieceSize),
    MonitorRef = erlang:monitor(process, Pid),
    Pid ! connect,
    Reply = {ok, MonitorRef},
    {reply, Reply, State};

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


