// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";

/**
 * @title SetDiscountRate
 * @notice Placeholder - MockYieldStrategy yield rate is no longer applicable
 * @dev AutoPoolYieldStrategy generates yield via vault share price appreciation,
 *      not a configurable yield rate. Use SimulateYield.s.sol to add yield instead.
 */
contract SetDiscountRate is Script {
    function run() external pure {
        console.log("SetDiscountRate is no longer applicable.");
        console.log("AutoPoolYieldStrategy yield is simulated via MockAutoDOLA.addYield().");
        console.log("Use SimulateYield.s.sol instead.");
    }
}
