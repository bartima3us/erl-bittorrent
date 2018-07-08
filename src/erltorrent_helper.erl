%%%-------------------------------------------------------------------
%%% @author bartimaeus
%%% @copyright (C) 2017, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 01. Jun 2017 15.59
%%%-------------------------------------------------------------------
-module(erltorrent_helper).
-author("bartimaeus").

%% API
-export([
    urlencode/1,
    random/1,
    convert_to_list/1,
    concat_file/1,
    get_packet/1,
    bin_piece_id_to_int/1,
    int_piece_id_to_bin/1,
    confirm_hash/1,
    get_little_piece/2,
    compare_little_piece/2,
    get_meta_data/0,
    compare_last_piece/0,
    compare_files/2
]).



%%%===================================================================
%%% API
%%%===================================================================

%% @doc
%% PHP urlencode style function
%%
%% 432D7D1A 0B153F3F 5CE1B453 C367A5B5 5DF453E9
%% C-%7D%1A%0B%15%3F%3F%5C%E1%B4S%C3g%A5%B5%5D%F4S%E9
%% C - %7D %1A %0B %15 %3F %3F %5C %E1 %B4 S %C3 g %A5 %B5 %5D %F4 S %E9
%% C   - 67     C
%% -   - 45     -
%% }   - 125    %
%% SUB - 26     %
%% VT  - 11     %
%% NAK - 21     %
%% ?   - 63     %
%% ?   - 63     %
%% \   - 92     %
%% ß   - 225    %
%% ┤   - 180    %
%% S   - 83     S
%% ├   - 195    %
%% g   - 103    g
%% Ñ   - 165    %
%% Á   - 181    %
%% ]   - 93     %
%% ¶   - 244    %
%% S   - 83     S
%% Ú   - 233    %
%%
urlencode(String) ->
    Value = case is_binary(String) of
    true -> binary_to_list(String);
        _ -> String
    end,
    %% Integers, uppercase chars, lowercase chars, - _
    AllowedSymbols = lists:seq(48, 57) ++ lists:seq(65, 90) ++ lists:seq(97, 122) ++ [45, 95],
    Parse = fun (Symbol) ->
        case lists:member(Symbol, AllowedSymbols) of
            true ->
                Symbol;
            _ ->
                HexList = httpd_util:integer_to_hexlist(Symbol),
                case string:len(HexList) of
                    1 -> "%0" ++ string:to_lower(HexList);
                    _ -> "%" ++ string:to_lower(HexList)
                end
        end
    end,
    lists:map(Parse, Value).


%% @doc
%% Convert piece ID from binary to integer
%% @todo make function generic
bin_piece_id_to_int(PieceId) when is_binary(PieceId) ->
    <<Id:32>> = PieceId,
    Id.

%% @doc
%% Convert piece ID from integer to binary
%% @todo make function generic
int_piece_id_to_bin(PieceId) when is_integer(PieceId) ->
    <<PieceId:32>>.


%% @doc
%% Generate random string
%%
random(Length) ->
    L = [0,1,2,3,4,5,6,7,8,9,"Q","W","E","R","T","Y","U","I","O","P","A","S","D","F","G","H","J","K","L","Z","X","C","V","B","N","M"],
    RandomList = [X||{_,X} <- lists:sort([ {random:uniform(), N} || N <- L])],
    lists:sublist(RandomList, Length).


%% @doc
%% Convert binary or integer to list
%%
convert_to_list(Var) when is_binary(Var) ->
    binary_to_list(Var);

convert_to_list(Var) when is_integer(Var) ->
    integer_to_list(Var);

convert_to_list(Var) when is_list(Var) ->
    Var.


%% @doc
%% Make socket active once
%%
get_packet(Socket) ->
    inet:setopts(Socket, [{active, once}]).


%% @doc
%% Concat all parts and pieces into file
%% @todo need to make smarter algorithm without doubling a file
concat_file(TorrentName) ->
    {ok, Pieces} = file:list_dir(filename:join(["temp", TorrentName])),
    WritePieceFun = fun(Piece) ->
        write_piece(TorrentName, Piece)
    end,
    lists:map(WritePieceFun, sort(Pieces)),
    ok.


%% @doc
%% Concat pieces
%%
write_piece(TorrentName, Piece) ->
    {ok, LittlePieces} = file:list_dir(filename:join(["temp", TorrentName, Piece])),
    WriteLittlePieceFun = fun(LittlePiece) ->
        write_little_piece(TorrentName, Piece, LittlePiece)
    end,
    lists:map(WriteLittlePieceFun, sort_with_split(LittlePieces)),
    ok.


%% @doc
%% Concat parts
%% @todo rename little piece and part to block
write_little_piece(TorrentName, Piece, LittlePiece) ->
    {ok, Content} = file:read_file(filename:join(["temp", TorrentName, Piece, LittlePiece])),
    file:write_file(filename:join(["downloads", TorrentName]), Content, [append]),
    ok.


%% @doc
%% Sort directories by name
%%
sort(Files) ->
    List2 = lists:map(fun (File) -> list_to_integer(File) end, Files),
    List3 = lists:sort(List2),
    lists:map(fun (File) -> integer_to_list(File) end, List3).


%% @doc
%% Sort files in directory by name
%%
sort_with_split(Files) ->
    List2 = lists:map(
        fun (File) ->
            [Name, _Extension] = string:tokens(File, "."),
            list_to_integer(Name)
        end,
        Files
    ),
    List3 = lists:sort(List2),
    lists:map(fun (File) -> integer_to_list(File) ++ ".part" end, List3).



%%%===================================================================
%%% Temporary debug functions
%%%===================================================================

%%
%%
%%
confirm_hash(Piece) ->
    File = filename:join(["torrents", "[Commie] Banana Fish - 01 [3600C7D5].mkv.torrent"]),
    {ok, Bin} = file:read_file(File),
    {ok, {dict, MetaInfo}} = erltorrent_bencoding:decode(Bin),
    {dict, Info} = dict:fetch(<<"info">>, MetaInfo),
    Pieces = dict:fetch(<<"pieces">>, Info),
    Exclude = list_to_integer(Piece) * 20,
    <<_Off:Exclude/binary, FirstHash:20/binary, _Rest/binary>> = Pieces,
    io:format("First piece hash=~p~n", [erltorrent_bin_to_hex:bin_to_hex(FirstHash)]),

    TorrentName = "[Commie] Banana Fish - 01 [3600C7D5].mkv",
    write_piece(TorrentName, Piece),
    {ok, DownloadedPiece} = file:read_file(filename:join(["downloads", TorrentName])),
    DownloadedHash = crypto:hash(sha, DownloadedPiece),
    io:format("Downloaded hash=~p~n", [erltorrent_bin_to_hex:bin_to_hex(DownloadedHash)]),
    ok.


%%
%%
%%
get_little_piece(Piece, Offset) ->
    File = filename:join(["temp", "[Commie] Banana Fish - 01 [3600C7D5].mkv", Piece, Offset ++ ".part"]),
    {ok, Bin} = file:read_file(File),
    file:write_file("test.txt", erltorrent_bin_to_hex:bin_to_hex(Bin)),
    ok.


%%
%%
%%
compare_little_piece(Piece, Offset) ->
    Exclude = trunc(list_to_integer(Piece) * 16384 * 64 + (list_to_integer(Offset) / 16384) * 16384),
    {ok, OriginalFileBin} = file:read_file("[Commie] Banana Fish - 01 [3600C7D5].mkv"),
    <<_:Exclude/binary, CuttedOriginal:16384/binary, Rest/binary>> = OriginalFileBin,
    File = filename:join(["temp", "[Commie] Banana Fish - 01 [3600C7D5].mkv", Piece, Offset ++ ".part"]),
    {ok, Bin} = file:read_file(File),
    io:format("Rest byte size=~p", [byte_size(Rest)]),
    file:write_file("test_mano.txt", erltorrent_bin_to_hex:bin_to_hex(Bin)),
    file:write_file("test_original.txt", erltorrent_bin_to_hex:bin_to_hex(CuttedOriginal)),
    ok.


%%
%%
%%
compare_files(Piece, Offset) ->
    Exclude = trunc(list_to_integer(Piece) * 16384 * 64 + (list_to_integer(Offset) / 16384) * 16384),
    {ok, OriginalFileBin} = file:read_file("[Commie] Banana Fish - 01 [3600C7D5].mkv"),
    {ok, MyFileBin} = file:read_file("downloads/[Commie] Banana Fish - 01 [3600C7D5].mkv"),
    <<_:Exclude/binary, CuttedOriginal:16384/binary, _RestOriginal/binary>> = OriginalFileBin,
    <<_:Exclude/binary, CuttedMy:16384/binary, _RestMy/binary>> = MyFileBin,
    file:write_file("test_original.txt", erltorrent_bin_to_hex:bin_to_hex(CuttedOriginal)),
    file:write_file("test_mano.txt", erltorrent_bin_to_hex:bin_to_hex(CuttedMy)),
    ok.

%%
%%
%%
compare_last_piece() ->
    Exclude = trunc(203 * 16384 * 64 + (573440 / 16384) * 16384),
    {ok, OriginalFileBin} = file:read_file("[Commie] Banana Fish - 01 [3600C7D5].mkv"),
    <<_:Exclude/binary, _CuttedOriginal:16384/binary, Rest/binary>> = OriginalFileBin,
    File = filename:join(["temp", "[Commie] Banana Fish - 01 [3600C7D5].mkv", "203", "589824" ++ ".part"]),
    {ok, Bin} = file:read_file(File),
    io:format("Rest byte size=~p", [byte_size(Rest)]),
    file:write_file("test_mano.txt", erltorrent_bin_to_hex:bin_to_hex(Bin)),
    file:write_file("test_original.txt", erltorrent_bin_to_hex:bin_to_hex(Rest)),
    ok.


%%
%%
%%
get_meta_data() ->
    File = filename:join(["torrents", "[Commie] Banana Fish - 01 [3600C7D5].mkv.torrent"]),
    {ok, Bin} = file:read_file(File),
    {ok, {dict, MetaInfo}} = erltorrent_bencoding:decode(Bin),
    {dict, Info} = dict:fetch(<<"info">>, MetaInfo),
    FileName = dict:fetch(<<"name">>, Info),
    Pieces = dict:fetch(<<"pieces">>, Info),
    FullSize = dict:fetch(<<"length">>, Info),
    PieceSize = dict:fetch(<<"piece length">>, Info),
    TrackerLink = binary_to_list(dict:fetch(<<"announce">>, MetaInfo)),
    PiecesAmount = list_to_integer(float_to_list(math:ceil(FullSize / PieceSize), [{decimals, 0}])),
    LastPieceLength = FullSize - (PiecesAmount - 1) * PieceSize,
    io:format("File name = ~p~n", [FileName]),
    io:format("Piece size = ~p bytes~n", [PieceSize]),
    io:format("Full file size = ~p~n", [FullSize]),
    io:format("Pieces amount = ~p~n", [PiecesAmount]),
    io:format("LastPieceLength = ~p~n", [LastPieceLength]),
    ok.


