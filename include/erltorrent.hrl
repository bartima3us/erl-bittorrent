-type message_type() :: choke | unchoke | interested | not_interested | have | bitfield | request | piece | cancel.
-type payload()      :: binary().
-type piece_id_bin() :: binary().
-type piece_id_int() :: integer().
-type block_id_int() :: integer().
-type ip_port()      :: {inet:ip_address(), inet:port_number()}.

% @todo unhardcode because all piece can be smaller than this number
-define(DEFAULT_REQUEST_LENGTH, 16384).

-record(piece_data, {
    payload      :: payload(),      % @todo maybe don't need
    length       :: binary(),        % 4 bytes % @todo maybe don't need
    piece_index  :: piece_id_int(),
    block_offset :: binary()         % 4 bytes % @todo maybe don't need
}).

-record(bitfield_data, {
    parsed  :: [{piece_id_int(), boolean()}],
    payload :: payload(), % @todo maybe don't need
    length  :: binary()   % 4 bytes % @todo maybe don't need
}).

-record(piece, {
    piece_id                    :: piece_id_int(),
    piece_length                :: integer(),           % Full length of piece
    last_block_id               :: block_id_int(),      % If there are 10 blocks: last_block_id=9
    blocks                      :: [block_id_int()],    % Which blocks are left
    piece_hash                  :: binary(),            % Piece confirm hash from torrent file
    % @todo maybe don't need
    status = not_requested      :: requested | not_requested
}).