// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@forge-std/Test.sol";

/// @dev TEMP -- delete after the index-4 mint path has been verified.

interface IERC20Like {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IERC1155Like {
    function balanceOf(address, uint256) external view returns (uint256);
}

interface INFTMinterV2Like {
    function mint(uint256 index, address recipient) external returns (bool);
    function configs(uint256) external view returns (address, uint256, uint256, bool);
    function setDispatcherDisabled(uint256, bool) external;
}

interface IDispatcherMinter {
    function setMinter(address) external;
}

interface IBalancerPoolerV2Like {
    function batchMinter() external view returns (address);
    function batchDonationSize() external view returns (uint256);
    function usdc() external view returns (address);
    function setBatchDonationSize(uint256) external;
    function sUSDS() external view returns (address);
    function pool(uint256 minBPT, uint256 minUSDC) external;
}

/**
 * @title  TempSimulate40MintsIndex4 (TEMP -- DELETE ME)
 * @notice Mainnet-fork-only simulation of 40 sequential mints at NFTMinterV2
 *         dispatcher index 4 using the new BalancerPoolerV2 + batchMinter
 *         configuration left by story-048 + follow-ups. Verifies the full
 *         mint path before broadcasting the owner-side fixes for real.
 *
 *         Performs (all via prank, never broadcast):
 *           1. setDispatcherDisabled(4, false)            (pending owner fix)
 *           2. NEW_POOLER.setMinter(NFT_MINTER_V2)         (pending owner fix)
 *           3. deal 482 USDS to USER
 *           4. USER approves NFT_MINTER_V2
 *           5. mint(4, USER) x 40, logging price and asserting NFT bal increments
 *
 *         Run:
 *           forge script script/TempSimulate40MintsIndex4.s.sol \
 *             --fork-url $RPC_MAINNET -vv
 */
contract TempSimulate40MintsIndex4 is Script, Test {
    address constant USER          = 0x3E9003DA2ad56A7cc677b6b414AD475A0231Eb28;
    address constant USDS          = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant NFT_MINTER_V2 = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address constant NEW_POOLER    = 0x26F89f4B46eB164303985795ee20b15BB1Edb38A;
    address constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    uint256 constant MINT_COUNT    = 40;
    uint256 constant USDS_FUND     = 482e18;

    function run() external {
        require(block.chainid == 1, "Mainnet fork required");

        console.log("======================================");
        console.log("  TEMP SIMULATE 40 MINTS @ INDEX 4");
        console.log("======================================");
        console.log("USER:          ", USER);
        console.log("NFT_MINTER_V2: ", NFT_MINTER_V2);
        console.log("NEW_POOLER:    ", NEW_POOLER);
        console.log("");

        // ====== Apply pending owner fixes via prank ======
        console.log("--- Applying pending owner fixes (prank) ---");
        vm.startPrank(OWNER_ADDRESS);
        INFTMinterV2Like(NFT_MINTER_V2).setDispatcherDisabled(4, false);
        IDispatcherMinter(NEW_POOLER).setMinter(NFT_MINTER_V2);
        IBalancerPoolerV2Like(NEW_POOLER).setBatchDonationSize(10);
        vm.stopPrank();

        (address d4, uint256 startPrice, uint256 growth, bool disabled) =
            INFTMinterV2Like(NFT_MINTER_V2).configs(4);
        require(d4 == NEW_POOLER, "configs(4).dispatcher != NEW_POOLER");
        require(!disabled, "configs(4).disabled still true");
        console.log("Start price (USDS):", startPrice);
        console.log("Growth (bps):      ", growth);

        // ====== Fund user with USDS ======
        deal(USDS, USER, USDS_FUND);
        console.log("USDS dealt:        ", IERC20Like(USDS).balanceOf(USER));

        uint256 startNftBal = IERC1155Like(NFT_MINTER_V2).balanceOf(USER, 4);
        console.log("Pre-mint NFT bal:  ", startNftBal);

        // ====== Snapshot batchMinter wiring + pre-balances ======
        address batchMinter      = IBalancerPoolerV2Like(NEW_POOLER).batchMinter();
        uint256 batchDonationSize = IBalancerPoolerV2Like(NEW_POOLER).batchDonationSize();
        address usdc             = IBalancerPoolerV2Like(NEW_POOLER).usdc();
        require(batchMinter != address(0), "batchMinter unset on NEW_POOLER");
        require(usdc != address(0),         "usdc unset on NEW_POOLER");
        if (batchDonationSize == 0) {
            console.log("WARNING: batchDonationSize == 0 -- donation phase is OFF; batchMinter will not receive USDC");
        }

        uint256 preBatchUSDC   = IERC20Like(usdc).balanceOf(batchMinter);
        uint256 prePoolerUSDS  = IERC20Like(USDS).balanceOf(NEW_POOLER);
        console.log("batchMinter:           ", batchMinter);
        console.log("batchDonationSize (%): ", batchDonationSize);
        console.log("USDC token:            ", usdc);
        console.log("batchMinter USDC pre:  ", preBatchUSDC);
        console.log("pooler   USDS  pre:    ", prePoolerUSDS);
        console.log("");

        // ====== Approve + mint loop ======
        vm.startPrank(USER);
        IERC20Like(USDS).approve(NFT_MINTER_V2, type(uint256).max);

        uint256 totalSpent = 0;
        for (uint256 i = 0; i < MINT_COUNT; i++) {
            (, uint256 priceNow,,) = INFTMinterV2Like(NFT_MINTER_V2).configs(4);
            totalSpent += priceNow;

            INFTMinterV2Like(NFT_MINTER_V2).mint(4, USER);

            if (i == 0 || (i + 1) % 10 == 0) {
                console.log("  mint #", i + 1);
                console.log("    price:", priceNow);
            }
        }
        vm.stopPrank();

        // ====== Verify ======
        uint256 endNftBal = IERC1155Like(NFT_MINTER_V2).balanceOf(USER, 4);
        uint256 remainingUSDS = IERC20Like(USDS).balanceOf(USER);

        // ====== Trigger pool() to fire the donation phase ======
        address sUSDSAddr = IBalancerPoolerV2Like(NEW_POOLER).sUSDS();
        uint256 poolerSUSDSPreP = IERC20Like(sUSDSAddr).balanceOf(NEW_POOLER);
        console.log("");
        console.log("--- Calling pool() from authorised pooler ---");
        console.log("pooler sUSDS pre-pool(): ", poolerSUSDSPreP);

        vm.startPrank(OWNER_ADDRESS);
        IBalancerPoolerV2Like(NEW_POOLER).pool(0, 0);
        vm.stopPrank();

        uint256 poolerSUSDSPostP = IERC20Like(sUSDSAddr).balanceOf(NEW_POOLER);
        console.log("pooler sUSDS post-pool():", poolerSUSDSPostP);

        uint256 postBatchUSDC  = IERC20Like(usdc).balanceOf(batchMinter);
        uint256 postPoolerUSDS = IERC20Like(USDS).balanceOf(NEW_POOLER);

        console.log("");
        console.log("--- Result ---");
        console.log("Final NFT bal (id 4):", endNftBal);
        console.log("NFTs minted:         ", endNftBal - startNftBal);
        console.log("Total USDS spent:    ", totalSpent);
        console.log("Remaining USDS:      ", remainingUSDS);
        console.log("");
        console.log("--- batchMinter top-up ---");
        console.log("batchMinter USDC post: ", postBatchUSDC);
        console.log("batchMinter USDC delta:", postBatchUSDC - preBatchUSDC);
        console.log("pooler   USDS  post:   ", postPoolerUSDS);

        require(endNftBal - startNftBal == MINT_COUNT, "NFT mint count mismatch");
        require(totalSpent <= USDS_FUND, "Spent exceeded funded amount (impossible)");
        if (batchDonationSize > 0) {
            require(
                postBatchUSDC > preBatchUSDC,
                "batchMinter received no USDC across 40 mints -- donation phase did not fire"
            );
            console.log("OK -- batchMinter received USDC");
        } else {
            console.log("SKIP -- batchDonationSize == 0 (donation phase off); no batchMinter topup expected");
        }

        console.log("");
        console.log("======================================");
        console.log("  SIMULATION SUCCEEDED");
        console.log("======================================");
    }
}
