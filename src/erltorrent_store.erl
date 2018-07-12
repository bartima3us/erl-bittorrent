%%%-------------------------------------------------------------------
%%% @author bartimaeus
%%% @copyright (C) 2018, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 12. Jul 2018 19.38
%%%-------------------------------------------------------------------
-module(erltorrent_store).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

-include("erltorrent.hrl").
-include("erltorrent_store.hrl").

-define(SCHEMA_VERSION, 0).

-export([
    wait_for_tables/1
]).



%%%===================================================================
%%% Startup functions
%%%===================================================================

tables() -> [
    erltorrent_store_files,
    erltorrent_store_meta
].


%% @doc
%%  Creates mnesia tables.
%%
create_tables(Nodes) ->
    OptDC = {disc_copies, Nodes},
    CreateTableCheckFun = fun
        ({atomic, ok}) -> ok;
        ({aborted, {already_exists, _Table}}) -> ok
    end,
    ok = CreateTableCheckFun(mnesia:create_table(erltorrent_store_files, [{attributes, record_info(fields, erltorrent_store_files)}, OptDC])),
    ok = CreateTableCheckFun(mnesia:create_table(erltorrent_store_meta,  [{attributes, record_info(fields, erltorrent_store_meta)}, OptDC])),
    ok.


%% @doc
%% Wait for all tables become available.
%%
-spec wait_for_tables(number()) -> ok | term().
wait_for_tables(Timeout) ->
    application:stop(mnesia),
    ok = case mnesia:create_schema([node()]) of
        ok -> ok;
        {error, {_Node, {already_exists, _Node}}} -> ok
    end,
    application:start(mnesia),
    ok = create_tables([node()]),
    case mnesia:wait_for_tables(tables(), Timeout) of
        ok -> ok = schema_change(get_schema_version(), ?SCHEMA_VERSION);
        {error, Reason} -> {error, Reason}
    end.


%% @doc
%% Update schema if necessary.
%%
schema_change(Version, Version) ->
    ok;

schema_change(CurrentSchemaVersion, NewSchemaVersion) when CurrentSchemaVersion =/= NewSchemaVersion ->
    ok = do_schema_change(CurrentSchemaVersion, NewSchemaVersion),
    ok = update_schema_version(NewSchemaVersion),
    ok.

do_schema_change(_CurrentSchemaVersion, _NewSchemaVersion) ->
    ok.



%%%===================================================================
%%% Query functions
%%%===================================================================

%% @doc
%% Update schema version.
%%
update_schema_version(SchemaVersion) ->
    ok = mnesia:activity(transaction, fun() ->
        ok = mnesia:write(#erltorrent_store_meta{key = schema_version, value = SchemaVersion})
    end).


%% @doc
%% Get schema version.
%%
get_schema_version() ->
    mnesia:activity(transaction, fun() ->
        case mnesia:read({erltorrent_store_meta, schema_version}) of
            [#erltorrent_store_meta{value = SchemaVersion}] ->
                SchemaVersion;
            [] ->
                0
        end
    end).


