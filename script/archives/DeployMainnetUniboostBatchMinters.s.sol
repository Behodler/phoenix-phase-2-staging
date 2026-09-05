// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {NFTMinterV2} from "@yield-claim-nft/NFTMinterV2.sol";
import {BatchNFTMinter} from "nft-staking/BatchNFTMinter.sol";
import {ITokenMinterV2} from "@yield-claim-nft/interfaces/ITokenMinterV2.sol";

/**
 * @title DeployMainnetUniboostBatchMinters
 * @notice Follow-up to the Story 071 Uniboost cutover: deploy the three dedicated per-token
 *         BatchNFTMinter UI entry-points the frontend expects (EyeBatchNFTMinter /
 *         ScxBatchNFTMinter / FlxBatchNFTMinter), one per live Uniboost dispatcher
 *         (EYE=index 1, SCX=index 2, FLX=index 3). A BatchNFTMinter pins exactly one dispatcher
 *         index, so each Uniboost NFT needs its own instance to be batch-mintable in one tx.
 *
 *         Mirrors DeployMocks._deployNudgelessBatchMinter exactly:
 *           new BatchNFTMinter(owner) -> setTokenMinter(NFTMinterV2) -> setDispatcherIndex(idx).
 *
 *         ---- Nudge DELIBERATELY DISABLED (safety) ----
 *         These are "pure loopers": nudgeSize stays 0 and nudgePaymentToken stays address(0)
 *         (the constructor defaults — the nudge setters are intentionally NEVER called). A
 *         configured nudge on a permissionless batchMint is a known USDC-drain vector, so we
 *         leave it off and ASSERT it off in _verifyFinalState.
 *
 *         ---- Donation wiring is NOT touched ----
 *         This script calls NO Uniboost setter. Each Uniboost's donation recipient must remain
 *         the shared index-4 LSP BatchNFTMinter (0x86866e..) so every Uniboost mint keeps
 *         nudging the BalancerPooler NFT (phUSD liquidity). We assert recipient()==0x86866e..
 *         for all three Uniboosts BOTH before (precondition) and after (verification) — belt and
 *         braces, even though we never write to them.
 *
 * LEDGER SIGNER: Owner 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 (HD path m/44'/60'/46'/0/0)
 *
 * Dry run:   PREVIEW_MODE=true forge script script/DeployMainnetUniboostBatchMinters.s.sol:DeployMainnetUniboostBatchMinters --rpc-url $RPC_MAINNET -vvv
 * Broadcast: see npm run uniboost-batchminters:broadcast (legacy gas, per the story-071 gas lesson).
 */
contract DeployMainnetUniboostBatchMinters is Script {
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant NFT_MINTER_V2 = 0x39Af088408e815844c567037C157B31d48d2E10F;

    // Live Uniboost dispatchers (deployed by the Story 071 cutover), registered at indices 1/2/3.
    address public constant UNIBOOST_EYE = 0x63f4aCE0304d795A458fc2567F2c4eFeB60970CA;
    address public constant UNIBOOST_SCX = 0xea6bAa2170E60e9069646d689730533176c59a03;
    address public constant UNIBOOST_FLX = 0xb490c48701eB44D59af4A530d75B4fd3E79B5ddD;

    uint256 public constant EYE_INDEX = 1;
    uint256 public constant SCX_INDEX = 2;
    uint256 public constant FLX_INDEX = 3;

    // The shared index-4 LSP BatchNFTMinter every Uniboost donates to. Asserted, never written.
    address public constant DONATION_RECIPIENT = 0x86866e01a115C17892Ed04c548F2e8638851029d;

    string constant PROGRESS_FILE = "server/deployments/progress.uniboost-batchminters.1.json";
    uint256 constant CHAIN_ID = 1;
    string constant NETWORK_NAME = "mainnet";

    struct Entry {
        string name;
        address addr;
        bool deployed;
    }

    mapping(string => Entry) public deployments;
    string[] public contractNames;
    bool isPreview;

    address public eyeBatchNFTMinter;
    address public scxBatchNFTMinter;
    address public flxBatchNFTMinter;

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "Wrong chain id - expected Mainnet (1)");
    }

    function run() external {
        console.log("=========================================");
        console.log("  MAINNET UNIBOOST BATCH MINTERS (story 071 follow-up)");
        console.log("=========================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        _loadProgressFile();
        isPreview = vm.envOr("PREVIEW_MODE", false);

        _phase0_preconditions();

        if (isPreview) {
            console.log("\n*** PREVIEW MODE - impersonating owner (no signing, no progress file) ***\n");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        eyeBatchNFTMinter = _deployNudgelessBatchMinter(UNIBOOST_EYE, EYE_INDEX, "EyeBatchNFTMinter");
        scxBatchNFTMinter = _deployNudgelessBatchMinter(UNIBOOST_SCX, SCX_INDEX, "ScxBatchNFTMinter");
        flxBatchNFTMinter = _deployNudgelessBatchMinter(UNIBOOST_FLX, FLX_INDEX, "FlxBatchNFTMinter");

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        _verifyFinalState();

        if (!isPreview) {
            _writeProgressFile("completed");
        }
        _printSummary();
    }

    function _phase0_preconditions() internal view {
        console.log("\n=== Phase 0: Preconditions ===");
        require(NFTMinterV2(NFT_MINTER_V2).owner() == OWNER_ADDRESS, "NFTMinterV2.owner != OWNER");

        // Uniboosts must be registered at their expected indices (cutover completed).
        require(NFTMinterV2(NFT_MINTER_V2).dispatcherToIndex(UNIBOOST_EYE) == EYE_INDEX, "EYE not at index 1");
        require(NFTMinterV2(NFT_MINTER_V2).dispatcherToIndex(UNIBOOST_SCX) == SCX_INDEX, "SCX not at index 2");
        require(NFTMinterV2(NFT_MINTER_V2).dispatcherToIndex(UNIBOOST_FLX) == FLX_INDEX, "FLX not at index 3");

        // Donation wiring must already point at the shared LSP BatchNFTMinter (we must NOT change it).
        require(IRecipientReadable(UNIBOOST_EYE).recipient() == DONATION_RECIPIENT, "EYE recipient != 0x86866e..");
        require(IRecipientReadable(UNIBOOST_SCX).recipient() == DONATION_RECIPIENT, "SCX recipient != 0x86866e..");
        require(IRecipientReadable(UNIBOOST_FLX).recipient() == DONATION_RECIPIENT, "FLX recipient != 0x86866e..");
        console.log("Preconditions OK: indices 1/2/3 registered; donations all -> 0x86866e.. (untouched)");
    }

    function _deployNudgelessBatchMinter(address uniboost, uint256 expectedIdx, string memory name)
        internal
        returns (address addr)
    {
        uint256 idx = NFTMinterV2(NFT_MINTER_V2).dispatcherToIndex(uniboost);
        require(idx == expectedIdx, "batch minter: uniboost index mismatch");

        BatchNFTMinter bm;
        if (_isDeployed(name)) {
            bm = BatchNFTMinter(deployments[name].addr);
            console.log(string.concat(name, " already deployed at:"), address(bm));
        } else {
            bm = new BatchNFTMinter(OWNER_ADDRESS);
            _track(name, address(bm));
            if (!isPreview) _writeProgressFile("in_progress");
            console.log(string.concat(name, " deployed at:"), address(bm));
        }

        // Idempotent wiring (only write if not already correct on-chain), pinning the trusted
        // minter + dispatcher index so batchMint is enabled. Nudge setters are NEVER called.
        if (address(bm.tokenMinter()) != NFT_MINTER_V2) {
            bm.setTokenMinter(ITokenMinterV2(NFT_MINTER_V2));
            console.log(string.concat(name, ".setTokenMinter -> NFTMinterV2"));
        }
        if (bm.dispatcherIndex() != idx) {
            bm.setDispatcherIndex(idx);
            console.log(string.concat(name, ".setDispatcherIndex ->"), idx);
        }
        addr = address(bm);
    }

    function _verifyFinalState() internal view {
        console.log("\n=== Verification ===");
        _verifyOne(eyeBatchNFTMinter, EYE_INDEX, "Eye");
        _verifyOne(scxBatchNFTMinter, SCX_INDEX, "Scx");
        _verifyOne(flxBatchNFTMinter, FLX_INDEX, "Flx");

        // Donation wiring must be exactly as we found it (we never touched a Uniboost).
        require(IRecipientReadable(UNIBOOST_EYE).recipient() == DONATION_RECIPIENT, "post: EYE recipient changed");
        require(IRecipientReadable(UNIBOOST_SCX).recipient() == DONATION_RECIPIENT, "post: SCX recipient changed");
        require(IRecipientReadable(UNIBOOST_FLX).recipient() == DONATION_RECIPIENT, "post: FLX recipient changed");
        console.log("  Uniboost donations still all -> 0x86866e.. (BalancerPooler nudge intact)");
    }

    function _verifyOne(address bmAddr, uint256 expectedIdx, string memory label) internal view {
        require(bmAddr != address(0) && bmAddr.code.length > 0, string.concat(label, ": batch minter has no code"));
        BatchNFTMinter bm = BatchNFTMinter(bmAddr);
        require(address(bm.tokenMinter()) == NFT_MINTER_V2, string.concat(label, ": tokenMinter wrong"));
        require(bm.dispatcherIndex() == expectedIdx, string.concat(label, ": dispatcherIndex wrong"));
        require(bm.nudgeSize() == 0, string.concat(label, ": nudgeSize must be 0 (nudge disabled)"));
        require(bm.nudgePaymentToken() == address(0), string.concat(label, ": nudgePaymentToken must be 0"));
        require(bm.owner() == OWNER_ADDRESS, string.concat(label, ": owner != OWNER"));
        console.log(string.concat("  ", label, "BatchNFTMinter OK (wired, nudge disabled, owner=OWNER):"), bmAddr);
    }

    // ------------------------- progress file -------------------------

    function _loadProgressFile() internal {
        try vm.readFile(PROGRESS_FILE) returns (string memory json) {
            if (bytes(json).length > 0) {
                _parseEntry(json, "EyeBatchNFTMinter");
                _parseEntry(json, "ScxBatchNFTMinter");
                _parseEntry(json, "FlxBatchNFTMinter");
            }
        } catch {
            console.log("No existing progress file, starting fresh");
        }
    }

    function _parseEntry(string memory json, string memory name) internal {
        try vm.parseJsonAddress(json, string.concat(".contracts.", name, ".address")) returns (address a) {
            bool dep;
            try vm.parseJsonBool(json, string.concat(".contracts.", name, ".deployed")) returns (bool d) {
                dep = d;
            } catch {}
            if (dep && a != address(0)) {
                deployments[name] = Entry({name: name, addr: a, deployed: true});
                contractNames.push(name);
                console.log("Loaded from progress:", name, a);
            }
        } catch {}
    }

    /// @dev A progress address with NO on-chain code is a phantom (a poisoned "completed" written
    ///      during simulation but never broadcast) — treat it as NOT deployed so it redeploys.
    function _isDeployed(string memory name) internal view returns (bool) {
        address a = deployments[name].addr;
        return deployments[name].deployed && a != address(0) && a.code.length > 0;
    }

    function _track(string memory name, address addr) internal {
        if (deployments[name].addr == address(0)) contractNames.push(name);
        deployments[name] = Entry({name: name, addr: addr, deployed: true});
    }

    function _writeProgressFile(string memory status) internal {
        string memory json = string.concat(
            '{"chainId": ',
            vm.toString(CHAIN_ID),
            ',"networkName": "',
            NETWORK_NAME,
            '","deploymentStatus": "',
            status,
            '","contracts": {'
        );
        for (uint256 i = 0; i < contractNames.length; i++) {
            string memory name = contractNames[i];
            Entry memory e = deployments[name];
            if (i > 0) json = string.concat(json, ",");
            json = string.concat(
                json, '"', name, '": {"address": "', vm.toString(e.addr), '","deployed": ', e.deployed ? "true" : "false", "}"
            );
        }
        json = string.concat(json, "}}");
        vm.writeFile(PROGRESS_FILE, json);
        console.log("Progress file updated:", PROGRESS_FILE);
    }

    function _printSummary() internal view {
        console.log("\n=========================================");
        console.log("  UNIBOOST BATCH MINTERS SUMMARY");
        console.log("EyeBatchNFTMinter:", eyeBatchNFTMinter);
        console.log("ScxBatchNFTMinter:", scxBatchNFTMinter);
        console.log("FlxBatchNFTMinter:", flxBatchNFTMinter);
        console.log("=========================================");
    }
}

/// @dev Minimal read surface of a Uniboost dispatcher — just its donation recipient.
interface IRecipientReadable {
    function recipient() external view returns (address);
}
