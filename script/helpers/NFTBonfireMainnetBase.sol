// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "@forge-std/Script.sol";
import {StdCheats} from "@forge-std/StdCheats.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev The live NFTMinterV2 surface the bonfire cutover touches (lib/yield-claim-nft/src/NFTMinterV2.sol).
///      The mainnet minter was deployed from an older submodule commit, so the preview probes each getter.
interface INFTMinterV2Bonfire {
    function owner() external view returns (address);
    function nextIndex() external view returns (uint256);
    function authorizedBurners(address burner) external view returns (bool);
    function setAuthorizedBurner(address burner, bool authorized) external;
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/// @dev The live Antimatter surface (lib/antimatter/src/Antimatter.sol L188-212). `setApprovedMinter` is a SILENT
///      no-op on an unchanged value, so every call is read back with `isApprovedMinter`. `mint` is deliberately
///      absent: the cutover never mints antimatter (Antimatter lets its owner mint, and OWNER must never receive).
interface IAntimatterBonfire {
    function owner() external view returns (address);
    function setApprovedMinter(address minter, bool approved) external;
    function isApprovedMinter(address minter) external view returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev The live PauserV2 surface (lib/pauser/src/PauserV2.sol).
interface IPauserV2Bonfire {
    function owner() external view returns (address);
    function isRegistered(address c) external view returns (bool);
    function register(address c) external;
    function pause() external;
    function unpause() external;
    function eyeToken() external view returns (address);
    function eyeBurnAmount() external view returns (uint256);
    function getPausableContracts() external view returns (address[] memory);
}

/**
 * @title NFTBonfireMainnetBase  (story 129, sprint nft-bonfire)
 * @notice Shared constants, address-book readers, progress-file readers and the OWNER balance invariant for the
 *         mainnet NFTBonfire cutover (`DeployNFTBonfireMainnet`) and its read-only verifier
 *         (`VerifyNFTBonfireMainnet`).
 *
 *         Configuration safety (CLAUDE.md, Configuration Safety, L292-328). Every value below is human-confirmed:
 *           - RATE_PER_DAY = 10e18 (10 AM/day)    - human decision 2026-11-05;
 *           - MAX_PAYOUT   = 100e18 (100 AM cap)  - human decision 2026-11-05. Audit yield-claim-nft run 23 L-29
 *             suggested a 1-2 day cap (10-20 AM); the human kept 100 AM because the most expensive NFT is ~$70,
 *             and will lower it later (stop -> cap -> resume, runbook) if burn-profit premiums are excessive;
 *           - owner        = OWNER EOA (Ledger m/44'/60'/46'/0/0), which owns NFTMinterV2, Antimatter and PauserV2,
 *             so one script does everything. No ownership handoff (repo convention: no transferOwnership in script/);
 *           - NO FUNDS TO THE LEDGER (human requirement 2026-11-06): nothing in this cutover may transfer, mint or
 *             credit any asset to OWNER. OWNER only pays gas. Enforced in-script by `_snapshotOwnerBalances` /
 *             `_assertOwnerBalancesNotIncreased`, not by trust.
 *         The NFTMinterV2 / Antimatter / PauserV2 addresses are read from the hand-maintained address book
 *         (server/deployments/mainnet-addresses.ts) AND pinned here; any drift between the two refuses.
 */
abstract contract NFTBonfireMainnetBase is Script, StdCheats {
    uint256 internal constant CHAIN_ID = 1;
    string internal constant NETWORK_NAME = "mainnet";

    /// @dev The Ledger owner EOA. Pays gas. NEVER a recipient of anything.
    address internal constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    /// @dev Book `NFTMinter` (V2), L125.
    address internal constant NFT_MINTER = 0x39Af088408e815844c567037C157B31d48d2E10F;
    /// @dev Book `Antimatter`, L214.
    address internal constant ANTIMATTER = 0x9CA92B527012DfC6Fdca7B7493C722D5901FF151;
    /// @dev Book `Pauser`, L72: PauserV2, broadcast by the human on 2026-11-05 (progress.pauser-v2.1.json).
    address internal constant PAUSER_V2 = 0x669Ebfa5309db66683c199Cfe22516DECBe1a154;
    /// @dev The RETIRED V1 Pauser. Never called, never registered with.
    address internal constant PAUSER_V1 = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;

    uint256 internal constant RATE_PER_DAY = 10e18;
    uint256 internal constant MAX_PAYOUT = 100e18;

    string internal constant BOOK_FILE = "server/deployments/mainnet-addresses.ts";
    string internal constant PROGRESS_FILE = "server/deployments/progress.nft-bonfire.1.json";

    /// @notice Reverted when any OWNER balance rose across the run. `token == address(0)` is ETH; `id` is the
    ///         ERC1155 id for the NFTMinterV2 entries and 0 for ERC20s.
    error OwnerBalanceIncreased(address token, uint256 id, uint256 before, uint256 after_);

    // ============ OWNER balance invariant (no funds to the Ledger) ============

    struct OwnerBalances {
        uint256 eth;
        address[] erc20s;
        uint256[] erc20Balances;
        uint256[] nftIds;
        uint256[] nftBalances;
    }

    OwnerBalances internal ownerBefore;

    /// @notice The ERC20s whose OWNER balance must not rise: Antimatter, phUSD, the SYA reward/yield tokens
    ///         (USDC, DOLA, USDe, sUSDe, USDS, sUSDS) and EYE. Every one is read from the book (whole-key match).
    function _watchedErc20s() internal view returns (address[] memory t) {
        string memory book = vm.readFile(BOOK_FILE);
        string[9] memory keys = ["Antimatter", "PhUSD", "USDC", "Dola", "USDe", "SUSDe", "USDS", "SUSDS", "EYE"];
        t = new address[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            t[i] = _requireBook(book, keys[i]);
        }
    }

    /// @notice Every ERC1155 id the minter knows of: 0 .. nextIndex() (token id == dispatcher index; 0 and the
    ///         next unused index are included as a margin).
    function _watchedNftIds() internal view returns (uint256[] memory ids) {
        uint256 next = INFTMinterV2Bonfire(NFT_MINTER).nextIndex();
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
            b.nftBalances[i] = INFTMinterV2Bonfire(NFT_MINTER).balanceOf(OWNER, b.nftIds[i]);
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

    /// @notice Revert with `OwnerBalanceIncreased` if any watched OWNER balance rose since the snapshot. ETH must be
    ///         non-increasing (OWNER only pays gas). Called AFTER the last broadcast/prank call, and inside the
    ///         preview smoke before its snapshot is reverted.
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
            uint256 nowBal = INFTMinterV2Bonfire(NFT_MINTER).balanceOf(OWNER, ownerBefore.nftIds[i]);
            if (nowBal > ownerBefore.nftBalances[i]) {
                revert OwnerBalanceIncreased(NFT_MINTER, ownerBefore.nftIds[i], ownerBefore.nftBalances[i], nowBal);
            }
        }
        console.log(string.concat(stage, ": OWNER balance invariant OK (no asset credited to the Ledger account)"));
    }

    // ============ Address book ============

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

    /// @notice The book's `NFTBonfire` key (address(0) while it is still the ZERO placeholder). `virtual` so fork
    ///         tests can simulate the post-patch book.
    function _bookBonfire() internal view virtual returns (address) {
        string memory book = vm.readFile(BOOK_FILE);
        require(vm.indexOf(book, "\n  NFTBonfire: \"") != type(uint256).max, "address book: no NFTBonfire key");
        return _bookAddress(book, "NFTBonfire");
    }

    /// @notice The wiring targets must match the book exactly (Configuration Safety), and none may be zero/OWNER.
    function _requireBookMatchesConstants() internal view {
        string memory book = vm.readFile(BOOK_FILE);
        require(_requireBook(book, "NFTMinter") == NFT_MINTER, "address book NFTMinter != pinned NFTMinterV2");
        require(_requireBook(book, "Antimatter") == ANTIMATTER, "address book Antimatter != pinned Antimatter");
        require(_requireBook(book, "Pauser") == PAUSER_V2, "address book Pauser != PauserV2 (V1 is RETIRED)");
        require(PAUSER_V2 != PAUSER_V1, "PauserV2 constant is the retired V1 Pauser");
        require(RATE_PER_DAY != 0 && MAX_PAYOUT != 0, "rate/cap constants must be non-zero");
        require(MAX_PAYOUT >= RATE_PER_DAY, "cap below one day of accrual");
    }

    // ============ Progress file ============

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

    /// @notice The NFTBonfire recorded by a broadcast, or address(0) when none.
    function _progressBonfire() internal view returns (address) {
        string memory json = _progressJson();
        if (bytes(json).length == 0 || !vm.keyExistsJson(json, ".contracts.NFTBonfire.address")) return address(0);
        return vm.parseJsonAddress(json, ".contracts.NFTBonfire.address");
    }

    /// @notice True when scripts/confirm-nft-bonfire-progress.js has marked the progress `completed`.
    function _progressCompleted() internal view returns (bool) {
        string memory json = _progressJson();
        if (bytes(json).length == 0 || !vm.keyExistsJson(json, ".deploymentStatus")) return false;
        return keccak256(bytes(vm.parseJsonString(json, ".deploymentStatus"))) == keccak256("completed");
    }
}
