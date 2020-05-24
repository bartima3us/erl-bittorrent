%%%-------------------------------------------------------------------
%%% @author bartimaeus
%%% @copyright (C) 2019, sarunas.bartusevicius@gmail.com
%%% @doc
%%% Used for end game.
%%% @end
%%% Created : 03. May 2019 10.34
%%%-------------------------------------------------------------------
-module(erltorrent_peer_events).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

-behaviour(gen_event).

-include_lib("gen_bittorrent/include/gen_bittorrent.hrl").
-include("erltorrent.hrl").

%% API
-export([
    start_link/1,
    add_sup_handler/3,
    piece_completed/2,
    delete_handler/2
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
    piece_id        :: piece_id_int(),
    ip_port         :: ip_port(),
    downloader_pid  :: pid()
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
start_link(PieceId) ->
    gen_event:start_link({local, get_process_name(PieceId)}).

%%--------------------------------------------------------------------
%% @doc
%% Adds an event handler
%%
%% @spec add_handler() -> ok | {'EXIT', Reason} | term()
%% @end
%%--------------------------------------------------------------------
add_sup_handler(PieceId, IpPort, Pid) ->
    lager:info("Add handler. PieceId=~p from=~p, pid=~p", [PieceId, IpPort, Pid]),
    gen_event:add_sup_handler(get_process_name(PieceId), {?MODULE, Pid}, [PieceId, IpPort, Pid]).


%%  @doc
%%  Delete handler.
%%
delete_handler(PieceId, Pid) ->
    lager:info("Delete handler. PieceId=~p, pid=~p", [PieceId, Pid]),
    gen_event:delete_handler(get_process_name(PieceId), {?MODULE, Pid}, []).


%%  @doc
%%  Piece has been downloaded successfully.
%%
piece_completed(PieceId, From) ->
    gen_event:notify(?MODULE, {piece_completed, PieceId, From}).



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
init([PieceId, IpPort, DownloaderPid]) ->
    NewState = #state{
        piece_id       = PieceId,
        ip_port        = IpPort,
        downloader_pid = DownloaderPid
    },
    {ok, NewState}.

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
handle_event({piece_completed, PieceId, From}, State = #state{ip_port = IpPort, downloader_pid = Pid}) when From =/= Pid ->
    lager:info("Sent piece_completed to PieceId=~p from=~p", [PieceId, IpPort]),
    #state{piece_id = PieceId, ip_port = IpPort} = State,
    % Send only to PieceId owners except From (he's a sender so he knows that he downloaded that piece)
    ok = erltorrent_leech_server:piece_completed(IpPort, PieceId, Pid, 0),
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

%%  @private
%%  @doc
%%  Get process name.
%%  @end
-spec get_process_name(
    PieceId :: piece_id_int()
) -> ProcessName :: atom().

get_process_name(PieceId) ->
    erlang:list_to_atom(?MODULE_STRING ++ "_" ++ erlang:integer_to_list(PieceId)).


