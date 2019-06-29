%%%-------------------------------------------------------------------
%%% @author bartimaeus
%%% @copyright (C) 2017, sarunas.bartusevicius@gmail.com
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
    get_packet/1,
    bin_piece_id_to_int/1,
    int_piece_id_to_bin/1,
    do_exit/2,
    do_exit/1,
    do_monitor/2,
    get_milliseconds_timestamp/0,
    shuffle_list/1
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
%% Exit process fun. Need because of mock purposes for tests.
%%
do_exit(Pid, Reason) ->
    exit(Pid, Reason).


%% @doc
%% Exit process fun. Need because of mock purposes for tests.
%%
do_exit(Reason) ->
    exit(Reason).


%% @doc
%% Monitor fun. Need because of mock purposes for tests.
%%
do_monitor(Type, Pid) ->
    erlang:monitor(Type, Pid).


%% @doc
%% Get current timestamp in milliseconds
%%
get_milliseconds_timestamp() ->
    {Mega, Sec, Micro} = os:timestamp(),
    (Mega * 1000000 + Sec) * 1000 + round(Micro / 1000).


%% @doc
%% Shuffle list elements in random order
%%
shuffle_list(List) ->
    [ X || {_, X} <- lists:sort([{random:uniform(), N} || N <- List]) ].


