start:
	rm -f log/*
	rebar3 shell --config=test/sys

tests:
	rebar3 eunit