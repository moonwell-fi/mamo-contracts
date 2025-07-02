test:
	forge test --fork-url base --ffi -vvv --no-match-contract "MoonwellMorphoStrategy|StrategyFactoryIntegrationTest|MulticallIntegrationTest|SlippagePriceCheckerTest|MamoStrategyRegistryIntegrationTest|FeeSplitterIntegrationTest|VirtualsFeeSplitterIntegrationTest"

coverage:
	forge coverage --fork-url base --ffi --report lcov --skip s.sol --no-match-coverage t.sol --ir-minimum -vvv && genhtml lcov.info --branch-coverage --output-dir coverage

deploy-broadcast:
	export DEPLOY_ENV="8453_PROD" && forge script script/DeploySystem.s.sol:DeploySystem --fork-url base --account mamo-test --verify --slow -vvvvv --broadcast --sender   0xDca82E03057329f53Ed4173429D46B0511E46Fb8             

usdc-strategy:
	export ASSET_CONFIG_PATH="config/strategies/USDCStrategyConfig.json" && forge test --fork-url base --ffi -vvv --mc MoonwellMorphoStrategy -vvv

cbbtc-strategy:
	export ASSET_CONFIG_PATH="config/strategies/cbBTCStrategyConfig.json" && forge test --fork-url base --ffi --mc MoonwellMorphoStrategy  -vvv

usdc-price-checker:
	export ASSET_CONFIG_PATH="config/strategies/USDCStrategyConfig.json" && forge test --fork-url base --ffi --mc SlippagePriceCheckerTest -vvv 

cbbtc-price-checker:
	export ASSET_CONFIG_PATH="config/strategies/cbBTCStrategyConfig.json" && forge test --fork-url base --ffi --mc SlippagePriceCheckerTest -vvv 

strategy-factory:
	export ASSET_CONFIG_PATH="./config/strategies/cbBTCStrategyConfig.json" && forge test --fork-url base --ffi --mc StrategyFactoryIntegrationTest

strategy-multicall:
	export ASSET_CONFIG_PATH="./config/strategies/cbBTCStrategyConfig.json" && forge test --fork-url base --ffi --mc MulticallIntegrationTest

fee-splitter:
	forge test --fork-url base --ffi --mc FeeSplitterIntegrationTest -vv

virtuals-fee-splitter:
	forge test --fork-url base --ffi --mc VirtualsFeeSplitterIntegrationTest -vv

.PHONY: test coverage deploy-broadcast usdc-strategy cbbtc-strategy strategy-factory strategy-multicall usdc-price-checker cbbtc-price-checker fee-splitter virtuals-fee-splitter integration-test