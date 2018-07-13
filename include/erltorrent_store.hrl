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
    started     :: integer(), % When piece downloading started in milliseconds timestamp
    updated_at  :: integer()  % When last update took place in milliseconds timestamp
}).

-record(erltorrent_store_meta, {
    key     :: schema_version,
    value   :: integer()
}).