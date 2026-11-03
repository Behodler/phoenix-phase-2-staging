// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "@forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {NFTBonfire} from "@yield-claim-nft/NFTBonfire.sol";
import {NFTMinterV2} from "@yield-claim-nft/NFTMinterV2.sol";
import {Antimatter} from "antimatter/Antimatter.sol";
import {Pauser} from "@pauser/Pauser.sol";
import {PauserV2} from "@pauser/PauserV2.sol";
import {IPausedView} from "@pauser/interfaces/IPausedView.sol";
import {MockEYE} from "../src/mocks/MockEYE.sol";
import {NFTBonfireLocalWiring} from "../script/helpers/NFTBonfireLocalWiring.sol";
import {PauserV2LocalMigration} from "../script/helpers/PauserV2LocalMigration.sol";

/// @title  PauserV2LocalMigrationTest
/// @notice Story 127. Builds a V1 `Pauser` with REAL Phoenix registrants (NFTMinterV2, Antimatter,
///         NFTBonfire wired through `NFTBonfireLocalWiring`, plus a second NFTMinterV2 standing in for
///         the retired StableStaker V1), rotates them onto `PauserV2` through `PauserV2LocalMigration`
///         - the SAME library DeployMocks Phase 11.16 calls - and then runs the local smoke: an EYE
///         holder pauses everything through V2, the owner unpauses everything. Nothing here connects
///         to a live :8545; `script/SmokePauserV2Local.s.sol` runs the same round-trip against anvil.
contract PauserV2LocalMigrationTest is Test {
    Pauser internal v1;
    PauserV2 internal v2;
    MockEYE internal eye;

    NFTMinterV2 internal nftMinter;
    Antimatter internal antimatter;
    NFTBonfire internal bonfire;
    NFTMinterV2 internal retired;

    address internal owner = address(this);
    address internal eyeHolder = makeAddr("eyeHolder");

    function setUp() public {
        eye = new MockEYE();
        v1 = new Pauser(address(eye));

        nftMinter = new NFTMinterV2(owner);
        antimatter = new Antimatter(owner);
        retired = new NFTMinterV2(owner);

        nftMinter.setPauser(address(v1));
        v1.register(address(nftMinter));
        retired.setPauser(address(v1));
        v1.register(address(retired));
        antimatter.setPauser(address(v1));
        v1.register(address(antimatter));

        bonfire = NFTBonfireLocalWiring.deploy(owner, nftMinter, antimatter);
        NFTBonfireLocalWiring.wire(bonfire, nftMinter, antimatter, v1);

        v2 = new PauserV2(address(eye));
    }

    function _live() internal view returns (address[3] memory) {
        return [address(nftMinter), address(antimatter), address(bonfire)];
    }

    function _paused(address c) internal view returns (bool) {
        return IPausedView(c).paused();
    }

    // ---------------------------------------------------------------- rotation

    function test_migrate_rotatesEveryLiveRegistrant_inV1Order_excludingRetired() public {
        uint256 migrated = PauserV2LocalMigration.migrate(v1, v2, address(retired));
        assertEq(migrated, 3, "migrated count");

        address[] memory onV2 = v2.getPausableContracts();
        assertEq(onV2.length, 3, "V2 count");
        // V1 order is nftMinter, retired, antimatter, bonfire; V2 is that minus retired.
        assertEq(onV2[0], address(nftMinter));
        assertEq(onV2[1], address(antimatter));
        assertEq(onV2[2], address(bonfire));

        address[3] memory live = _live();
        for (uint256 i = 0; i < live.length; i++) {
            assertEq(NFTMinterV2(live[i]).pauser(), address(v2), "live registrant pauser is V2");
        }
        assertFalse(v2.isRegistered(address(retired)), "retired not on V2");
        assertEq(retired.pauser(), address(v1), "retired stays on V1");
        assertEq(v1.getPausableContracts().length, 4, "V1 left untouched (orphaned)");
    }

    function test_health_isClean_afterMigration() public {
        PauserV2LocalMigration.migrate(v1, v2, address(retired));
        PauserV2LocalMigration.requireHealthy(v2);
    }

    function test_migrate_isIdempotent() public {
        PauserV2LocalMigration.migrate(v1, v2, address(retired));
        uint256 again = PauserV2LocalMigration.migrate(v1, v2, address(retired));
        assertEq(again, 3);
        assertEq(v2.getPausableContracts().length, 3, "no duplicate registration");
    }

    function test_migrate_reverts_whenRetiredIsNotOnV1() public {
        NFTMinterV2 stranger = new NFTMinterV2(owner);
        vm.expectRevert(bytes("story-127: retired registrant is not on Pauser V1"));
        this.migrateExternal(address(stranger));
    }

    function test_requireMigrated_reverts_whenAV1RegistrantIsMissingFromV2() public {
        PauserV2LocalMigration.migrate(v1, v2, address(retired));
        v2.unregister(address(antimatter));
        vm.expectRevert(bytes("story-127: PauserV2 registrant count != V1 count - 1"));
        this.requireMigratedExternal();
    }

    function test_requireHealthy_reverts_whenARegistrantIsAlreadyPaused() public {
        PauserV2LocalMigration.migrate(v1, v2, address(retired));
        vm.prank(address(v2));
        nftMinter.pause();
        vm.expectRevert(bytes("story-127: PauserV2 health: alreadyPaused is not empty"));
        this.requireHealthyExternal();
    }

    function test_requireHealthy_reverts_whenARegistrantLeftV2() public {
        PauserV2LocalMigration.migrate(v1, v2, address(retired));
        antimatter.setPauser(owner);
        vm.expectRevert(bytes("story-127: PauserV2 health: notPauser is not empty"));
        this.requireHealthyExternal();
    }

    // ---------------------------------------------------------------- smoke: pause / unpause round-trip

    function test_smoke_eyeHolderPausesEverything_ownerUnpausesEverything() public {
        PauserV2LocalMigration.migrate(v1, v2, address(retired));
        address[3] memory live = _live();

        uint256 burn = v2.eyeBurnAmount();
        eye.mint(eyeHolder, burn);
        uint256 supplyBefore = eye.totalSupply();

        vm.startPrank(eyeHolder);
        eye.approve(address(v2), burn);
        v2.pause();
        vm.stopPrank();

        assertEq(eye.balanceOf(eyeHolder), 0, "EYE pulled from holder");
        assertEq(eye.totalSupply(), supplyBefore - burn, "EYE burned");
        for (uint256 i = 0; i < live.length; i++) {
            assertTrue(_paused(live[i]), "registrant paused by V2");
        }
        assertFalse(_paused(address(retired)), "retired (on V1) untouched by V2");

        v2.unpause();
        for (uint256 i = 0; i < live.length; i++) {
            assertFalse(_paused(live[i]), "registrant unpaused by owner");
        }
    }

    function test_smoke_unpause_isOwnerOnly() public {
        PauserV2LocalMigration.migrate(v1, v2, address(retired));
        vm.prank(eyeHolder);
        vm.expectRevert();
        v2.unpause();
    }

    // ---------------------------------------------------------------- external shims for expectRevert

    function migrateExternal(address retiredAddr) external {
        PauserV2LocalMigration.migrate(v1, v2, retiredAddr);
    }

    function requireMigratedExternal() external view {
        PauserV2LocalMigration.requireMigrated(v1, v2, address(retired));
    }

    function requireHealthyExternal() external view {
        PauserV2LocalMigration.requireHealthy(v2);
    }
}
