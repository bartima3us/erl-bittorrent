start:
	rm -f log/*
	rebar3 shell --config=test/sys.config --sname erltorrent

tests:
	rebar3 eunit