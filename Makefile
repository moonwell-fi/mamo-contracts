test:
	forge test --fork-url base --ffi -vvv --no-match-contract "MoonwellMorphoStrategy|StrategyFactoryIntegrationTest|MulticallIntegrationTest|SlippagePriceCheckerTest|MamoStrategyRegistryIntegrationTest|FeeSplitterIntegrationTest"

test-unit:
	forge test --ffi -vvv --match-path "test/*.unit.t.sol"

# NOTE: `--skip s.sol` suffix-matches ANY file ending in "s.sol" — it excludes deploy scripts
# (.s.sol) AND test/harness/*Harness.sol only by naming accident. A test helper named e.g.
# FooHelper.sol or FooMock.sol would match neither s.sol nor t.sol and silently pollute coverage:
# keep test-only contracts suffixed "Harness.sol" (or extend the skip list here).
# Explicitly skipped for exactly that reason: script/tenderly/FreshFeed.sol (a vnet-only Chainlink
# aggregator mock, code-replaced onto the real feed addresses via tenderly_setCode) and
# script/tenderly/TenderlySwapHelper.sol (the price-sim swap-callback holder). Neither is product code.
coverage:
	forge coverage --fork-url base --ffi --report lcov --skip s.sol --skip FreshFeed.sol --skip TenderlySwapHelper.sol --no-match-coverage t.sol --ir-minimum -vvv && genhtml lcov.info --branch-coverage --output-dir coverage

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

# MamoLeveragedAeroStrategy account unit tests. Mocks only (no fork): the Sherwood strategy/vault are
# stubbed, so NO --fork-url. Matches test/MamoLeveragedAeroStrategy*.unit.t.sol.
leveraged-aero-account:
	forge test --ffi --match-path "test/MamoLeveragedAeroStrategy*.unit.t.sol" -vvv

# LeveragedAeroVault + vendored-strategy unit tests. Mocks only (no fork): the vendored strategy is
# stubbed by test/mocks/MockVaultStrategy.sol for the vault suite, and the strategy's own suite runs
# against venue mocks, so NO --fork-url.
#
# BOTH paths are listed explicitly. `test-unit`'s "test/*.unit.t.sol" glob does cross `/` on the
# pinned forge nightly and picks up test/leveraged-aero/ as well, but that is a property of the
# matcher, not something the suite should depend on — naming the directory here keeps the vendored
# strategy's tests running if a toolchain bump ever tightens the glob.
leveraged-aero-vault:
	forge test --ffi --match-path "test/LeveragedAeroVault.unit.t.sol" -vvv
	forge test --ffi --match-path "test/leveraged-aero/*.unit.t.sol" -vvv

test-all:
	$(MAKE) test test-unit usdc-strategy cbbtc-strategy usdc-price-checker cbbtc-price-checker strategy-factory strategy-multicall mamo-staking fee-splitter lp-auto-balancer-v2 lp-v2-setup leveraged-aero-account leveraged-aero-vault

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

# POOLED-layer deploy against the LIVE persistent Base-fork vnet (runbook Phase B). B.0 FreshFeed-
# overrides the 5 venue Chainlink feeds via tenderly_setCode (never stale, warping safe) → B.1 deploys
# the LeveragedAerodromeCLStrategy TEMPLATE + LeveragedAeroVault(USDC, owner=MAMO_MULTISIG) as
# DEPLOYER_EOA → B.2/B.3 as the multisig: vault.cloneAndBind(template, MAMO_REBALANCER, initData), the
# atomic clone+initialize+bind → B.4 seed USDC, approve the vault, activateStrategy(SEED) → B.5 asserts
# every post-condition the account layer depends on. Run this BEFORE tenderly-leveraged-aero-account on
# a fresh vnet. ALWAYS reuses TENDERLY_VNET_RPC_URL; NEVER time-warps. Key env: MAMO_REBALANCER (the
# strategy proposer — a dedicated operator address, NOT MAMO_BACKEND), SEED (default 100k USDC), LP_POOL
# (pending product decision) and the rest of the venue book — see run-leveraged-aero-stack.sh.
tenderly-leveraged-aero-stack:
	./script/tenderly/run-harness.sh leveraged-aero-stack

# Account-layer deploy-drive + e2e smoke against the LIVE persistent Base-fork vnet where the POOLED
# layer (LeveragedAeroVault + a LeveragedAerodromeCLStrategy clone) is already deployed — by
# `make tenderly-leveraged-aero-stack`, which must run first on a fresh vnet. Replays proposal 012
# (deploy impl+factory, the 3 multisig actions, validate) then the full account lifecycle
# (create→deposit→withdraw→request→fulfill→claim→depositIdle gate) as unlocked-impersonation broadcast
# txs. ALWAYS reuses TENDERLY_VNET_RPC_URL. The pooled addresses default to whatever
# script/tenderly/leveraged-aero-vnet.json records (env vars still override).
tenderly-leveraged-aero-account:
	./script/tenderly/run-harness.sh leveraged-aero-account

.PHONY: test test-unit coverage deploy-broadcast usdc-strategy cbbtc-strategy strategy-factory strategy-multicall usdc-price-checker cbbtc-price-checker fee-splitter integration-test mamo-staking lp-auto-balancer-v2 lp-v2-setup leveraged-aero-account leveraged-aero-vault test-all tenderly-harness tenderly-matrix tenderly-price-checker tenderly-leveraged-aero-stack tenderly-leveraged-aero-account
