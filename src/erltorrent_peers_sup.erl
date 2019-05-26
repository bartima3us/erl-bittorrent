%%%-------------------------------------------------------------------
%%% @author bartimaeus
%%% @copyright (C) 2019, sarunas.bartusevicius@gmail.com
%%% @doc
%%%
%%% @end
%%% Created : 06. May 2019 19.35
%%%-------------------------------------------------------------------
-module(erltorrent_peers_sup).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

-behaviour(supervisor).

%% API
-export([start_link/0, add_child/5]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


add_child(Peer, PeerId, Hash, FileName, FullSize) ->
    Id = {Peer, sup},
    Spec = #{
        id          => Id,
        start       => {erltorrent_peer_sup, start_link, [Peer, PeerId, Hash, FileName, FullSize]},
        restart     => temporary,
        shutdown    => infinity,
        type        => supervisor,
        modules     => [erltorrent_peer_sup]
    },
    Children = supervisor:which_children(?MODULE),
    case lists:keysearch(Id, 1, Children) of
        false      ->
            {ok, _} = supervisor:start_child(?MODULE, Spec),
            ok;
        {value, _} ->
            ok
    end.

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    % This supervisor must be very vital
    {ok, {{one_for_one, 200, 10}, []}}.