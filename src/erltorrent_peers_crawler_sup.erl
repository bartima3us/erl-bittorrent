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
-export([start_link/0, start_child/4]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


start_child(AnnounceLink, Hash, PeerId, FullSize) ->
    ok = await_started(50),
    supervisor:start_child(?MODULE, [AnnounceLink, Hash, PeerId, FullSize]).


%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    Crawler = #{
        id          => peers_crawler,
        start       => {erltorrent_peers_crawler, start_link, []},
        restart     => permanent,
        shutdown    => 5000,
        type        => worker,
        modules     => [erltorrent_peers_crawler]
    },
    {ok, {{simple_one_for_one, 5, 10}, [Crawler]}}.


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


