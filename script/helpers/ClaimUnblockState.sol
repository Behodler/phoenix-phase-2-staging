// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "@forge-std/Vm.sol";

/// @title  ClaimUnblockState  (story 122)
/// @notice Answers one question for the StableStaker V1 -> V2 cutover script and its verifier: has the
///         SYAHarvester mainnet script (story 122, Script A) deliberately opened `StableStakerV2.claim`?
///
///         The V2 cutover (stories 082-096) kept `claimEnabled == false` and asserted it in three places.
///         Story 122's `DeploySyaHarvesterMainnet` ends with `StableStakerV2.setClaimEnabled(true)`, which
///         would turn those assertions red against live mainnet. They are made state-aware rather than
///         deleted: `claimEnabled == true` is accepted ONLY once the unblock is on record, and `false`
///         stays the expectation before that.
///
///         "On record" means either
///         - the SYAHarvester progress file says the claim-enable step completed (`.claimEnabled == true`), or
///         - the address book's `SYAHarvester` key is non-zero (the patcher only fills it after a broadcast
///           whose script ended with the claim enable).
/// @dev    Reads files only; never reverts on a missing or malformed file (that is simply "not recorded").
library ClaimUnblockState {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant SYA_HARVESTER_PROGRESS = "server/deployments/progress.sya-harvester.1.json";
    string internal constant ADDRESS_BOOK = "server/deployments/mainnet-addresses.ts";

    /// @notice True when the story-122 claim unblock is recorded in the default progress file or address book.
    function recorded() internal view returns (bool) {
        return recordedAt(SYA_HARVESTER_PROGRESS, ADDRESS_BOOK);
    }

    /// @notice `recorded()` against explicit paths, so tests can point at scratch copies.
    function recordedAt(string memory progressPath, string memory bookPath) internal view returns (bool) {
        return progressRecordsClaimEnabled(progressPath) || bookHasSyaHarvester(bookPath);
    }

    function progressRecordsClaimEnabled(string memory progressPath) internal view returns (bool) {
        string memory json;
        try vm.readFile(progressPath) returns (string memory j) {
            json = j;
        } catch {
            return false;
        }
        if (bytes(json).length == 0 || !vm.keyExistsJson(json, ".claimEnabled")) return false;
        return vm.parseJsonBool(json, ".claimEnabled");
    }

    /// @dev Matches only an uncommented top-level `  SYAHarvester: "0x..."` entry.
    function bookHasSyaHarvester(string memory bookPath) internal view returns (bool) {
        string memory book;
        try vm.readFile(bookPath) returns (string memory b) {
            book = b;
        } catch {
            return false;
        }
        string memory needle = "\n  SYAHarvester: \"";
        uint256 at = vm.indexOf(book, needle);
        if (at == type(uint256).max) return false;
        bytes memory src = bytes(book);
        uint256 start = at + bytes(needle).length;
        if (src.length < start + 42) return false;
        bytes memory lit = new bytes(42);
        for (uint256 i; i < 42; i++) {
            lit[i] = src[start + i];
        }
        return vm.parseAddress(string(lit)) != address(0);
    }
}
