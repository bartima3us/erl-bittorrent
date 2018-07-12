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

tables() -> [
    erltorrent_store_files,
    erltorrent_store_meta
].

schema_version() ->
    mnesia:activity(transaction, fun() ->
        case mnesia:read({erltorrent_store_meta, schema_version}) of
            [#erltorrent_store_meta{value = SchemaVersion}] ->
                SchemaVersion;
            [] ->
                0
        end
    end).

%%
%%  Creates mnesia tables.
%%
create_tables(Nodes) ->
    DefOptDC = {disc_copies, Nodes},
    OK = {atomic, ok},
    OK = mnesia:create_table(erltorrent_store_files, [{attributes, record_info(fields, erltorrent_store_files)}, DefOptDC]),
    OK = mnesia:create_table(erltorrent_store_meta,  [{attributes, record_info(fields, erltorrent_store_meta)}, DefOptDC]),
    ok.

%% @doc
%% Wait for all tables become available.
%%
-spec wait_for_tables(number()) -> ok | term().
wait_for_tables(Timeout) ->

    application:stop(mnesia),
    ok = mnesia:create_schema([node()]),
    application:start(mnesia),
    ok = create_tables([node()]),

    case mnesia:wait_for_tables(tables(), Timeout) of
        ok ->
            ok = schema_change(schema_version(), ?SCHEMA_VERSION);
        {timeout, MissingTables} ->
            case lists:sort(MissingTables) =:= lists:sort([erltorrent_store_meta]) of
                true  -> ok = schema_change(0, ?SCHEMA_VERSION);
                false -> {timeout, MissingTables}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

schema_change(Version, Version) ->
    ok;

schema_change(CurrentSchemaVersion, NewSchemaVersion) when CurrentSchemaVersion =/= NewSchemaVersion ->
    ok = do_schema_change(CurrentSchemaVersion, NewSchemaVersion),
    ok = update_schema_version(NewSchemaVersion),
    ok.

do_schema_change(0, 1) ->
    Nodes = mnesia:system_info(db_nodes) ++ mnesia:system_info(extra_db_nodes),
    DefOptDC = {disc_copies, Nodes},
    mnesia:create_table(epss_store_meta, [{attributes, record_info(fields, erltorrent_store_meta)}, DefOptDC]),
    ok.

%% @doc
%% Update schema version.
%%
update_schema_version(SchemaVersion) ->
    ok = mnesia:activity(transaction, fun() ->
        ok = mnesia:write(#erltorrent_store_meta{key = schema_version, value = SchemaVersion})
    end).