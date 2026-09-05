// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {MintPageView} from "../src/views/MintPageView.sol";
import {IPageView} from "../src/views/IPageView.sol";
import {INFTMinterV2 as INFTMinter} from "@yield-claim-nft/interfaces/INFTMinterV2.sol";
import {BurnRecorder} from "@yield-claim-nft/BurnRecorder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployMainnetMintPageView
 * @notice Story 071 follow-up: redeploy MintPageView on mainnet. The live view (0x7e32..) is a
 *         PRE-cutover build whose per-row `balance` reads a hardcoded label token (EYE/SCX/Flax).
 *         Since the cutover repointed indices 1/2/3 to USDC-primed Uniboost dispatchers, the UI's
 *         "EYE/SCX/Flax balance" rows must report the user's USDC — but the old view returns 0
 *         (proven on-chain: getData(usdcHolder)[3] and [9] == 0 despite a large USDC balance).
 *
 *         The current MintPageView source fixes this: allowance/balance are sourced from each
 *         dispatcher's live primeToken() (MintPageView.sol _fillTokenData, ~L193/202). DeployMocks
 *         deploys this fixed view locally; the cutover omitted the mainnet redeploy. This script
 *         does the differential: deploy the fixed view, re-point ViewRouter's "mint" page at it,
 *         and assert the balance rows now read USDC.
 *
 *         Stateless view — no funds, no user state. Only side effects: one CREATE + one
 *         ViewRouter.setPage (owner-gated; ViewRouter.owner == OWNER, verified).
 *
 * LEDGER SIGNER: Owner 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 (HD path m/44'/60'/46'/0/0)
 * Dry run:   PREVIEW_MODE=true forge script script/DeployMainnetMintPageView.s.sol:DeployMainnetMintPageView --rpc-url $RPC_MAINNET -vvv
 * Broadcast: npm run mintpageview:broadcast (legacy 0.5gwei — the story-071 gas lesson).
 */
contract DeployMainnetMintPageView is Script {
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant NFT_MINTER_V2 = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address public constant BURN_RECORDER = 0x2A2c4186C906d3b347c86882ad4Bd1f2bE05579F;
    address public constant VIEW_ROUTER = 0xC17Ce1cE5ebB43fc0cfda9Fe8BbC849c0894631a;
    address public constant OLD_MINT_PAGE_VIEW = 0x7E329338D319882BA1809b648eBa584B3A4630CB;

    // Token args — vestigial (kept for constructor-ABI stability; no longer drive balance/allowance,
    // which come from dispatcher.primeToken()). Passed as the real mainnet addresses regardless.
    address public constant EYE = 0x155ff1A85F440EE0A382eA949f24CE4E0b751c65;
    address public constant SCX = 0x1B8568FbB47708E9E9D31Ff303254f748805bF21;
    address public constant FLX = 0x0cf758D4303295C43CD95e1232f0101ADb3DA9E8;
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    bytes32 public constant MINT_KEY = keccak256("mint");

    // Read-only mainnet USDC holder used ONLY to verify the balance rows now read USDC.
    // (Binance 14 — large USDC balance, no state touched.)
    address public constant VERIFY_PROBE = 0x28C6c06298d514Db089934071355E5743bf21d60;

    address public newMintPageView;

    function setUp() public view {
        require(block.chainid == 1, "Wrong chain id - expected Mainnet (1)");
    }

    function run() external {
        require(block.chainid == 1, "Wrong chain ID - expected Mainnet (1)");
        bool isPreview = vm.envOr("PREVIEW_MODE", false);

        // Preconditions.
        require(IViewRouterLike(VIEW_ROUTER).owner() == OWNER_ADDRESS, "ViewRouter.owner != OWNER (setPage would revert)");
        address current = IViewRouterLike(VIEW_ROUTER).pages(MINT_KEY);
        console.log("ViewRouter 'mint' page currently:", current);

        if (isPreview) {
            console.log("\n*** PREVIEW MODE - impersonating owner (no signing) ***\n");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        MintPageView view_ = new MintPageView(
            INFTMinter(NFT_MINTER_V2), BurnRecorder(BURN_RECORDER), EYE, SCX, FLX, USDS, WBTC, USDC
        );
        newMintPageView = address(view_);
        console.log("MintPageView deployed at:", newMintPageView);

        // Re-point the router so consumers of ViewRouter.getPage("mint") get the fixed view too.
        IViewRouterLike(VIEW_ROUTER).setPage(MINT_KEY, IPageView(newMintPageView));
        console.log("ViewRouter.setPage('mint') -> new MintPageView");

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        _verify(view_);
        console.log("\nNEW MintPageView:", newMintPageView, "(patch mainnet-addresses.ts MintPageView -> this)");
    }

    function _verify(MintPageView view_) internal view {
        require(IViewRouterLike(VIEW_ROUTER).pages(MINT_KEY) == newMintPageView, "verify: router 'mint' not repointed");

        // The core fix: the EYE (offset [3]) and SCX (offset [9]) balance rows must now equal the
        // probe's USDC balance (the Uniboost primeToken), not the label token / zero.
        uint256[] memory d = view_.getData(VERIFY_PROBE);
        uint256 usdcBal = IERC20(USDC).balanceOf(VERIFY_PROBE);
        require(d.length > 9, "verify: getData too short");
        require(d[3] == usdcBal, "verify: EYE balance row != USDC.balanceOf(probe)");
        require(d[9] == usdcBal, "verify: SCX balance row != USDC.balanceOf(probe)");
        require(d[5] == 1 && d[11] == 2, "verify: EYE/SCX dispatcher indices wrong");
        console.log("Verified: EYE[3] & SCX[9] balance rows now report USDC balance:", usdcBal);
    }
}

interface IViewRouterLike {
    function owner() external view returns (address);
    function pages(bytes32 key) external view returns (address);
    function setPage(bytes32 key, IPageView page) external;
}
