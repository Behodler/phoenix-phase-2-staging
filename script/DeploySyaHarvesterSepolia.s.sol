// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "@forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStableYieldAccumulator} from "@stable-yield-accumulator/interfaces/IStableYieldAccumulator.sol";
import {SYAHarvester} from "sya-harvester/SYAHarvester.sol";
import {SyaHarvesterLocalStack, IMintableHarvestStable} from "./helpers/SyaHarvesterLocalStack.sol";
import {SyaHarvesterLocalConfig} from "./helpers/SyaHarvesterLocalConfig.sol";

/// @notice SYA's public `strategyTokens` mapping getter, which `IStableYieldAccumulator` does not declare.
interface ISyaStrategyTokens {
    function strategyTokens(address strategy) external view returns (address);
}

/**
 * @title DeploySyaHarvesterSepolia
 * @notice Add-on to `DeployMocksSepolia` + `DeployUniswapHelperSepolia`: deploys SYAHarvester and the
 *         infrastructure it executes against (Curve Router NG mock, crvUSD and the USDe/crvUSD and
 *         crvUSD/USDC Curve pools, Uniswap V4 PoolManager + liquidity router with a seeded native-ETH/USDC
 *         pool) on the mock stack recorded in `server/deployments/progress.11155111.json`, then appends
 *         them to that file so `extract:sepolia` surfaces the `SYAHarvester` key (the infrastructure is
 *         dropped by the extractor, as on anvil).
 *
 * @dev It is the Sepolia leg of DeployMocks Phases 11.11 (story 115) and 11.12 (story 116), through the
 *      same `SyaHarvesterLocalStack` / `SyaHarvesterLocalConfig` libraries. It runs AFTER
 *      `DeployUniswapHelperSepolia` because the harvester's DOLA route runs through the
 *      MockCurveDolaMetaPool that script deploys. Differences from DeployMocks, and why:
 *        - USDe's SYA registration is not here: `DeployMocksSepolia` registers it in Phase 7.5 and
 *          seeds the USDe strategy in Phase 9.57. This script requires both.
 *        - The V4 ETH/USDC pool's ETH side is the faucet-sized `SEPOLIA_WETH_SEED` (wei, default 0.1 ether)
 *          instead of 100 ETH, still at 2000 USDC/ETH.
 *        - USDC FLASH FLOAT. `harvest` flash-borrows SYA's whole claim payment in USDC from the PoolManager
 *          (`take`), so the PoolManager must physically hold at least that much USDC. A faucet-sized pool
 *          holds only ~200 USDC per 0.1 ETH, so `V4_USDC_FLOAT` mock USDC is minted straight into the
 *          PoolManager. It is not pool liquidity and belongs to nobody: `take` can lend it, but every
 *          unlock must settle its deltas to zero, so it cannot be withdrawn. Only the pool's ETH side
 *          limits the payout.
 *        - NO SMOKE HARVEST. DeployMocks' smoke harvest asserts a payout covering 3M gas at 50 gwei
 *          (~0.15 ETH), calibrated for a 100-ETH pool. A faucet-sized pool cannot honour that, and the
 *          harvest would spend the claimable yield the UI needs. `SyaHarvesterLocalConfig.deploy` still
 *          asserts the full configuration (owner, immutables, ETH pool key, Router NG route contiguity),
 *          and test/SyaHarvesterLocalHarvest.t.sol proves the harvest path itself.
 *
 *      Idempotent: a progress file that already names a SYAHarvester with code makes the run a no-op.
 *      One that names a SYAHarvester WITHOUT code was recorded in forge's local pass but never landed; the
 *      script refuses, and the entries it appended must be removed by hand before re-running.
 *
 *      OWNERSHIP EXCEPTION. Same as DeployMocksSepolia (story 098): every token here is a mock with an
 *      unrestricted mint. The harvester and the PoolManager are owned by the deployer EOA.
 *
 *      HOW TO RUN (env from .envrc: RPC_SEPOLIA, DEPLOYER_SEPOLIA_pk; optional SEPOLIA_WETH_SEED):
 *        npm run sya-harvester:sepolia-preview   # simulation only, no broadcast, progress file untouched
 *        npm run sya-harvester:sepolia           # broadcast, then extract + generate sepolia-addresses.ts
 */
contract DeploySyaHarvesterSepolia is Script {
    string public constant PROGRESS_FILE = "server/deployments/progress.11155111.json";
    /// @dev Same default as DeployMocksSepolia's SEPOLIA_DEFAULT_WETH_SEED.
    uint256 public constant DEFAULT_ETH_SEED = 0.1 ether;
    /// @dev Mock USDC minted into the PoolManager as harvest flash float (see the header). Sepolia's SYA
    ///      starts with ~2.3k USDC of claimable yield (DOLA, USDC, USDe seeds); the float covers that
    ///      many times over as yield accrues between harvests.
    uint256 public constant V4_USDC_FLOAT = 100_000e6;

    function _progressFile() internal view virtual returns (string memory) {
        return PROGRESS_FILE;
    }

    function _deployerKey() internal view virtual returns (uint256) {
        return vm.envUint("DEPLOYER_SEPOLIA_pk");
    }

    function _ethSeed() internal view virtual returns (uint256) {
        return vm.envOr("SEPOLIA_WETH_SEED", DEFAULT_ETH_SEED);
    }

    /// @dev PREVIEW_MODE=true (the :preview npm key) skips the progress-file write: forge runs the script
    ///      locally even without --broadcast, and a recorded-but-never-landed harvester would block the real run.
    function _previewMode() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }

    function run() external {
        require(block.chainid == 11155111, "DeploySyaHarvesterSepolia: sepolia only");

        string memory json = vm.readFile(_progressFile());
        if (vm.keyExistsJson(json, ".contracts.SYAHarvester.address")) {
            address recorded = vm.parseJsonAddress(json, ".contracts.SYAHarvester.address");
            require(recorded.code.length > 0, "DeploySyaHarvesterSepolia: recorded SYAHarvester has no code");
            console.log("SYAHarvester already deployed (progress file), nothing to do:", recorded);
            return;
        }

        SyaHarvesterLocalConfig.Inputs memory cfg = _harvesterInputs(json);

        uint256 key = _deployerKey();
        cfg.owner = vm.addr(key);
        uint256 ethSeed = _ethSeed();
        console.log("Deployer:", cfg.owner);
        console.log("V4 ETH/USDC pool ETH seed (wei, SEPOLIA_WETH_SEED):", ethSeed);
        require(ethSeed > 0, "DeploySyaHarvesterSepolia: SEPOLIA_WETH_SEED is zero");
        // The seed plus its 1% rounding margin is sent; the unused margin is refunded.
        require(cfg.owner.balance > ethSeed + ethSeed / 100, "DeploySyaHarvesterSepolia: deployer ETH below the seed");

        vm.startBroadcast(key);
        SyaHarvesterLocalStack.Infra memory s = SyaHarvesterLocalStack.deploy(
            SyaHarvesterLocalStack.Inputs({
                usdc: cfg.usdc,
                dola: cfg.dola,
                usde: cfg.usde,
                curveDola: cfg.curveDola,
                poolManagerOwner: cfg.owner,
                payer: cfg.owner
            }),
            ethSeed
        );
        IMintableHarvestStable(cfg.usdc).mint(address(s.poolManager), V4_USDC_FLOAT);
        SYAHarvester h = SyaHarvesterLocalConfig.deploy(s, cfg);
        vm.stopBroadcast();

        require(
            address(s.poolManager).balance >= ethSeed * 99 / 100, "DeploySyaHarvesterSepolia: V4 pool not seeded (ETH)"
        );
        require(
            IERC20(cfg.usdc).balanceOf(address(s.poolManager)) >= V4_USDC_FLOAT,
            "DeploySyaHarvesterSepolia: PoolManager USDC float missing"
        );
        require(
            address(h).balance == 0 && IERC20(cfg.usdc).balanceOf(address(h)) == 0,
            "DeploySyaHarvesterSepolia: harvester not empty"
        );

        if (_previewMode()) {
            console.log("PREVIEW_MODE: progress file left unchanged");
        } else {
            _recordDeployment(json, s, address(h));
        }

        console.log("  MockCrvUSD:", address(s.crvUSD));
        console.log("  MockCurveUsdeCrvusdPool (USDe=0, crvUSD=1):", address(s.curveUsdeCrvusd));
        console.log("  MockCurveCrvusdUsdcPool (USDC=0, crvUSD=1):", address(s.curveCrvusdUsdc));
        console.log("  MockCurveRouterNG:", address(s.router));
        console.log("  UniswapV4PoolManager:", address(s.poolManager));
        console.log("  UniswapV4LiquidityRouter:", address(s.liquidityRouter));
        console.log("  ETH/USDC V4 pool liquidity:", uint256(s.ethPoolLiquidity));
        console.log("  SYAHarvester:", address(h));
        console.log("  routes: DOLA -> USDC (1 hop), USDe -> crvUSD -> USDC (2 hops); USDC (reward token) has no route");
    }

    /// @dev Reads the harvester's dependencies from the progress file (owner is filled in by `run`) and
    ///      requires the DeployMocksSepolia state it builds on: USDC as SYA's reward token, USDe registered.
    function _harvesterInputs(string memory json) internal view returns (SyaHarvesterLocalConfig.Inputs memory cfg) {
        cfg.sya = _dependency(json, "StableYieldAccumulator");
        cfg.usdc = _dependency(json, "MockUSDC");
        cfg.dola = _dependency(json, "MockDola");
        cfg.usde = _dependency(json, "USDe");
        cfg.curveDola = _dependency(json, "MockCurveDolaMetaPool");
        require(
            IStableYieldAccumulator(cfg.sya).rewardToken() == cfg.usdc,
            "DeploySyaHarvesterSepolia: SYA reward token is not USDC"
        );
        require(
            ISyaStrategyTokens(cfg.sya).strategyTokens(_dependency(json, "YieldStrategyUSDe")) == cfg.usde,
            "DeploySyaHarvesterSepolia: USDe not registered with SYA - redeploy with the current DeployMocksSepolia"
        );
    }

    function _recordDeployment(string memory json, SyaHarvesterLocalStack.Infra memory s, address h) internal {
        string memory curveEntries = string.concat(
            _entry("MockCrvUSD", address(s.crvUSD)),
            ",",
            _entry("MockCurveUsdeCrvusdPool", address(s.curveUsdeCrvusd)),
            ",",
            _entry("MockCurveCrvusdUsdcPool", address(s.curveCrvusdUsdc)),
            ",",
            _entry("MockCurveRouterNG", address(s.router))
        );
        string memory v4Entries = string.concat(
            _entry("UniswapV4PoolManager", address(s.poolManager)),
            ",",
            _entry("UniswapV4LiquidityRouter", address(s.liquidityRouter)),
            ",",
            _entry("SYAHarvester", h)
        );
        _appendProgress(json, string.concat(curveEntries, ",", v4Entries));
    }

    function _dependency(string memory json, string memory name) internal view returns (address a) {
        string memory path = string.concat(".contracts.", name, ".address");
        require(
            vm.keyExistsJson(json, path),
            string.concat(
                "DeploySyaHarvesterSepolia: ",
                name,
                " missing from progress file - run deploy:sepolia and uniswap-helper:sepolia first"
            )
        );
        a = vm.parseJsonAddress(json, path);
        require(a.code.length > 0, string.concat("DeploySyaHarvesterSepolia: ", name, " has no code"));
    }

    /// @dev Same entry shape as DeployMocksSepolia._writeProgressFile.
    function _entry(string memory name, address a) internal pure returns (string memory) {
        return string.concat(
            '"',
            name,
            '": {"address": "',
            vm.toString(a),
            '","deployed": true,"configured": true,"deployGas": 0,"configGas": 0}'
        );
    }

    /// @dev Splices `entries` into the "contracts" object, which DeployMocksSepolia writes last, so the
    ///      file always ends in "}}" (contracts object, then root object).
    function _appendProgress(string memory json, string memory entries) internal {
        bytes memory b = bytes(json);
        uint256 n = b.length;
        while (n > 0 && (b[n - 1] == " " || b[n - 1] == "\n" || b[n - 1] == "\r" || b[n - 1] == "\t")) n--;
        require(
            n >= 2 && b[n - 2] == "}" && b[n - 1] == "}", "DeploySyaHarvesterSepolia: unexpected progress file shape"
        );
        bytes memory head = new bytes(n - 2);
        for (uint256 i = 0; i < n - 2; i++) {
            head[i] = b[i];
        }
        vm.writeFile(_progressFile(), string.concat(string(head), ",", entries, "}}"));
        console.log("Progress file updated:", _progressFile());
    }
}
