%%%-------------------------------------------------------------------
%%% @author $author
%%% @copyright (C) $year, $company
%%% @doc
%%%
%%% @end
%%% Created : $fulldate
%%%-------------------------------------------------------------------
-module(erltorrent_peers_crawler).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

-behaviour(gen_server).

-include("erltorrent.hrl").

%% API
-export([start_link/6]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {
    file_name       :: binary(),
    announce_link   :: string(),
    hash            :: binary(),
    peer_id         :: binary(),
    full_size       :: integer(),
    piece_size      :: integer(),
    crawl_after     :: integer() % ms
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
start_link(FileName, AnnounceLink, Hash, PeerId, FullSize, PieceSize) ->
    gen_server:start_link(?MODULE, [FileName, AnnounceLink, Hash, PeerId, FullSize, PieceSize], []).



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
init([FileName, AnnounceLink, Hash, PeerId, FullSize, PieceSize]) ->
    lager:info("Crawler is started. AnnounceLink=~p", [AnnounceLink]),
    State = #state{
        file_name       = FileName,
        announce_link   = AnnounceLink,
        hash            = Hash,
        peer_id         = PeerId,
        full_size       = FullSize,
        piece_size      = PieceSize,
        crawl_after     = 10000
    },
    self() ! crawl,
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
handle_info(crawl, State) ->
    #state{
        file_name       = FileName,
        announce_link   = AnnounceLink,
        hash            = Hash,
        peer_id         = PeerId,
        full_size       = FullSize,
        piece_size      = PieceSize,
        crawl_after     = CrawlAfter
    } = State,
    EncodedHash = erltorrent_helper:urlencode(Hash),
    {ok, {dict, Result}} = connect_to_tracker(AnnounceLink, EncodedHash, PeerId, FullSize),
    PeersIP = get_peers(dict:fetch(<<"peers">>, Result)),
    lager:info("Peers list = ~p", [PeersIP]),
%%    AllowedPorts = [
%%        29856,
%%        51904,
%%        29659,
%%        55510,
%%        11426 % true
%%    ],
    ok = lists:foreach(
        fun
%%            (Peer = {_, Port}) ->
%%                case lists:member(Port, AllowedPorts) of
%%                    true ->
%%                        ok = erltorrent_peers_sup:add_child(Peer, PeerId, Hash, FileName, FullSize, PieceSize);
%%                    false ->
%%                        ok
%%                end;
%%            (_) ->
%%                lager:info("xxxxxxxxx PEER DISCARDED!!!!! TESTING MODE. xxxxxxxxx"),
%%                ok
            (Peer) -> ok = erltorrent_peers_sup:add_child(Peer, PeerId, Hash, FileName, FullSize, PieceSize)
        end,
        PeersIP
    ),
    NewCrawlAfter = case CrawlAfter < 20000 of
        true  -> CrawlAfter + 1000;
        false -> CrawlAfter
    end,
    erlang:send_after(CrawlAfter, self(), crawl),
    {noreply, State#state{crawl_after = NewCrawlAfter}};


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
connect_to_tracker(TrackerLink, Hash, PeerId, FullSize) ->
    inets:start(),
    Separator = case string:str(TrackerLink, "?") of 0 -> "?"; _ -> "&" end,
    FullLink = TrackerLink ++ Separator ++ "info_hash=" ++ Hash ++ "&peer_id=" ++ PeerId ++ "&port=54761&uploaded=0&downloaded=0&left=" ++ erltorrent_helper:convert_to_list(FullSize) ++ "&corrupt=0&key=4ACCCA00&event=started&numwant=200&compact=1&no_peer_id=1&supportcrypto=1&redundant=0",
    % Lets imitate Deluge!
    Headers = [
        {"User-Agent", "Deluge 1.3.12"}, % @todo need to check if it is needed
        {"Accept-Encoding", "gzip"}
    ],
    {ok, {{_Version, _Code, _ReasonPhrase}, _Headers, Body}} = httpc:request(get, {FullLink, Headers}, [], [{body_format, binary}]),
    erltorrent_bencoding:decode(Body).

