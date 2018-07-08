Erlang BitTorrent client
============

![https://image.ibb.co/cKFVcT/erltorrent_small.png](https://image.ibb.co/cKFVcT/erltorrent_small.png)

Only downloading at the moment. There is no any possibility to share downloaded file (real pirate's client). There is no possibility to download multiple files torrent at the moment.

Tested only on Lithuanian tracker 'Linkomanija'.

Tested on Erlang/OTP 18, Erlang/OTP 19, Erlang/OTP 20.

## Compile and start
```
$ make start
```

## EUnit tests
```
$ make tests
```

## Examples

Put .torrent file into 'torrents' directory. Then:

```
$ make start
erltorrent_server:download("TorrentName.torrent").
```