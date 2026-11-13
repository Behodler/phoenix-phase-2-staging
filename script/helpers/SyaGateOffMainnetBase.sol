// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SyaHarvesterMainnetBase} from "../DeploySyaHarvesterMainnet.s.sol";

/// @dev The LIVE (retiring) StableYieldAccumulator `0x0cD3...21B6`, deployed from a pre-028/029 commit. Only the
///      functions whose ABI did not change under yield-accumulator:029 are declared. `tokenConfigs` and
///      `getTokenConfig` are deliberately ABSENT: the live SYA returns a 3-word TokenConfig that does not decode
///      through the 029 4-field struct, and since the human's 2026-11-07 decision the token configs are hard-coded
///      constants, so nothing ever needs to read them from the old SYA. Shape copied from the archive `ISYALike`
///      (script/archives/DeployMainnetPromotionReady.s.sol L3625), not imported.
interface IOldSYA {
    function owner() external view returns (address);
    function rewardToken() external view returns (address);
    function phlimbo() external view returns (address);
    function nftMinter() external view returns (address);
    function nudge() external view returns (address);
    function nudgeSplit() external view returns (uint256);
    function nudgeStreamer() external view returns (address);
    function pauser() external view returns (address);
    function paused() external view returns (bool);
    function getDiscountRate() external view returns (uint256);
    function getYieldStrategies() external view returns (address[] memory);
    function strategyTokens(address strategy) external view returns (address);
    function isRegisteredStrategy(address strategy) external view returns (bool);
    function removeYieldStrategy(address strategy) external;
    function approvePhlimbo(uint256 amount) external;
    function setPauser(address newPauser) external;
    function claim(uint256 nftIndex, uint256 minRewardTokenSupplied, address[] calldata exemptStrategies) external;
}

/// @dev The AYieldStrategy admin surface (lib/vault/src/AYieldStrategy.sol L309). `setAsideBuffer` is never touched.
interface ISyaStrategyAdmin {
    function owner() external view returns (address);
    function pauser() external view returns (address);
    function authorizedWithdrawers(address withdrawer) external view returns (bool);
    function setWithdrawer(address withdrawer, bool auth) external;
}

/// @dev The live NFTMinterV2 surface the cutover touches.
interface INFTMinterV2SyaGateOff {
    function owner() external view returns (address);
    function nextIndex() external view returns (uint256);
    function authorizedBurners(address burner) external view returns (bool);
    function setAuthorizedBurner(address burner, bool authorized) external;
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/// @dev The live PauserV2 surface (lib/pauser/src/PauserV2.sol). `unregister` is unconditional on V2.
interface IPauserV2SyaGateOff {
    function owner() external view returns (address);
    function isRegistered(address c) external view returns (bool);
    function register(address c) external;
    function unregister(address c) external;
    function pause() external;
    function unpause() external;
    function eyeToken() external view returns (address);
    function eyeBurnAmount() external view returns (uint256);
    function getPausableContracts() external view returns (address[] memory);
}

/**
 * @title SyaGateOffMainnetBase  (story 131, sprint nft-bonfire)
 * @notice Shared constants, address-book / progress readers, the token-set check and the OWNER balance invariant for
 *         the gate-free SYA mainnet replacement (`ReplaceSYAGateOffMainnet`) and its read-only verifier
 *         (`VerifySyaGateOffMainnet`). Extends story 122's `SyaHarvesterMainnetBase` so the SYAHarvester redeploy
 *         reuses its Curve routes, ETH pool key, story-052 payload checker and read-back helpers byte for byte. Its
 *         `_preflight` (which requires `SYA.nftMinter() == book NFTMinter`) and its progress file are NOT reused:
 *         `_progressFile()` is overridden to this story's `progress.sya-gate-off.1.json`, so `_progressHarvester()`
 *         reads the NEW harvester from it.
 *
 *         Configuration safety (phStaging2 CLAUDE.md, Configuration Safety). Provenance of every value:
 *           - token configs HARD-CODED, not mirrored (human decision 2026-11-07, "No point in failing the script for
 *             something we know"): USDC 6, DOLA 18, USDe 18, each rate 1e18 (1:1). Each constant is checked against
 *             the token's on-chain `decimals()` before use, which catches a wrong address or a typo;
 *           - discount 100 bps (1%) - human decision 2026-11-06;
 *           - nftMinter left ZERO (the gate OFF) - the point of the story (yield-accumulator:028);
 *           - pauser PauserV2 (book `Pauser`, live since 2026-11-05). The V1 Pauser is RETIRED and never called;
 *           - every other wiring value (rewardToken, phlimbo, nudge, nudgeSplit, nudgeStreamer, the strategy list) is
 *             MIRRORED LIVE from the old SYA at run time; each mirrored value is `require`d non-zero / in range.
 *             Mirroring does NOT honour a phStaging2:119 nudge repoint: 119 repoints only the NEW (live) SYA and
 *             leaves the old SYA on the paused old minter (119 Decision 5). On an adopted SYA the step-3 re-run guard
 *             (story 133, audit pps55m1) refuses to write a mirrored value over a later, different one;
 *           - owner OWNER (the SYA constructor sets `Ownable(msg.sender)`, and the Ledger sender is OWNER).
 *         NO FUNDS TO THE LEDGER (human requirement 2026-11-06): OWNER only pays gas, enforced by
 *         `_snapshotOwnerBalances` / `_assertOwnerBalancesNotIncreased`.
 */
abstract contract SyaGateOffMainnetBase is SyaHarvesterMainnetBase {
    /// @dev The live SYA being retired (book `StableYieldAccumulator` until the patcher repoints it).
    address internal constant OLD_SYA = 0x0cD353bfda674D04823B2826ffafB83B560D21B6;
    /// @dev The live SYAHarvester (immutable `sya` == OLD_SYA) being replaced. Never adopted.
    address internal constant OLD_HARVESTER = 0xeE426A950Cb17D559F6391ef0D140715CD46703B;
    /// @dev Book `Pauser` (L72): PauserV2, broadcast by the human 2026-11-05 (story 128).
    address internal constant PAUSER_V2 = 0x669Ebfa5309db66683c199Cfe22516DECBe1a154;
    /// @dev The RETIRED V1 Pauser. Never called.
    address internal constant PAUSER_V1 = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;
    /// @dev Book `NFTMinter` (V2).
    address internal constant NFT_MINTER = 0x39Af088408e815844c567037C157B31d48d2E10F;

    // ---- Hard-coded token configs (human decision 2026-11-07). Addresses == book `USDC` / `Dola` / `USDe`. ----
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address internal constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    uint8 internal constant USDC_DECIMALS = 6;
    uint8 internal constant DOLA_DECIMALS = 18;
    uint8 internal constant USDE_DECIMALS = 18;
    uint256 internal constant RATE_1_TO_1 = 1e18;

    /// @dev Claim discount on the new SYA: 100 bps = 1% (human decision 2026-11-06). The old SYA runs 3000.
    uint256 internal constant NEW_DISCOUNT_BPS = 100;

    string internal constant GATE_OFF_PROGRESS_FILE = "server/deployments/progress.sya-gate-off.1.json";

    /// @notice Reverted when any OWNER balance rose across the run. `token == address(0)` is ETH; `id` is the
    ///         ERC1155 id for the NFTMinterV2 entries and 0 for ERC20s.
    error OwnerBalanceIncreased(address token, uint256 id, uint256 before, uint256 after_);

    // ============ Tokens ============

    function _targetTokens() internal pure returns (address[3] memory) {
        return [USDC, USDE, DOLA];
    }

    function _expectedDecimals(address token) internal pure returns (uint8) {
        if (token == USDC) return USDC_DECIMALS;
        if (token == DOLA) return DOLA_DECIMALS;
        if (token == USDE) return USDE_DECIMALS;
        revert("token set: not one of USDC / DOLA / USDe");
    }

    function _tokenName(address token) internal pure returns (string memory) {
        if (token == USDC) return "USDC";
        if (token == DOLA) return "DOLA";
        if (token == USDE) return "USDe";
        return "?";
    }

    /// @notice Each token's on-chain `decimals()` equals its hard-coded constant (catches a wrong address or typo).
    function _requireOnChainDecimals() internal view {
        address[3] memory t = _targetTokens();
        for (uint256 i = 0; i < 3; i++) {
            require(t[i].code.length > 0, string.concat("token has no code: ", _tokenName(t[i])));
            require(
                IERC20Metadata(t[i]).decimals() == _expectedDecimals(t[i]),
                string.concat("on-chain decimals() != hard-coded constant for ", _tokenName(t[i]))
            );
        }
    }

    /// @notice The token set check: exactly 3 strategies whose tokens are USDC, DOLA and USDe, one each. Also
    ///         cross-checks each strategy against the book's YieldStrategyUSDC / YieldStrategyUSDe / YieldStrategyDola
    ///         (a cross-check only: the list itself stays the LIVE one).
    function _requireStrategyTokenSet(address[] memory strategies, address[] memory tokens) internal view {
        require(strategies.length == 3 && tokens.length == 3, "token set: strategy list must have exactly 3 entries");
        bool seenUsdc;
        bool seenDola;
        bool seenUsde;
        string memory book = vm.readFile(ADDRESS_BOOK);
        for (uint256 i = 0; i < 3; i++) {
            address s = strategies[i];
            address t = tokens[i];
            require(s != address(0), "token set: zero strategy");
            if (t == USDC) {
                require(!seenUsdc, "token set: USDC appears more than once");
                seenUsdc = true;
                require(
                    s == _requireBook(book, "YieldStrategyUSDC"), "token set: USDC strategy != book YieldStrategyUSDC"
                );
            } else if (t == DOLA) {
                require(!seenDola, "token set: DOLA appears more than once");
                seenDola = true;
                require(
                    s == _requireBook(book, "YieldStrategyDola"), "token set: DOLA strategy != book YieldStrategyDola"
                );
            } else if (t == USDE) {
                require(!seenUsde, "token set: USDe appears more than once");
                seenUsde = true;
                require(
                    s == _requireBook(book, "YieldStrategyUSDe"), "token set: USDe strategy != book YieldStrategyUSDe"
                );
            } else {
                revert("token set: a strategy's token is not one of USDC / DOLA / USDe");
            }
        }
        require(seenUsdc && seenDola && seenUsde, "token set: USDC, DOLA and USDe must each appear once");
    }

    // ============ Address book ============

    /// @notice Book constants this story pins. Any drift refuses.
    function _requireBookMatchesConstants() internal view {
        string memory book = vm.readFile(ADDRESS_BOOK);
        require(_requireBook(book, "USDC") == USDC, "address book USDC != hard-coded USDC");
        require(_requireBook(book, "Dola") == DOLA, "address book Dola != hard-coded DOLA");
        require(_requireBook(book, "USDe") == USDE, "address book USDe != hard-coded USDe");
        require(_requireBook(book, "NFTMinter") == NFT_MINTER, "address book NFTMinter != pinned NFTMinterV2");
        require(_requireBook(book, "Pauser") == PAUSER_V2, "address book Pauser != PauserV2 (V1 is RETIRED)");
        require(PAUSER_V2 != PAUSER_V1, "PauserV2 constant is the retired V1 Pauser");
        require(NEW_DISCOUNT_BPS == 100, "discount must be the human-decided 100 bps");
    }

    /// @notice The book's `StableYieldAccumulator` key. `virtual` so fork tests can simulate the patched book.
    function _bookSya() internal view virtual returns (address) {
        return _requireBook(vm.readFile(ADDRESS_BOOK), "StableYieldAccumulator");
    }

    /// @notice The book's `SYAHarvester` key. `virtual` so fork tests can simulate the patched book.
    function _bookHarvester() internal view virtual returns (address) {
        return _requireBook(vm.readFile(ADDRESS_BOOK), "SYAHarvester");
    }

    /// @notice The story-122 harvester config, pointed at `sya` (the NEW SYA).
    function _harvesterConfig(address sya) internal view returns (Config memory c) {
        string memory book = vm.readFile(ADDRESS_BOOK);
        c.sya = sya;
        c.usdc = USDC;
        c.dola = DOLA;
        c.usde = USDE;
        c.stableStakerV2 = _requireBook(book, "StableStakerV2");
        c.nftMinter = NFT_MINTER;
    }

    // ============ Progress file ============

    function _progressFile() internal view virtual override returns (string memory) {
        return GATE_OFF_PROGRESS_FILE;
    }

    function _progressJson() internal view returns (string memory json) {
        try vm.readFile(_progressFile()) returns (string memory j) {
            json = j;
        } catch {
            json = "";
        }
    }

    function _progressAddress(string memory key) internal view returns (address) {
        string memory json = _progressJson();
        string memory path = string.concat(".contracts.", key, ".address");
        if (bytes(json).length == 0 || !vm.keyExistsJson(json, path)) return address(0);
        return vm.parseJsonAddress(json, path);
    }

    function _progressNonce(string memory key) internal view returns (bool ok, uint256 nonce) {
        string memory json = _progressJson();
        string memory path = string.concat(".contracts.", key, ".createNonce");
        if (bytes(json).length == 0 || !vm.keyExistsJson(json, path)) return (false, 0);
        return (true, vm.parseJsonUint(json, path));
    }

    /// @notice The new SYA recorded by a broadcast, or address(0) when none.
    function _progressSya() internal view returns (address) {
        return _progressAddress("StableYieldAccumulator");
    }

    /// @notice True when scripts/confirm-sya-gate-off-progress.js has marked the progress `completed`.
    function _progressCompleted() internal view returns (bool) {
        string memory json = _progressJson();
        if (bytes(json).length == 0 || !vm.keyExistsJson(json, ".deploymentStatus")) return false;
        return keccak256(bytes(vm.parseJsonString(json, ".deploymentStatus"))) == keccak256("completed");
    }

    // ============ OWNER balance invariant (no funds to the Ledger) ============

    struct OwnerBalances {
        uint256 eth;
        address[] erc20s;
        uint256[] erc20Balances;
        uint256[] nftIds;
        uint256[] nftBalances;
    }

    OwnerBalances internal ownerBefore;

    /// @notice The ERC20s whose OWNER balance must not rise: Antimatter, phUSD, the SYA tokens and their
    ///         neighbours (USDC, DOLA, USDe, sUSDe, USDS, sUSDS) and EYE. Every one read from the book (whole key).
    function _watchedErc20s() internal view returns (address[] memory t) {
        string memory book = vm.readFile(ADDRESS_BOOK);
        string[9] memory keys = ["Antimatter", "PhUSD", "USDC", "Dola", "USDe", "SUSDe", "USDS", "SUSDS", "EYE"];
        t = new address[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            t[i] = _requireBook(book, keys[i]);
        }
    }

    /// @notice Every ERC1155 id the minter knows of: 0 .. nextIndex() (0 and the next unused index as margin).
    function _watchedNftIds() internal view returns (uint256[] memory ids) {
        uint256 next = INFTMinterV2SyaGateOff(NFT_MINTER).nextIndex();
        require(next > 1 && next < 1000, "NFTMinterV2.nextIndex() out of range - cannot enumerate ids");
        ids = new uint256[](next + 1);
        for (uint256 i = 0; i <= next; i++) {
            ids[i] = i;
        }
    }

    function _readOwnerBalances() internal view returns (OwnerBalances memory b) {
        b.eth = OWNER.balance;
        b.erc20s = _watchedErc20s();
        b.erc20Balances = new uint256[](b.erc20s.length);
        for (uint256 i = 0; i < b.erc20s.length; i++) {
            b.erc20Balances[i] = IERC20(b.erc20s[i]).balanceOf(OWNER);
        }
        b.nftIds = _watchedNftIds();
        b.nftBalances = new uint256[](b.nftIds.length);
        for (uint256 i = 0; i < b.nftIds.length; i++) {
            b.nftBalances[i] = INFTMinterV2SyaGateOff(NFT_MINTER).balanceOf(OWNER, b.nftIds[i]);
        }
    }

    /// @notice Take the snapshot. Call BEFORE the first broadcast/prank call.
    function _snapshotOwnerBalances() internal {
        OwnerBalances memory b = _readOwnerBalances();
        ownerBefore.eth = b.eth;
        delete ownerBefore.erc20s;
        delete ownerBefore.erc20Balances;
        delete ownerBefore.nftIds;
        delete ownerBefore.nftBalances;
        for (uint256 i = 0; i < b.erc20s.length; i++) {
            ownerBefore.erc20s.push(b.erc20s[i]);
            ownerBefore.erc20Balances.push(b.erc20Balances[i]);
        }
        for (uint256 i = 0; i < b.nftIds.length; i++) {
            ownerBefore.nftIds.push(b.nftIds[i]);
            ownerBefore.nftBalances.push(b.nftBalances[i]);
        }
        console.log("OWNER balance snapshot taken: ETH wei", b.eth);
        console.log("  ERC20s watched:", b.erc20s.length, " NFTMinterV2 ids watched:", b.nftIds.length);
    }

    /// @notice Revert `OwnerBalanceIncreased` if any watched OWNER balance rose since the snapshot (ETH must be
    ///         non-increasing). Called AFTER the last broadcast/prank call, and inside each preview smoke.
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
            uint256 nowBal = INFTMinterV2SyaGateOff(NFT_MINTER).balanceOf(OWNER, ownerBefore.nftIds[i]);
            if (nowBal > ownerBefore.nftBalances[i]) {
                revert OwnerBalanceIncreased(NFT_MINTER, ownerBefore.nftIds[i], ownerBefore.nftBalances[i], nowBal);
            }
        }
        console.log(string.concat(stage, ": OWNER balance invariant OK (no asset credited to the Ledger account)"));
    }
}
