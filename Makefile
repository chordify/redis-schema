all: test-stack test-cabal

.PHONY: toc test-stack test-cabal build-stack build-cabal

build-stack:
	stack build

test-stack: build-stack
	stack test

build-cabal:
	cabal build --enable-tests

test-cabal:
	cabal test

toc:
	bash mktoc.sh
