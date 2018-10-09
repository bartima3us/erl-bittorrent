start:
	rm -f log/*
	rm -f db/*
	rebar3 shell --config=test/sys.config --sname erltorrent

tests:
	rebar3 eunit