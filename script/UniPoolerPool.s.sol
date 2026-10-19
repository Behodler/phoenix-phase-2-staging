// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

/**
 * @title UniPoolerPool  (story 105, sprint Balancexit)
 * @notice One owner transaction: `UniPoolerV2.pool(sUSDSIn, minPhusdOut, minLP)` on the live index-4 UniPooler, which
 *         zaps accumulated sUSDS into the phUSD/sUSDS Uniswap V2 pair (half swapped to phUSD, then added as
 *         liquidity; the LP stays on the pooler). docs/BalancerWinddownPlan.md section 4 Stage 4 step 6 (the first
 *         `pool()` of the sUSDS that accumulated during the holding pattern), and any later manual pool.
 *
 *         WHICH POOLER. `UniPooler` is read from server/deployments/mainnet-addresses.ts (hand-maintained; patched by
 *         `unipooler-cutover:broadcast`). The script refuses while it is the zero placeholder, and require()s that it
 *         is the live `NFTMinter.configs(4).dispatcher`, so a stale or wrong book entry fails here, not on chain.
 *
 *         INPUTS (all REQUIRED and non-zero; CLAUDE.md "Configuration Safety"):
 *           SUSDS_IN_WEI       sUSDS to pool (at most the pooler's sUSDS balance)
 *           MIN_PHUSD_OUT_WEI  floor on the phUSD the swap leg buys
 *           MIN_LP_WEI         floor on the LP minted
 *         Quote them off-chain, in the SAME shell before :preview and :broadcast so both use identical floors:
 *             eval "$(node scripts/quote-unipooler-pool.js all 50)"
 *         The script re-quotes `quotePool(SUSDS_IN_WEI)` live and require()s each floor to lie in
 *         [quote * (1 - MAX_TOLERANCE_BPS), quote]: above the quote `pool()` would revert anyway, and below the band
 *         the floor no longer protects against a sandwich. Re-quote and retry if the pair moved.
 *
 *         CALLER. `pool` is `onlyAuthorizedPooler`; OWNER is authorized pooler #1 (re-authorized by the cutover). The
 *         script require()s OWNER's auth (`poolerAuthVersion[OWNER] == authVersion`) and that the pooler is not paused.
 *         Kill switch, independent of this script: `UniPoolerV2.incrementAuthVersion()`.
 *
 *         No addresses change: there is no mainnet-addresses.ts backup or patcher step.
 *
 * Preview:   npm run unipooler:pool:preview     (PREVIEW_MODE=true, OWNER prank on a fork, nothing signed)
 * Broadcast: npm run unipooler:pool:broadcast   (Ledger m/44'/60'/46'/0/0)
 */

/// @notice Minimal interface for the live UniPoolerV2 (copied, not imported, per repo script precedent).
interface IUniPoolerV2Pool {
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function sUSDS() external view returns (address);
    function pair() external view returns (address);
    function authVersion() external view returns (uint256);
    function poolerAuthVersion(address pooler) external view returns (uint256);
    function quotePool(uint256 sUSDSIn) external view returns (uint256 swapIn, uint256 phusdOut, uint256 expectedLP);
    function pool(uint256 sUSDSIn, uint256 minPhusdOut, uint256 minLP) external;
}

interface IUniPoolerPoolNFTMinter {
    function configs(uint256 index)
        external
        view
        returns (address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled);
}

interface IUniPoolerPoolERC20 {
    function balanceOf(address account) external view returns (uint256);
}

contract UniPoolerPool is Script {
    uint256 public constant CHAIN_ID = 1;
    string public constant ADDRESS_BOOK = "server/deployments/mainnet-addresses.ts";

    /// @dev Mainnet OWNER EOA (Ledger m/44'/60'/46'/0/0); authorized pooler #1 on UniPoolerV2.
    address public constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant NFT_MINTER = 0x39Af088408e815844c567037C157B31d48d2E10F; // NFTMinter (V2)
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    uint256 public constant DISPATCHER_INDEX = 4;

    /// @dev Loosest floor accepted: 1% below the live quote. scripts/quote-unipooler-pool.js caps its tolerance here.
    uint256 public constant MAX_TOLERANCE_BPS = 100;

    function run() external {
        console.log("=================================================");
        console.log("  UniPoolerV2.pool() - MAINNET index 4 (story 105)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        bool isPreview = _previewModeFromEnv();
        console.log(isPreview ? "Mode: PREVIEW (OWNER prank, nothing signed)" : "Mode: BROADCAST (Ledger)");

        (uint256 sUSDSIn, uint256 minPhusdOut, uint256 minLP) = _inputsFromEnv();
        _requireInputs(sUSDSIn, minPhusdOut, minLP);

        IUniPoolerV2Pool pooler = IUniPoolerV2Pool(_resolvePooler());
        _preflight(pooler);

        uint256 balance = IUniPoolerPoolERC20(SUSDS).balanceOf(address(pooler));
        require(balance > 0, "preflight: pooler holds 0 sUSDS - nothing to pool");
        require(sUSDSIn <= balance, "preflight: SUSDS_IN_WEI exceeds the pooler's sUSDS balance");

        (uint256 swapIn, uint256 phusdOut, uint256 expectedLP) = pooler.quotePool(sUSDSIn);
        _requireFloorInBand(minPhusdOut, phusdOut, "MIN_PHUSD_OUT_WEI");
        _requireFloorInBand(minLP, expectedLP, "MIN_LP_WEI");

        address pair = pooler.pair();
        uint256 lpBefore = IUniPoolerPoolERC20(pair).balanceOf(address(pooler));

        console.log("  UniPooler          :", address(pooler));
        console.log("  pair               :", pair);
        console.log("  pooler sUSDS       :", balance);
        console.log("  SUSDS_IN_WEI       :", sUSDSIn);
        console.log("  quote swapIn       :", swapIn);
        console.log("  quote phusdOut     :", phusdOut);
        console.log("  quote expectedLP   :", expectedLP);
        console.log("  MIN_PHUSD_OUT_WEI  :", minPhusdOut);
        console.log("  MIN_LP_WEI         :", minLP);
        console.log("  pooler LP before   :", lpBefore);

        if (isPreview) {
            vm.startPrank(OWNER);
        } else {
            vm.startBroadcast();
        }
        pooler.pool(sUSDSIn, minPhusdOut, minLP);
        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        uint256 lpAfter = IUniPoolerPoolERC20(pair).balanceOf(address(pooler));
        uint256 balanceAfter = IUniPoolerPoolERC20(SUSDS).balanceOf(address(pooler));
        console.log("  pooler LP after    :", lpAfter);
        console.log("  pooler sUSDS after :", balanceAfter);
        require(lpAfter >= lpBefore + minLP, "post: pooler LP rose by less than MIN_LP_WEI");
        // Not "fell by exactly SUSDS_IN_WEI": the router's optimal-amount selection in `addLiquidity` can leave a
        // little sUSDS dust on the pooler (it stays there for the next pool), but never spends more than asked.
        require(balanceAfter >= balance - sUSDSIn, "post: pooler spent more sUSDS than SUSDS_IN_WEI");
        require(balanceAfter < balance, "post: pooler sUSDS did not fall");
        console.log("  sUSDS dust left    :", balanceAfter - (balance - sUSDSIn));
        console.log("OK: pooled", sUSDSIn, "sUSDS; LP minted:", lpAfter - lpBefore);
        if (isPreview) {
            console.log("PREVIEW: nothing broadcast. Run unipooler:pool:broadcast with the Ledger, same shell/env.");
        }
    }

    // ------------------------------------------------------------------------------------------------- checks

    function _requireInputs(uint256 sUSDSIn, uint256 minPhusdOut, uint256 minLP) internal pure {
        require(sUSDSIn > 0, "input: SUSDS_IN_WEI unset or zero (quote with scripts/quote-unipooler-pool.js)");
        require(minPhusdOut > 0, "input: MIN_PHUSD_OUT_WEI unset or zero - refusing an unprotected swap");
        require(minLP > 0, "input: MIN_LP_WEI unset or zero - refusing an unprotected add");
    }

    /// @dev `floor` must be in [quote * (10000 - MAX_TOLERANCE_BPS) / 10000, quote].
    function _requireFloorInBand(uint256 floor, uint256 quote, string memory name) internal pure {
        require(quote > 0, string.concat("quote: live ", name, " quote is zero"));
        require(floor <= quote, string.concat("quote: ", name, " above the live quote - pair moved, re-quote"));
        require(
            floor >= (quote * (10000 - MAX_TOLERANCE_BPS)) / 10000,
            string.concat("quote: ", name, " more than MAX_TOLERANCE_BPS below the live quote - re-quote")
        );
    }

    function _resolvePooler() internal view returns (address pooler) {
        pooler = _bookAddress(_addressBook(), "UniPooler");
        require(
            pooler != address(0),
            "preflight: mainnet-addresses.ts UniPooler is the zero placeholder - run the Stage 4 cutover first"
        );
        require(pooler.code.length > 0, "preflight: UniPooler has no code");
        (address d,,,) = IUniPoolerPoolNFTMinter(NFT_MINTER).configs(DISPATCHER_INDEX);
        require(d == pooler, "preflight: mainnet-addresses.ts UniPooler is not NFTMinter configs(4).dispatcher");
    }

    function _preflight(IUniPoolerV2Pool pooler) internal view {
        require(pooler.owner() == OWNER, "preflight: UniPooler owner is not OWNER");
        require(!pooler.paused(), "preflight: UniPooler is paused");
        require(pooler.sUSDS() == SUSDS, "preflight: UniPooler sUSDS mismatch");
        require(pooler.poolerAuthVersion(OWNER) == pooler.authVersion(), "preflight: OWNER is not an authorized pooler");
    }

    /// @dev The address literal of `key` in mainnet-addresses.ts, or address(0) when the key is absent. Matches only
    ///      an uncommented top-level entry (`\n  <key>: "0x..."`) - same reader as DeployMainnetUniPoolerCutover's.
    function _bookAddress(string memory book, string memory key) internal pure returns (address) {
        string memory needle = string.concat("\n  ", key, ": \"");
        uint256 at = vm.indexOf(book, needle);
        if (at == type(uint256).max) return address(0);
        bytes memory src = bytes(book);
        uint256 start = at + bytes(needle).length;
        require(src.length >= start + 42, string.concat("address book: truncated entry for ", key));
        bytes memory lit = new bytes(42);
        for (uint256 i; i < 42; i++) {
            lit[i] = src[start + i];
        }
        return vm.parseAddress(string(lit));
    }

    /// @dev The ONE reader of the address book. `virtual` only so the fork test can inject a post-cutover book.
    function _addressBook() internal view virtual returns (string memory) {
        return vm.readFile(ADDRESS_BOOK);
    }

    /// @dev The ONE reader of SUSDS_IN_WEI / MIN_PHUSD_OUT_WEI / MIN_LP_WEI (unset reads as 0 and is refused).
    ///      `virtual` only so fork-test harnesses can inject inputs (`vm.setEnv` is process-wide).
    function _inputsFromEnv() internal view virtual returns (uint256 sUSDSIn, uint256 minPhusdOut, uint256 minLP) {
        sUSDSIn = vm.envOr("SUSDS_IN_WEI", uint256(0));
        minPhusdOut = vm.envOr("MIN_PHUSD_OUT_WEI", uint256(0));
        minLP = vm.envOr("MIN_LP_WEI", uint256(0));
    }

    /// @dev The ONE reader of PREVIEW_MODE. `virtual` only so fork-test harnesses can pin the mode.
    function _previewModeFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }
}
