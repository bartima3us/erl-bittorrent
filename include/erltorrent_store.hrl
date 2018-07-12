-record(erltorrent_store_file, {
    hash        :: binary(),
    file_name   :: term()
}).

-record(erltorrent_store_piece, {
    id          :: tuple(),
    hash        :: binary(),
    piece_id    :: integer(),
    count       :: integer(),
    status      :: downloading | completed,
    started     :: integer(), % When piece downloading started in Gregorian seconds
    updated_at  :: integer()  % When last update took place in Gregorian seconds
}).

-record(erltorrent_store_meta, {
    key     :: schema_version,
    value   :: integer()
}).