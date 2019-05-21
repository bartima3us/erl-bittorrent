-record(erltorrent_store_file, {
    hash        :: binary(),
    file_name   :: term()
}).

-record(erltorrent_store_piece, {
    id                  :: tuple(), % os:timestamp
    hash                :: binary(),
    piece_id            :: integer(),
    blocks              :: [integer()],
    status              :: downloading | completed,
    % @todo maybe don't need
    started_at          :: integer(), % When piece downloading started in milliseconds timestamp
    % @todo maybe don't need
    updated_at          :: integer()  % When last update took place in milliseconds timestamp
}).

-record(erltorrent_store_block_time, {
    id              :: {piece_id_int(), block_id_int()},
    piece_id        :: piece_id_int(),
    requested_at    :: integer(),
    received_at     :: integer()
}).

-record(erltorrent_store_peer, {
    id              :: tuple(), % os:timestamp
    hash            :: binary(),
    ip_port         :: {tuple(), integer()},
    blocks_time     :: [#erltorrent_store_block_time{}]
}).

-record(erltorrent_store_meta, {
    key     :: schema_version,
    value   :: integer()
}).