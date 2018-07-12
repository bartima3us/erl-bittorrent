-record(erltorrent_store_files, {
    file   :: term(),
    length :: integer()
}).

-record(erltorrent_store_meta, {
    key     :: schema_version | term(),
    value   :: term()
}).