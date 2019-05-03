%%%-------------------------------------------------------------------
%%% @author bartimaeus
%%% @copyright (C) 2019, sarunas.bartusevicius@gmail.com
%%% @doc
%%%
%%% @end
%%% Created : 03. May 2019 10.34
%%%-------------------------------------------------------------------
-module(erltorrent_peer_events).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

-behaviour(gen_event).

-include("erltorrent.hrl").

%% API
-export([
    start_link/0,
    add_sup_handler/2,
    end_game/0,
    block_downloaded/3,
    swap_sup_handler/2
]).

%% gen_event callbacks
-export([
    init/1, 
    handle_event/2, 
    handle_call/2,
    handle_info/2, 
    terminate/2, 
    code_change/3
]).

-record(state, {
    downloader_pid      :: pid(),
    piece_id            :: piece_id_int(),
    end_game = false    :: boolean()
}).


%%%===================================================================
%%% gen_event callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Creates an event manager
%%
%% @spec start_link() -> {ok, Pid} | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_event:start_link({local, ?MODULE}).

%%--------------------------------------------------------------------
%% @doc
%% Adds an event handler
%%
%% @spec add_handler() -> ok | {'EXIT', Reason} | term()
%% @end
%%--------------------------------------------------------------------
add_sup_handler(Id, Args) ->
    gen_event:add_sup_handler(?MODULE, {?MODULE, Id}, Args).


%%  @doc
%%  Swap old handler to new one.
%%
swap_sup_handler(OldId, NewId) ->
    gen_event:swap_sup_handler(?MODULE, {{?MODULE, OldId}, switch}, {{?MODULE, NewId}, NewId}).


%%  @doc
%%  End game mode is enabled.
%%
end_game() ->
    gen_event:notify(?MODULE, end_game).


%%  @doc
%%  Block from piece downloaded successfully.
%%
block_downloaded(PieceId, BlockId, From) ->
    gen_event:notify(?MODULE, {block_downloaded, PieceId, BlockId, From}).



%%%===================================================================
%%% gen_event callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a new event handler is added to an event manager,
%% this function is called to initialize the event handler.
%%
%% @spec init(Args) -> {ok, State}
%% @end
%%--------------------------------------------------------------------
init([DownloaderPid, PieceId]) ->
    {ok, #state{downloader_pid = DownloaderPid, piece_id = PieceId}};

init({PieceId, DownloaderPid}) ->
    {ok, #state{downloader_pid = DownloaderPid, piece_id = PieceId}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever an event manager receives an event sent using
%% gen_event:notify/2 or gen_event:sync_notify/2, this function is
%% called for each installed event handler to handle the event.
%%
%% @spec handle_event(Event, State) ->
%%                          {ok, State} |
%%                          {swap_handler, Args1, State1, Mod2, Args2} |
%%                          remove_handler
%% @end
%%--------------------------------------------------------------------
handle_event(end_game, State) ->
    {ok, State#state{end_game = true}};

handle_event({block_downloaded, PieceId, BlockId, From}, State = #state{piece_id = PieceId, downloader_pid = Pid}) when From =/= Pid ->
    Pid ! {block_downloaded, BlockId},
    {ok, State};

handle_event(_Event, State) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever an event manager receives a request sent using
%% gen_event:call/3,4, this function is called for the specified
%% event handler to handle the request.
%%
%% @spec handle_call(Request, State) ->
%%                   {ok, Reply, State} |
%%                   {swap_handler, Reply, Args1, State1, Mod2, Args2} |
%%                   {remove_handler, Reply}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, State) ->
    Reply = ok,
    {ok, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called for each installed event handler when
%% an event manager receives any other message than an event or a
%% synchronous request (or a system message).
%%
%% @spec handle_info(Info, State) ->
%%                         {ok, State} |
%%                         {swap_handler, Args1, State1, Mod2, Args2} |
%%                         remove_handler
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever an event handler is deleted from an event manager, this
%% function is called. It should be the opposite of Module:init/1 and
%% do any necessary cleaning up.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(switch, #state{downloader_pid = DownloaderPid}) ->
    DownloaderPid;

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


