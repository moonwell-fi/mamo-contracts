test:
	forge test --fork-url base --ffi -vvv

coverage:
	forge coverage --fork-url base --ffi --report lcov --skip s.sol --no-match-coverage t.sol --ir-minimum -vvv && genhtml lcov.info --branch-coverage --output-dir coverage

deploy-broadcast:
	export DEPLOY_ENV="8453_PROD" && forge script script/DeploySystem.s.sol:DeploySystem --fork-url base --account mamo-test --verify --slow -vvvvv --broadcast --sender   0xDca82E03057329f53Ed4173429D46B0511E46Fb8             


usdc-strategy:
	export ASSET_CONFIG_PATH="config/strategies/USDCStrategyConfig.json" && forge test --fork-url base --ffi -vvv --mc MoonwellMorphoStrategy --mt testSlippageAffectsPriceCheck

cbbtc-strategy:
	export ASSET_CONFIG_PATH="config/strategies/cbBTCStrategyConfig.json" && forge test --fork-url base --ffi -vvvvv --mc MoonwellMorphoStrategy  --mt testSlippageAffectsPriceCheck


.PHONY: test coverage deploy-broadcast usdc-strategy cbbtc-strategy 