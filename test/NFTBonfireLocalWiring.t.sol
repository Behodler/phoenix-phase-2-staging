// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "@forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {NFTBonfire} from "@yield-claim-nft/NFTBonfire.sol";
import {NFTMinterV2} from "@yield-claim-nft/NFTMinterV2.sol";
import {GatherV2} from "@yield-claim-nft/dispatchers/GatherV2.sol";
import {Antimatter} from "antimatter/Antimatter.sol";
import {Pauser} from "@pauser/Pauser.sol";
import {MockEYE} from "../src/mocks/MockEYE.sol";
import {NFTBonfireLocalWiring} from "../script/helpers/NFTBonfireLocalWiring.sol";

/// @dev Minimal ERC20 used only as GatherV2's token so a dispatcher index exists to mint from.
contract BonfireWiringMockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
}

/// @title  NFTBonfireLocalWiringTest
/// @notice Story 125. Deploys a REAL NFTMinterV2, Antimatter, Pauser and NFTBonfire in-process and
///         wires them through `NFTBonfireLocalWiring` - the SAME library calls DeployMocks Phase 11.15
///         makes, so the order (burner, AM minter, pauser + register, cap, rate LAST) is the anvil one.
///         Nothing here connects to a live :8545.
contract NFTBonfireLocalWiringTest is Test {
    uint256 internal constant NFT_ID = 1;

    NFTMinterV2 internal nftMinter;
    Antimatter internal antimatter;
    Pauser internal pauser;
    MockEYE internal eye;
    NFTBonfire internal bonfire;

    address internal owner = address(this);
    address internal holder = makeAddr("holder");
    address internal stranger = makeAddr("stranger");
    address internal nftMintAuth = makeAddr("nftMintAuth");

    function setUp() public {
        vm.warp(1_700_000_000);

        nftMinter = new NFTMinterV2(owner);
        GatherV2 gather = new GatherV2(address(new BonfireWiringMockERC20()), address(0xFEED), owner);
        nftMinter.registerDispatcher(address(gather), 1e18, 0); // index 1
        nftMinter.setAuthorizedMinter(nftMintAuth, true);
        vm.startPrank(nftMintAuth);
        nftMinter.mintFor(NFT_ID, holder);
        nftMinter.mintFor(NFT_ID, holder);
        vm.stopPrank();

        antimatter = new Antimatter(owner);
        eye = new MockEYE();
        pauser = new Pauser(address(eye));

        bonfire = NFTBonfireLocalWiring.deploy(owner, nftMinter, antimatter);
    }

    function _wire() internal {
        NFTBonfireLocalWiring.wire(bonfire, nftMinter, antimatter, pauser);
    }

    // ---------------------------------------------------------------- wiring end state

    function test_wiring_endState() public {
        _wire();
        assertTrue(nftMinter.authorizedBurners(address(bonfire)), "burner");
        assertTrue(antimatter.isApprovedMinter(address(bonfire)), "AM minter");
        assertEq(bonfire.pauser(), address(pauser), "pauser");
        assertTrue(pauser.isRegistered(address(bonfire)), "registered");
        assertEq(bonfire.maxPayout(), 100e18, "cap");
        assertEq(bonfire.ratePerDay(), 10e18, "rate");
        assertEq(NFTBonfireLocalWiring.MAX_PAYOUT, 100e18);
        assertEq(NFTBonfireLocalWiring.RATE_PER_DAY, 10e18);
        assertEq(bonfire.owner(), owner);
    }

    // ---------------------------------------------------------------- rate 0

    function test_burn_revertsBurningDisabled_whileRateZero() public {
        vm.prank(holder);
        vm.expectRevert(NFTBonfire.NFTBonfire__BurningDisabled.selector);
        bonfire.burn(NFT_ID, 0);
    }

    // ---------------------------------------------------------------- accrual + cap

    function test_pendingPayout_oneDay_isRate() public {
        _wire();
        vm.warp(block.timestamp + 1 days);
        assertEq(bonfire.pendingPayout(), 10e18);
    }

    function test_pendingPayout_thirtyDays_isCapped() public {
        _wire();
        vm.warp(block.timestamp + 30 days);
        assertEq(bonfire.pendingPayout(), 100e18);
    }

    // ---------------------------------------------------------------- burn

    function test_burn_mintsPotToBurner_burnsOneNft_resetsPot() public {
        _wire();
        vm.warp(block.timestamp + 1 days);

        uint256 nftBefore = nftMinter.balanceOf(holder, NFT_ID);
        uint256 amBefore = antimatter.balanceOf(holder);

        vm.prank(holder);
        uint256 payout = bonfire.burn(NFT_ID, 10e18);

        assertEq(payout, 10e18, "payout");
        assertEq(antimatter.balanceOf(holder), amBefore + 10e18, "AM minted to burner");
        assertEq(nftMinter.balanceOf(holder, NFT_ID), nftBefore - 1, "one NFT burned");
        assertEq(bonfire.pendingPayout(), 0, "pot reset");
        assertEq(bonfire.accruedStored(), 0, "stored pot reset");
    }

    function test_burn_nonHolderCannotBurn() public {
        _wire();
        vm.warp(block.timestamp + 1 days);
        assertEq(nftMinter.balanceOf(stranger, NFT_ID), 0);

        vm.prank(stranger);
        // NFTBonfire.burn has no holder check; NFTMinterV2._burn -> OZ ERC1155._update reverts.
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, stranger, 0, 1, NFT_ID)
        );
        bonfire.burn(NFT_ID, 0);

        assertEq(antimatter.balanceOf(stranger), 0);
        assertEq(bonfire.pendingPayout(), 10e18, "pot untouched by the failed burn");
    }

    // ---------------------------------------------------------------- global pause

    function test_globalPause_blocksBurns_unpauseRestores() public {
        _wire();
        vm.warp(block.timestamp + 1 days);

        // Anyone holding the EYE burn amount can trigger the global pause.
        eye.mint(stranger, pauser.eyeBurnAmount());
        vm.startPrank(stranger);
        eye.approve(address(pauser), pauser.eyeBurnAmount());
        pauser.pause();
        vm.stopPrank();
        assertTrue(bonfire.paused(), "bonfire paused by the global Pauser");

        vm.prank(holder);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        bonfire.burn(NFT_ID, 0);

        pauser.unpause(); // owner-only
        assertFalse(bonfire.paused());

        vm.prank(holder);
        uint256 payout = bonfire.burn(NFT_ID, 0);
        assertEq(payout, 10e18, "accrual continued through the pause");
    }

    // ---------------------------------------------------------------- order guard

    /// @dev The library refuses to set the cap once a rate is live (audit L-29: never change the cap
    ///      while burns are live). Proves the read-back gate is real, not decorative.
    function test_wire_revertsIfRateAlreadyLive() public {
        bonfire.setRatePerDay(1e18);
        vm.expectRevert(bytes("story-125: rate must still be 0 when the cap is set"));
        this.wireExternal();
    }

    function wireExternal() external {
        _wire();
    }
}
