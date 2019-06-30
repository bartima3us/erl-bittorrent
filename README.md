Erlang BitTorrent client
============

![https://image.ibb.co/cKFVcT/erltorrent_small.png](https://image.ibb.co/cKFVcT/erltorrent_small.png)

Currently only for downloading. There is no any possibility to share downloaded file (real pirate's client).

Tested on Lithuanian trackers "Linkomanija.net", "Torrent.lt" and Russian tracker "RuTracker.net".

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