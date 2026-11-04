// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "@forge-std/Test.sol";
import {PauserV2MainnetBase} from "../script/helpers/PauserV2MainnetBase.sol";

/// @dev Exposes the broadcast gas-price guard. The env read is bypassed so tests never touch the
///      process-wide PAUSER_V2_GAS_PRICE_WEI.
contract GasPriceGuardHarness is PauserV2MainnetBase {
    function check(uint256 gasPriceWei) external view {
        _requireGasPriceHeadroom(gasPriceWei);
    }
}

/// @notice Audit run 49 L-03: a fixed legacy price below the base fee stalls the --slow broadcast, and the
///         stalled run cannot be replaced at the same price. The guard refuses to start without 2x headroom.
contract PauserV2GasPriceGuardTest is Test {
    GasPriceGuardHarness internal h;

    function setUp() public {
        h = new GasPriceGuardHarness();
    }

    function test_passes_whenGasPriceIsExactlyTwiceBaseFee() public {
        vm.fee(0.15 gwei);
        h.check(0.3 gwei);
    }

    function test_passes_atTodaysBaseFeeWithDefaultPrice() public {
        vm.fee(31445140); // mainnet block 26,337,583
        h.check(0.3 gwei);
    }

    function test_reverts_whenGasPriceBelowTwiceBaseFee() public {
        vm.fee(0.15 gwei + 1);
        vm.expectRevert(bytes("PAUSER_V2_GAS_PRICE_WEI < 2 x block.basefee: raise it (runbook: Gas price)"));
        h.check(0.3 gwei);
    }

    function test_reverts_whenBaseFeeSpikesAboveGasPrice() public {
        vm.fee(2.28 gwei); // the 90-day max the auditor sampled
        vm.expectRevert(bytes("PAUSER_V2_GAS_PRICE_WEI < 2 x block.basefee: raise it (runbook: Gas price)"));
        h.check(0.3 gwei);
    }

    function test_reverts_whenGasPriceUnset() public {
        vm.fee(0);
        vm.expectRevert(bytes("PAUSER_V2_GAS_PRICE_WEI unset or 0"));
        h.check(0);
    }
}
