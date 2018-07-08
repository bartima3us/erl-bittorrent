-module(erltorrent_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    Server = #{
        id => server,
        start => {erltorrent_server, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [erltorrent_server]
    },
    {ok, {{one_for_one, 5, 10}, [Server]}}.

