start:
	rm -f log/*
	rm -f db/*
	rm -rf downloads/*
	rebar3 shell --config=test/sys.config --sname erltorrent

tests:
	rebar3 eunit