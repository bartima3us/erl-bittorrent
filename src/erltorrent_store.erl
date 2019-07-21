%%%-------------------------------------------------------------------
%%% @author bartimaeus
%%% @copyright (C) 2018, sarunas.bartusevicius@gmail.com
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
-define(TABLE_SET(N, O), mnesia:create_table(N, [{attributes, record_info(fields, N)}, O])).
-define(TABLE_BAG(N, O), mnesia:create_table(N, [{type, bag}, {attributes, record_info(fields, N)}, O])).

-export([
    insert_file/2,
    read_file/1,
    read_piece/4,
    update_piece/5,
    read_pieces/1,
    mark_piece_completed/2,
    mark_piece_new/3,
    update_blocks_time/6,
    read_blocks_time/1,
    read_blocks_time/2,
    read_blocks_time/3,
    read_completed_pieces_time/1,
    read_peer_pieces_time/2
]).

-export([
    wait_for_tables/1
]).



%%%===================================================================
%%% API
%%%===================================================================

%% @doc
%% Get file by hash
%%
read_file(Hash) ->
    Fun = fun() ->
        case mnesia:read(erltorrent_store_file, Hash) of
            [Fetched = #erltorrent_store_file{}] -> Fetched;
            [] -> false
        end
    end,
    {atomic, Result} = mnesia:transaction(Fun),
    Result.


%% @doc
%% Insert new file
%%
insert_file(Hash, FileName) ->
    Fun = fun() ->
        File = #erltorrent_store_file{
            hash      = Hash,
            file_name = FileName
        },
        mnesia:write(File)
    end,
    {atomic, ok} = mnesia:transaction(Fun).


%% @doc
%% Get all pieces state by hash.
%%
read_pieces(Hash) ->
    Fun = fun() ->
        MatchHead = #erltorrent_store_piece{
            hash     = Hash,
            _        = '_'
        },
        mnesia:match_object(MatchHead)
    end,
    {atomic, Result} = mnesia:transaction(Fun),
    Result.


%% @doc
%% Get current piece state. Update it if needed.
%%
read_piece(Hash, IpPort, PieceId, LastBlockId) ->
    Fun = fun() ->
        MatchHead = #erltorrent_store_piece{
            hash     = Hash,
            piece_id = PieceId,
            _        = '_'
        },
        case mnesia:match_object(MatchHead) of
            [Result = #erltorrent_store_piece{}] ->
                Result;
            []       ->
                Piece = #erltorrent_store_piece{
                    id          = os:timestamp(),
                    hash        = Hash,
                    ip_port     = IpPort,
                    piece_id    = PieceId,
                    blocks      = lists:seq(0, LastBlockId - 1),
                    status      = downloading,
                    started_at  = erltorrent_helper:get_milliseconds_timestamp()
                },
                mnesia:write(Piece),
                Piece
        end
    end,
    {atomic, Result} = mnesia:transaction(Fun),
    Result.


%%
%%
%%
update_piece(Hash, IpPort, PieceId, LastBlockId, DownloadedBlockId) ->
    Piece = read_piece(Hash, IpPort, PieceId, LastBlockId),
    #erltorrent_store_piece{blocks = Blocks} = Piece,
    Fun = fun () ->
        NewBlocks = Blocks -- [DownloadedBlockId],
        UpdatedPiece = Piece#erltorrent_store_piece{
            blocks      = NewBlocks,
            updated_at  = erltorrent_helper:get_milliseconds_timestamp()
        },
        % @todo solve error after download restarting
        mnesia:write(erltorrent_store_piece, UpdatedPiece, write)
    end,
    {atomic, _} = mnesia:transaction(Fun),
    ok.


%%
%%
%%
update_blocks_time(Hash, IpPort, PieceId, BlockId, Time, Field) ->
    Id = {PieceId, BlockId},
    Fun = fun() ->
        MatchHead = #erltorrent_store_peer{
            hash     = Hash,
            ip_port  = IpPort,
            _        = '_'
        },
        case mnesia:match_object(MatchHead) of
            [Result = #erltorrent_store_peer{blocks_time = BlocksTime}] ->
                NewBlocksTime = case lists:keysearch(Id, #erltorrent_store_block_time.id, BlocksTime) of
                    false ->
                        BlockTime = #erltorrent_store_block_time{
                            id       = Id,
                            piece_id = PieceId
                        },
                        NewBlockTime = case Field of
                            requested_at -> BlockTime#erltorrent_store_block_time{requested_at = Time};
                            received_at  -> BlockTime#erltorrent_store_block_time{received_at = Time}
                        end,
                        [NewBlockTime | BlocksTime];
                    {value, BlockTime} ->
                        NewBlockTime = case Field of
                            requested_at -> BlockTime#erltorrent_store_block_time{requested_at = Time};
                            received_at  -> BlockTime#erltorrent_store_block_time{received_at = Time}
                        end,
                        lists:keyreplace(Id, #erltorrent_store_block_time.id, BlocksTime, NewBlockTime)
                end,
                UpdatedPeer = Result#erltorrent_store_peer{
                    blocks_time = NewBlocksTime
                },
                mnesia:write(erltorrent_store_peer, UpdatedPeer, write),
                UpdatedPeer;
            []       ->
                BlockTime = #erltorrent_store_block_time{
                    id       = Id,
                    piece_id = PieceId
                },
                Peer = #erltorrent_store_peer{
                    id          = os:timestamp(),
                    hash        = Hash,
                    ip_port     = IpPort,
                    blocks_time = [
                        case Field of
                            requested_at -> BlockTime#erltorrent_store_block_time{requested_at = Time};
                            received_at  -> BlockTime#erltorrent_store_block_time{received_at = Time}
                        end
                    ]
                },
                mnesia:write(Peer),
                Peer
        end
    end,
    mnesia:ets(Fun),
    ok.


%%  @doc
%%  Read all blocks time
%%
read_blocks_time(Hash) ->
    MatchHead = #erltorrent_store_peer{
        hash        = Hash,
        blocks_time = '$1',
        _           = '_'
    },
    Fun = fun() ->
        mnesia:select(erltorrent_store_peer, [{MatchHead, [], ['$1']}])
    end,
    lists:flatten(mnesia:ets(Fun)).


%%  @doc
%%  Read all completed pieces downloading time.
%%
read_completed_pieces_time(Hash) ->
    MatchHead = #erltorrent_store_piece{
        hash        = Hash,
        started_at  = '$1',
        updated_at  = '$2',
        status      = completed,
        _           = '_'
    },
    Fun = fun() ->
        mnesia:select(erltorrent_store_piece, [{MatchHead, [], [['$1', '$2']]}])
    end,
    {atomic, Result} = mnesia:transaction(Fun),
    Result.


%%  @doc
%%  Read peer pieces downloading time of peer.
%%
read_peer_pieces_time(Hash, IpPort) ->
    MatchHead = #erltorrent_store_piece{
        hash        = Hash,
        ip_port     = IpPort,
        started_at  = '$1',
        updated_at  = '$2',
        _           = '_'
    },
    Fun = fun() ->
        mnesia:select(erltorrent_store_piece, [{MatchHead, [], [['$1', '$2']]}])
    end,
    {atomic, Result} = mnesia:transaction(Fun),
    Result.


%%  @doc
%%  Read peer blocks time
%%
read_blocks_time(Hash, IpPort) ->
    MatchHead = #erltorrent_store_peer{
        hash        = Hash,
        ip_port     = IpPort,
        blocks_time = '$1',
        _           = '_'
    },
    Fun = fun() ->
        mnesia:select(erltorrent_store_peer, [{MatchHead, [], ['$1']}])
    end,
    case mnesia:ets(Fun) of
        [Result] -> Result;
        []       -> []
    end.


%%  @doc
%%  Read peer blocks time
%%
read_blocks_time(Hash, IpPort, PieceId) ->
    lists:filter(
        fun (#erltorrent_store_block_time{piece_id = PI})  ->
            PI == PieceId
        end,
        read_blocks_time(Hash, IpPort)
    ).


%% @doc
%% Change piece status to completed.
%%
mark_piece_completed(Hash, PieceId) ->
    Fun = fun() ->
        MatchHead = #erltorrent_store_piece{
            hash     = Hash,
            piece_id = PieceId,
            _        = '_'
        },
        [Result = #erltorrent_store_piece{}] = mnesia:match_object(MatchHead),
        UpdatedPiece = Result#erltorrent_store_piece{
            status  = completed
        },
        mnesia:write(erltorrent_store_piece, UpdatedPiece, write)
    end,
    {atomic, Result} = mnesia:transaction(Fun),
    Result.


%% @doc
%% Change piece blocks to initial
%%
mark_piece_new(Hash, PieceId, LastBlockId) ->
    Fun = fun() ->
        MatchHead = #erltorrent_store_piece{
            hash     = Hash,
            piece_id = PieceId,
            _        = '_'
        },
        [Result = #erltorrent_store_piece{}] = mnesia:match_object(MatchHead),
        UpdatedPiece = Result#erltorrent_store_piece{
            blocks      = lists:seq(0, LastBlockId),
            started_at  = erltorrent_helper:get_milliseconds_timestamp(),
            updated_at  = undefined
        },
        mnesia:write(erltorrent_store_piece, UpdatedPiece, write)
    end,
    {atomic, Result} = mnesia:transaction(Fun),
    Result.



%%%===================================================================
%%% Startup functions
%%%===================================================================

%% @doc
%% Tables list
%%
tables() -> [
    erltorrent_store_file,
    erltorrent_store_meta,
    erltorrent_store_piece,
    erltorrent_store_peer
].


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
%%  Creates mnesia tables.
%%
create_tables(Nodes) ->
    OptDC = {disc_copies, Nodes},
    OptRC = {ram_copies, Nodes},
    CreateTableCheckFun = fun
        ({atomic, ok}) -> ok;
        ({aborted, {already_exists, _Table}}) -> ok
    end,
    ok = CreateTableCheckFun(?TABLE_SET(erltorrent_store_file, OptDC)),
    ok = CreateTableCheckFun(?TABLE_SET(erltorrent_store_piece, OptDC)),
    ok = CreateTableCheckFun(?TABLE_SET(erltorrent_store_meta, OptDC)),
    ok = CreateTableCheckFun(?TABLE_SET(erltorrent_store_peer, OptRC)),
    ok.


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


