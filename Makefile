.PHONY: test helptags

test:
	nvim --headless --clean -l tests/run.lua

helptags:
	nvim --headless --clean -u NONE --cmd "set rtp+=." -c "helptags doc" -c "qa!"
