// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "@forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NFTMinterV2} from "@yield-claim-nft/NFTMinterV2.sol";
import {NFTStakerPriceScaled} from "nft-staking/NFTStakerPriceScaled.sol";
import {MockRewardToken} from "../src/mocks/MockRewardToken.sol";
import {MockUSDS} from "../src/mocks/MockUSDS.sol";

/// @dev The local RatchetBatchNFTMinter's (`BatchNFTMinter`) 4-arg entrypoint.
interface IRatchetBatchMinterLocal {
    function batchMint(uint256 count, address recipient, uint256 paymentAmount, uint256 minReward)
        external
        returns (uint256 totalPaid);
}

/// @title  AcceptRatchetShutdownLocal
/// @notice Story 135. Anvil acceptance for DeployMocks Phase 11.19 (ratchet minting shut down after
///         `RATCHET_PRE_SHUTDOWN_MINTS` id-7 mints to the deployer), run against a live anvil after
///         `npm run dev` (`npm run ratchet-shutdown:acceptance-local`).
///         SIMULATION ONLY - never pass --broadcast: forge forks the anvil state, so the chain is left exactly as
///         DeployMocks left it, and `vm.warp` / `vm.prank` act on the fork only. Asserts:
///           1. the deployer (NFTMinterV2's owner) holds >= 5 id-7 NFTs and `configs(7).disabled`, with index 7
///              still the NudgeRatchet;
///           2. a funded `NFTMinterV2.mint(7, ...)` reverts "NFTMinterV2: dispatcher is disabled";
///           3. a funded `RatchetBatchNFTMinter.batchMint` reverts with the same reason (it loops `mint(7)`);
///           4. the deployer stakes its id-7 NFTs into RatchetNFTStaker, warps a day, claims a positive phUSD
///              reward, and unstakes them all back;
///           5. after a warp far past the staker's reward runway (no new hook debt accrues once minting stops),
///              the deployer can still stake, claim and unstake: exits survive an exhausted budget;
///           6. index 4 (UniPoolerV2) still mints: the disable is per index.
contract AcceptRatchetShutdownLocal is Script {
    uint256 internal constant RATCHET_INDEX = 7;
    uint256 internal constant UNI_POOLER_INDEX = 4;
    uint256 internal constant RATCHET_PRE_SHUTDOWN_MINTS = 5;
    bytes32 internal constant DISABLED_REASON = keccak256("NFTMinterV2: dispatcher is disabled");

    NFTMinterV2 internal nft;
    NFTStakerPriceScaled internal staker;
    IRatchetBatchMinterLocal internal batchMinter;
    MockRewardToken internal usdc;
    MockUSDS internal usds;
    IERC20 internal phUSD;
    address internal nudgeRatchet;
    address internal deployer;
    address internal prober = vm.addr(uint256(keccak256("story-135 ratchet-shutdown prober")));

    function run() external {
        require(block.chainid == 31337, "AcceptRatchetShutdownLocal: local only");
        _load();

        // 1. state left by Phase 11.19
        (address d7,,, bool disabled) = nft.configs(RATCHET_INDEX);
        require(d7 == nudgeRatchet, "index 7 is not the NudgeRatchet");
        require(disabled, "configs(7).disabled is false - Phase 11.19 did not run");
        uint256 held = nft.balanceOf(deployer, RATCHET_INDEX);
        require(held >= RATCHET_PRE_SHUTDOWN_MINTS, "deployer holds fewer than 5 id-7 NFTs");
        console.log("1. deployer id-7 NFTs:", held);
        console.log("   configs(7).disabled == true");

        // 2 + 3. funded mint(7) and batchMint both refused
        _probeMintsRefused();

        // 4. stake -> warp -> claim (> 0) -> unstake
        _stakeClaimUnstake(held);

        // 5. exhausted budget: exits still work
        _exitsSurviveExhaustedBudget(held);

        // 6. index 4 unaffected
        _index4StillMints();

        console.log("\nRATCHET SHUTDOWN ACCEPTANCE: ALL CHECKS PASSED (simulation; chain untouched)");
    }

    function _load() internal {
        string memory json = vm.readFile("server/deployments/progress.31337.json");
        nft = NFTMinterV2(_addr(json, "NFTMinterV2"));
        staker = NFTStakerPriceScaled(_addr(json, "RatchetNFTStaker"));
        batchMinter = IRatchetBatchMinterLocal(_addr(json, "RatchetBatchNFTMinter"));
        usdc = MockRewardToken(_addr(json, "MockUSDC"));
        usds = MockUSDS(_addr(json, "MockUSDS"));
        phUSD = IERC20(_addr(json, "MockPhUSD"));
        nudgeRatchet = _addr(json, "NudgeRatchet");
        deployer = nft.owner();
        require(address(staker.rewardToken()) == address(phUSD), "RatchetNFTStaker reward token is not phUSD");
        require(staker.dispatcherIndex() == RATCHET_INDEX, "RatchetNFTStaker is not on index 7");
        console.log("NFTMinterV2:", address(nft));
        console.log("RatchetNFTStaker:", address(staker));
        console.log("deployer (NFTMinterV2 owner):", deployer);
    }

    function _addr(string memory json, string memory key) internal pure returns (address) {
        return vm.parseJsonAddress(json, string.concat(".contracts.", key, ".address"));
    }

    function _requireDisabledRevert(bool ok, bytes memory ret, string memory what) internal pure {
        require(!ok, string.concat(what, " succeeded with ratchet minting disabled"));
        require(ret.length >= 68, string.concat(what, " reverted without a reason string"));
        bytes memory body = new bytes(ret.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = ret[i + 4];
        }
        require(
            keccak256(bytes(abi.decode(body, (string)))) == DISABLED_REASON,
            string.concat(what, " did not revert with 'NFTMinterV2: dispatcher is disabled'")
        );
    }

    function _probeMintsRefused() internal {
        (, uint256 p7,,) = nft.configs(RATCHET_INDEX);
        usdc.mint(prober, p7 * 4);
        vm.startPrank(prober);
        usdc.approve(address(nft), p7 * 2);
        usdc.approve(address(batchMinter), p7 * 2);
        (bool ok, bytes memory ret) =
            address(nft).call(abi.encodeWithSignature("mint(uint256,address)", RATCHET_INDEX, prober));
        _requireDisabledRevert(ok, ret, "NFTMinterV2.mint(7)");
        console.log("2. mint(7) reverted: NFTMinterV2: dispatcher is disabled");
        (ok, ret) = address(batchMinter).call(
            abi.encodeCall(IRatchetBatchMinterLocal.batchMint, (2, prober, p7 * 2, 0))
        );
        _requireDisabledRevert(ok, ret, "RatchetBatchNFTMinter.batchMint");
        vm.stopPrank();
        require(nft.balanceOf(prober, RATCHET_INDEX) == 0, "prober received an id-7 NFT");
        console.log("3. RatchetBatchNFTMinter.batchMint reverted: NFTMinterV2: dispatcher is disabled");
    }

    function _stakeClaimUnstake(uint256 n) internal {
        (uint256 staked0,) = staker.users(deployer);
        vm.startPrank(deployer);
        nft.setApprovalForAll(address(staker), true);
        staker.stake(n);
        vm.stopPrank();
        (uint256 staked1,) = staker.users(deployer);
        require(staked1 == staked0 + n, "stake did not credit the position");
        require(nft.balanceOf(deployer, RATCHET_INDEX) == 0, "stake did not take the NFTs");

        vm.warp(block.timestamp + 1 days);
        uint256 ph0 = phUSD.balanceOf(deployer);
        vm.prank(deployer);
        staker.claim();
        uint256 claimed = phUSD.balanceOf(deployer) - ph0;
        require(claimed > 0, "claim paid no phUSD after a day staked");
        console.log("4. staked / claimed phUSD after 1 day:", n, claimed);

        vm.prank(deployer);
        staker.unstake(staked1);
        require(nft.balanceOf(deployer, RATCHET_INDEX) == staked1, "unstake did not return the NFTs");
        (uint256 staked2,) = staker.users(deployer);
        require(staked2 == 0, "unstake left a position");
        console.log("   unstaked back to the deployer:", staked1);
    }

    function _exitsSurviveExhaustedBudget(uint256 n) internal {
        vm.prank(deployer);
        staker.stake(n);
        uint256 runway = staker.runwaySeconds();
        vm.warp(block.timestamp + runway + 3650 days);
        vm.prank(deployer);
        staker.claim();
        uint256 budget = staker.totalBudget();
        console.log("5. warped past the runway (s) + 10y; remaining budget:", runway, budget);
        uint256 ph0 = phUSD.balanceOf(deployer);
        vm.prank(deployer);
        staker.claim();
        require(phUSD.balanceOf(deployer) == ph0, "exhausted budget still paid on a second claim");
        vm.prank(deployer);
        staker.unstake(n);
        require(nft.balanceOf(deployer, RATCHET_INDEX) == n, "exhausted budget: unstake did not return the NFTs");
        console.log("   claim + unstake succeeded with the budget exhausted");
    }

    function _index4StillMints() internal {
        (, uint256 p4,,) = nft.configs(UNI_POOLER_INDEX);
        usds.mint(prober, p4);
        uint256 before = nft.balanceOf(prober, UNI_POOLER_INDEX);
        vm.startPrank(prober);
        usds.approve(address(nft), p4);
        nft.mint(UNI_POOLER_INDEX, prober);
        vm.stopPrank();
        require(nft.balanceOf(prober, UNI_POOLER_INDEX) == before + 1, "index 4 did not mint");
        console.log("6. index 4 still mints");
    }
}
