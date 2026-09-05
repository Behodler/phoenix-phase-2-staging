// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {Vm} from "@forge-std/Vm.sol";

/**
 * @title AddressLoader
 * @notice Resolves locally deployed contract addresses for the anvil interaction scripts.
 *
 * @dev STORY 079 — THESE WERE HARDCODED AND WERE WRONG.
 *
 *      Every getter used to return a literal captured from some past deploy. Anvil addresses are
 *      derived from the deployer's nonce, so they shift whenever `DeployMocks.s.sol` gains or
 *      loses a deployment — which it does most sprints. `getPhlimbo()` had drifted to an address
 *      holding no code, and the scripts built on it had been failing silently long before the
 *      PhlimboV3 cutover; adding V3 only made a second, louder problem out of the same root
 *      cause. Reading `server/deployments/local.json` — the artifact `extract:addresses` writes
 *      immediately after every deploy, and the same file the UI consumes — makes drift
 *      structurally impossible rather than something to remember to fix.
 *
 *      Consequence: the getters are `view`, not `pure`, and a script that calls them requires
 *      `npm run extract:addresses` to have run for the current deploy. `npm run dev` chains the
 *      two, so this holds by default.
 */
library AddressLoader {
    /// @dev The standard forge cheatcode address. Declared locally because a library cannot
    ///      inherit `Script`'s `vm`.
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string private constant LOCAL_DEPLOYMENTS = "server/deployments/local.json";

    /**
     * @notice Resolves one contract's address from the extracted local deployment file.
     * @dev Reverts with an actionable message rather than returning `address(0)`: a zero address
     *      silently turns every downstream call into a no-op-looking failure, which is exactly
     *      the class of bug the hardcoded constants produced.
     */
    function get(string memory name) internal view returns (address addr) {
        // ANVIL ONLY, ENFORCED. `local.json` is chain 31337's address book and carries no chain
        // discriminator, so a script that imported this library and ran against a fork or a real
        // network would silently receive anvil addresses — on mainnet that is an approve/transfer
        // to a stranger's contract. Cheap to assert, catastrophic to omit; the getters are
        // deliberately NOT parameterised by chain, because the answer for any other chain is
        // "use the mainnet address book", not "read a different file".
        require(
            block.chainid == 31337,
            "AddressLoader is anvil-only (chain 31337) - it reads server/deployments/local.json; use the mainnet address constants instead"
        );
        string memory json = vm.readFile(LOCAL_DEPLOYMENTS);
        string memory key = string.concat(".contracts.", name, ".address");
        require(
            vm.keyExistsJson(json, key),
            string.concat(
                "AddressLoader: '", name, "' not in server/deployments/local.json - run `npm run extract:addresses`"
            )
        );
        addr = vm.parseJsonAddress(json, key);
        require(addr != address(0), string.concat("AddressLoader: '", name, "' resolved to the zero address"));
    }

    // ========== Token Addresses ==========

    function getPhUSD() internal view returns (address) {
        return get("PhUSD");
    }

    function getUSDC() internal view returns (address) {
        return get("USDC");
    }

    function getRewardToken() internal view returns (address) {
        return getUSDC();
    }

    // ========== Core Contract Addresses ==========

    function getMinter() internal view returns (address) {
        return get("PhusdStableMinter");
    }

    /**
     * @notice The WOUND-DOWN PhlimboV2 incumbent, published under the legacy `PhlimboEA` key.
     * @dev STORY 079: THIS IS ALMOST CERTAINLY NOT WHAT YOU WANT. After the cutover rehearsal
     *      this contract holds zero stake, emits at APY 0 and has had its phUSD mint authority
     *      revoked. It is retained only so a late staker could exit, mirroring mainnet. The live
     *      farm — the one users stake into and the one the yield funnel feeds — is
     *      `getPhlimboV3()`.
     */
    function getPhlimboV2() internal view returns (address) {
        return get("PhlimboEA");
    }

    /// @notice The live post-cutover farm. Use this for staking, withdrawing, claiming and pool reads.
    function getPhlimboV3() internal view returns (address) {
        return get("PhlimboV3");
    }

    /**
     * @notice Back-compat alias resolving to the LIVE farm (PhlimboV3).
     * @dev Deliberately repointed rather than deleted. Every caller of `getPhlimbo()` meant "the
     *      farm users interact with", and that is now V3; leaving it on V2 would keep those
     *      scripts compiling while quietly operating on an empty, wound-down contract.
     */
    function getPhlimbo() internal view returns (address) {
        return getPhlimboV3();
    }

    function getViewRouter() internal view returns (address) {
        return get("ViewRouter");
    }

    // ========== Test Helpers ==========

    function getDefaultUser() internal pure returns (address) {
        return 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    }

    // Second test user (Anvil account #1)
    function getSecondUser() internal pure returns (address) {
        return 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    }

    function getDefaultPrivateKey() internal pure returns (uint256) {
        return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    }

    // Second user private key (Anvil account #1)
    function getSecondPrivateKey() internal pure returns (uint256) {
        return 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    }

    function logAddresses() internal view {
        console.log("=== Deployed Contract Addresses ===");
        console.log("MockPhUSD:", getPhUSD());
        console.log("MockUSDC:", getUSDC());
        console.log("PhusdStableMinter:", getMinter());
        console.log("PhlimboV2 (wound down):", getPhlimboV2());
        console.log("PhlimboV3 (live farm):", getPhlimboV3());
        console.log("===================================");
    }
}
