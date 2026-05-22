// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@stable-yield-accumulator/StableYieldAccumulator.sol";
import {DepositView} from "../src/views/DepositView.sol";
import {IPhlimbo} from "@phlimbo-ea/interfaces/IPhlimbo.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC20Minimal {
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @title RewireSYAToPhlimboV2
/// @notice Follow-up to story-049 (MigratePhlimboV1ToV2). The migration broadcast
///         deployed PhlimboV2 and migrated all user state, but did not repoint
///         StableYieldAccumulator at the new Phlimbo. Until this script runs,
///         SYA.claim() would forceApprove + collectReward against the dead V1
///         (which has no `whenNotPaused` guard on collectReward), silently
///         sending USDC into a stakerless contract.
///
///         Two owner-signed calls fix this:
///           1. SYA.setPhlimbo(V2)
///           2. SYA.approvePhlimbo(amount)
///
///         Order matters: setPhlimbo must come first because approvePhlimbo
///         approves whatever `phlimbo` storage currently points at.
///
/// @dev    Env vars:
///           PREVIEW_MODE   bool   default false (true = vm.prank instead of broadcast)
///           APPROVE_AMOUNT uint   default type(uint256).max
contract RewireSYAToPhlimboV2 is Script {
    // ==========================================
    //         LIVE MAINNET ADDRESSES
    // ==========================================

    // From server/deployments/mainnet-addresses.ts.
    address public constant SYA   = 0x3bBE928340c61a65Cb6C4a87B3fb59B6f3F7606a;
    address public constant USDC  = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant V1    = 0x3984eBC84d45a889dDAc595d13dc0aC2E54819F4;
    address public constant V2    = 0x6084a02C2Ac0127ddF1e617De257c61480A2AeE0;

    /// @notice Existing DepositView baked PhlimboEA (V1) as immutable in its
    /// constructor (deployed by DeployMainnetNFT.s.sol). Its read-only ABI is
    /// V2-compatible (no signature drift in pendingPhUSD / pendingStable /
    /// userInfo / phUSDPerSecond / rewardPerSecond), so we redeploy with V2
    /// baked in instead of touching the contract. DepositPageView is
    /// deprecated and intentionally NOT redeployed by this script.
    address public constant OLD_DEPOSIT_VIEW = 0x2Fdf77d4Ea75eFd48922B8E521612197FFbB564c;

    // SYA owner = ledger key at HD path m/44'/60'/46'/0/0 (same signer as story-049).
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    bool internal isPreview;
    uint256 internal approveAmount;

    // Runtime-captured.
    DepositView public newDepositView;

    function setUp() public {
        require(block.chainid == 1, "Wrong chain id - expected Mainnet (1)");
    }

    function run() external {
        console.log("==================================================");
        console.log(" RewireSYAToPhlimboV2 -- story-049 follow-up      ");
        console.log("==================================================");
        console.log("Chain id:              ", block.chainid);
        console.log("SYA:                   ", SYA);
        console.log("USDC:                  ", USDC);
        console.log("V1 (old phlimbo):      ", V1);
        console.log("V2 (new phlimbo):      ", V2);
        console.log("Owner (ledger signer): ", OWNER_ADDRESS);

        isPreview = vm.envOr("PREVIEW_MODE", false);
        approveAmount = vm.envOr("APPROVE_AMOUNT", type(uint256).max);
        console.log("PREVIEW_MODE:          ", isPreview);
        console.log("APPROVE_AMOUNT:        ", approveAmount);

        _preFlightChecks();

        if (isPreview) {
            console.log("");
            console.log("*** PREVIEW MODE -- impersonating owner via prank ***");
            console.log("");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        _step1_setPhlimboV2();
        _step2_approveV2();
        _step3_redeployDepositView();

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        _postStateAsserts();

        console.log("");
        console.log("==================================================");
        console.log(" SYA rewire complete (in-memory only if preview)  ");
        console.log("==================================================");
    }

    // ==========================================
    //              PRE-FLIGHT
    // ==========================================

    function _preFlightChecks() internal view {
        console.log("");
        console.log("=== Pre-flight checks ===");

        StableYieldAccumulator sya = StableYieldAccumulator(SYA);

        address syaOwner = sya.owner();
        address currentPhlimbo = sya.phlimbo();
        uint256 currentV1Allowance = IERC20Minimal(USDC).allowance(SYA, V1);
        uint256 currentV2Allowance = IERC20Minimal(USDC).allowance(SYA, V2);

        console.log("sya.owner():            ", syaOwner);
        console.log("sya.phlimbo():          ", currentPhlimbo);
        console.log("USDC allowance SYA->V1: ", currentV1Allowance);
        console.log("USDC allowance SYA->V2: ", currentV2Allowance);

        require(syaOwner == OWNER_ADDRESS, "SYA owner != OWNER_ADDRESS constant");
        // We expect the rewire has not yet happened. If it has, no-op the script.
        require(currentPhlimbo == V1, "SYA.phlimbo() is not V1 -- rewire may already be done");
    }

    // ==========================================
    // Step 1: setPhlimbo(V2)
    // ==========================================

    function _step1_setPhlimboV2() internal {
        console.log("");
        console.log("=== Step 1: SYA.setPhlimbo(V2) ===");
        StableYieldAccumulator(SYA).setPhlimbo(V2);
        console.log("setPhlimbo(", V2, ") sent");
    }

    // ==========================================
    // Step 2: approvePhlimbo(amount)
    // ==========================================

    function _step2_approveV2() internal {
        console.log("");
        console.log("=== Step 2: SYA.approvePhlimbo(APPROVE_AMOUNT) ===");
        StableYieldAccumulator(SYA).approvePhlimbo(approveAmount);
        console.log("approvePhlimbo(", approveAmount, ") sent");
    }

    // ==========================================
    // Step 3: redeploy DepositView pointing at V2
    // ==========================================

    function _step3_redeployDepositView() internal {
        console.log("");
        console.log("=== Step 3: deploy new DepositView(V2, PHUSD) ===");
        newDepositView = new DepositView(IPhlimbo(V2), IERC20(PHUSD));
        console.log("New DepositView deployed at:", address(newDepositView));
        console.log("Old DepositView (to retire): ", OLD_DEPOSIT_VIEW);
    }

    // ==========================================
    //            POST-STATE ASSERTS
    // ==========================================

    function _postStateAsserts() internal view {
        console.log("");
        console.log("=== Post-state asserts ===");

        StableYieldAccumulator sya = StableYieldAccumulator(SYA);
        address newPhlimbo = sya.phlimbo();
        uint256 v2Allowance = IERC20Minimal(USDC).allowance(SYA, V2);

        console.log("sya.phlimbo():            ", newPhlimbo);
        console.log("USDC allowance SYA->V2:   ", v2Allowance);
        console.log("newDepositView.phlimbo(): ", address(newDepositView.phlimbo()));
        console.log("newDepositView.phUSD():   ", address(newDepositView.phUSD()));

        require(newPhlimbo == V2, "post: sya.phlimbo() != V2");
        require(v2Allowance == approveAmount, "post: SYA->V2 allowance != APPROVE_AMOUNT");
        require(address(newDepositView.phlimbo()) == V2, "post: DepositView.phlimbo() != V2");
        require(address(newDepositView.phUSD()) == PHUSD, "post: DepositView.phUSD() != PHUSD");

        console.log("OK -- SYA repointed/approved + DepositView redeployed against V2");
    }
}
