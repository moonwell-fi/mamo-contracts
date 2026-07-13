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

# NOTE: no --fork-url here. The V2 integration test self-forks at a PINNED block via
# vm.createSelectFork inside setUp. Passing --fork-url base in addition makes foundry 1.7.x
# init the OP-stack L1Block handler against the CLI fork and panic ("Missing operator fee
# scalar for isthmus L1 Block") before the in-test vm.fee(0) workaround runs.
lp-auto-balancer-v2:
	forge test --ffi --mc LPAutoBalancerV2Integration -vvv

# Same op-revm note as lp-auto-balancer-v2: the FPS setup test self-forks at a PINNED block via
# vm.createSelectFork in setUp with the vm.fee(0) Isthmus workaround. NO --fork-url here.
lp-v2-setup:
	forge test --ffi --mc LPAutoBalancerV2SetupTest -vvv

test-all:
	$(MAKE) test test-unit usdc-strategy cbbtc-strategy usdc-price-checker cbbtc-price-checker strategy-factory strategy-multicall mamo-staking fee-splitter lp-auto-balancer-v2 lp-v2-setup

# Tenderly Virtual TestNet harness: deploy LPAutoBalancerV2 to a Base-fork vnet and drive its real
# lifecycle as broadcast txs (no-swap reset conservation, single-sided rebuild, fee/AERO skim, role
# gating, cooldown, exit). Uses TENDERLY_VNET_RPC_URL from .env (or creates a vnet if TENDERLY_*
# creds are set). See script/tenderly/README.md.
tenderly-harness:
	./script/tenderly/run-harness.sh

# LPAutoBalancerV2 price-simulation scenario matrix on a fresh vnet: calm reset→in-range,
# large-move-down→single-sided (the _mainRange fix under a real price move), calm-gate→TwapDeviation,
# stale-oracle→StaleOracle. Fresh vnet by default (--reuse to reuse TENDERLY_VNET_RPC_URL).
tenderly-matrix:
	./script/tenderly/run-harness.sh lpv2-matrix

# SlippagePriceChecker gate against the live checker + real Chainlink config on a fresh vnet:
# fair minOut passes, under-priced fails, stale feed reverts.
tenderly-price-checker:
	./script/tenderly/run-harness.sh price-checker

.PHONY: test test-unit coverage deploy-broadcast usdc-strategy cbbtc-strategy strategy-factory strategy-multicall usdc-price-checker cbbtc-price-checker fee-splitter integration-test mamo-staking lp-auto-balancer-v2 lp-v2-setup test-all tenderly-harness tenderly-matrix tenderly-price-checker