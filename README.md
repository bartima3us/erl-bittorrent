Erlang BitTorrent client
============

![https://image.ibb.co/cKFVcT/erltorrent_small.png](https://image.ibb.co/cKFVcT/erltorrent_small.png)

Currently only for downloading. There is no any possibility to share downloaded file (real pirate's client). There is no possibility to download multiple files torrent at the moment.

Tested on Russian tracker "RuTracker.net" and Lithuanian trackers "Linkomanija.net" and "Torrent.lt".

Works only on Erlang/OTP 20 or newer.

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
erltorrent:download("TorrentName.torrent").
```