%%%-------------------------------------------------------------------
%%% @author bartimaeus
%%% @copyright (C) 2019, sarunas.bartusevicius@gmail.com
%%% @doc
%%%
%%% @end
%%% Created : 06. May 2019 19.33
%%%-------------------------------------------------------------------
-module(erltorrent).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

%% API
-export([download/1]).

%% @doc
%% Start download
%%
download(TorrentName) when is_binary(TorrentName) ->
    download(binary_to_list(TorrentName));

download(TorrentName) when is_list(TorrentName) ->
    erltorrent_sup:start_child(TorrentName).