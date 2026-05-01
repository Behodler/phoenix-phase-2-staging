// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@pauser/Pauser.sol";
import {BalancerPoolerMintDebtHook} from "@yield-claim-nft/V2/hooks/BalancerPoolerMintDebtHook.sol";
import {IDispatchHook} from "@yield-claim-nft/V2/interfaces/IDispatchHook.sol";
import {IBalancerPoolerMintDebtHook} from "@yield-claim-nft/V2/interfaces/IBalancerPoolerMintDebtHook.sol";
import {BalancerPoolerV2} from "@yield-claim-nft/V2/dispatchers/BalancerPoolerV2.sol";
import {NFTStaker} from "nft-staking/NFTStaker.sol";
import {BatchNFTMinter} from "nft-staking/BatchNFTMinter.sol";
import {INFTSupply} from "nft-staking/INFTSupply.sol";
import {FlaxToken} from "@flax-token/FlaxToken.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployMainnetNFTStaking
 * @notice Differential mainnet deployment for the NFT staking trio
 *         (BalancerPoolerMintDebtHook, NFTStaker, BatchNFTMinter), plus a
 *         setAuthorizedPooler(deployer, true) call on the live BalancerPoolerV2
 *         dispatcher. Mirrors Phase 3.7 of DeployMocks.s.sol and the
 *         preview/broadcast/progress pattern of DeployMainnetNFTV2.s.sol.
 *
 *         Wiring order (matters):
 *           1. Deploy BalancerPoolerMintDebtHook(owner, dispatcher, phUSD).
 *           2. BalancerPoolerV2.setHook(hook).
 *           3. Deploy NFTStaker(NFTMinterV2, 4, phUSD, owner, NFTMinterV2, 4).
 *           4. NFTStaker.setDispatcherHook(hook).
 *           5. hook.setRecipient(NFTStaker).
 *           6. FlaxToken(phUSD).setMinter(hook, true).
 *           7. NFTStaker.setTargetAPY(0.3e18) // 30%.
 *           8. Deploy BatchNFTMinter().
 *           9. NFTStaker.setPauser(Pauser); Pauser.register(NFTStaker).
 *          10. BalancerPoolerV2.setAuthorizedPooler(owner, true).
 *
 * LEDGER SIGNER:
 *   Owner: 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 (HD path m/44'/60'/46'/0/0)
 *
 * Dry run:
 *   PREVIEW_MODE=true forge script script/DeployMainnetNFTStaking.s.sol --rpc-url $RPC_MAINNET --slow -vvv
 *
 * Broadcast:
 *   forge script script/DeployMainnetNFTStaking.s.sol --rpc-url $RPC_MAINNET --broadcast
 *     --skip-simulation --slow --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */
contract DeployMainnetNFTStaking is Script {
    // ==========================================
    //         LIVE MAINNET ADDRESSES
    // ==========================================

    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant PAUSER = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;
    address public constant BALANCER_POOLER_V2 = 0x6e957842AFBCD01cE9DB296D173F39134b362771;
    address public constant NFT_MINTER_V2 = 0x39Af088408e815844c567037C157B31d48d2E10F;

    // ==========================================
    //         CONFIGURATION CONSTANTS
    // ==========================================

    /// @notice 30% APY (1e18-scaled fraction). Bounded by NFTStaker.MAX_TARGET_APY = 0.5e18.
    uint256 public constant TARGET_APY = 0.3e18;

    /// @notice The dispatcher slot index that BalancerPoolerV2 occupies in NFTMinterV2.
    ///         Used as both NFTStaker._stakedId and ._dispatcherIndex.
    uint256 public constant BALANCER_POOLER_DISPATCHER_INDEX = 4;

    // ==========================================
    //         DEPLOYMENT STATE
    // ==========================================

    address public balancerPoolerHook;
    address public nftStaker;
    address public batchNFTMinter;

    // Progress tracking
    string constant PROGRESS_FILE = "server/deployments/progress.nft-staking.1.json";
    uint256 constant CHAIN_ID = 1;
    string constant NETWORK_NAME = "mainnet";

    struct ContractDeployment {
        string name;
        address addr;
        bool deployed;
        bool configured;
        uint256 deployGas;
        uint256 configGas;
    }

    mapping(string => ContractDeployment) public deployments;
    string[] public contractNames;
    bool progressFileExists;
    bool isPreview;

    function run() external {
        console.log("=========================================");
        console.log("  MAINNET NFT STAKING DEPLOYMENT");
        console.log("=========================================");
        console.log("Chain ID:", block.chainid);
        console.log("Expected Chain ID:", CHAIN_ID);
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        console.log("");
        console.log("--- EXISTING CONTRACTS ---");
        console.log("Owner (ledger):       ", OWNER_ADDRESS);
        console.log("phUSD (FlaxToken):    ", PHUSD);
        console.log("Pauser:               ", PAUSER);
        console.log("BalancerPoolerV2:     ", BALANCER_POOLER_V2);
        console.log("NFTMinterV2:          ", NFT_MINTER_V2);
        console.log("Dispatcher index:     ", BALANCER_POOLER_DISPATCHER_INDEX);
        console.log("Target APY (1e18):    ", TARGET_APY);
        console.log("----------------------------------------------------");

        _loadProgressFile();

        isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("");
            console.log("*** PREVIEW MODE - Impersonating owner (no signing required) ***");
            console.log("*** Progress file will NOT be written ***");
            console.log("");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        // ====== Step 1: Deploy BalancerPoolerMintDebtHook ======
        console.log("\n=== Step 1: Deploy BalancerPoolerMintDebtHook ===");
        _deployHook();

        // ====== Step 2: Install hook on BalancerPoolerV2 ======
        console.log("\n=== Step 2: BalancerPoolerV2.setHook(hook) ===");
        _setHookOnDispatcher();

        // ====== Step 3: Deploy NFTStaker ======
        console.log("\n=== Step 3: Deploy NFTStaker ===");
        _deployNFTStaker();

        // ====== Step 4: NFTStaker.setDispatcherHook ======
        console.log("\n=== Step 4: NFTStaker.setDispatcherHook(hook) ===");
        _setDispatcherHookOnStaker();

        // ====== Step 5: hook.setRecipient(NFTStaker) ======
        console.log("\n=== Step 5: hook.setRecipient(NFTStaker) ===");
        _setRecipientOnHook();

        // ====== Step 6: FlaxToken.setMinter(hook, true) ======
        console.log("\n=== Step 6: phUSD.setMinter(hook, true) ===");
        _authorizeHookAsMinter();

        // ====== Step 7: NFTStaker.setTargetAPY(0.3e18) ======
        console.log("\n=== Step 7: NFTStaker.setTargetAPY(0.3e18) ===");
        _setTargetAPYOnStaker();

        // ====== Step 8: Deploy BatchNFTMinter ======
        console.log("\n=== Step 8: Deploy BatchNFTMinter ===");
        _deployBatchNFTMinter();

        // ====== Step 9: NFTStaker.setPauser + Pauser.register ======
        console.log("\n=== Step 9: NFTStaker.setPauser + Pauser.register ===");
        _registerStakerWithPauser();

        // ====== Step 10: BalancerPoolerV2.setAuthorizedPooler(owner, true) ======
        console.log("\n=== Step 10: BalancerPoolerV2.setAuthorizedPooler(owner, true) ===");
        _authorizeOwnerAsPooler();

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        if (!isPreview) {
            _markDeploymentComplete();
        }
        _printDeploymentSummary();
    }

    // ========================================
    // Step 1: Deploy hook
    // ========================================

    function _deployHook() internal {
        if (_isDeployed("BalancerPoolerMintDebtHook")) {
            balancerPoolerHook = deployments["BalancerPoolerMintDebtHook"].addr;
            console.log("BalancerPoolerMintDebtHook already deployed at:", balancerPoolerHook);
            return;
        }
        uint256 gasBefore = gasleft();
        BalancerPoolerMintDebtHook h = new BalancerPoolerMintDebtHook(
            OWNER_ADDRESS,
            BALANCER_POOLER_V2,
            PHUSD
        );
        balancerPoolerHook = address(h);
        _trackDeployment("BalancerPoolerMintDebtHook", balancerPoolerHook, gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
        console.log("BalancerPoolerMintDebtHook deployed at:", balancerPoolerHook);
        console.log("  ratio (constructor default):", uint256(h.ratio()));
    }

    // ========================================
    // Step 2: Install hook on dispatcher
    // ========================================

    function _setHookOnDispatcher() internal {
        if (_isConfigured("setHook")) {
            console.log("BalancerPoolerV2.setHook already configured");
            return;
        }
        require(balancerPoolerHook != address(0), "Hook must be deployed");

        uint256 gasBefore = gasleft();
        BalancerPoolerV2(BALANCER_POOLER_V2).setHook(IDispatchHook(balancerPoolerHook));
        console.log("BalancerPoolerV2.setHook -> BalancerPoolerMintDebtHook");

        _trackDeployment("setHook", address(0), 0);
        _markConfigured("setHook", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Step 3: Deploy NFTStaker
    // ========================================

    function _deployNFTStaker() internal {
        if (_isDeployed("NFTStaker")) {
            nftStaker = deployments["NFTStaker"].addr;
            console.log("NFTStaker already deployed at:", nftStaker);
            return;
        }
        uint256 gasBefore = gasleft();
        NFTStaker s = new NFTStaker(
            IERC1155(NFT_MINTER_V2),
            BALANCER_POOLER_DISPATCHER_INDEX,
            IERC20(PHUSD),
            OWNER_ADDRESS,
            INFTSupply(NFT_MINTER_V2),
            BALANCER_POOLER_DISPATCHER_INDEX
        );
        nftStaker = address(s);
        _trackDeployment("NFTStaker", nftStaker, gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
        console.log("NFTStaker deployed at:", nftStaker);
    }

    // ========================================
    // Step 4: NFTStaker.setDispatcherHook
    // ========================================

    function _setDispatcherHookOnStaker() internal {
        if (_isConfigured("setDispatcherHook")) {
            console.log("NFTStaker.setDispatcherHook already configured");
            return;
        }
        require(nftStaker != address(0), "NFTStaker must be deployed");
        require(balancerPoolerHook != address(0), "Hook must be deployed");

        uint256 gasBefore = gasleft();
        NFTStaker(nftStaker).setDispatcherHook(IBalancerPoolerMintDebtHook(balancerPoolerHook));
        console.log("NFTStaker.setDispatcherHook -> BalancerPoolerMintDebtHook");

        _trackDeployment("setDispatcherHook", address(0), 0);
        _markConfigured("setDispatcherHook", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Step 5: hook.setRecipient(NFTStaker)
    // ========================================

    function _setRecipientOnHook() internal {
        if (_isConfigured("setRecipient")) {
            console.log("BalancerPoolerMintDebtHook.setRecipient already configured");
            return;
        }
        require(nftStaker != address(0), "NFTStaker must be deployed");
        require(balancerPoolerHook != address(0), "Hook must be deployed");

        uint256 gasBefore = gasleft();
        BalancerPoolerMintDebtHook(balancerPoolerHook).setRecipient(nftStaker);
        console.log("BalancerPoolerMintDebtHook.setRecipient -> NFTStaker");

        _trackDeployment("setRecipient", address(0), 0);
        _markConfigured("setRecipient", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Step 6: phUSD.setMinter(hook, true)
    // ========================================

    function _authorizeHookAsMinter() internal {
        if (_isConfigured("setMinter_phUSD")) {
            console.log("phUSD.setMinter(hook, true) already configured");
            return;
        }
        require(balancerPoolerHook != address(0), "Hook must be deployed");

        uint256 gasBefore = gasleft();
        FlaxToken(PHUSD).setMinter(balancerPoolerHook, true);
        console.log("phUSD.setMinter(BalancerPoolerMintDebtHook, true)");

        _trackDeployment("setMinter_phUSD", address(0), 0);
        _markConfigured("setMinter_phUSD", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Step 7: NFTStaker.setTargetAPY(0.3e18)
    // ========================================

    function _setTargetAPYOnStaker() internal {
        if (_isConfigured("setTargetAPY")) {
            console.log("NFTStaker.setTargetAPY already configured");
            return;
        }
        require(nftStaker != address(0), "NFTStaker must be deployed");

        uint256 gasBefore = gasleft();
        NFTStaker(nftStaker).setTargetAPY(TARGET_APY);
        console.log("NFTStaker.setTargetAPY -> 0.3e18 (30%)");

        _trackDeployment("setTargetAPY", address(0), 0);
        _markConfigured("setTargetAPY", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Step 8: Deploy BatchNFTMinter
    // ========================================

    function _deployBatchNFTMinter() internal {
        if (_isDeployed("BatchNFTMinter")) {
            batchNFTMinter = deployments["BatchNFTMinter"].addr;
            console.log("BatchNFTMinter already deployed at:", batchNFTMinter);
            return;
        }
        uint256 gasBefore = gasleft();
        BatchNFTMinter b = new BatchNFTMinter();
        batchNFTMinter = address(b);
        _trackDeployment("BatchNFTMinter", batchNFTMinter, gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
        console.log("BatchNFTMinter deployed at:", batchNFTMinter);
    }

    // ========================================
    // Step 9: NFTStaker.setPauser + Pauser.register
    // ========================================

    function _registerStakerWithPauser() internal {
        require(nftStaker != address(0), "NFTStaker must be deployed");

        if (!_isConfigured("setPauser")) {
            uint256 gasBefore = gasleft();
            NFTStaker(nftStaker).setPauser(PAUSER);
            console.log("NFTStaker.setPauser -> Pauser");
            _trackDeployment("setPauser", address(0), 0);
            _markConfigured("setPauser", gasBefore - gasleft());
            if (!isPreview) _writeProgressFile();
        } else {
            console.log("NFTStaker.setPauser already configured");
        }

        if (!_isConfigured("pauser_register")) {
            uint256 gasBefore = gasleft();
            Pauser(PAUSER).register(nftStaker);
            console.log("Pauser.register(NFTStaker)");
            _trackDeployment("pauser_register", address(0), 0);
            _markConfigured("pauser_register", gasBefore - gasleft());
            if (!isPreview) _writeProgressFile();
        } else {
            console.log("Pauser.register(NFTStaker) already configured");
        }
    }

    // ========================================
    // Step 10: BalancerPoolerV2.setAuthorizedPooler(owner, true)
    // ========================================

    function _authorizeOwnerAsPooler() internal {
        if (_isConfigured("setAuthorizedPooler")) {
            console.log("BalancerPoolerV2.setAuthorizedPooler already configured");
            return;
        }

        uint256 gasBefore = gasleft();
        BalancerPoolerV2(BALANCER_POOLER_V2).setAuthorizedPooler(OWNER_ADDRESS, true);
        console.log("BalancerPoolerV2.setAuthorizedPooler(owner, true)");

        _trackDeployment("setAuthorizedPooler", address(0), 0);
        _markConfigured("setAuthorizedPooler", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Progress File Management
    // (mirrors DeployMainnetNFTV2.s.sol)
    // ========================================

    function _loadProgressFile() internal {
        try vm.readFile(PROGRESS_FILE) returns (string memory json) {
            if (bytes(json).length > 0) {
                progressFileExists = true;
                console.log("Found existing progress file, loading...");
                _parseProgressJson(json);
            }
        } catch {
            progressFileExists = false;
            console.log("No existing progress file found, starting fresh");
        }
    }

    function _parseProgressJson(string memory json) internal {
        string[12] memory names = [
            "BalancerPoolerMintDebtHook",
            "NFTStaker",
            "BatchNFTMinter",
            "setHook",
            "setDispatcherHook",
            "setRecipient",
            "setMinter_phUSD",
            "setTargetAPY",
            "setPauser",
            "pauser_register",
            "setAuthorizedPooler",
            ""
        ];
        for (uint256 i = 0; i < names.length; i++) {
            if (bytes(names[i]).length == 0) continue;
            _parseEntry(json, names[i]);
        }
    }

    function _parseEntry(string memory json, string memory name) internal {
        try vm.parseJsonAddress(json, string.concat(".contracts.", name, ".address")) returns (address addr) {
            bool deployed;
            try vm.parseJsonBool(json, string.concat(".contracts.", name, ".deployed")) returns (bool d) {
                deployed = d;
            } catch {}

            bool configured;
            try vm.parseJsonBool(json, string.concat(".contracts.", name, ".configured")) returns (bool c) {
                configured = c;
            } catch {}

            uint256 deployGas;
            try vm.parseJsonUint(json, string.concat(".contracts.", name, ".deployGas")) returns (uint256 g) {
                deployGas = g;
            } catch {}

            uint256 configGas;
            try vm.parseJsonUint(json, string.concat(".contracts.", name, ".configGas")) returns (uint256 g) {
                configGas = g;
            } catch {}

            if (deployed || configured) {
                deployments[name] = ContractDeployment({
                    name: name,
                    addr: addr,
                    deployed: deployed,
                    configured: configured,
                    deployGas: deployGas,
                    configGas: configGas
                });
                contractNames.push(name);
                console.log("Loaded from progress:", name);
                if (addr != address(0)) {
                    console.log("  address:", addr);
                }
            }
        } catch {}
    }

    function _isDeployed(string memory name) internal view returns (bool) {
        return deployments[name].deployed && deployments[name].addr != address(0);
    }

    function _isConfigured(string memory name) internal view returns (bool) {
        return deployments[name].configured;
    }

    function _trackDeployment(string memory name, address addr, uint256 gas) internal {
        bool found;
        for (uint256 i = 0; i < contractNames.length; i++) {
            if (keccak256(bytes(contractNames[i])) == keccak256(bytes(name))) {
                found = true;
                break;
            }
        }
        if (!found) {
            contractNames.push(name);
        }
        deployments[name] = ContractDeployment({
            name: name,
            addr: addr,
            deployed: true,
            configured: false,
            deployGas: gas,
            configGas: 0
        });
    }

    function _markConfigured(string memory name, uint256 gas) internal {
        deployments[name].configured = true;
        deployments[name].configGas = gas;
    }

    function _markDeploymentComplete() internal {
        _writeProgressFileWithStatus("completed");
    }

    function _writeProgressFile() internal {
        _writeProgressFileWithStatus("in_progress");
    }

    function _writeProgressFileWithStatus(string memory status) internal {
        string memory json = "{";
        json = string.concat(json, '"chainId": ', vm.toString(CHAIN_ID), ",");
        json = string.concat(json, '"networkName": "', NETWORK_NAME, '",');
        json = string.concat(json, '"deploymentStatus": "', status, '",');
        json = string.concat(json, '"contracts": {');

        for (uint256 i = 0; i < contractNames.length; i++) {
            string memory name = contractNames[i];
            ContractDeployment memory d = deployments[name];
            if (i > 0) json = string.concat(json, ",");
            json = string.concat(json, '"', name, '": {');
            json = string.concat(json, '"address": "', vm.toString(d.addr), '",');
            json = string.concat(json, '"deployed": ', d.deployed ? "true" : "false", ",");
            json = string.concat(json, '"configured": ', d.configured ? "true" : "false", ",");
            json = string.concat(json, '"deployGas": ', vm.toString(d.deployGas), ",");
            json = string.concat(json, '"configGas": ', vm.toString(d.configGas));
            json = string.concat(json, "}");
        }
        json = string.concat(json, "}}");

        vm.writeFile(PROGRESS_FILE, json);
        console.log("Progress file updated:", PROGRESS_FILE);
    }

    // ========================================
    // Summary
    // ========================================

    function _printDeploymentSummary() internal view {
        console.log("");
        console.log("=========================================");
        console.log("    NFT STAKING DEPLOYMENT SUMMARY");
        console.log("=========================================");
        console.log("BalancerPoolerMintDebtHook:", balancerPoolerHook);
        console.log("NFTStaker:                 ", nftStaker);
        console.log("BatchNFTMinter:            ", batchNFTMinter);
        console.log("");
        console.log("Wiring:");
        console.log("  BalancerPoolerV2 -> hook installed");
        console.log("  NFTStaker -> hook configured");
        console.log("  hook recipient -> NFTStaker");
        console.log("  phUSD authorizes hook as minter");
        console.log("  NFTStaker.targetAPY = 0.3e18 (30%)");
        console.log("  NFTStaker registered with Pauser");
        console.log("  BalancerPoolerV2.authorizedPooler[owner] = true");
        console.log("");
        _printGasSummary();
        console.log("=========================================");
    }

    function _printGasSummary() internal view {
        console.log("--- Gas consumption (per step) ---");
        uint256 totalDeployGas;
        uint256 totalConfigGas;
        for (uint256 i = 0; i < contractNames.length; i++) {
            ContractDeployment memory d = deployments[contractNames[i]];
            if (d.deployGas > 0) {
                console.log("  deploy ", d.name);
                console.log("    gas:", d.deployGas);
                totalDeployGas += d.deployGas;
            }
            if (d.configGas > 0) {
                console.log("  config ", d.name);
                console.log("    gas:", d.configGas);
                totalConfigGas += d.configGas;
            }
        }
        console.log("");
        console.log("Total deploy gas:", totalDeployGas);
        console.log("Total config gas:", totalConfigGas);
        console.log("TOTAL GAS:       ", totalDeployGas + totalConfigGas);
    }
}
