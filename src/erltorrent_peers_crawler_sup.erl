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
-export([start_link/0, start_child/5]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


start_child(FileName, AnnounceLink, Hash, PeerId, FullSize) ->
    supervisor:start_child(?MODULE, [FileName, AnnounceLink, Hash, PeerId, FullSize]).


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


