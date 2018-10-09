-record(erltorrent_store_file, {
    hash        :: binary(),
    file_name   :: term()
}).

-record(erltorrent_store_piece, {
    id                  :: tuple(),
    hash                :: binary(),
    piece_id            :: integer(),
    blocks              :: [integer()],
    status              :: downloading | completed,
    % @todo maybe don't need
    started_at          :: integer(), % When piece downloading started in milliseconds timestamp
    % @todo maybe don't need
    updated_at          :: integer()  % When last update took place in milliseconds timestamp
}).

-record(erltorrent_store_meta, {
    key     :: schema_version,
    value   :: integer()
}).