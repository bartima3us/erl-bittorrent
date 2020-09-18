%%%-------------------------------------------------------------------
%%% @author bartimaeus
%%% @copyright (C) 2019, sarunas.bartusevicius@gmail.com
%%% @doc
%%%
%%% @end
%%% Created : 06. May 2019 19.35
%%%-------------------------------------------------------------------
-module(erltorrent_peers_crawler).
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

-record(state, {
    announce_link   :: string(),
    hash            :: binary(),
    peer_id         :: binary(),
    full_size       :: integer(),
    crawl_after     :: integer(), % ms
    downloaded    = 0  :: integer(),
    left
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
start_link(AnnounceLink, Hash, PeerId, FullSize) ->
    gen_server:start_link(?MODULE, [AnnounceLink, Hash, PeerId, FullSize], []).



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
init([AnnounceLink, Hash, PeerId, FullSize]) ->
    lager:info("Crawler is started. AnnounceLink=~p", [AnnounceLink]),
    State = #state{
        announce_link   = AnnounceLink,
        hash            = Hash,
        peer_id         = PeerId,
        full_size       = FullSize,
        crawl_after     = 10000
    },
    % Add DHT client event handler
    ok = erline_dht_sup:start(node1),
    % @todo subscribe again after event manager crash
    gen_event:add_handler('erline_dht_node1$event_manager', erltorrent_dht_event_handler, [PeerId, FullSize]),
    % Start crawlers
    self() ! tracker_crawl,
    erlang:send_after(5000, self(), dht_crawl), % Wait a bit until DHT node will receive more peers
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
%%
handle_info(tracker_crawl, State) ->
    % Crawl from tracker
    #state{
        announce_link   = AnnounceLink,
        hash            = Hash,
        peer_id         = PeerId,
        full_size       = FullSize,
        downloaded      = Downloaded
    } = State,
    EncodedHash = erltorrent_helper:urlencode(Hash),
    Left = FullSize - Downloaded,
    {ok, {dict, Result}} = connect_to_tracker(AnnounceLink, EncodedHash, PeerId, Left, Downloaded),
    PeersIP = get_peers(dict:fetch(<<"peers">>, Result)),
    CrawlAfter = dict:fetch(<<"interval">>, Result),
    case dict:is_key(<<"failure reason">>, Result) of
        true  -> lager:info("Failure reason = ~p", [dict:fetch(<<"failure reason">>, Result)]);
        false -> ok
    end,
    ok = lists:foreach(fun
        (Peer = {PeerIp, PeerPort}) ->
            ok = erline_dht_bucket:add_node(node1, PeerIp, PeerPort), % Despite of we don't know whether peer port is the same like DHT node port, still try to add it.
            ok = erltorrent_peers_sup:add_child(Peer, PeerId, Hash, FullSize)
    end, PeersIP),
    NewCrawlAfter = case CrawlAfter < 20000 of
        true  -> CrawlAfter + 1000;
        false -> CrawlAfter
    end,
    erlang:send_after(CrawlAfter, self(), tracker_crawl),
    {noreply, State#state{crawl_after = NewCrawlAfter}};

handle_info(dht_crawl, State = #state{hash = Hash}) ->
    % Crawl from DHT
    ok = erline_dht:get_peers(node1, Hash),
    erlang:send_after(60000, self(), dht_crawl), % @todo is it needed?
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

%% @priv
%% Parse peers list
%%
get_peers(PeersList) ->
    get_peers(PeersList, []).

get_peers(<<>>, Result) ->
    lists:reverse(Result);

get_peers(PeersList, Result) ->
    <<Byte1:8, Byte2:8, Byte3:8, Byte4:8, Port:16, Rest/binary>> = PeersList,
    get_peers(Rest, [{{Byte1, Byte2, Byte3, Byte4}, Port} | Result]).


%% @priv
%% Make HTTP connect to tracker to get information
%%
connect_to_tracker(TrackerLink, Hash, PeerId, FullSize, Downloaded) ->
    inets:start(),
    Separator = case string:str(TrackerLink, "?") of 0 -> "?"; _ -> "&" end,
    FullLink = TrackerLink ++ Separator ++ "info_hash=" ++ Hash ++ "&peer_id=" ++ PeerId ++ "&port=54761&uploaded=0&downloaded=" ++ integer_to_list(Downloaded) ++ "&left=" ++ erltorrent_helper:convert_to_list(FullSize) ++ "&corrupt=0&key=4ACCCA00&event=started&numwant=200&compact=1&no_peer_id=1&supportcrypto=1&redundant=0",
    % Lets imitate Deluge!
    Headers = [
        {"User-Agent", "Deluge 1.3.12"}, % @todo need to check if it is needed
        {"Accept-Encoding", "gzip"}
    ],
    {ok, {{_Version, _Code, _ReasonPhrase}, _Headers, Body}} = httpc:request(get, {FullLink, Headers}, [], [{body_format, binary}]),
    erltorrent_bencoding:decode(Body).

