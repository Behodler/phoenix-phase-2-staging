// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

interface ISYA {
    function claim(uint256 nftIndex, uint256 minRewardTokenSupplied) external;
    function calculateClaimAmount() external view returns (uint256);
    function getYieldStrategies() external view returns (address[] memory);
    function strategyTokens(address) external view returns (address);
    function tokenConfigs(address) external view returns (uint8, uint256, bool);
    function getYield(address) external view returns (uint256);
    function nftMinter() external view returns (address);
    function rewardToken() external view returns (address);
    function phlimbo() external view returns (address);
    function minterAddress() external view returns (address);
    function discountRate() external view returns (uint256);
    function paused() external view returns (bool);
}

interface IYS {
    function withdrawFrom(address token, address client, uint256 amount, address recipient) external;
    function paused() external view returns (bool);
    function vault() external view returns (address);
}

interface IERC4626Like {
    function paused() external view returns (bool);
    function name() external view returns (string memory);
}

interface IERC1155Like {
    function balanceOf(address owner, uint256 id) external view returns (uint256);
}

interface IERC20Like {
    function balanceOf(address owner) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface INFTMinterV2Like {
    function authorizedBurners(address) external view returns (bool);
    function paused() external view returns (bool);
    function nextIndex() external view returns (uint256);
    function configs(uint256)
        external
        view
        returns (address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled);
}

/// @notice Read-only diagnostic: simulates StableYieldAccumulator.claim() for a given user
///         + NFT index and reports exactly why the call would revert (or succeeds).
///
/// Usage (no broadcast):
///   forge script script/interactions/DryRunClaimSYA.s.sol --rpc-url $RPC_MAINNET -vvvv
///
/// Override the user/index via env:
///   USER=0xabc... NFT_INDEX=1 forge script ... -vvvv
contract DryRunClaimSYA is Script {
    address constant SYA = 0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E;
    address constant DEFAULT_USER = 0x2593be17Dd1C31B4c124A18BAC3a7aE19567ae37;

    function run() external {
        address user = vm.envOr("USER", DEFAULT_USER);
        uint256 nftIndex = vm.envOr("NFT_INDEX", uint256(0));

        ISYA sya = ISYA(SYA);
        address nftMinter = sya.nftMinter();
        address rewardToken = sya.rewardToken();
        address minter = sya.minterAddress();

        console.log("=== SYA Claim Dry-Run ===");
        console.log("user:           ", user);
        console.log("SYA:            ", SYA);
        console.log("nftMinter (V2): ", nftMinter);
        console.log("rewardToken:    ", rewardToken);
        console.log("phlimbo:        ", sya.phlimbo());
        console.log("minter (deposit holder):", minter);
        console.log("discountRate:   ", sya.discountRate());
        console.log("SYA paused:     ", sya.paused());
        console.log("NFTMinterV2 paused:", INFTMinterV2Like(nftMinter).paused());
        console.log("SYA authorized as burner on V2:", INFTMinterV2Like(nftMinter).authorizedBurners(SYA));

        // ---- Locate the user's NFT ----
        if (nftIndex == 0) {
            uint256 next = INFTMinterV2Like(nftMinter).nextIndex();
            console.log("\n-- Scanning V2 NFT balances (indices 1..nextIndex-1) --");
            for (uint256 i = 1; i < next; i++) {
                uint256 bal = IERC1155Like(nftMinter).balanceOf(user, i);
                (address dispatcher,,,) = INFTMinterV2Like(nftMinter).configs(i);
                console.log("index", i);
                console.log("  dispatcher:", dispatcher);
                console.log("  balance:   ", bal);
                if (bal > 0 && nftIndex == 0) {
                    nftIndex = i;
                }
            }
            require(nftIndex != 0, "No NFT held by user");
            console.log("Auto-selected NFT index:", nftIndex);
        } else {
            uint256 bal = IERC1155Like(nftMinter).balanceOf(user, nftIndex);
            console.log("\nUser balance at index", nftIndex);
            console.log("  =", bal);
            require(bal > 0, "User holds no NFT at given index");
        }

        // ---- Pricing ----
        uint256 owe = sya.calculateClaimAmount();
        uint256 userBal = IERC20Like(rewardToken).balanceOf(user);
        uint256 allow = IERC20Like(rewardToken).allowance(user, SYA);
        console.log("\n-- Reward-token (USDC) accounting --");
        console.log("calculateClaimAmount (owed):", owe);
        console.log("user reward-token balance:  ", userBal);
        console.log("user allowance to SYA:      ", allow);
        if (userBal < owe) console.log("WARN: user balance < owed");
        if (allow < owe)   console.log("WARN: allowance < owed");

        // ---- Per-strategy probe ----
        address[] memory strategies = sya.getYieldStrategies();
        console.log("\n-- Per-strategy probe --");
        for (uint256 i = 0; i < strategies.length; i++) {
            address strat = strategies[i];
            address token = sya.strategyTokens(strat);
            uint256 yield_ = sya.getYield(strat);
            (uint8 dec, uint256 fx, bool tokPaused) = sya.tokenConfigs(token);
            console.log("strategy:", strat);
            console.log("  token:        ", token);
            console.log("  decimals:     ", dec);
            console.log("  exchangeRate: ", fx);
            console.log("  token paused: ", tokPaused);
            console.log("  pending yield:", yield_);
            console.log("  strategy paused:", IYS(strat).paused());

            if (yield_ > 0 && !tokPaused) {
                // Probe upstream ERC4626 where applicable
                try IYS(strat).vault() returns (address vault) {
                    console.log("  upstream vault:", vault);
                    try IERC4626Like(vault).paused() returns (bool p) {
                        console.log("  upstream paused:", p);
                    } catch {}
                    try IERC4626Like(vault).name() returns (string memory n) {
                        console.log("  upstream name: ", n);
                    } catch {}
                } catch {}

                // Static-call withdrawFrom from SYA's address — SYA owns the auth
                vm.prank(SYA);
                (bool ok, bytes memory ret) = strat.staticcall(
                    abi.encodeWithSelector(IYS.withdrawFrom.selector, token, minter, yield_, user)
                );
                if (ok) {
                    console.log("  withdrawFrom probe: OK (would succeed)");
                } else {
                    console.log("  withdrawFrom probe: REVERT");
                    if (ret.length >= 4) {
                        bytes4 sel;
                        assembly { sel := mload(add(ret, 0x20)) }
                        console.logBytes4(sel);
                    }
                }
            }
        }

        // ---- Full claim() simulation ----
        console.log("\n-- Full claim() simulation --");
        vm.prank(user);
        (bool claimOk, bytes memory claimRet) =
            SYA.call(abi.encodeWithSelector(ISYA.claim.selector, nftIndex, uint256(0)));
        if (claimOk) {
            console.log("claim(nftIndex,0): OK (would succeed)");
        } else {
            console.log("claim(nftIndex,0): REVERT");
            if (claimRet.length >= 4) {
                bytes4 sel;
                assembly { sel := mload(add(claimRet, 0x20)) }
                console.logBytes4(sel);
            }
        }
    }
}
