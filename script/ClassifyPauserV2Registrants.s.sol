// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "@forge-std/Script.sol";
import "@forge-std/console.sol";

/**
 * @title ClassifyPauserV2Registrants  (story 128, sprint global-pauser-v2) - READ-ONLY
 * @notice On-chain half of the PauserV2 registrant classification. Reads `V1.getPausableContracts()` from the live
 *         mainnet Pauser and, for each registrant, logs:
 *           - code size;
 *           - owner(), pauser() and paused() (each a low-level staticcall, so a registrant without the getter
 *             is reported as "n/a" instead of aborting the sweep);
 *           - getTotalShares() (AYieldStrategy family) and totalSupply() (token registrants such as Antimatter);
 *           - its non-zero balances of every ERC-20 in the book that could be a position (vault shares, base
 *             tokens, reward tokens);
 *           - its non-zero ERC-1155 balances of the NFTMinter V2 and the retired V1 NFTMinter ids 1..8 (stakers).
 *         The off-chain half (book labels across every historical book, progress-file labels, Etherscan verified
 *         names) is `scripts/pauser-v2-registrant-labels.js`. The merged LIVE / RETIRED verdict table is
 *         `docs/pauser-v2-registrants.md`.
 *
 *         Sends nothing and needs no sender:
 *           forge script script/ClassifyPauserV2Registrants.s.sol:ClassifyPauserV2Registrants --rpc-url $RPC_MAINNET -vv
 */
contract ClassifyPauserV2Registrants is Script {
    uint256 constant CHAIN_ID = 1;
    address constant PAUSER_V1 = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    address constant NFT_MINTER_V2 = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address constant NFT_MINTER_V1 = 0xd936461f1C15eA9f34Ca1F20ecD54A0819068811;

    struct Tok {
        string name;
        address addr;
    }

    function _tokens() internal pure returns (Tok[] memory t) {
        t = new Tok[](17);
        t[0] = Tok("phUSD", 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605);
        t[1] = Tok("USDC", 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        t[2] = Tok("DOLA", 0x865377367054516e17014CcdED1e7d814EDC9ce4);
        t[3] = Tok("autoDOLA", 0x79eB84B5E30Ef2481c8f00fD0Aa7aAd6Ac0AA54d);
        t[4] = Tok("sDOLA", 0xb45ad160634c528Cc3D2926d9807104FA3157305);
        t[5] = Tok("autoUSD", 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35);
        t[6] = Tok("USDS", 0xdC035D45d973E3EC169d2276DDab16f1e407384F);
        t[7] = Tok("sUSDS", 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD);
        t[8] = Tok("USDe", 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3);
        t[9] = Tok("sUSDe", 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497);
        t[10] = Tok("EYE", 0x155ff1A85F440EE0A382eA949f24CE4E0b751c65);
        t[11] = Tok("SCX", 0x1B8568FbB47708E9E9D31Ff303254f748805bF21);
        t[12] = Tok("Flax", 0x0cf758D4303295C43CD95e1232f0101ADb3DA9E8);
        t[13] = Tok("Kendu", 0xaa95f26e30001251fb905d264Aa7b00eE9dF6C18);
        t[14] = Tok("WBTC", 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
        t[15] = Tok("Antimatter", 0x9CA92B527012DfC6Fdca7B7493C722D5901FF151);
        t[16] = Tok("waUSDC", 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E);
    }

    function run() external view {
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        address[] memory regs = IV1Pauser(PAUSER_V1).getPausableContracts();
        console.log("=================================================");
        console.log("  CLASSIFY V1 Pauser registrants (story 128) - READ-ONLY");
        console.log("=================================================");
        console.log("V1 Pauser:", PAUSER_V1);
        console.log("Block:", block.number);
        console.log("Registrants:", regs.length);

        Tok[] memory toks = _tokens();
        for (uint256 i = 0; i < regs.length; i++) {
            address c = regs[i];
            console.log("-------------------------------------------------");
            console.log("#", i, c);
            console.log("  codeSize:", c.code.length);
            (bool okO, address o) = _addr(c, "owner()");
            console.log(okO ? "  owner:" : "  owner: n/a", o);
            if (okO) console.log(o == OWNER ? "  owner == OWNER" : "  owner != OWNER  <<<");
            (bool okP, address p) = _addr(c, "pauser()");
            console.log(okP ? "  pauser:" : "  pauser: n/a", p);
            if (okP) console.log(p == PAUSER_V1 ? "  pauser == V1" : "  pauser != V1  <<<");
            (bool okPd, uint256 pd) = _uint(c, "paused()");
            if (okPd) console.log("  paused:", pd == 1 ? "true" : "false");
            else console.log("  paused: n/a (no getter)");
            (bool okS, uint256 shares) = _uint(c, "getTotalShares()");
            if (okS) console.log("  getTotalShares:", shares);
            (bool okT, uint256 ts) = _uint(c, "totalSupply()");
            if (okT) console.log("  totalSupply:", ts);
            for (uint256 k = 0; k < toks.length; k++) {
                uint256 b = _balanceOf(toks[k].addr, c);
                if (b > 0) console.log(string.concat("  bal ", toks[k].name, ":"), b);
            }
            for (uint256 id = 1; id <= 8; id++) {
                uint256 b2 = _balance1155(NFT_MINTER_V2, c, id);
                if (b2 > 0) console.log("  NFTMinterV2 id / balance:", id, b2);
                uint256 b1 = _balance1155(NFT_MINTER_V1, c, id);
                if (b1 > 0) console.log("  NFTMinterV1 id / balance:", id, b1);
            }
        }
    }

    function _addr(address c, string memory sig) internal view returns (bool, address) {
        (bool ok, bytes memory d) = c.staticcall(abi.encodeWithSignature(sig));
        if (!ok || d.length < 32) return (false, address(0));
        uint256 w = abi.decode(d, (uint256));
        if (w >> 160 != 0) return (false, address(0));
        return (true, address(uint160(w)));
    }

    function _uint(address c, string memory sig) internal view returns (bool, uint256) {
        (bool ok, bytes memory d) = c.staticcall(abi.encodeWithSignature(sig));
        if (!ok || d.length < 32) return (false, 0);
        return (true, abi.decode(d, (uint256)));
    }

    function _balanceOf(address token, address who) internal view returns (uint256) {
        (bool ok, bytes memory d) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        if (!ok || d.length < 32) return 0;
        return abi.decode(d, (uint256));
    }

    function _balance1155(address token, address who, uint256 id) internal view returns (uint256) {
        (bool ok, bytes memory d) = token.staticcall(abi.encodeWithSignature("balanceOf(address,uint256)", who, id));
        if (!ok || d.length < 32) return 0;
        return abi.decode(d, (uint256));
    }
}

interface IV1Pauser {
    function getPausableContracts() external view returns (address[] memory);
}
