// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/console.sol";
import {UniswapHelper} from "../src/periphery/UniswapHelper.sol";
import {UniswapHelperMainnetBase, IUniHelperPreflightV2Router} from "./DeployUniswapHelperMainnet.s.sol";

interface IUniHelperVerifyFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

/**
 * @title VerifyUniswapHelper  (story 111, sprint Balancexit)
 * @notice READ-ONLY verifier for the mainnet UniswapHelper: no --broadcast, no --sender, no prank/deal.
 *
 *         WHICH HELPER. `server/deployments/progress.uniswap-helper.1.json` (written by the deploy) and the
 *         `UniswapHelper` key of `mainnet-addresses.ts` (filled by the patcher). Whichever is non-zero is used; when
 *         both are, they must agree. With neither it fails "verify: no UniswapHelper address" - broadcast first.
 *
 *         WHAT IT CHECKS. The helper has code; every immutable equals the expected constructor input (the same
 *         `expectedConfig()` the deploy used: address-book keys where they exist, constants otherwise); the venue
 *         preflight still holds; `pair()` equals `factory.getPair(sUSDS, phUSD)`.
 *
 *         THE PAIR MAY NOT EXIST YET. Until story 103's cutover is broadcast (Stage 4) `pair()` is zero. That is
 *         NOT a failure: the verifier logs "pair not yet created (Stage 4 pending)" and skips the quote smoke test.
 *         Once the pair exists it quotes 1,000 of every supported stable into phUSD, 1,000 phUSD back out to each,
 *         and the two ETH routes (QuoterV2 quotes are non-view, so this run() is not `view`; nothing is sent),
 *         requiring each to be non-zero. If the address book's `PhusdSusdsPair` is non-zero it must equal `pair()`.
 *
 * Usage: npm run uniswap-helper:verify
 */
contract VerifyUniswapHelper is UniswapHelperMainnetBase {
    function run() external {
        console.log("=================================================");
        console.log("  VERIFY UniswapHelper - MAINNET (story 111)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        HelperConfig memory c = expectedConfig();
        _requireCode(c);
        _requireVenues(c);

        address fromProgress = _progressHelper();
        address fromBook = _bookHelper();
        console.log("  progress file :", fromProgress);
        console.log("  address book  :", fromBook);
        if (fromProgress != address(0) && fromBook != address(0)) {
            require(fromProgress == fromBook, "verify: progress file and mainnet-addresses.ts name different helpers");
        }
        address h = fromBook != address(0) ? fromBook : fromProgress;
        require(
            h != address(0),
            "verify: no UniswapHelper address (no progress file and the address-book key is zero) - broadcast first"
        );

        UniswapHelper helper = UniswapHelper(payable(h));
        _checkImmutables(helper, c);
        console.log("OK: UniswapHelper", h, "- every immutable matches.");

        address p = helper.pair();
        address factory = IUniHelperPreflightV2Router(c.v2Router).factory();
        require(p == IUniHelperVerifyFactory(factory).getPair(c.sUSDS, c.phUSD), "verify: pair() != factory.getPair");
        // Story 120: the AM/sUSDS pair resolves lazily too; zero until the mainnet AM pool cutover.
        require(
            helper.amPair() == IUniHelperVerifyFactory(factory).getPair(c.sUSDS, c.antimatter),
            "verify: amPair() != factory.getPair"
        );
        console.log("AM/sUSDS pair (zero until the AM pool cutover):", helper.amPair());
        if (p == address(0)) {
            console.log("pair not yet created (Stage 4 pending) - quote smoke test skipped.");
            return;
        }

        address bookPair = _bookAddress(vm.readFile(ADDRESS_BOOK), "PhusdSusdsPair");
        if (bookPair != address(0)) require(bookPair == p, "verify: PhusdSusdsPair in mainnet-addresses.ts != pair()");
        console.log("phUSD/sUSDS pair:", p);
        _quoteSmoke(helper, c);
        console.log("OK: quote smoke test passed on every route.");
    }

    /// @dev The helper named by the address book's `UniswapHelper` key. `virtual` only so fork tests pinned before
    ///      the deploy can stand in the pre-patch zero placeholder; production reads ADDRESS_BOOK.
    function _bookHelper() internal view virtual returns (address) {
        return _bookAddress(vm.readFile(ADDRESS_BOOK), "UniswapHelper");
    }

    function _quoteSmoke(UniswapHelper helper, HelperConfig memory c) internal {
        address[5] memory stables = [c.sUSDS, c.USDS, c.USDC, c.DOLA, c.USDe];
        string[5] memory names = ["sUSDS", "USDS", "USDC", "DOLA", "USDe"];
        for (uint256 i; i < 5; i++) {
            uint256 unit = stables[i] == c.USDC ? 1e6 : 1e18;
            uint256 toPhusd = helper.quoteToPhUSD(stables[i], 1000 * unit);
            uint256 fromPhusd = helper.quoteFromPhUSD(stables[i], 1000e18);
            console.log(string.concat("  1000 ", names[i], " -> phUSD:"), toPhusd);
            console.log(string.concat("  1000 phUSD -> ", names[i], ":"), fromPhusd);
            require(toPhusd > 0, string.concat("verify: zero quote ", names[i], " -> phUSD"));
            require(fromPhusd > 0, string.concat("verify: zero quote phUSD -> ", names[i]));
        }
        uint256 ethToPhusd = helper.quoteETHToPhUSD(1 ether);
        uint256 phusdToEth = helper.quotePhUSDToETH(1000e18);
        console.log("  1 ETH -> phUSD:", ethToPhusd);
        console.log("  1000 phUSD -> ETH (wei):", phusdToEth);
        require(ethToPhusd > 0, "verify: zero quote ETH -> phUSD");
        require(phusdToEth > 0, "verify: zero quote phUSD -> ETH");
    }
}
