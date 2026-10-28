// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "@forge-std/Script.sol";
import {UniswapHelperLocalStack} from "./helpers/UniswapHelperLocalStack.sol";
import {UniswapHelper} from "../src/periphery/UniswapHelper.sol";
import {MockSkyPSM} from "../src/mocks/MockSkyPSM.sol";

/**
 * @title DeployUniswapHelperSepolia
 * @notice Add-on to `DeployMocksSepolia`: deploys `UniswapHelper` (story 109) and the four venue mocks it
 *         calls (Uniswap V3 SwapRouter + QuoterV2, Curve DOLA-3CRV metapool, Curve USDe/USDC
 *         stableswap-ng) against the mock stack a DeployMocksSepolia run recorded in
 *         `server/deployments/progress.11155111.json`, then appends them to that file so
 *         `extract:sepolia` surfaces the `UniswapHelper` key (the venue mocks are dropped by the
 *         extractor, as on anvil).
 *
 * @dev It is the Sepolia leg of DeployMocks Phase 11.8 (story 110), through the same
 *      `UniswapHelperLocalStack` library, with one difference: the V3 router's WETH reserve is the
 *      faucet-sized `SEPOLIA_WETH_SEED` (wei, default 0.1 ether) instead of 100 ETH, and its USDC side is
 *      scaled to match at 2000 USDC/ETH. The deployer is also topped up to the same 10k demo balances.
 *
 *      Chained onto `deploy:sepolia` and `deploy:sepolia:resume`, so a fresh deploy brings it along.
 *      Idempotent: a progress file that already names a UniswapHelper with code makes the run a no-op.
 *      One that names a UniswapHelper WITHOUT code was recorded in forge's local pass but never landed;
 *      the script refuses and the entries it appended must be removed by hand before re-running.
 *
 *      OWNERSHIP EXCEPTION. Same as DeployMocksSepolia (story 098): every token here is a mock with an
 *      unrestricted mint; UniswapHelper itself has no owner or admin.
 *
 *      HOW TO RUN (env from .envrc: RPC_SEPOLIA, DEPLOYER_SEPOLIA_pk; optional SEPOLIA_WETH_SEED):
 *        npm run uniswap-helper:sepolia-preview   # simulation only, no broadcast, progress file untouched
 *        npm run uniswap-helper:sepolia           # broadcast, then extract + generate sepolia-addresses.ts
 */
contract DeployUniswapHelperSepolia is Script {
    string public constant PROGRESS_FILE = "server/deployments/progress.11155111.json";
    /// @dev Same default as DeployMocksSepolia's SEPOLIA_DEFAULT_WETH_SEED.
    uint256 public constant DEFAULT_WETH_RESERVE = 0.1 ether;
    /// @dev Same demo top-up as DeployMocks Phase 11.8 (UH_DEMO_18 / UH_DEMO_USDC).
    uint256 internal constant DEMO_18 = 10_000e18;
    uint256 internal constant DEMO_USDC = 10_000e6;

    function _progressFile() internal view virtual returns (string memory) {
        return PROGRESS_FILE;
    }

    function _deployerKey() internal view virtual returns (uint256) {
        return vm.envUint("DEPLOYER_SEPOLIA_pk");
    }

    function _wethReserve() internal view virtual returns (uint256) {
        return vm.envOr("SEPOLIA_WETH_SEED", DEFAULT_WETH_RESERVE);
    }

    /// @dev PREVIEW_MODE=true (the :preview npm key) skips the progress-file write: forge runs the script
    ///      locally even without --broadcast, and a recorded-but-never-landed helper would block the real run.
    function _previewMode() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }

    function run() external {
        require(block.chainid == 11155111, "DeployUniswapHelperSepolia: sepolia only");

        string memory json = vm.readFile(_progressFile());
        if (vm.keyExistsJson(json, ".contracts.UniswapHelper.address")) {
            address recorded = vm.parseJsonAddress(json, ".contracts.UniswapHelper.address");
            require(recorded.code.length > 0, "DeployUniswapHelperSepolia: recorded UniswapHelper has no code");
            console.log("UniswapHelper already deployed (progress file), nothing to do:", recorded);
            return;
        }

        UniswapHelperLocalStack.Inputs memory t = UniswapHelperLocalStack.Inputs({
            phUSD: _dependency(json, "MockPhUSD"),
            sUSDS: _dependency(json, "MockSUSDS"),
            usds: _dependency(json, "MockUSDS"),
            usdc: _dependency(json, "MockUSDC"),
            dola: _dependency(json, "MockDola"),
            usde: _dependency(json, "USDe"),
            weth: _dependency(json, "WETH9"),
            skyPSM: _dependency(json, "MockSkyPSM"),
            v2Router: _dependency(json, "UniswapV2Router02"),
            antimatter: _dependency(json, "Antimatter")
        });
        address pair = _dependency(json, "PhusdSusdsPair");

        uint256 key = _deployerKey();
        address deployer = vm.addr(key);
        uint256 wethReserve = _wethReserve();
        console.log("Deployer:", deployer);
        console.log("V3 router WETH reserve (wei, SEPOLIA_WETH_SEED):", wethReserve);
        require(wethReserve > 0, "DeployUniswapHelperSepolia: SEPOLIA_WETH_SEED is zero");
        require(deployer.balance > wethReserve, "DeployUniswapHelperSepolia: deployer ETH below SEPOLIA_WETH_SEED");

        vm.startBroadcast(key);
        UniswapHelperLocalStack.Venues memory v = UniswapHelperLocalStack.deploy(t, wethReserve);
        UniswapHelperLocalStack.topUpDemoBalances(t, deployer, deployer, DEMO_18, DEMO_USDC);
        vm.stopBroadcast();

        require(v.helper.pair() == pair, "DeployUniswapHelperSepolia: UniswapHelper resolves the wrong pair");
        require(MockSkyPSM(t.skyPSM).tin() == 0, "DeployUniswapHelperSepolia: MockSkyPSM tin not zero");

        if (_previewMode()) {
            console.log("PREVIEW_MODE: progress file left unchanged");
        } else {
            _appendProgress(
                json,
                string.concat(
                    _entry("MockUniswapV3SwapRouter", address(v.v3Router)),
                    ",",
                    _entry("MockUniswapV3QuoterV2", address(v.v3Quoter)),
                    ",",
                    _entry("MockCurveDolaMetaPool", address(v.curveDola)),
                    ",",
                    _entry("MockCurveStableSwapNG", address(v.curveUsde)),
                    ",",
                    _entry("UniswapHelper", address(v.helper))
                )
            );
        }

        console.log("  MockUniswapV3SwapRouter:", address(v.v3Router));
        console.log("  MockUniswapV3QuoterV2:", address(v.v3Quoter));
        console.log("  MockCurveDolaMetaPool (DOLA=0, USDC=2):", address(v.curveDola));
        console.log("  MockCurveStableSwapNG (USDe=0, USDC=1):", address(v.curveUsde));
        console.log("  UniswapHelper:", address(v.helper));
    }

    function _dependency(string memory json, string memory name) internal view returns (address a) {
        string memory path = string.concat(".contracts.", name, ".address");
        require(
            vm.keyExistsJson(json, path),
            string.concat(
                "DeployUniswapHelperSepolia: ", name, " missing from progress file - run deploy:sepolia first"
            )
        );
        a = vm.parseJsonAddress(json, path);
        require(a.code.length > 0, string.concat("DeployUniswapHelperSepolia: ", name, " has no code"));
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
            n >= 2 && b[n - 2] == "}" && b[n - 1] == "}", "DeployUniswapHelperSepolia: unexpected progress file shape"
        );
        bytes memory head = new bytes(n - 2);
        for (uint256 i = 0; i < n - 2; i++) {
            head[i] = b[i];
        }
        vm.writeFile(_progressFile(), string.concat(string(head), ",", entries, "}}"));
        console.log("Progress file updated:", _progressFile());
    }
}
