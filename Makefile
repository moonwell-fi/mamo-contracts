test:
	forge test --fork-url base --ffi -vvv --no-match-contract "MoonwellMorphoStrategy|StrategyFactoryIntegrationTest|MulticallIntegrationTest|SlippagePriceCheckerTest|MamoStrategyRegistryIntegrationTest|FeeSplitterIntegrationTest"

test-unit:
	forge test --ffi -vvv --match-path "test/*.unit.t.sol"

coverage:
	forge coverage --fork-url base --ffi --report lcov --skip s.sol --no-match-coverage t.sol --ir-minimum -vvv && genhtml lcov.info --branch-coverage --output-dir coverage

deploy-broadcast:
	export DEPLOY_ENV="8453_PROD" && forge script script/DeploySystem.s.sol:DeploySystem --fork-url base --account mamo-test --verify --slow -vvvvv --broadcast --sender   0xDca82E03057329f53Ed4173429D46B0511E46Fb8

usdc-strategy:
	export ASSET_CONFIG_PATH="config/strategies/USDCStrategyConfig.json" && forge test --fork-url base --ffi -vvv --mc MoonwellMorphoStrategy -vvv

cbbtc-strategy:
	export ASSET_CONFIG_PATH="config/strategies/cbBTCStrategyConfig.json" && forge test --fork-url base --ffi --mc MoonwellMorphoStrategy  -vvv

weth-strategy:
	export ASSET_CONFIG_PATH="config/strategies/WETHStrategyConfig.json" && forge test --fork-url base --ffi --mc MoonwellMorphoStrategy  -vvv

usdc-price-checker:
	export ASSET_CONFIG_PATH="config/strategies/USDCStrategyConfig.json" && forge test --fork-url base --ffi --mc SlippagePriceCheckerTest -vvv

cbbtc-price-checker:
	export ASSET_CONFIG_PATH="config/strategies/cbBTCStrategyConfig.json" && forge test --fork-url base --ffi --mc SlippagePriceCheckerTest -vvv

weth-price-checker:
	export ASSET_CONFIG_PATH="config/strategies/WETHStrategyConfig.json" && forge test --fork-url base --ffi --mc SlippagePriceCheckerTest -vvv

strategy-factory:
	export ASSET_CONFIG_PATH="./config/strategies/cbBTCStrategyConfig.json" && forge test --fork-url base --ffi --mc StrategyFactoryIntegrationTest

strategy-multicall:
	export ASSET_CONFIG_PATH="./config/strategies/cbBTCStrategyConfig.json" && forge test --fork-url base --ffi --mc MulticallIntegrationTest

mamo-staking:
	forge test --fork-url base --ffi --mc MamoStaking -vvv

fee-splitter:
	forge test --fork-url base --ffi --mc FeeSplitterIntegrationTest -vv

# Robinhood Chain: MorphoVaultsStrategy against real Morpho Vault V2 bytecode. No fork needed.
robinhood-vaults-v2:
	forge test --ffi --match-path "test/MorphoVaultsStrategyVaultV2.integration.t.sol" -vv

# Robinhood Chain: the live fork suites (chassis + baskets). Skip themselves unless ROBINHOOD_RPC_URL is set.
robinhood-fork:
	forge test --ffi --match-path "test/Robinhood*Fork.integration.t.sol" -vv

test-all:
	$(MAKE) test test-unit usdc-strategy cbbtc-strategy usdc-price-checker cbbtc-price-checker strategy-factory strategy-multicall mamo-staking fee-splitter robinhood-vaults-v2 robinhood-fork

.PHONY: test test-unit coverage deploy-broadcast usdc-strategy cbbtc-strategy strategy-factory strategy-multicall usdc-price-checker cbbtc-price-checker fee-splitter integration-test mamo-staking robinhood-vaults-v2 robinhood-fork test-all