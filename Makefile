test:
	forge test --fork-url base --ffi -vvv

coverage:
	forge coverage --fork-url base --ffi --report lcov --skip s.sol --no-match-coverage t.sol --ir-minimum -vvv && genhtml lcov.info --branch-coverage --output-dir coverage

deploy-broadcast:
	forge script script/VersionedDeploySystem.s.sol:VersionedDeploySystem --fork-url base --account mamo-test --verify --slow -vv --broadcast                

.PHONY: test coverage deploy-broadcast
