%%%-------------------------------------------------------------------
%%% @author sarunas
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 17. May 2016 23.55
%%%-------------------------------------------------------------------
-module(torrent).
-author("sarunas").

%% API
-export([run/0]).

%% erl -pa
%% c(torrent).
%% torrent:run();

%% list_to_integer("E", 16) bsl 4 bor list_to_integer("1",16)

%%-define(KAZKOKSFLAG, 1 bsl 4).

%% https://wiki.theory.org/index.php/BitTorrentSpecification
%% http://jonas.nitro.dk/bittorrent/bittorrent-rfc.html
%% http://www.bittorrent.org/beps/bep_0003.html

%% Architektūra:
%% Supervizorius paleidžia gen_fsm ir kitą supervizorių, prie kurio kabinsiu atskirus peero gen_fsm'us.

%% 109.77.13.83:64096
%% http://tracker.linkomanija.org:2710/fb34109c0d7c9583aa3e1069944de2ef/announce?info_hash=%85%bdW%1e%24V%e4%15!5%d2r%15%0a*4%fcbW%0a&peer_id=-DE13C0-qjul29Q3a4Nc&port=60080&uploaded=0&downloaded=0&left=2218991616&corrupt=0&key=3A34F2AD&event=started&numwant=20

%% bittorrent or http or ip.src == 78.61.170.219 or ip.dst == 78.61.170.219
%% (bittorrent or http) and ip.dst != 239.255.255.250
%% tcp.port eq 25

% https://github.com/richcarl/eunit/blob/master/examples/eunit_examples.erl

get_peers_ip(<<>>, Result) ->
  lists:reverse(Result);
get_peers_ip(PeersList, Result) ->
  <<Byte1:8, Byte2:8, Byte3:8, Byte4:8, Port:16, Rest/binary>> = PeersList,
  get_peers_ip(Rest, [{{Byte1,Byte2,Byte3,Byte4}, Port}|Result]).

run() ->
  File = "gen/torrents/[HorribleSubs] Osake wa Fuufu ni Natte Kara - 05 [720p].mkv.torrent",
  {ok, Bin} = file:read_file(File),
  {ok, {dict, MetaInfo}} = bencoding:decode(Bin),
  TrackerLink = binary_to_list(dict:fetch(<<"announce">>, MetaInfo)), %% Trackerio linkas
%%  PeerId = "-ER0000-" ++ random(6) ++ "-" ++ random(4) ++ "-",
  PeerId = "-ER0000-45AF6T-NM81-",
  {dict, Info} = dict:fetch(<<"info">>, MetaInfo),
  FileName = dict:fetch(<<"name">>, Info),
  Length = dict:fetch(<<"length">>, Info),
  Pieces = dict:fetch(<<"pieces">>, Info),
  Left = dict:fetch(<<"length">>, Info), % viso failo dydis (ex. 290006769)
  PieceLength = dict:fetch(<<"piece length">>, Info), % vieno gabalėlio dydis (ex. 524288)
  % gabalėlių kiekis = Left / PieceLength (ex. 553,144014359 = 290006769 / 524288)

  io:format("Length=~p~n~n", [Length]),
  io:format("Piece length=~p~n~n", [PieceLength]),
  io:format("Name=~p~n~n", [FileName]),
  io:format("Pieces bit size=~p~n~n", [bit_size(Pieces)]), % (ex. 88640)
  % gabalėlių kiekis = pieces_bit_size / 8 (paverčiam į baitus) / 20 (nes 20 bytes sha1 hash'ai)
  % (ex. 554 = 88640 / 8 / 20)

  % ex. Bitfield:
  % ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff
  % ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff
  % ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff
  % ff ff ff ff ff ff c0
  %
  % Yra 69 pilni (1111 1111) baitai ir pats paskutinis - c0 nepilnas (1100 0000)
  % 69 * 8 + 2 = 554 gabalėliai
  % Jei bitas - 0, reiškia peeras neturi šito gabalėlio; jei 1 - turi.
  %
  % Po bitfield eina have žinutės, kurios papildo Bitfieldą.
  % Padarius 2 handshake tam pačiam peer, kad ir 1 sekundės laikotarpiu,
  % neabejotinai gausi 2 skirtingus bitfield ir skirtingas have žinutes,
  % tačiau have žinutėms užpildžius bitfieldą, rezultatas bus toks pats.

  <<FirstHash:20/binary, _Rest/binary>> = Pieces,
  io:format("First piece hash=~p~n~n", [bin_to_hex:bin_to_hex(FirstHash)]),

  BencodedInfo = binary_to_list(bencoding:encode(dict:fetch(<<"info">>, MetaInfo))),
  HashBinString = sha1:binstring(BencodedInfo),
  Hash = helper:urlencode(HashBinString),

  {ok, {dict, Result}} = connect_to_tracker(TrackerLink, Hash, PeerId, Left),
  PeersIP = get_peers_ip(dict:fetch(<<"peers">>, Result), []),

  io:format("All peers~p~n", [PeersIP]),
  message:start(PeersIP, HashBinString, PeerId, FileName)
.

%% Example: "http://tracker.linkomanija.org:2710/fb34109c0d7c9583aa3e1069944de2ef/announce?info_hash=C-%7d%1a%0b%15%3f%3f%5c%e1%b4S%c3g%a5%b5%5d%f4S%e9&peer_id=-DE13C0-XLVT-DTrs9S-&port=61940&uploaded=0&downloaded=0&left=2075261731&corrupt=0&key=4ACCCA00&event=started&numwant=200&compact=1&no_peer_id=1&supportcrypto=1&redundant=0"
connect_to_tracker(TrackerLink, Hash, PeerId, Left) ->
  inets:start(),
  Separator = case string:str(TrackerLink, "?") of 0 -> "?"; _ -> "&" end,
  FullLink = TrackerLink ++ Separator ++ "info_hash=" ++ Hash ++ "&peer_id=" ++ PeerId ++ "&port=61940&uploaded=0&downloaded=0&left=" ++ convert_to_list(Left) ++ "&corrupt=0&key=4ACCCA00&event=started&numwant=200&compact=1&no_peer_id=1&supportcrypto=1&redundant=0",

  {ok, {{_Version, _Code, _ReasonPhrase}, _Headers, Body}} = httpc:request(get, {FullLink, []}, [], [{body_format, binary}]),
  bencoding:decode(Body)
.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%
%%
%%
convert_to_list(Var) when is_binary(Var) ->
  binary_to_list(Var);

convert_to_list(Var) when is_integer(Var) ->
  integer_to_list(Var);

convert_to_list(Var) ->
  Var.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% http://stackoverflow.com/questions/5879861/how-to-convert-torrent-info-hash-for-scrape-using-php
%% urlencode( pack('H*', '85BD571E2456E4152135D272150A2A34FC62570A') )
%% http://string-functions.com/hex-string.aspx

%% 85BD571E 2456E415 2135D272 150A2A34 FC62570A
%% %85%bdW%1e%24V%e4%15!5%d2r%15%0a*4%fcbW%0a

%% T = 16#85BD571E2456E4152135D272150A2A34FC62570A.
%% T2 = <<T:160>>
%% io:format("~s~n", [T2]).
%% os:cmd("php -r 'echo urlencode(pack(\"H*\", \"85BD571E2456E4152135D272150A2A34FC62570A\"));'").