// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

/// @notice Pins the exact Foundry `vm.serialize*` semantics that
///         `DeployMainnetPromotionReady._writeProgressFileWithStatus` depends on after the
///         story-072 MemoryOOG fix. These are behaviours of the cheatcode implementation, not of
///         our code, so they are pinned here rather than assumed: a Foundry upgrade that changed
///         any of them would silently corrupt the mainnet progress file, which four separate
///         consumers parse (the script's own `_loadProgressFile`, `VerifyPromotionReady`,
///         `patch-mainnet-addresses-promotion-ready.js`, and the documented manual-trim procedure).
contract ProgressSerializerSemanticsTest is Test {
    /// @dev THE LOAD-BEARING ONE. The rewrite builds each contract entry into its own object key
    ///      and then folds that entry into the parent `contracts` object. That only produces the
    ///      required shape if `serializeString` embeds a valid-JSON value as a nested OBJECT
    ///      rather than as an escaped string. If this ever flips, `.contracts.<Name>.address`
    ///      stops resolving and every consumer breaks at once.
    function test_serializeString_embedsChildJsonAsObject() public {
        string memory entryKey = "sem.entry";
        vm.serializeAddress(entryKey, "address", address(0xBEEF));
        vm.serializeBool(entryKey, "deployed", true);
        string memory entry = vm.serializeUint(entryKey, "deployGas", 750710);

        string memory parent = vm.serializeString("sem.contracts", "NudgeStreamer", entry);
        string memory root = vm.serializeString("sem.root", "contracts", parent);

        // Resolves through two levels of nesting => both were embedded as objects.
        assertEq(vm.parseJsonAddress(root, ".contracts.NudgeStreamer.address"), address(0xBEEF));
        assertTrue(vm.parseJsonBool(root, ".contracts.NudgeStreamer.deployed"));
        assertEq(vm.parseJsonUint(root, ".contracts.NudgeStreamer.deployGas"), 750710);
    }

    /// @dev The serializer's Rust-side state persists for the whole run keyed by object key. The
    ///      rewrite relies on this to avoid re-serialising all ~98 entries on every one of ~186
    ///      writes — it re-emits ONE entry and gets the whole accumulated object back. If state
    ///      did not persist, each write would emit a single-entry file and silently destroy the
    ///      resume record.
    function test_serializerStatePersistsAcrossCalls() public {
        vm.serializeUint("sem.persist", "a", 1);
        vm.serializeUint("sem.persist", "b", 2);
        string memory out = vm.serializeUint("sem.persist", "c", 3);

        assertEq(vm.parseJsonUint(out, ".a"), 1);
        assertEq(vm.parseJsonUint(out, ".b"), 2);
        assertEq(vm.parseJsonUint(out, ".c"), 3);
    }

    /// @dev Re-emitting an existing key must UPDATE it in place, not duplicate it. This is what
    ///      makes `_trackDeployment` (deployed:true/configured:false) followed later by
    ///      `_trackConfig` (configured:true) settle on the latter.
    function test_reEmittingKeyUpdatesInPlace() public {
        vm.serializeBool("sem.update", "configured", false);
        string memory out = vm.serializeBool("sem.update", "configured", true);
        assertTrue(vm.parseJsonBool(out, ".configured"));
    }

    /// @dev The 23-digit baselines MUST stay JSON strings. `_loadProgressFile` reads them as
    ///      `vm.parseUint(vm.parseJsonString(...))` and the Node patcher runs them through
    ///      `JSON.parse` — as a JSON number, 18227822538254130313743 silently loses precision in
    ///      JS (it exceeds Number.MAX_SAFE_INTEGER by ~6 orders of magnitude). Pin the string
    ///      round-trip so nobody "tidies" these into serializeUint.
    function test_baselinesRoundTripAsStringsNotNumbers() public {
        uint256 bpt = 18227822538254130313743;
        vm.serializeString("sem.base", "bptAtCutover", vm.toString(bpt));
        string memory baselines = vm.serializeString("sem.base", "phusdMinterMask", vm.toString(uint256(270080)));
        string memory root = vm.serializeString("sem.baseroot", "baselines", baselines);

        // Reads back through the exact idiom `_loadProgressFile` uses.
        assertEq(vm.parseUint(vm.parseJsonString(root, ".baselines.bptAtCutover")), bpt);
        assertEq(vm.parseUint(vm.parseJsonString(root, ".baselines.phusdMinterMask")), 270080);
    }

    /// @dev A conditionally-omitted baseline must be ABSENT, not present-and-zero. The verifier
    ///      aborts loudly on an absent baseline and equally loudly on a zero one, so the two are
    ///      not interchangeable; `_loadProgressFile` distinguishes them with a try/catch.
    function test_omittedKeyIsAbsentNotZero() public {
        string memory out = vm.serializeString("sem.omit", "present", "1");
        // Routed through an external call: `vm.expectRevert` cannot wrap a cheatcode invoked at
        // the same call depth ("call didn't revert at a lower depth than cheatcode call depth").
        try this.parseJsonStringExternal(out, ".absent") returns (string memory) {
            revert("absent baseline key resolved - omission is no longer distinguishable from zero");
        } catch {}
    }

    function parseJsonStringExternal(string memory json, string memory path)
        external
        view
        returns (string memory)
    {
        return vm.parseJsonString(json, path);
    }
}
