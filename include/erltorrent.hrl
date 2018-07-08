-type message_type() :: choke | unchoke | interested | uninterested | have | bitfield | request | piece | cancel.
-type payload()      :: binary().
-type piece_id_bin() :: binary().
-type piece_id_int() :: integer().

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