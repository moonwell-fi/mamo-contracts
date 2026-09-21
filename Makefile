DEPLOY_ENV ?= 8453_TESTING
ADDRESSES_PATH ?= ./script/stock-accounts/addresses-dryrun

test:
	forge test --fork-url base --ffi -vvv --no-match-contract "MoonwellMorphoStrategy|StrategyFactoryIntegrationTest|MulticallIntegrationTest|SlippagePriceCheckerTest|MamoStrategyRegistryIntegrationTest|FeeSplitterIntegrationTest|StockAccountPriceCheckerIntegrationTest|StockAccountStrategyInvariantsUnitTest|ERC20StrategyV2Test|StockAccountRouterSwapIntegrationTest|StockAccountSystemSetupTest"

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

# StockAccountPriceChecker (CT-02): unit suite is mock-only; the integration suite self-forks Base at a
# PINNED block in setUp (no --fork-url: foundry 1.7.x panics on Isthmus L1Block otherwise) and needs BASE_RPC_URL.
stock-price-checker:
	forge test --ffi --match-contract StockAccountPriceChecker -vvv

# check-extra-masked-returns (SC2312) is the point of this: a command substitution used straight in a
# comparison or as an argument throws its own failure away, which is how a check passes without having
# checked anything. Scoped to the stock-accounts scripts; the rest of the repo is not clean yet.
shell-lint:
	shellcheck -x --source-path=SCRIPTDIR --enable=check-extra-masked-returns \
		script/stock-accounts/*.sh script/stock-accounts/scenarios/*.sh

# StockAccountRouterSwap (real-router coverage): self-forks Base at a PINNED block in setUp, same as the
# price-checker suite above (no --fork-url), and needs BASE_RPC_URL.
stock-router-swap:
	forge test --ffi --match-contract StockAccountRouterSwapIntegrationTest -vvv

# Base-fork rehearsal of multisig proposal 016 (the MAINNET deployment of the stock accounts system),
# followed by a real user lifecycle on the result. Self-forks at a PINNED block in setUp, same
# op-revm reason as the two suites above (no --fork-url), and needs BASE_RPC_URL.
stock-accounts-setup:
	forge test --ffi --match-contract StockAccountSystemSetupTest -vvv

deploy-stock-accounts:
	rm -rf script/stock-accounts/addresses-dryrun && mkdir -p script/stock-accounts/addresses-dryrun && cp addresses/*.json script/stock-accounts/addresses-dryrun/
	ADDRESSES_PATH=$(ADDRESSES_PATH) DEPLOY_ENV=$(DEPLOY_ENV) ADMIN_MODE=calldata forge script script/DeployStockAccounts.s.sol:DeployStockAccounts --fork-url base --sender 0xDca82E03057329f53Ed4173429D46B0511E46Fb8 -vv

stock-pool-readiness:
	rm -rf script/stock-accounts/addresses-dryrun && mkdir -p script/stock-accounts/addresses-dryrun && cp addresses/*.json script/stock-accounts/addresses-dryrun/
	ADDRESSES_PATH=$(ADDRESSES_PATH) DEPLOY_ENV=$(DEPLOY_ENV) forge script script/StockAccountsPoolReadiness.s.sol:StockAccountsPoolReadiness --fork-url base --sender 0xDca82E03057329f53Ed4173429D46B0511E46Fb8 -vv

tenderly-stock-accounts:
	./script/stock-accounts/vnet-up.sh

tenderly-stock-accounts-scenarios:
	./script/stock-accounts/scenarios/run.sh

test-all:
	$(MAKE) test test-unit usdc-strategy cbbtc-strategy usdc-price-checker cbbtc-price-checker strategy-factory strategy-multicall mamo-staking fee-splitter stock-price-checker stock-router-swap stock-accounts-setup

.PHONY: shell-lint stock-price-checker stock-accounts-setup deploy-stock-accounts stock-pool-readiness tenderly-stock-accounts tenderly-stock-accounts-scenarios test test-unit coverage deploy-broadcast usdc-strategy cbbtc-strategy strategy-factory strategy-multicall usdc-price-checker cbbtc-price-checker fee-splitter integration-test mamo-staking test-all stock-router-swap

