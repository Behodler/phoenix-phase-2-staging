// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockKendu
 * @notice Mock Kendu token (18 decimals) used as a third nudge-reward asset on the
 *         local anvil chain, alongside USDC and phUSD.
 * @dev Mirrors `MockSCX` minus the `IBurnable` surface — nothing burns Kendu — and
 *      deliberately has NO transfer fee: both `NudgeStreamer` and
 *      `BatchNFTMinterMultiToken` assume `transfer(x)` delivers exactly `x`, so a
 *      fee-on-transfer mock here would silently break stream accounting.
 *      Local testing only: `mint` is unrestricted.
 */
contract MockKendu is ERC20 {
    constructor() ERC20("Mock Kendu", "mKENDU") {
        // Mint 1 million KENDU (18 decimals) to deployer for testing
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }

    /**
     * @notice Allow anyone to mint for testing purposes
     * @dev Local dev only — the real Kendu token has restricted minting.
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
