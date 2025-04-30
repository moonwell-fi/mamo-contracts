test:
	forge test --fork-url base --ffi -vvv

coverage:
	forge coverage --fork-url base --ffi --report lcov --skip s.sol --ir-minimum -vvv && genhtml lcov.info --branch-coverage --output-dir coverage

.PHONY: test coverage
