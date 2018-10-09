start:
	rm -f log/*
	rm -rf temp/*
	rm -f db/*
	rm -f downloads/*
	rebar3 shell --config=test/sys.config --sname erltorrent

tests:
	rebar3 eunit