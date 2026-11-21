// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "@forge-std/Script.sol";
import {StdCheats} from "@forge-std/StdCheats.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev The live phUSD (FlaxToken, lib/flax-token-v2/src/FlaxToken.sol) surface the booster cutover touches.
///      `authorizedMinters` returns the `MinterInfo {bool canMint; uint256 mintVersion}` struct, ABI-identical to a
///      `(bool, uint256)` tuple. `revokeAllMintPrivileges` is deliberately ABSENT: it bumps the global mintVersion
///      and would invalidate every live minter. `mint` is deliberately absent too.
interface IPhUSDBooster {
    function owner() external view returns (address);
    function mintVersion() external view returns (uint256);
    function authorizedMinters(address minter) external view returns (bool canMint, uint256 mintVersion);
    function setMinter(address minter, bool canMint) external;
}

/// @dev The live Antimatter surface (lib/antimatter/src/Antimatter.sol). `mint` is deliberately absent.
interface IAntimatterBoosterView {
    function owner() external view returns (address);
    function phUSD() external view returns (address);
    function phUSDMinter() external view returns (address);
    function paused() external view returns (bool);
}

/// @dev The live PhusdStableMinter V2 surface (lib/phUSD-stable-minter/src/PhusdStableMinter.sol).
interface IPhusdStableMinterBooster {
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function stablecoinConfigs(address stable)
        external
        view
        returns (
            address yieldStrategy,
            uint256 exchangeRate,
            uint8 decimals,
            bool enabled,
            uint256 maxMintPerDay,
            uint256 mintedToday,
            uint256 lastMintTimestamp
        );
}

/// @dev The YieldStrategy principal read, exactly as AntimatterBooster._poc reads it.
interface IYieldStrategyPrincipal {
    function principalOf(address token, address client) external view returns (uint256);
}

/// @dev The live PauserV2 surface (lib/pauser/src/PauserV2.sol).
interface IPauserV2Booster {
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
 * @title AntimatterBoosterMainnetBase  (story 139, sprint antimatter-boost)
 * @notice Shared constants, address-book readers, progress-file readers, the OWNER balance invariant and the phUSD
 *         minter-set integrity snapshot for the mainnet AntimatterBooster cutover (`DeployAntimatterBoosterMainnet`)
 *         and its read-only verifier (`VerifyAntimatterBoosterMainnet`).
 *
 *         Configuration safety. Every value below is human-confirmed or read from the hand-maintained book:
 *           - BOOST_BPS = 1_500 (15%)  - human decision at planning, 2026-11-21 (antimatter MAX_BOOST_BPS is 2_500);
 *           - tracked stables DOLA / USDC / USDe - all three, so the 1/6 POC denominator is right;
 *           - owner = OWNER EOA (Ledger m/44'/60'/46'/0/0), which owns phUSD, Antimatter, the active minter and
 *             PauserV2, so one script does everything;
 *           - OWNER phUSD mint revoke (`phUSD.setMinter(OWNER, false)`) as the LAST step - human request (safety);
 *           - NO FUNDS TO THE LEDGER: nothing may transfer, mint or credit any asset to OWNER, not even in transit.
 *             Enforced in-script after EVERY transaction by `_assertOwnerBalancesNotIncreased`.
 *         POC is measured against the ACTIVE minter only (`Antimatter.phUSDMinter()`), never the legacy V1 minter
 *         0x435B0A1884bd0fb5667677C9eb0e59425b1477E5 (it holds ~3,749.6 USDe in the shared USDe strategy and is
 *         excluded by AntimatterBooster's design, NatSpec L28-30). V1 appears below only in the minter-set snapshot.
 */
abstract contract AntimatterBoosterMainnetBase is Script, StdCheats {
    uint256 internal constant CHAIN_ID = 1;
    string internal constant NETWORK_NAME = "mainnet";

    /// @dev The Ledger owner EOA. Pays gas. NEVER a recipient of anything.
    address internal constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    /// @dev Book `PhUSD`.
    address internal constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    /// @dev Book `PhusdStableMinter` (V2, the ACTIVE minter Antimatter deposits through).
    address internal constant PHUSD_STABLE_MINTER = 0x94855ACA13952D81507C92D3CdBb2e25D3bbE60C;
    /// @dev Book `Antimatter`.
    address internal constant ANTIMATTER = 0x9CA92B527012DfC6Fdca7B7493C722D5901FF151;
    /// @dev Book `Pauser`: PauserV2 (story 128).
    address internal constant PAUSER_V2 = 0x669Ebfa5309db66683c199Cfe22516DECBe1a154;
    /// @dev The RETIRED V1 Pauser. Never called, never registered with.
    address internal constant PAUSER_V1 = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;

    /// @dev Book `Dola` / `USDC` / `USDe` and their book strategies (the active minter's registrations).
    address internal constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address internal constant YS_DOLA = 0x981c7BE1460c7C8Cb40B8EB5908B29510Ae0B7EE; // sDOLA strategy (story 092)
    address internal constant YS_USDC = 0xaFDf8DeA96a0F37Aae4869f813901bf73a3eAB83;
    address internal constant YS_USDE = 0xaC2e5936Eca286eC364d4D5Bcca33145fBe57f95; // shared with V1 minter

    /// @dev The initial boost: 15% of the full annihilation output. ONE constant (human decision 2026-11-21).
    uint256 internal constant BOOST_BPS = 1_500;
    /// @dev AntimatterBooster.MAX_BOOST_BPS, re-checked against the deployed contract.
    uint256 internal constant MAX_BOOST_BPS = 2_500;

    string internal constant BOOK_FILE = "server/deployments/mainnet-addresses.ts";
    string internal constant PROGRESS_FILE = "server/deployments/progress.antimatter-booster.1.json";

    /// @notice Reverted when any OWNER balance rose. `token == address(0)` is ETH.
    error OwnerBalanceIncreased(address token, uint256 before, uint256 after_);
    /// @notice Reverted when a phUSD minter-set entry other than the booster / OWNER changed across the run.
    error MinterSetChanged(
        address who, bool canMintBefore, uint256 versionBefore, bool canMintAfter, uint256 versionAfter
    );
    /// @notice Reverted when phUSD's global mintVersion moved (only `revokeAllMintPrivileges` moves it).
    error MintVersionChanged(uint256 before, uint256 after_);
    /// @notice Reverted when the booster is not a live phUSD minter after wiring.
    error BoosterNotLiveMinter(address booster);
    /// @notice Reverted when OWNER still holds the phUSD mint right after wiring.
    error OwnerStillPhusdMinter();

    // ============ OWNER balance invariant (no funds to the Ledger) ============

    struct OwnerBalances {
        uint256 eth;
        address[] erc20s;
        uint256[] erc20Balances;
    }

    OwnerBalances internal ownerBefore;

    /// @notice The ERC20s whose OWNER balance must not rise. Every one is read from the book (whole-key match).
    function _watchedErc20s() internal view returns (address[] memory t) {
        string memory book = vm.readFile(_bookFile());
        string[9] memory keys = ["Antimatter", "PhUSD", "USDC", "Dola", "USDe", "SUSDe", "USDS", "SUSDS", "EYE"];
        t = new address[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            t[i] = _requireBook(book, keys[i]);
        }
    }

    /// @notice Take the snapshot. Call BEFORE the first broadcast/prank call.
    function _snapshotOwnerBalances() internal {
        address[] memory t = _watchedErc20s();
        ownerBefore.eth = OWNER.balance;
        delete ownerBefore.erc20s;
        delete ownerBefore.erc20Balances;
        for (uint256 i = 0; i < t.length; i++) {
            ownerBefore.erc20s.push(t[i]);
            ownerBefore.erc20Balances.push(IERC20(t[i]).balanceOf(OWNER));
        }
        console.log("OWNER balance snapshot taken: ETH wei", ownerBefore.eth, " ERC20s watched:", t.length);
    }

    /// @notice Revert `OwnerBalanceIncreased` if any watched OWNER balance rose since the snapshot (ETH must be
    ///         non-increasing: OWNER only pays gas). Called after EVERY transaction, inside the preview smoke before
    ///         its snapshot is reverted, and at the end of the run.
    function _assertOwnerBalancesNotIncreased(string memory stage) internal view {
        require(ownerBefore.erc20s.length > 0, "OWNER balance snapshot was never taken");
        if (OWNER.balance > ownerBefore.eth) revert OwnerBalanceIncreased(address(0), ownerBefore.eth, OWNER.balance);
        for (uint256 i = 0; i < ownerBefore.erc20s.length; i++) {
            uint256 nowBal = IERC20(ownerBefore.erc20s[i]).balanceOf(OWNER);
            if (nowBal > ownerBefore.erc20Balances[i]) {
                revert OwnerBalanceIncreased(ownerBefore.erc20s[i], ownerBefore.erc20Balances[i], nowBal);
            }
        }
        console.log(string.concat("  ", stage, ": OWNER balance invariant OK"));
    }

    // ============ phUSD minter-set integrity ============

    /// @notice Every address that has ever been named in a phUSD `MinterSet` event (read from the phUSD logs at
    ///         block ~26,466,600), live or revoked. Snapshotting revoked entries too means a stray RE-GRANT is caught,
    ///         not only a stray revoke. The cutover may change exactly two entries: the booster (added) and OWNER
    ///         (revoked). APPEND ONLY.
    function _knownMinterCandidates() internal pure returns (address[] memory set) {
        set = new address[](19);
        // live phUSD minters at planning
        set[0] = OWNER; // revoked by this cutover (step 6)
        set[1] = 0xA06ae98c150f3ab5c109Df05Fc51be1dC25E2573; // unidentified, paused, owned by OWNER (out of scope)
        set[2] = 0x3984eBC84d45a889dDAc595d13dc0aC2E54819F4; // PhlimboEA (legacy, out of scope)
        set[3] = 0x4A26ad83306a2F17155799fDD9449f77eb3F8bD7; // BalancerPoolerMintDebtHook
        set[4] = PHUSD_STABLE_MINTER; // PhusdStableMinter V2 (active)
        set[5] = 0x0F05c34d458dd8953864a56857a2bb67ecb22683; // UniboostHookEYE
        set[6] = 0xfe4Ed16a8450c76768e1EB5FF8292806E2204a2A; // UniboostHookSCX
        set[7] = 0x8F48E5431814FfaC9c35cf934Aa2556A946Fb33C; // UniboostHookFLX
        set[8] = 0x09AceB96337df1316e0D2d7EEEa44d754D1f8d05; // NudgeRatchetMintDebtHook
        set[9] = 0x8D3A8E3ba43DEb8C7e2110DF437a92243523b6ca; // PhlimboV3
        set[10] = 0xA6d3fc83C91B8319D219cEB12B46e3dfF064B58F; // StableStakerV2
        set[11] = ANTIMATTER; // Antimatter
        // revoked at planning (a re-grant would be an unexpected change)
        set[12] = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5; // PhusdStableMinter V1
        set[13] = 0xbce8ABC09BaEDCabE93419bF875f6186e182079A; // StableStaker V1
        set[14] = 0x6084a02C2Ac0127ddF1e617De257c61480A2AeE0; // PhlimboV2
        set[15] = 0xBe79DC2C302165025166f09193d9905EF262C064;
        set[16] = 0x14277a0BC38a6bb7eb732c3A49190030632F727e;
        set[17] = 0xb50CaF00647127F7A4945C4b007c4EfA205364dE;
        set[18] = 0xdCddB2F6548D5F1baC812110679E4c87e4BA9958;
    }

    struct MinterEntry {
        bool canMint;
        uint256 version;
    }

    MinterEntry[] internal minterBefore;
    uint256 internal mintVersionBefore;
    bool internal minterSnapshotTaken;

    function _minterInfo(address a) internal view returns (bool canMint, uint256 version) {
        (canMint, version) = IPhUSDBooster(PHUSD).authorizedMinters(a);
    }

    /// @notice True when `a` can mint phUSD right now (FlaxToken.mint: `canMint && version == mintVersion`).
    function _isLivePhusdMinter(address a) internal view returns (bool) {
        (bool canMint, uint256 version) = _minterInfo(a);
        return canMint && version == IPhUSDOwnerVersion(PHUSD).mintVersion();
    }

    /// @notice Snapshot every known candidate's `authorizedMinters` entry plus the global mintVersion. Call BEFORE
    ///         the first transaction. On a resume the snapshot reflects the chain as it stands, so a booster grant
    ///         or OWNER revoke from an earlier leg is simply "already changed" - the post-wiring assert checks those
    ///         two entries ABSOLUTELY and every other entry RELATIVELY, which never relaxes for anyone else.
    function _snapshotMinterSet() internal {
        address[] memory set = _knownMinterCandidates();
        delete minterBefore;
        for (uint256 i = 0; i < set.length; i++) {
            (bool c, uint256 v) = _minterInfo(set[i]);
            minterBefore.push(MinterEntry(c, v));
        }
        mintVersionBefore = IPhUSDBooster(PHUSD).mintVersion();
        minterSnapshotTaken = true;
        console.log("phUSD minter-set snapshot taken: candidates", set.length, " mintVersion", mintVersionBefore);
    }

    /// @notice After wiring: exactly two changes. The booster is a live minter, OWNER is revoked
    ///         (`canMint == false`), every other candidate is byte-identical to the snapshot, and mintVersion is still
    ///         0 (and unchanged). Anything else reverts by name.
    function _assertMinterSetDelta(address booster) internal view {
        require(minterSnapshotTaken, "minter-set snapshot was never taken");
        uint256 mv = IPhUSDBooster(PHUSD).mintVersion();
        if (mv != mintVersionBefore || mv != 0) revert MintVersionChanged(mintVersionBefore, mv);
        address[] memory set = _knownMinterCandidates();
        for (uint256 i = 0; i < set.length; i++) {
            (bool c, uint256 v) = _minterInfo(set[i]);
            if (set[i] == OWNER) {
                if (c) revert OwnerStillPhusdMinter();
                continue;
            }
            if (set[i] == booster) continue; // checked absolutely below
            if (c != minterBefore[i].canMint || v != minterBefore[i].version) {
                revert MinterSetChanged(set[i], minterBefore[i].canMint, minterBefore[i].version, c, v);
            }
        }
        if (!_isLivePhusdMinter(booster)) revert BoosterNotLiveMinter(booster);
        console.log("  phUSD minter-set delta OK: booster added, OWNER revoked, all else unchanged, mintVersion 0");
    }

    // ============ Active-minter POC (mirrors AntimatterBooster._poc) ============

    /// @notice The ACTIVE minter, resolved at runtime. Never V1, never hard-coded into the math.
    function _activeMinter() internal view returns (address) {
        return IAntimatterBoosterView(ANTIMATTER).phUSDMinter();
    }

    /// @notice Normalised principal of `stable` held by the active minter, exactly as the booster measures it.
    function _minterPoc18(address stable) internal view returns (uint256) {
        address m = _activeMinter();
        (address ys,, uint8 dec,,,,) = IPhusdStableMinterBooster(m).stablecoinConfigs(stable);
        require(ys != address(0) && dec <= 18, "POC: stable not registered on the active minter");
        return IYieldStrategyPrincipal(ys).principalOf(stable, m) * 10 ** (18 - dec);
    }

    // ============ Address book ============

    /// @dev `virtual` so fork tests can point the book reader at a scratch copy (book-mismatch refusal test).
    function _bookFile() internal view virtual returns (string memory) {
        return BOOK_FILE;
    }

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

    /// @notice The book's `AntimatterBooster` key (address(0) while it is still the ZERO placeholder). `virtual` so
    ///         fork tests can simulate the post-patch book.
    function _bookBooster() internal view virtual returns (address) {
        string memory book = vm.readFile(_bookFile());
        require(
            vm.indexOf(book, "\n  AntimatterBooster: \"") != type(uint256).max, "address book: no AntimatterBooster key"
        );
        return _bookAddress(book, "AntimatterBooster");
    }

    /// @notice Every pinned target must match the book exactly (Configuration Safety).
    function _requireBookMatchesConstants() internal view {
        string memory book = vm.readFile(_bookFile());
        require(_requireBook(book, "PhUSD") == PHUSD, "address book PhUSD != pinned phUSD");
        require(
            _requireBook(book, "PhusdStableMinter") == PHUSD_STABLE_MINTER,
            "address book PhusdStableMinter != pinned active minter (V2)"
        );
        require(_requireBook(book, "Antimatter") == ANTIMATTER, "address book Antimatter != pinned Antimatter");
        require(_requireBook(book, "Pauser") == PAUSER_V2, "address book Pauser != PauserV2 (V1 is RETIRED)");
        require(_requireBook(book, "Dola") == DOLA, "address book Dola != pinned DOLA");
        require(_requireBook(book, "USDC") == USDC, "address book USDC != pinned USDC");
        require(_requireBook(book, "USDe") == USDE, "address book USDe != pinned USDe");
        require(_requireBook(book, "YieldStrategyDola") == YS_DOLA, "address book YieldStrategyDola != pinned");
        require(_requireBook(book, "YieldStrategyUSDC") == YS_USDC, "address book YieldStrategyUSDC != pinned");
        require(_requireBook(book, "YieldStrategyUSDe") == YS_USDE, "address book YieldStrategyUSDe != pinned");
        require(PAUSER_V2 != PAUSER_V1, "PauserV2 constant is the retired V1 Pauser");
        require(BOOST_BPS > 0 && BOOST_BPS <= MAX_BOOST_BPS, "BOOST_BPS out of (0, MAX_BOOST_BPS]");
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

    /// @notice The AntimatterBooster recorded by a broadcast, or address(0) when none.
    function _progressBooster() internal view returns (address) {
        string memory json = _progressJson();
        if (bytes(json).length == 0 || !vm.keyExistsJson(json, ".contracts.AntimatterBooster.address")) {
            return address(0);
        }
        return vm.parseJsonAddress(json, ".contracts.AntimatterBooster.address");
    }

    /// @notice True when scripts/confirm-antimatter-booster-progress.js has marked the progress `completed`.
    function _progressCompleted() internal view returns (bool) {
        string memory json = _progressJson();
        if (bytes(json).length == 0 || !vm.keyExistsJson(json, ".deploymentStatus")) return false;
        return keccak256(bytes(vm.parseJsonString(json, ".deploymentStatus"))) == keccak256("completed");
    }
}

/// @dev Separate one-function view so `_isLivePhusdMinter` reads stay obviously read-only.
interface IPhUSDOwnerVersion {
    function mintVersion() external view returns (uint256);
}
