-type message_type() :: choke | unchoke | interested | not_interested | have | bitfield | request | piece | cancel.
-type ip_port()      :: {inet:ip_address(), inet:port_number()}.

% Smallest transmission unit in the bittorent protocol
% http://torrentinvites.org/f29/piece-size-guide-167985/
-define(REQUEST_LENGTH, 16384).

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