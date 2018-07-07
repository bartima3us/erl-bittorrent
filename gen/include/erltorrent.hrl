-type message_type() :: choke | unchoke | interested | uninterested | have | bitfield | request | piece | cancel.
-type payload()      :: binary().
-type piece_id_bin() :: binary().
-type piece_id_int() :: integer().

-record(piece_data, {
    payload      :: payload(),
    length       :: binary(),        % 4 bytes
    piece_index  :: piece_id_bin(),  % 4 bytes
    block_offset :: binary()         % 4 bytes
}).

-record(bitfield_data, {
    parsed  :: [{piece_id_int(), boolean()}],
    payload :: payload(),
    length  :: binary()   % 4 bytes % @todo neaišku, ar reikia
}).