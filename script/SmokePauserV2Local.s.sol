// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "@forge-std/Script.sol";
import {PauserV2} from "@pauser/PauserV2.sol";
import {IPausable} from "@pauser/interfaces/IPausable.sol";
import {MockEYE} from "../src/mocks/MockEYE.sol";
import {PauserV2LocalMigration} from "./helpers/PauserV2LocalMigration.sol";

/// @title  SmokePauserV2Local
/// @notice Story 127. Local smoke for DeployMocks Phase 11.16, run against a live anvil after
///         `npm run dev` (`npm run pauser-v2:smoke-local`). SIMULATION ONLY - never pass --broadcast:
///         it forks the anvil state, so the chain is left exactly as DeployMocks left it.
///
///         Resolves the `Pauser` address key from `server/deployments/progress.31337.json` (it must be
///         PauserV2 after Phase 11.16), asserts `health()` is clean, then:
///           1. a fresh EYE holder approves and calls `pause()` -> every registrant reports paused;
///           2. the owner calls `unpause()` -> every registrant reports unpaused.
///         Registrants without a `paused()` getter are reported and checked through their pauser only.
contract SmokePauserV2Local is Script {
    function run() external {
        require(block.chainid == 31337, "SmokePauserV2Local: local only");

        string memory json = vm.readFile("server/deployments/progress.31337.json");
        PauserV2 v2 = PauserV2(vm.parseJsonAddress(json, ".contracts.Pauser.address"));
        MockEYE eye = MockEYE(vm.parseJsonAddress(json, ".contracts.MockEYE.address"));
        require(address(v2).code.length > 0, "SmokePauserV2Local: no code at the Pauser key");
        require(v2.eyeToken() == address(eye), "SmokePauserV2Local: Pauser key is not PauserV2 over MockEYE");

        PauserV2LocalMigration.requireHealthy(v2);
        address[] memory regs = v2.getPausableContracts();
        require(regs.length > 0, "SmokePauserV2Local: PauserV2 has no registrants");
        console.log("PauserV2:", address(v2));
        console.log("registrants:", regs.length);

        for (uint256 i = 0; i < regs.length; i++) {
            require(IPausable(regs[i]).pauser() == address(v2), "SmokePauserV2Local: registrant pauser is not V2");
            (bool ok, bool isPaused) = _paused(regs[i]);
            require(!ok || !isPaused, "SmokePauserV2Local: registrant already paused before the smoke");
        }

        // 1. EYE holder pauses everything.
        address holder = vm.addr(uint256(keccak256("pauserV2-smoke-eye-holder")));
        uint256 burn = v2.eyeBurnAmount();
        eye.mint(holder, burn);
        uint256 supplyBefore = eye.totalSupply();
        vm.startPrank(holder);
        eye.approve(address(v2), burn);
        v2.pause();
        vm.stopPrank();
        require(eye.totalSupply() == supplyBefore - burn, "SmokePauserV2Local: EYE not burned");

        uint256 noGetter;
        for (uint256 i = 0; i < regs.length; i++) {
            (bool ok, bool isPaused) = _paused(regs[i]);
            if (!ok) {
                noGetter++;
                console.log("  no paused() getter (pause() was still called):", regs[i]);
                continue;
            }
            require(isPaused, "SmokePauserV2Local: registrant NOT paused by PauserV2.pause()");
        }
        console.log("pause(): every registrant with a paused() getter reports paused; without getter:", noGetter);

        // 2. Owner unpauses everything.
        vm.prank(v2.owner());
        v2.unpause();
        for (uint256 i = 0; i < regs.length; i++) {
            (bool ok, bool isPaused) = _paused(regs[i]);
            if (!ok) continue;
            require(!isPaused, "SmokePauserV2Local: registrant still paused after owner unpause()");
        }
        PauserV2LocalMigration.requireHealthy(v2);
        console.log("unpause(): every registrant reports unpaused; health() clean. SMOKE PASSED");
    }

    function _paused(address c) internal view returns (bool ok, bool isPaused) {
        (bool success, bytes memory ret) = c.staticcall(abi.encodeWithSignature("paused()"));
        if (!success || ret.length < 32) return (false, false);
        uint256 word = abi.decode(ret, (uint256));
        if (word > 1) return (false, false);
        return (true, word == 1);
    }
}
