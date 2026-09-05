// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@forge-std/Test.sol"; // for `deal` (StdCheats)

/// @title  PreviewBatchMint40 (mainnet-fork preview — NOT for broadcast)
/// @notice End-to-end fork dry-run of the NEW, post-incident BatchNFTMinter
///         (0x6e98…5071, deployed/seeded by ReplaceBatchNFTMinter.s.sol / story-050).
///
///         Proves two things the user asked for, against live mainnet state:
///           1. `batchMint(40, …)` actually mints 40 NFTs (ERC1155 id 4) to the
///              recipient, paying the dispatcher's ramping USDS price.
///           2. The recipient receives the "whale reward" — the nudge pot, the
///              new minter's full USDC balance (~50.42 USDC), paid out because
///              count (40) >= nudgeSize (40).
///
///         The deployer has no USDS, so we `deal` it the funding amount on the
///         fork ("steal" USDS by writing the balance slot — same approach as
///         TempSimulate40MintsIndex4.s.sol's `deal(USDS, USER, …)`).
///
///         SLIPPAGE PROTECTION (per user request): `minReward` defaults to the
///         EXACT current nudge pot, read live on the fork
///         (`USDC.balanceOf(NEW_MINTER)` at run time — observed 50_418_813 =
///         50.418813 USDC on 2026-05-30 at mainnet head). This is the tightest
///         possible floor: if anyone front-runs and drains/shrinks the pot, the
///         deliverable reward drops below `minReward` and `batchMint` reverts
///         `BatchMint__RewardBelowMinimum`, rolling back the 40 mints and the
///         USDS pull so the caller never pays mint costs for a sniped reward.
///         Override with `MIN_REWARD=<6dp-usdc-wei>` if a looser floor is wanted.
///
///         This script NEVER broadcasts — it pranks the deployer on a fork.
///
///         Run:
///           forge script script/PreviewBatchMint40.s.sol:PreviewBatchMint40 \
///             --fork-url $RPC_MAINNET -vv
///
///         Optional env overrides:
///           DEPLOYER=0x…           caller + NFT/reward recipient (default: ledger owner)
///           PAYMENT_AMOUNT=<wei>   USDS pulled upfront, surplus refunded (default 500e18)
///           USDS_FUND=<wei>        USDS dealt to the deployer (default = PAYMENT_AMOUNT)
///           MIN_REWARD=<6dp-wei>   nudge slippage floor (default = live pot, exact)

interface IERC20Like {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IERC1155Like {
    function balanceOf(address, uint256) external view returns (uint256);
}

interface IBatchNFTMinterLike {
    function batchMint(uint256 count, address recipient, uint256 paymentAmount, uint256 minReward)
        external
        returns (uint256 totalPaid);
    function nudgePaymentToken() external view returns (address);
    function nudgeSize() external view returns (uint256);
    function dispatcherIndex() external view returns (uint256);
    function tokenMinter() external view returns (address);
    function paused() external view returns (bool);
}

interface INFTMinterV2Like {
    function configs(uint256) external view returns (address dispatcher, uint256 price, uint256 growthBps, bool disabled);
}

contract PreviewBatchMint40 is Script, Test {
    // ===== Mainnet addresses (from server/deployments/mainnet-addresses.ts) =====
    address constant NEW_MINTER    = 0x6e9886AfDF07DD67dc70b8335E4e9DF14B445071; // new BatchNFTMinter (story-050)
    address constant NFT_MINTER_V2 = 0x39Af088408e815844c567037C157B31d48d2E10F; // nftsV2.NFTMinter
    address constant USDS          = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant USDC          = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Ledger owner / deployer used elsewhere in this repo (ReplaceBatchNFTMinter.OWNER).
    address constant DEFAULT_DEPLOYER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    uint256 constant MINT_COUNT  = 40;
    uint256 constant NFT_ID      = 4;  // ERC1155 id == dispatcher index 4 (the USDS path)
    // Default USDS pulled upfront. 40 mints at ~12.3726 USDS ramping +1bps/mint ≈ 495.88 USDS
    // (≈ the user's 495.8709 figure); batchMint refunds any surplus above its 1e6-wei dust
    // floor, so the buffer above is returned and `totalPaid` reports the true net cost.
    uint256 constant DEFAULT_PAYMENT = 500e18;

    function run() external {
        require(block.chainid == 1, "Mainnet fork required (use --fork-url $RPC_MAINNET)");

        address deployer  = vm.envOr("DEPLOYER", DEFAULT_DEPLOYER);
        uint256 payment   = vm.envOr("PAYMENT_AMOUNT", DEFAULT_PAYMENT);
        uint256 usdsFund  = vm.envOr("USDS_FUND", payment);
        require(usdsFund >= payment, "USDS_FUND must cover PAYMENT_AMOUNT");

        IBatchNFTMinterLike minter = IBatchNFTMinterLike(NEW_MINTER);

        // ---- The exact current nudgeReward = the live USDC pot, used as the slippage floor ----
        uint256 currentPot = IERC20Like(USDC).balanceOf(NEW_MINTER);
        uint256 minReward  = vm.envOr("MIN_REWARD", currentPot);

        console.log("==================================================");
        console.log("  PREVIEW: batchMint(40) on NEW BatchNFTMinter");
        console.log("==================================================");
        console.log("BatchNFTMinter:    ", NEW_MINTER);
        console.log("deployer/recipient:", deployer);
        console.log("");

        // ---- Pre-flight: config + the reward we expect ----
        console.log("--- config (live mainnet) ---");
        console.log("nudgePaymentToken: ", minter.nudgePaymentToken());
        console.log("nudgeSize:         ", minter.nudgeSize());
        console.log("dispatcherIndex:   ", minter.dispatcherIndex());
        console.log("tokenMinter:       ", minter.tokenMinter());
        console.log("paused:            ", minter.paused());
        require(minter.nudgePaymentToken() == USDC, "nudge token != USDC");
        require(minter.nudgeSize() == MINT_COUNT,   "nudgeSize != 40 (count would not clear the gate)");
        require(minter.dispatcherIndex() == NFT_ID, "dispatcherIndex != 4");
        require(!minter.paused(),                   "minter is paused");

        (address dispatcher, uint256 price,, bool disabled) = INFTMinterV2Like(NFT_MINTER_V2).configs(NFT_ID);
        require(dispatcher != address(0) && !disabled, "index-4 dispatcher missing/disabled");
        console.log("index-4 next price (USDS):", price);
        console.log("");

        console.log("--- nudge reward (whale reward) ---");
        console.log("current USDC pot (exact):", currentPot); // 6dp: e.g. 50418813 = 50.418813 USDC
        console.log("minReward (slippage floor):", minReward);
        require(currentPot > 0, "nudge pot is empty -- nothing to test");
        require(currentPot >= minReward, "current pot already below minReward floor");
        console.log("");

        // ---- Fund the deployer with USDS (it holds none) ----
        deal(USDS, deployer, usdsFund);
        console.log("--- funded deployer ---");
        console.log("USDS dealt:", IERC20Like(USDS).balanceOf(deployer));
        console.log("");

        // ---- Snapshot pre-state ----
        uint256 preNft       = IERC1155Like(NFT_MINTER_V2).balanceOf(deployer, NFT_ID);
        uint256 preUsdc      = IERC20Like(USDC).balanceOf(deployer);
        uint256 preUsds      = IERC20Like(USDS).balanceOf(deployer);

        // ---- Approve + batchMint ----
        vm.startPrank(deployer);
        IERC20Like(USDS).approve(NEW_MINTER, payment);
        uint256 totalPaid = minter.batchMint(MINT_COUNT, deployer, payment, minReward);
        vm.stopPrank();

        // ---- Snapshot post-state ----
        uint256 postNft       = IERC1155Like(NFT_MINTER_V2).balanceOf(deployer, NFT_ID);
        uint256 postUsdc      = IERC20Like(USDC).balanceOf(deployer);
        uint256 postUsds      = IERC20Like(USDS).balanceOf(deployer);
        uint256 potAfter      = IERC20Like(USDC).balanceOf(NEW_MINTER);

        uint256 nftMinted     = postNft - preNft;
        uint256 rewardGot     = postUsdc - preUsdc;
        uint256 usdsSpentNet  = preUsds - postUsds;

        console.log("--- result ---");
        console.log("NFTs minted (id 4):     ", nftMinted);
        console.log("USDS spent (net):       ", usdsSpentNet);   // ~495.88e18 -- the real cost of 40 mints
        console.log("batchMint totalPaid:    ", totalPaid);
        console.log("whale reward USDC got:  ", rewardGot);      // ~50.42 USDC
        console.log("nudge pot after (USDC): ", potAfter);       // should be ~0
        console.log("");

        // ---- Assertions: (1) NFTs minted, (2) whale reward received ----
        require(nftMinted == MINT_COUNT, "FAIL: did not mint exactly 40 NFTs");
        require(rewardGot == currentPot, "FAIL: reward received != current pot");
        require(rewardGot >= minReward,  "FAIL: reward below slippage floor");
        require(rewardGot >= 50_000_000, "FAIL: whale reward < ~50 USDC");
        require(potAfter == 0,           "FAIL: nudge pot not fully paid out");

        console.log("==================================================");
        console.log("  PREVIEW PASSED");
        console.log("  - 40 NFTs minted to recipient");
        console.log("  - whale reward delivered (~50 USDC), pot drained");
        console.log("==================================================");
    }
}
