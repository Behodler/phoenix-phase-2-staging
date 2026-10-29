// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "@forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockPhUSD} from "../src/mocks/MockPhUSD.sol";
import {MockUSDS} from "../src/mocks/MockUSDS.sol";
import {MockSUSDS} from "../src/mocks/MockSUSDS.sol";
import {AntimatterPoolSeeder} from "../src/periphery/AntimatterPoolSeeder.sol";
import {UniswapHelper} from "../src/periphery/UniswapHelper.sol";
import {UniPoolerV2} from "@yield-claim-nft/dispatchers/UniPoolerV2.sol";
import {Antimatter} from "antimatter/Antimatter.sol";
import {IUniswapV2FactoryLike, IUniswapV2RouterLike} from "./helpers/UniswapV2Deployer.sol";

/// @notice The pair reads this script needs.
interface ISepoliaAmPairLike {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

/**
 * @title DeployAntimatterPoolSepolia
 * @notice Add-on to `DeployMocksSepolia` (after `DeployUniswapHelperSepolia` and `DeploySyaHarvesterSepolia`):
 *         brings the Sepolia mock stack to DeployMocks' Antimatter market feature set, then appends
 *         `AntimatterPoolSeeder` and `AntimatterSusdsPair` to `server/deployments/progress.11155111.json`
 *         so `extract:sepolia` replaces their zero placeholders.
 *
 * @dev The Sepolia leg of three DeployMocks phases, in DeployMocks order:
 *        - Phase 11.9 (story 112): deepen the phUSD/sUSDS pair to `SUSDS_TARGET` sUSDS (DeployMocks'
 *          ~181k), LP minted to UniPoolerV2 (protocol-owned, the LP the cutover carves). Liquidity is
 *          added at the PREVAILING ratio, which on Sepolia is phUSD par (1 sUSDS = 1.1 USDS = 1.1 phUSD)
 *          rather than DeployMocks' mainnet ratio, so the phUSD side lands near 199k, not 231k.
 *          The phUSD is minted outright, as in DeployMocks. DeployMocksSepolia's terminal sweep revoked
 *          the deployer's phUSD mint right, so the deployer (phUSD's owner) re-grants it to itself,
 *          mints, and revokes it again; the run ends by asserting the deployer is NOT a live minter.
 *        - Phase 11.10 (story 114): the Antimatter/sUSDS cutover, driven exactly as DeployMocks drives it
 *          (and as the mainnet OWNER would): `lpForBps(AM_CUTOVER_BPS)` -> `UniPoolerV2.rescueERC20` ->
 *          approve -> grant the seeder the Antimatter minter role (asserted) -> `seed` with unwrap floors
 *          0.1% under the pro-rata share -> revoke the role. AM/sUSDS LP to the deployer.
 *        - Phase 11.14 (story 120): assert UniswapHelper resolves the new AM/sUSDS pair, and mint the
 *          deployer `AM_DEMO` Antimatter to start with (the deployer owns Antimatter, which admits it as
 *          a minter).
 *
 *      Idempotent: a progress file that already names an AntimatterPoolSeeder with code makes the run a
 *      no-op. One that names a seeder WITHOUT code was recorded in forge's local pass but never landed;
 *      the script refuses, and the entries it appended must be removed by hand (or the broadcast resumed
 *      with forge `--resume`).
 *
 *      OWNERSHIP EXCEPTION. Same as DeployMocksSepolia (story 098): every token here is a mock with an
 *      unrestricted mint, and the seeder is owned by the deployer EOA.
 *
 *      HOW TO RUN (env from .envrc: RPC_SEPOLIA, DEPLOYER_SEPOLIA_pk):
 *        npm run antimatter-pool:sepolia-preview   # simulation only, no broadcast, progress file untouched
 *        npm run antimatter-pool:sepolia           # broadcast, then extract + generate sepolia-addresses.ts
 */
contract DeployAntimatterPoolSepolia is Script {
    string public constant PROGRESS_FILE = "server/deployments/progress.11155111.json";
    /// @dev DeployMocks `UNI_PAIR_SUSDS_TARGET` (mainnet post-cutover depth x10).
    uint256 public constant SUSDS_TARGET = 181_000e18;
    /// @dev DeployMocks `AM_CUTOVER_BPS`: half the protocol-owned phUSD/sUSDS LP becomes AM/sUSDS LP.
    uint256 public constant AM_CUTOVER_BPS = 5_000;
    /// @dev DeployMocks `UNI_POOL_TOLERANCE_BPS` / `UNI_BPS`.
    uint256 public constant TOLERANCE_BPS = 10;
    uint256 public constant BPS = 10_000;
    /// @dev DeployMocks `UH_DEMO_18`: the demo Antimatter Phase 11.14 mints the deployer.
    uint256 public constant AM_DEMO = 10_000e18;

    struct Stack {
        MockPhUSD phUSD;
        MockUSDS usds;
        MockSUSDS susds;
        Antimatter antimatter;
        UniPoolerV2 uniPoolerV2;
        UniswapHelper uniswapHelper;
        IUniswapV2RouterLike router;
        IUniswapV2FactoryLike factory;
        address phusdSusdsPair;
        address deployer;
    }

    function _progressFile() internal view virtual returns (string memory) {
        return PROGRESS_FILE;
    }

    function _deployerKey() internal view virtual returns (uint256) {
        return vm.envUint("DEPLOYER_SEPOLIA_pk");
    }

    /// @dev PREVIEW_MODE=true (the :preview npm key) skips the progress-file write.
    function _previewMode() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }

    function run() external {
        require(block.chainid == 11155111, "DeployAntimatterPoolSepolia: sepolia only");

        string memory json = vm.readFile(_progressFile());
        if (vm.keyExistsJson(json, ".contracts.AntimatterPoolSeeder.address")) {
            address recorded = vm.parseJsonAddress(json, ".contracts.AntimatterPoolSeeder.address");
            require(recorded.code.length > 0, "DeployAntimatterPoolSepolia: recorded AntimatterPoolSeeder has no code");
            console.log("AntimatterPoolSeeder already deployed (progress file), nothing to do:", recorded);
            return;
        }

        uint256 key = _deployerKey();
        Stack memory s = _stack(json, vm.addr(key));
        console.log("Deployer:", s.deployer);
        require(s.antimatter.owner() == s.deployer, "DeployAntimatterPoolSepolia: deployer does not own Antimatter");
        require(s.uniPoolerV2.owner() == s.deployer, "DeployAntimatterPoolSepolia: deployer does not own UniPoolerV2");
        require(s.phUSD.owner() == s.deployer, "DeployAntimatterPoolSepolia: deployer does not own phUSD");
        require(!_isLiveMinter(s.phUSD, s.deployer), "DeployAntimatterPoolSepolia: deployer is already a phUSD minter");
        require(
            s.factory.getPair(address(s.antimatter), address(s.susds)) == address(0),
            "DeployAntimatterPoolSepolia: AM/sUSDS pair already exists"
        );

        vm.startBroadcast(key);
        _deepenPhusdSusdsSeed(s);
        (AntimatterPoolSeeder seeder, address amPair) = _antimatterPoolCutover(s);
        _antimatterDemoBalance(s, amPair);
        vm.stopBroadcast();

        require(
            !_isLiveMinter(s.phUSD, s.deployer), "DeployAntimatterPoolSepolia: deployer phUSD mint right not revoked"
        );
        console.log("End state: deployer phUSD mint right REVOKED (as DeployMocksSepolia's terminal sweep left it)");

        if (_previewMode()) {
            console.log("PREVIEW_MODE: progress file left unchanged");
        } else {
            _appendProgress(
                json,
                string.concat(
                    _entry("AntimatterPoolSeeder", address(seeder)), ",", _entry("AntimatterSusdsPair", amPair)
                )
            );
        }
        console.log("  AntimatterPoolSeeder:", address(seeder));
        console.log("  AntimatterSusdsPair:", amPair);
    }

    // ------------------------------------------------------------------
    // Phase 11.9: deepen the phUSD/sUSDS pair, LP to UniPoolerV2
    // ------------------------------------------------------------------

    function _deepenPhusdSusdsSeed(Stack memory s) internal {
        console.log("\n=== Phase 11.9 (Sepolia): Deepen the phUSD/sUSDS seed (story 112) ===");
        (uint256 rS, uint256 rP) = _phusdSusdsReserves(s);
        require(rS > 0 && rP > 0, "story-112: phUSD/sUSDS pair not seeded");
        require(SUSDS_TARGET > rS, "story-112: pair already at depth");

        // sUSDS to reach the target, +1 token of headroom for the router's rounding; phUSD at the prevailing ratio.
        uint256 addS = SUSDS_TARGET - rS + 1e18;
        uint256 addP = (addS * rP) / rS;

        uint256 usdsIn = s.susds.previewMint(addS);
        uint256 usdsBal = s.usds.balanceOf(s.deployer);
        if (usdsBal < usdsIn) s.usds.mint(s.deployer, usdsIn - usdsBal);
        s.usds.approve(address(s.susds), usdsIn);
        s.susds.mint(addS, s.deployer);

        // Temporary phUSD mint right (revoked below; asserted after the broadcast).
        s.phUSD.setMinter(s.deployer, true);
        s.phUSD.mint(s.deployer, addP);
        s.phUSD.setMinter(s.deployer, false);

        uint256 lpBefore = IERC20(s.phusdSusdsPair).balanceOf(address(s.uniPoolerV2));
        IERC20(address(s.susds)).approve(address(s.router), addS);
        IERC20(address(s.phUSD)).approve(address(s.router), addP);
        (uint256 usedS, uint256 usedP, uint256 liquidity) = s.router
            .addLiquidity(
                address(s.susds),
                address(s.phUSD),
                addS,
                addP,
                addS,
                addP,
                address(s.uniPoolerV2),
                block.timestamp + 1 hours
            );
        require(usedS == addS && usedP == addP, "story-112: router did not take the sized deepening");

        (uint256 aS, uint256 aP) = _phusdSusdsReserves(s);
        require(aS >= SUSDS_TARGET, "story-112: deepened sUSDS reserve below target");
        require(
            liquidity > 0 && IERC20(s.phusdSusdsPair).balanceOf(address(s.uniPoolerV2)) == lpBefore + liquidity,
            "story-112: UniPoolerV2 does not hold the added LP"
        );
        console.log("  phUSD/sUSDS reserves after deepening - sUSDS:", aS);
        console.log("  phUSD/sUSDS reserves after deepening - phUSD:", aP);
        console.log("  LP held by UniPoolerV2:", IERC20(s.phusdSusdsPair).balanceOf(address(s.uniPoolerV2)));
    }

    // ------------------------------------------------------------------
    // Phase 11.10: Antimatter/sUSDS cutover
    // ------------------------------------------------------------------

    function _antimatterPoolCutover(Stack memory s) internal returns (AntimatterPoolSeeder seeder, address amPair) {
        console.log("\n=== Phase 11.10 (Sepolia): Antimatter/sUSDS cutover (story 114) ===");
        seeder = new AntimatterPoolSeeder(
            s.deployer,
            address(s.phUSD),
            address(s.susds),
            address(s.antimatter),
            address(s.router),
            s.phusdSusdsPair,
            address(s.uniPoolerV2)
        );
        require(seeder.owner() == s.deployer, "story-114: seeder owner != deployer");
        require(seeder.lpSource() == address(s.uniPoolerV2), "story-114: seeder lpSource != UniPoolerV2");

        uint256 phusdSupply = s.phUSD.totalSupply();
        uint256 poolerLp = IERC20(s.phusdSusdsPair).balanceOf(address(s.uniPoolerV2));

        // 1. Size the slice. 2. Rescue it to the owner. 3. Approve the seeder.
        uint256 lpAmount = seeder.lpForBps(AM_CUTOVER_BPS);
        require(lpAmount > 0 && lpAmount == poolerLp * AM_CUTOVER_BPS / BPS, "story-114: lpForBps sizing");
        (uint256 minP, uint256 minS) = _cutoverMins(s, lpAmount);
        s.uniPoolerV2.rescueERC20(s.phusdSusdsPair, s.deployer, lpAmount);
        IERC20(s.phusdSusdsPair).approve(address(seeder), lpAmount);

        // 4. Grant the Antimatter minter role, asserted (setApprovedMinter is a silent no-op on an unchanged value).
        s.antimatter.setApprovedMinter(address(seeder), true);
        require(s.antimatter.isApprovedMinter(address(seeder)), "story-114: seeder is not an AM minter");

        // 5. Seed, then revoke the role (one-shot posture).
        (uint256 amMinted, uint256 liquidity) = seeder.seed(lpAmount, minP, minS, s.deployer, block.timestamp + 1 hours);
        s.antimatter.setApprovedMinter(address(seeder), false);
        require(!s.antimatter.isApprovedMinter(address(seeder)), "story-114: seeder AM minter role not revoked");

        amPair = seeder.amSusdsPair();
        require(amPair != address(0), "story-114: AM/sUSDS pair not created");
        require(
            s.factory.getPair(address(s.antimatter), address(s.susds)) == amPair,
            "story-114: AM/sUSDS pair is not the factory's canonical pair"
        );
        require(
            liquidity > 0 && IERC20(amPair).balanceOf(s.deployer) == liquidity,
            "story-114: deployer lacks the AM/sUSDS LP"
        );
        require(amMinted > 0 && s.phUSD.totalSupply() + amMinted == phusdSupply, "story-114: phUSD burn != AM minted");
        {
            (uint112 a0, uint112 a1,) = ISepoliaAmPairLike(amPair).getReserves();
            uint256 rAm = ISepoliaAmPairLike(amPair).token0() == address(s.antimatter) ? uint256(a0) : uint256(a1);
            require(rAm == amMinted && a0 > 0 && a1 > 0, "story-114: AM/sUSDS reserves wrong");
        }
        require(
            IERC20(s.phusdSusdsPair).balanceOf(address(s.uniPoolerV2)) == poolerLp - lpAmount,
            "story-114: UniPoolerV2 LP != pre-cutover minus the slice"
        );
        require(
            IERC20(address(s.phUSD)).balanceOf(address(seeder)) == 0
                && IERC20(address(s.antimatter)).balanceOf(address(seeder)) == 0
                && IERC20(address(s.susds)).balanceOf(address(seeder)) == 0
                && IERC20(s.phusdSusdsPair).balanceOf(address(seeder)) == 0,
            "story-114: AntimatterPoolSeeder holds a residual balance"
        );
        console.log("  AM minted == phUSD burned:", amMinted);
        console.log("  AM/sUSDS LP to deployer:", liquidity);
        console.log("  seeder AM minter role granted, used once, REVOKED");
    }

    function _cutoverMins(Stack memory s, uint256 lpAmount) internal view returns (uint256 minP, uint256 minS) {
        uint256 supply = IERC20(s.phusdSusdsPair).totalSupply();
        minP = IERC20(address(s.phUSD)).balanceOf(s.phusdSusdsPair) * lpAmount / supply * (BPS - TOLERANCE_BPS) / BPS;
        minS = IERC20(address(s.susds)).balanceOf(s.phusdSusdsPair) * lpAmount / supply * (BPS - TOLERANCE_BPS) / BPS;
        require(minP > 0 && minS > 0, "story-114: unwrap floors are zero");
    }

    // ------------------------------------------------------------------
    // Phase 11.14: UniswapHelper sees the AM pair; demo Antimatter for the deployer
    // ------------------------------------------------------------------

    function _antimatterDemoBalance(Stack memory s, address amPair) internal {
        console.log("\n=== Phase 11.14 (Sepolia): Antimatter demo balance (story 120) ===");
        require(s.uniswapHelper.antimatter() == address(s.antimatter), "story-120: UniswapHelper antimatter mismatch");
        require(s.uniswapHelper.amPair() == amPair, "story-120: UniswapHelper resolves the wrong AM pair");
        uint256 before = s.antimatter.balanceOf(s.deployer);
        s.antimatter.mint(s.deployer, AM_DEMO);
        require(s.antimatter.balanceOf(s.deployer) == before + AM_DEMO, "story-120: demo AM mint did not land");
        console.log("  deployer demo AM minted:", AM_DEMO);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _stack(string memory json, address deployer) internal view returns (Stack memory s) {
        s.phUSD = MockPhUSD(_dependency(json, "MockPhUSD"));
        s.usds = MockUSDS(_dependency(json, "MockUSDS"));
        s.susds = MockSUSDS(_dependency(json, "MockSUSDS"));
        s.antimatter = Antimatter(_dependency(json, "Antimatter"));
        s.uniPoolerV2 = UniPoolerV2(_dependency(json, "UniPoolerV2"));
        s.uniswapHelper = UniswapHelper(payable(_dependency(json, "UniswapHelper")));
        s.router = IUniswapV2RouterLike(_dependency(json, "UniswapV2Router02"));
        s.factory = IUniswapV2FactoryLike(s.router.factory());
        s.phusdSusdsPair = _dependency(json, "PhusdSusdsPair");
        s.deployer = deployer;
        require(
            s.factory.getPair(address(s.susds), address(s.phUSD)) == s.phusdSusdsPair,
            "DeployAntimatterPoolSepolia: PhusdSusdsPair is not the factory's canonical pair"
        );
    }

    function _phusdSusdsReserves(Stack memory s) internal view returns (uint256 rS, uint256 rP) {
        (uint112 r0, uint112 r1,) = ISepoliaAmPairLike(s.phusdSusdsPair).getReserves();
        (rS, rP) = ISepoliaAmPairLike(s.phusdSusdsPair).token0() == address(s.susds)
            ? (uint256(r0), uint256(r1))
            : (uint256(r1), uint256(r0));
    }

    /// @dev The two-field minter idiom DeployMocksSepolia's terminal sweep uses.
    function _isLiveMinter(MockPhUSD phUSD, address who) internal view returns (bool) {
        MockPhUSD.MinterInfo memory info = phUSD.authorizedMinters(who);
        return info.canMint && info.mintVersion == phUSD.mintVersion();
    }

    function _dependency(string memory json, string memory name) internal view returns (address a) {
        string memory path = string.concat(".contracts.", name, ".address");
        require(
            vm.keyExistsJson(json, path),
            string.concat(
                "DeployAntimatterPoolSepolia: ",
                name,
                " missing from progress file - run deploy:sepolia and uniswap-helper:sepolia first"
            )
        );
        a = vm.parseJsonAddress(json, path);
        require(a.code.length > 0, string.concat("DeployAntimatterPoolSepolia: ", name, " has no code"));
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

    /// @dev Splices `entries` into the "contracts" object, which DeployMocksSepolia writes last.
    function _appendProgress(string memory json, string memory entries) internal {
        bytes memory b = bytes(json);
        uint256 n = b.length;
        while (n > 0 && (b[n - 1] == " " || b[n - 1] == "\n" || b[n - 1] == "\r" || b[n - 1] == "\t")) n--;
        require(
            n >= 2 && b[n - 2] == "}" && b[n - 1] == "}", "DeployAntimatterPoolSepolia: unexpected progress file shape"
        );
        bytes memory head = new bytes(n - 2);
        for (uint256 i = 0; i < n - 2; i++) {
            head[i] = b[i];
        }
        vm.writeFile(_progressFile(), string.concat(string(head), ",", entries, "}}"));
        console.log("Progress file updated:", _progressFile());
    }
}
