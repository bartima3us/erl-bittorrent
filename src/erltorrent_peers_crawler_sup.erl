%%%-------------------------------------------------------------------
%%% @author bartimaeus
%%% @copyright (C) 2019, sarunas.bartusevicius@gmail.com
%%% @doc
%%%
%%% @end
%%% Created : 06. May 2019 19.35
%%%-------------------------------------------------------------------
-module(erltorrent_peers_crawler_sup).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

-behaviour(supervisor).

%% API
-export([
    start_link/0,
    start_crawler/4
]).

%% Supervisor callbacks
-export([
    init/1
]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_crawler(AnnounceLink, Hash, PeerId, FullSize) ->
    ok = await_started(50),
    CurrentChildren = supervisor:which_children(?MODULE),
    case lists:keysearch(erline_dht, 1, CurrentChildren) of
        false ->
            DhtChild = #{
                id          => erline_dht,
                start       => {erline_dht_sup, start_link, []},
                restart     => permanent,
                shutdown    => 5000,
                type        => worker,
                modules     => [erline_dht_sup]
            },
            CrawlerChild = #{
                id          => peers_crawler,
                start       => {erltorrent_peers_crawler, start_link, [AnnounceLink, Hash, PeerId, FullSize]},
                restart     => permanent,
                shutdown    => 5000,
                type        => worker,
                modules     => [erltorrent_peers_crawler]
            },
            {ok, _} = supervisor:start_child(?MODULE, DhtChild),
            {ok, _} = supervisor:start_child(?MODULE, CrawlerChild),
            ok;
        {value, _} ->
            ok
    end.


%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, {{rest_for_one, 5, 10}, []}}.


%% ===================================================================
%% Internal functions
%% ===================================================================

%%  @private
%%  @doc
%%  Await supervisor to start.
%%  @end
await_started(0) ->
    {error, supervisor_can_not_start};

await_started(Tries) ->
    case erlang:whereis(?MODULE) of
        Pid when is_pid(Pid) ->
            ok;
        undefined ->
            timer:sleep(100),
            await_started(Tries - 1)
    end.


