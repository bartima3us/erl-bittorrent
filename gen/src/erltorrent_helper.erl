%%%-------------------------------------------------------------------
%%% @author sarunas
%%% @copyright (C) 2017, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 01. Jun 2017 15.59
%%%-------------------------------------------------------------------
-module(erltorrent_helper).
-author("sarunas").

%% API
-export([
    urlencode/1,
    random/1,
    convert_to_list/1,
    concat_file/1
]).

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

%% httpd_util:integer_to_hexlist(125) - 7D

%%
%%
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


%%
%%
%%
random(Length) ->
    L = [0,1,2,3,4,5,6,7,8,9,"Q","W","E","R","T","Y","U","I","O","P","A","S","D","F","G","H","J","K","L","Z","X","C","V","B","N","M"],
    RandomList = [X||{_,X} <- lists:sort([ {random:uniform(), N} || N <- L])],
    lists:sublist(RandomList, Length).


%%
%%
%%
convert_to_list(Var) when is_binary(Var) ->
    binary_to_list(Var);

convert_to_list(Var) when is_integer(Var) ->
    integer_to_list(Var);

convert_to_list(Var) when is_list(Var) ->
    Var.


%%
%%
%%
concat_file(TorrentName) ->
    {ok, Chunks} = file:list_dir(filename:join(["temp", TorrentName])),
    WriteChunkFun = fun(Chunk) ->
        write_chunk(TorrentName, Chunk)
    end,
    lists:map(WriteChunkFun, Chunks),
    ok.


%%
%%
%%
write_chunk(TorrentName, Chunk) ->
    {ok, Pieces} = file:list_dir(filename:join(["temp", TorrentName, Chunk])),
    WritePieceFun = fun(Piece) ->
        write_piece(TorrentName, Chunk, Piece)
    end,
    lists:map(WritePieceFun, Pieces),
    ok.


%%
%%
%%
write_piece(TorrentName, Chunk, Piece) ->
    {ok, Content} = file:read_file(filename:join(["temp", TorrentName, Chunk, Piece])),
    file:write_file(filename:join(["downloads", TorrentName]), Content, [append]),
    ok.