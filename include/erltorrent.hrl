-type message_type() :: choke | unchoke | interested | not_interested | have | bitfield | request | piece | cancel.
-type payload()      :: binary().
-type piece_id_bin() :: binary().
-type piece_id_int() :: integer().
-type block_id_int() :: integer().
-type ip_port()      :: {inet:ip_address(), inet:port_number()}.

% Smallest transmission unit in the bittorent protocol
% http://torrentinvites.org/f29/piece-size-guide-167985/
% @todo unhardcode for gen_bittorrent use for other than torrent downloading purposes.
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
    piece_size                  :: integer(),           % Full length of this piece
    last_block_id               :: block_id_int(),      % If there are 10 blocks: last_block_id=9
    blocks                      :: [block_id_int()],    % Which blocks are left
    piece_hash                  :: binary(),            % Piece confirm hash from torrent file
    std_piece_size              :: integer(),           % Standard piece size from torrent file (differs from last piece size)
    % @todo maybe don't need
    status = not_requested      :: requested | not_requested
}).