// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "@forge-std/Script.sol";
import {StdCheats} from "@forge-std/StdCheats.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BatchNFTMinterNudgeDiscount} from "nft-staking/BatchNFTMinterNudgeDiscount.sol";

/// @dev The live NFTMinterV2 surface (lib/yield-claim-nft/src/NFTMinterV2.sol).
interface INFTMinterV2ND {
    function owner() external view returns (address);
    function nextIndex() external view returns (uint256);
    function configs(uint256 index)
        external
        view
        returns (address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled);
    function authorizedMinters(address minter) external view returns (bool);
    function setAuthorizedMinter(address minter, bool authorized) external;
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/// @dev The live OLD minter, `BatchNFTMinterMultiToken` (lib/nft-staking/src/BatchNFTMinterMultiToken.sol).
interface IOldBatchMinterND {
    function owner() external view returns (address);
    function pauser() external view returns (address);
    function paused() external view returns (bool);
    function setPauser(address newPauser) external;
    function pause() external;
    function rescueERC20(IERC20 token, address to, uint256 amount) external;
    function isNudgeToken(address token) external view returns (bool);
}

/// @dev The live PauserV2 surface (lib/pauser/src/PauserV2.sol).
interface IPauserV2ND {
    function owner() external view returns (address);
    function isRegistered(address c) external view returns (bool);
    function register(address c) external;
    function unregister(address c) external;
    function pause() external;
    function unpause() external;
    function eyeToken() external view returns (address);
    function eyeBurnAmount() external view returns (uint256);
    function getPausableContracts() external view returns (address[] memory);
    function health()
        external
        view
        returns (
            address[] memory notPauser,
            address[] memory alreadyPaused,
            address[] memory noPausedGetter,
            address[] memory unreachable
        );
}

/// @dev The live NudgeStreamer (lib/nft-staking/src/NudgeStreamer.sol). No deregister, no owner withdraw.
interface INudgeStreamerND {
    function owner() external view returns (address);
    function streams(address batchMinter, address token)
        external
        view
        returns (uint256 duration, uint256 buffer, uint256 rewardPerSecond, uint256 lastUpdate);
    function registerStream(address batchMinter, address token, uint256 duration) external;
    function collectNudge(address recipientBatchMinter, address token, uint256 amount) external;
    function pendingStream(address batchMinter, address token) external view returns (uint256);
}

interface IMintDebtHookND {
    function ratio() external view returns (uint8);
    function recipient() external view returns (address);
    function owner() external view returns (address);
}

interface INFTStakerND {
    function rewardToken() external view returns (address);
    function owner() external view returns (address);
}

interface IOwnableND {
    function owner() external view returns (address);
}

interface IUniV2RouterND {
    function factory() external view returns (address);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
}

interface IUniV2FactoryND {
    function getPair(address a, address b) external view returns (address);
}

interface IUniV2PairND {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 r0, uint112 r1, uint32 ts);
}

interface ISkyPSMND {
    function tin() external view returns (uint256);
    function gem() external view returns (address);
    function usds() external view returns (address);
    function to18ConversionFactor() external view returns (uint256);
}

interface IERC4626ND {
    function previewDeposit(uint256 assets) external view returns (uint256);
    function asset() external view returns (address);
}

interface IUniPoolerV2ND {
    function batchDonationSize() external view returns (uint256);
    function setBatchDonationSize(uint256 size) external;
}

/// @dev Donor repoint setters (all onlyOwner on the live contracts).
interface IDonorBatchMinterND {
    function batchMinter() external view returns (address);
    function setBatchMinter(address newBatchMinter) external; // UniPoolerV2 :297, NudgeRatchet :96
}

interface IDonorRecipientND {
    function recipient() external view returns (address);
    function setRecipient(address newRecipient) external; // Uniboost
    function nudgeStreamer() external view returns (address);
}

interface IDonorNudgeND {
    function nudge() external view returns (address);
    function setNudgeAddress(address newNudge) external; // StableYieldAccumulator :485
}

/**
 * @title NudgeDiscountMainnetBase  (story 119, sprint nudge-discount)
 * @notice Shared constants, address-book readers, progress-file readers, the donor inventory, the route quote, the
 *         OWNER balance invariant and the post-cutover state assertions for:
 *           - `DeployMainnetNudgeDiscount`  (the cutover: preview / broadcast),
 *           - `VerifyNudgeDiscountMainnet`  (the read-only verifier),
 *           - `NudgeDiscountBuyAndBurn`     (the deferred `buyAndBurn` operation).
 *
 *         Every address the cutover touches is pinned here AND read from the hand-maintained address book
 *         (server/deployments/mainnet-addresses.ts); `_requireBookMatchesConstants` refuses any drift, so a stale book
 *         or a stale constant fails preflight. The Sky PSM, sUSDS-as-ERC4626 and USDS have no book key semantics the
 *         buy route can trust for its PSM, so PSM is a pinned constant only.
 *
 *         CUTOVER GATE (audit-27 M-01; the human's decision of 2026-11-12). `MAX_FREE_PER_BATCH`,
 *         `OVERFLOW_NFTS_PER_BOOST_POINT`, `MAX_BOOST` and `GATE_FMAX` come from the fork gate
 *         `test/fork/NudgeDiscountCutoverGate.t.sol`, measured against this script's own deploy+configure output
 *         (osaka, cold accounts, UniPoolerV2 donation leg ON at max(live batchDonationSize, 10), d = 50). The parameter
 *         table they come from is recorded in the story file (phStaging2:119, Autonomous Decisions, "Gate parameter
 *         table"); re-run the gate and update the table before changing any of them.
 */
abstract contract NudgeDiscountMainnetBase is Script, StdCheats {
    uint256 internal constant CHAIN_ID = 1;
    string internal constant NETWORK_NAME = "mainnet";

    /// @dev The Ledger owner EOA (m/44'/60'/46'/0/0). Pays gas. Never a net recipient of anything.
    address internal constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // ---- book-checked addresses (key names in comments) ----
    address internal constant NFT_MINTER = 0x39Af088408e815844c567037C157B31d48d2E10F; // NFTMinter (V2)
    address internal constant NUDGE_STREAMER = 0xF7e26179D6971985107AF66b078932D6484eBEAA; // NudgeStreamer
    address internal constant UNI_POOLER = 0x56997ea45091CBc01DB8a09E60DEDB8b3706a3D2; // UniPooler (index 4)
    address internal constant NFT_STAKER = 0xc8514f821A3d801Fa8a8c435840a992A4365a13b; // NFTStaker
    address internal constant MINT_DEBT_HOOK = 0x4A26ad83306a2F17155799fDD9449f77eb3F8bD7; // BalancerPoolerMintDebtHook
    address internal constant UNI_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D; // UniswapV2Router
    address internal constant PAIR = 0x0b96b8ab66d40ba3C7501aa8C28Cdc37688F6F7f; // PhusdSusdsPair
    address internal constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605; // PhUSD
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
    address internal constant KENDU = 0xaa95f26e30001251fb905d264Aa7b00eE9dF6C18; // Kendu
    address internal constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD; // SUSDS
    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F; // USDS
    /// @dev Book `Pauser`: PauserV2, live since phStaging2:128's 2026-11-05 broadcast.
    address internal constant PAUSER_V2 = 0x669Ebfa5309db66683c199Cfe22516DECBe1a154;
    /// @dev Book `BatchNFTMinter`: the live `BatchNFTMinterMultiToken` this cutover retires.
    address internal constant OLD_MINTER = 0x068395556b8c43eDf257DC54D109EA5910aE15c7;

    // ---- pinned only (no book key) ----
    address internal constant PSM = 0xA188EEC8F81263234dA3622A406892F3D630f98c; // Sky USDS<->USDC PSM
    /// @dev The RETIRED V1 Pauser (bricked by the story-128 migration). Never targeted.
    address internal constant PAUSER_V1 = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;
    /// @dev The StableYieldAccumulator story 131 retired. It may still name the old minter as `nudge()`; it has no
    ///      strategies, so it donates nothing. Excluded from the "no donor still targets the old minter" assertion.
    address internal constant RETIRED_SYA = 0x0cD353bfda674D04823B2826ffafB83B560D21B6;

    uint256 internal constant DISPATCHER_INDEX = 4;
    uint8 internal constant HOOK_RATIO = 50;

    // ---- owner-settable defaults (Concern 3: the human may change them before or after broadcast) ----
    uint8 internal constant DISCOUNT_PERCENT = 50;
    uint8 internal constant BURN_PERCENT = 100;
    uint256 internal constant USDC_STREAM_DURATION = 10 days;
    uint256 internal constant PHUSD_STREAM_DURATION = 30 days;
    uint256 internal constant KENDU_STREAM_DURATION = 30 days;

    // ---- cutover gate constants (see the NatSpec above and the story's gate parameter table) ----
    /// @dev Free NFTs per batch. `min(50, GATE_FMAX)`.
    uint256 internal constant MAX_FREE_PER_BATCH = 50;
    /// @dev Overflow free-equivalents per boost point. The Safeguard-4 minimum at d = 50 / cap 50 is 3.
    uint256 internal constant OVERFLOW_NFTS_PER_BOOST_POINT = 3;
    /// @dev Boost ceiling in discount points (contract bound 49). Target band 10-15.
    uint8 internal constant MAX_BOOST = 15;
    /// @dev Largest gas-safe free count measured by the gate (>= 10% headroom under 2^24 - intrinsic, d = 50, leg ON).
    uint256 internal constant GATE_FMAX = 54;

    string internal constant BOOK_FILE = "server/deployments/mainnet-addresses.ts";
    string internal constant PROGRESS_FILE = "server/deployments/progress.nudge-discount.1.json";
    string internal constant BOOK_KEY_NEW = "NudgeDiscountBatchMinter";

    uint256 internal constant WAD = 1e18;

    /// @notice Reverted when any OWNER balance rose across the run. `token == address(0)` is ETH; `id` is the
    ///         ERC1155 id for NFTMinterV2 entries and 0 for ERC20s.
    error OwnerBalanceIncreased(address token, uint256 id, uint256 before, uint256 after_);

    // =====================================================================
    // Gate constants
    // =====================================================================

    /// @notice Cutover gate (e): refuse on any zero value, a disabled boost, a boost above the contract bound, or a
    ///         cap above the measured Fmax. Runs in PREVIEW and broadcast alike.
    function _requireGateConstants() internal pure {
        require(MAX_FREE_PER_BATCH != 0, "gate: MAX_FREE_PER_BATCH is zero");
        require(OVERFLOW_NFTS_PER_BOOST_POINT != 0, "gate: OVERFLOW_NFTS_PER_BOOST_POINT is zero");
        require(MAX_BOOST != 0, "gate: MAX_BOOST is 0 - the boost must be set from the gate, never left disabled");
        require(MAX_BOOST <= 49, "gate: MAX_BOOST above the contract bound (49)");
        require(GATE_FMAX != 0, "gate: GATE_FMAX is zero");
        require(MAX_FREE_PER_BATCH <= GATE_FMAX, "gate: MAX_FREE_PER_BATCH > GATE_FMAX (not gas-safe)");
    }

    // =====================================================================
    // Address book
    // =====================================================================

    /// @dev The address literal of `key` in mainnet-addresses.ts, or address(0) when absent. Whole-key match on
    ///      `"\n  <key>: \""` (uncommented top-level entries only, so `USDC` never matches `AutoUSDC`).
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

    function _requireBook(string memory book, string memory key) internal pure returns (address a) {
        a = _bookAddress(book, key);
        require(a != address(0), string.concat("address book: key missing or zero in mainnet-addresses.ts: ", key));
    }

    function _book() internal view returns (string memory) {
        return vm.readFile(BOOK_FILE);
    }

    /// @notice The book's `NudgeDiscountBatchMinter` (address(0) while it is still the ZERO placeholder story 118
    ///         added). `virtual` so fork tests can simulate the post-patch book.
    function _bookNewMinter() internal view virtual returns (address) {
        string memory book = _book();
        require(
            vm.indexOf(book, string.concat("\n  ", BOOK_KEY_NEW, ": \"")) != type(uint256).max,
            "address book: no NudgeDiscountBatchMinter key (story 118 adds the zero placeholder)"
        );
        return _bookAddress(book, BOOK_KEY_NEW);
    }

    /// @notice The CURRENT StableYieldAccumulator (story 131 replaced it; never hard-coded).
    function _bookSya() internal view returns (address) {
        return _requireBook(_book(), "StableYieldAccumulator");
    }

    /// @notice Every row of the parameters table that has a book key must equal its pinned constant.
    function _requireBookMatchesConstants() internal view {
        string memory book = _book();
        require(_requireBook(book, "NFTMinter") == NFT_MINTER, "address book NFTMinter != pinned NFTMinterV2");
        require(_requireBook(book, "NudgeStreamer") == NUDGE_STREAMER, "address book NudgeStreamer != pinned");
        require(_requireBook(book, "UniPooler") == UNI_POOLER, "address book UniPooler != pinned UniPoolerV2");
        require(_requireBook(book, "NFTStaker") == NFT_STAKER, "address book NFTStaker != pinned");
        require(
            _requireBook(book, "BalancerPoolerMintDebtHook") == MINT_DEBT_HOOK,
            "address book BalancerPoolerMintDebtHook != pinned"
        );
        require(_requireBook(book, "UniswapV2Router") == UNI_ROUTER, "address book UniswapV2Router != pinned");
        require(_requireBook(book, "PhusdSusdsPair") == PAIR, "address book PhusdSusdsPair != pinned");
        require(_requireBook(book, "PhUSD") == PHUSD, "address book PhUSD != pinned");
        require(_requireBook(book, "USDC") == USDC, "address book USDC != pinned");
        require(_requireBook(book, "Kendu") == KENDU, "address book Kendu != pinned");
        require(_requireBook(book, "SUSDS") == SUSDS, "address book SUSDS != pinned");
        require(_requireBook(book, "USDS") == USDS, "address book USDS != pinned");
        require(_requireBook(book, "Pauser") == PAUSER_V2, "address book Pauser != PauserV2 (V1 is RETIRED)");
        require(PAUSER_V2 != PAUSER_V1, "PauserV2 constant is the retired V1 Pauser");
        require(_requireBook(book, "BatchNFTMinter") == OLD_MINTER, "address book BatchNFTMinter != the old minter");
    }

    // =====================================================================
    // Progress file
    // =====================================================================

    /// @dev `virtual` so fork tests can point at a scratch file.
    function _progressFile() internal view virtual returns (string memory) {
        return PROGRESS_FILE;
    }

    function _progressJson() internal view returns (string memory json) {
        try vm.readFile(_progressFile()) returns (string memory j) {
            json = j;
        } catch {
            json = "";
        }
    }

    /// @notice The new minter recorded by a broadcast, or address(0) when none.
    function _progressMinter() internal view returns (address) {
        string memory json = _progressJson();
        if (bytes(json).length == 0 || !vm.keyExistsJson(json, ".contracts.NudgeDiscountBatchMinter.address")) {
            return address(0);
        }
        return vm.parseJsonAddress(json, ".contracts.NudgeDiscountBatchMinter.address");
    }

    /// @notice True when scripts/confirm-nudge-discount-progress.js has marked the progress `completed`.
    function _progressCompleted() internal view returns (bool) {
        string memory json = _progressJson();
        if (bytes(json).length == 0 || !vm.keyExistsJson(json, ".deploymentStatus")) return false;
        return keccak256(bytes(vm.parseJsonString(json, ".deploymentStatus"))) == keccak256("completed");
    }

    // =====================================================================
    // Donor inventory (derived on-chain, never assumed)
    // =====================================================================

    /// @dev How a donor names its nudge sink: `batchMinter()` (UniPoolerV2, NudgeRatchet, ...), `recipient()`
    ///      (Uniboost) or `nudge()` (StableYieldAccumulator).
    enum DonorKind {
        BatchMinter,
        Recipient,
        Nudge
    }

    struct Donor {
        string label;
        address addr;
        DonorKind kind;
    }

    function _probeAddress(address c, bytes4 sel) internal view returns (bool ok, address a) {
        if (c.code.length == 0) return (false, address(0));
        (bool success, bytes memory data) = c.staticcall(abi.encodeWithSelector(sel));
        if (!success || data.length != 32) return (false, address(0));
        uint256 w = abi.decode(data, (uint256));
        if (w >> 160 != 0) return (false, address(0));
        return (true, address(uint160(w)));
    }

    /// @notice Every contract whose nudge sink is `target`: every NFTMinter dispatcher (`configs(i).dispatcher` for
    ///         i in 1 .. nextIndex-1) plus the CURRENT SYA from the book. Each candidate is probed for
    ///         `batchMinter()`, `recipient()` and `nudge()` with a staticcall. The retired SYA is never inventoried.
    function _donorInventory(address target) internal view returns (Donor[] memory out) {
        uint256 next = INFTMinterV2ND(NFT_MINTER).nextIndex();
        require(next > 1 && next < 1000, "donor inventory: NFTMinterV2.nextIndex() out of range");
        address[] memory cands = new address[](next);
        string[] memory labels = new string[](next);
        for (uint256 i = 1; i < next; i++) {
            (address d,,,) = INFTMinterV2ND(NFT_MINTER).configs(i);
            cands[i - 1] = d;
            labels[i - 1] = string.concat("NFTMinter.configs(", vm.toString(i), ").dispatcher");
        }
        cands[next - 1] = _bookSya();
        labels[next - 1] = "StableYieldAccumulator (book)";

        Donor[] memory tmp = new Donor[](cands.length);
        uint256 n;
        for (uint256 i = 0; i < cands.length; i++) {
            address c = cands[i];
            if (c == address(0) || c == RETIRED_SYA) continue;
            (bool ok, address a) = _probeAddress(c, IDonorBatchMinterND.batchMinter.selector);
            if (ok && a == target) {
                tmp[n++] = Donor(labels[i], c, DonorKind.BatchMinter);
                continue;
            }
            (ok, a) = _probeAddress(c, IDonorRecipientND.recipient.selector);
            if (ok && a == target) {
                tmp[n++] = Donor(labels[i], c, DonorKind.Recipient);
                continue;
            }
            (ok, a) = _probeAddress(c, IDonorNudgeND.nudge.selector);
            if (ok && a == target) tmp[n++] = Donor(labels[i], c, DonorKind.Nudge);
        }
        out = new Donor[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = tmp[i];
        }
    }

    function _setterName(DonorKind k) internal pure returns (string memory) {
        if (k == DonorKind.BatchMinter) return "setBatchMinter";
        if (k == DonorKind.Recipient) return "setRecipient";
        return "setNudgeAddress";
    }

    function _printInventory(string memory tag, Donor[] memory ds) internal pure {
        for (uint256 i = 0; i < ds.length; i++) {
            console.log(
                string.concat(tag, "|", ds[i].label, "|", vm.toString(ds[i].addr), "|", _setterName(ds[i].kind))
            );
        }
    }

    /// @notice A `recipient()` donor (Uniboost) is a nudge donor only if it routes its donation through the
    ///         NudgeStreamer (`collectNudge(recipient, primeToken, amt)`, Uniboost.sol:250): its `nudgeStreamer()`
    ///         must be the live streamer, otherwise `recipient` would be a plain transfer target.
    function _requireRecipientIsNudgeTarget(Donor memory d) internal view {
        if (d.kind != DonorKind.Recipient) return;
        (bool ok, address s) = _probeAddress(d.addr, IDonorRecipientND.nudgeStreamer.selector);
        require(
            ok && s == NUDGE_STREAMER, string.concat("donor ", d.label, ": recipient() is not a NudgeStreamer target")
        );
    }

    // =====================================================================
    // Route quote (the helper's maths, on-chain)
    // =====================================================================

    /// @notice phUSD out for `usdcIn` along the minter's `buyAndBurn` route: PSM `sellGem` (to18ConversionFactor,
    ///         minus `tin`) -> sUSDS `previewDeposit` -> `router.getAmountsOut(sUSDS -> phUSD)`. Identical to
    ///         scripts/quote-nudge-discount-buy-and-burn.js. The pinned contract (d7eb782) has no quote view.
    function _quoteRoute(BatchNFTMinterNudgeDiscount m, uint256 usdcIn) internal view returns (uint256 phusdOut) {
        ISkyPSMND psm = ISkyPSMND(address(m.psm()));
        uint256 gross = usdcIn * psm.to18ConversionFactor();
        uint256 usdsOut = gross - (gross * psm.tin()) / WAD;
        uint256 shares = IERC4626ND(address(m.sUSDS())).previewDeposit(usdsOut);
        address[] memory path = new address[](2);
        path[0] = address(m.sUSDS());
        path[1] = m.phUSD();
        uint256[] memory amounts = IUniV2RouterND(m.router()).getAmountsOut(shares, path);
        phusdOut = amounts[1];
    }

    // =====================================================================
    // OWNER balance invariant (no funds to the Ledger)
    // =====================================================================

    struct OwnerBalances {
        uint256 eth;
        address[] erc20s;
        uint256[] erc20Balances;
        uint256[] nftIds;
        uint256[] nftBalances;
    }

    OwnerBalances internal ownerBefore;

    /// @notice USDC, phUSD, Kendu (the three nudge tokens), USDS, sUSDS (the buy route) and EYE (the pause burn).
    function _watchedErc20s() internal view returns (address[] memory t) {
        string memory book = _book();
        string[6] memory keys = ["USDC", "PhUSD", "Kendu", "USDS", "SUSDS", "EYE"];
        t = new address[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            t[i] = _requireBook(book, keys[i]);
        }
    }

    function _watchedNftIds() internal view returns (uint256[] memory ids) {
        uint256 next = INFTMinterV2ND(NFT_MINTER).nextIndex();
        require(next > 1 && next < 1000, "NFTMinterV2.nextIndex() out of range - cannot enumerate ids");
        ids = new uint256[](next + 1);
        for (uint256 i = 0; i <= next; i++) {
            ids[i] = i;
        }
    }

    function _snapshotOwnerBalances() internal {
        ownerBefore.eth = OWNER.balance;
        delete ownerBefore.erc20s;
        delete ownerBefore.erc20Balances;
        delete ownerBefore.nftIds;
        delete ownerBefore.nftBalances;
        address[] memory t = _watchedErc20s();
        for (uint256 i = 0; i < t.length; i++) {
            ownerBefore.erc20s.push(t[i]);
            ownerBefore.erc20Balances.push(IERC20(t[i]).balanceOf(OWNER));
        }
        uint256[] memory ids = _watchedNftIds();
        for (uint256 i = 0; i < ids.length; i++) {
            ownerBefore.nftIds.push(ids[i]);
            ownerBefore.nftBalances.push(INFTMinterV2ND(NFT_MINTER).balanceOf(OWNER, ids[i]));
        }
        console.log("OWNER balance snapshot taken: ETH wei", ownerBefore.eth);
    }

    /// @notice Revert `OwnerBalanceIncreased` if any watched OWNER balance rose since the snapshot (ETH must be
    ///         non-increasing). The Phase 4 pot migration routes the old minter's tokens THROUGH OWNER
    ///         (`rescueERC20 -> OWNER`, then `collectNudge` pulls the exact amount back out in the next tx), so the
    ///         net is zero and this end-of-run check holds; each transit is also closed by its own assertion.
    function _assertOwnerBalancesNotIncreased(string memory stage) internal view {
        require(ownerBefore.erc20s.length > 0, "OWNER balance snapshot was never taken");
        if (OWNER.balance > ownerBefore.eth) {
            revert OwnerBalanceIncreased(address(0), 0, ownerBefore.eth, OWNER.balance);
        }
        for (uint256 i = 0; i < ownerBefore.erc20s.length; i++) {
            uint256 nowBal = IERC20(ownerBefore.erc20s[i]).balanceOf(OWNER);
            if (nowBal > ownerBefore.erc20Balances[i]) {
                revert OwnerBalanceIncreased(ownerBefore.erc20s[i], 0, ownerBefore.erc20Balances[i], nowBal);
            }
        }
        for (uint256 i = 0; i < ownerBefore.nftIds.length; i++) {
            uint256 nowBal = INFTMinterV2ND(NFT_MINTER).balanceOf(OWNER, ownerBefore.nftIds[i]);
            if (nowBal > ownerBefore.nftBalances[i]) {
                revert OwnerBalanceIncreased(NFT_MINTER, ownerBefore.nftIds[i], ownerBefore.nftBalances[i], nowBal);
            }
        }
        console.log(string.concat(stage, ": OWNER balance invariant OK (nothing credited to the Ledger account)"));
    }

    // =====================================================================
    // PauserV2 health
    // =====================================================================

    function _requirePauserHealthClean(string memory stage) internal view {
        (address[] memory notPauser, address[] memory alreadyPaused,, address[] memory unreachable) =
            IPauserV2ND(PAUSER_V2).health();
        for (uint256 i = 0; i < notPauser.length; i++) {
            console.log("  health notPauser:", notPauser[i]);
        }
        for (uint256 i = 0; i < alreadyPaused.length; i++) {
            console.log("  health alreadyPaused:", alreadyPaused[i]);
        }
        for (uint256 i = 0; i < unreachable.length; i++) {
            console.log("  health unreachable:", unreachable[i]);
        }
        require(
            notPauser.length == 0 && alreadyPaused.length == 0 && unreachable.length == 0,
            string.concat(stage, ": PauserV2.health() is not clean (notPauser / alreadyPaused / unreachable)")
        );
        console.log(string.concat("PAUSER_HEALTH|", stage, "|clean"));
    }

    // =====================================================================
    // Post-cutover state (the cutover's final assertion AND the verifier)
    // =====================================================================

    function _nudgeTokens() internal pure returns (address[3] memory) {
        return [USDC, PHUSD, KENDU];
    }

    function _streamDuration(address token) internal pure returns (uint256) {
        if (token == USDC) return USDC_STREAM_DURATION;
        if (token == PHUSD) return PHUSD_STREAM_DURATION;
        return KENDU_STREAM_DURATION;
    }

    /// @notice The new minter's full configuration (story checklist "configured ... read back").
    function _requireNewMinterConfigured(BatchNFTMinterNudgeDiscount m) internal view {
        string memory p = "post: ";
        require(address(m).code.length > 0, "post: new minter has no code");
        require(m.owner() == OWNER, "post: new minter owner() != OWNER");
        require(address(m.tokenMinter()) == NFT_MINTER, "post: tokenMinter != NFTMinterV2");
        require(m.dispatcherIndex() == DISPATCHER_INDEX, "post: dispatcherIndex != 4");
        address[3] memory toks = _nudgeTokens();
        for (uint256 i = 0; i < 3; i++) {
            require(m.isNudgeToken(toks[i]), string.concat(p, "nudge token not whitelisted: ", vm.toString(toks[i])));
        }
        require(address(m.discountToken()) == USDC, "post: discountToken != USDC");
        require(m.discountPercent() == DISCOUNT_PERCENT, "post: discountPercent != 50");
        require(m.burnPercent() == BURN_PERCENT, "post: burnPercent != 100");
        require(m.nftStaker() == NFT_STAKER, "post: nftStaker != NFTStaker");
        require(address(m.mintDebtHook()) == MINT_DEBT_HOOK, "post: mintDebtHook != BalancerPoolerMintDebtHook");
        require(address(m.psm()) == PSM, "post: psm != Sky PSM");
        require(address(m.sUSDS()) == SUSDS, "post: sUSDS != sUSDS");
        require(m.router() == UNI_ROUTER, "post: router != UniswapV2Router");
        require(m.pair() == PAIR, "post: pair != PhusdSusdsPair");
        require(m.phUSD() == PHUSD, "post: phUSD != PhUSD");
        require(m.buyerAuthVersion(OWNER) == m.authVersion(), "post: OWNER is not an authorised buyer");
        require(m.maxFreePerBatch() == MAX_FREE_PER_BATCH, "post: maxFreePerBatch != MAX_FREE_PER_BATCH");
        require(
            m.overflowNFTsPerBoostPoint() == OVERFLOW_NFTS_PER_BOOST_POINT,
            "post: overflowNFTsPerBoostPoint != OVERFLOW_NFTS_PER_BOOST_POINT"
        );
        require(m.maxBoost() == MAX_BOOST, "post: maxBoost != MAX_BOOST");
        require(m.boostDonationSafe(), "post: boostDonationSafe() is false");
        require(m.nudgeStreamer() == NUDGE_STREAMER, "post: nudgeStreamer != NudgeStreamer");
        for (uint256 i = 0; i < 3; i++) {
            (uint256 duration,,,) = INudgeStreamerND(NUDGE_STREAMER).streams(address(m), toks[i]);
            require(
                duration == _streamDuration(toks[i]),
                string.concat(p, "stream duration wrong for ", vm.toString(toks[i]))
            );
        }
        require(m.pauser() == PAUSER_V2, "post: new minter pauser() != PauserV2");
        require(IPauserV2ND(PAUSER_V2).isRegistered(address(m)), "post: new minter not registered with PauserV2");
        require(!m.paused(), "post: new minter is paused");
        require(INFTMinterV2ND(NFT_MINTER).authorizedMinters(address(m)), "post: authorizedMinters(new) is false");
    }

    /// @notice The old minter is frozen, off PauserV2, emptied, and no longer a nudge sink; the donors point at the
    ///         new minter; PauserV2 is healthy.
    function _requireCutoverState(BatchNFTMinterNudgeDiscount m) internal view {
        _requireNewMinterConfigured(m);
        IOldBatchMinterND old = IOldBatchMinterND(OLD_MINTER);
        require(!INFTMinterV2ND(NFT_MINTER).authorizedMinters(OLD_MINTER), "post: authorizedMinters(old) is true");
        require(old.paused(), "post: old minter is not paused");
        require(old.pauser() == OWNER, "post: old minter pauser() != OWNER");
        require(!IPauserV2ND(PAUSER_V2).isRegistered(OLD_MINTER), "post: old minter still registered with PauserV2");
        address[3] memory toks = _nudgeTokens();
        for (uint256 i = 0; i < 3; i++) {
            require(IERC20(toks[i]).balanceOf(OLD_MINTER) == 0, "post: old minter still holds a nudge token");
            (, uint256 buffer,,) = INudgeStreamerND(NUDGE_STREAMER).streams(OLD_MINTER, toks[i]);
            require(buffer == 0, "post: old minter still has a NudgeStreamer buffer");
        }
        Donor[] memory stale = _donorInventory(OLD_MINTER);
        _printInventory("STALE_DONOR", stale);
        require(stale.length == 0, "post: a donor still targets the old minter");
        Donor[] memory live = _donorInventory(address(m));
        _printInventory("DONOR_NEW", live);
        require(live.length > 0, "post: no donor targets the new minter");
        for (uint256 i = 0; i < live.length; i++) {
            _requireRecipientIsNudgeTarget(live[i]);
        }
        _requirePauserHealthClean("post");
        console.log("INFO|pendingBuyUSDC", m.pendingBuyUSDC());
        console.log("INFO|pendingStakerPhUSD", m.pendingStakerPhUSD());
        console.log("Cutover state OK.");
    }
}
