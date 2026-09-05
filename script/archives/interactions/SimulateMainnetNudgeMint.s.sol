// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BatchNFTMinter} from "nft-staking/BatchNFTMinter.sol";
import {ITokenMinterV2} from "@yield-claim-nft/interfaces/ITokenMinterV2.sol";

interface IDispatcherSetMinter {
    function setMinter(address) external;
    function owner() external view returns (address);
}

contract SimulateMainnetNudgeMint is Script {
    address constant BATCH = 0x4ef0fDe49360ed31c68ED442Ff263CC6291041f3;
    address constant NFT_MINTER_V2 = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant POOLER_OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    // sUSDS savings vault — known USDS whale (~6.2B USDS held).
    // Used to source USDS in-fork without slow balance-slot probing.
    address constant USDS_WHALE = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    uint256 constant DISPATCHER_INDEX = 6;

    function run() external {
        address caller = address(0xCAFE);
        address recipient = address(0xBEEF);

        // Default to 40 (mainnet nudge threshold). Override via env MINT_COUNT=N
        // to shrink for cheap fork-side verification — Alchemy roundtrips
        // dominate runtime on a live fork.
        uint256 count = vm.envOr("MINT_COUNT", uint256(40));
        console.log("count:", count);

        BatchNFTMinter batch = BatchNFTMinter(BATCH);

        (address dispatcher, uint256 startPrice, uint256 growthBps, bool disabled) = _readConfig();

        console.log("dispatcher:", dispatcher);
        console.log("startPrice:", startPrice);
        console.log("growthBps:", growthBps);
        console.log("disabled:", disabled);

        // Compute aggregate cost across count mints (price grows by growthBps each mint)
        uint256 total = 0;
        uint256 p = startPrice;
        for (uint256 i = 0; i < count; ++i) {
            total += p;
            p = p + (p * growthBps) / 10000;
        }
        console.log("aggregate USDS cost (wei):", total);

        // Add 1% padding
        uint256 payment = total + total / 100;
        console.log("payment with 1pct padding:", payment);

        // Source USDS from a known whale (sUSDS savings vault). Faster than
        // probing for the balance storage slot on every fork run.
        vm.prank(USDS_WHALE);
        IERC20(USDS).transfer(caller, payment);

        // Optional pre-broadcast verification: if APPLY_FIX=1, impersonate the
        // pooler owner and call setMinter(NFTMinterV2) in-fork before the batch
        // mint. Use to confirm the fix works against a live mainnet fork
        // without touching the ledger.
        if (vm.envOr("APPLY_FIX", false)) {
            console.log("APPLY_FIX=1 -> patching _minter via owner prank");
            vm.prank(POOLER_OWNER);
            IDispatcherSetMinter(dispatcher).setMinter(NFT_MINTER_V2);
        }

        vm.startPrank(caller);
        IERC20(USDS).approve(BATCH, payment);
        // batchMint was hardened: nftMinter/paymentToken/dispatcherIndex are now read
        // from contract state (not caller-supplied), plus a minReward slippage bound.
        // minReward = 0 here: read-only mainnet-fork simulation, not a real broadcast.
        try batch.batchMint(
            count,
            recipient,
            payment,
            0
        ) returns (uint256 totalPaid) {
            console.log("SUCCESS totalPaid:", totalPaid);
        } catch Error(string memory reason) {
            console.log("REVERT reason:", reason);
        } catch (bytes memory low) {
            console.log("REVERT low-level");
            console.logBytes(low);
        }
        vm.stopPrank();
    }

    function _readConfig() internal view returns (address, uint256, uint256, bool) {
        (bool ok, bytes memory data) = NFT_MINTER_V2.staticcall(
            abi.encodeWithSignature("configs(uint256)", DISPATCHER_INDEX)
        );
        require(ok, "configs read failed");
        return abi.decode(data, (address, uint256, uint256, bool));
    }

}
