// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IGyroECLPPool,
    IGyroECLPPoolFactory,
    IRouter,
    IPermit2,
    IRateProvider,
    TokenConfig,
    TokenType,
    PoolRoleAccounts
} from "./BalancerECLPInterfaces.sol";

/**
 * @title CreateBalancerECLPPool
 * @notice Deploys a Balancer V3 Gyro E-CLP pool for phUSD/sUSDS on Ethereum
 *         mainnet and seeds it with initial liquidity.
 *
 *         The pool uses an elliptic concentrated liquidity curve to concentrate
 *         liquidity within the phUSD price range of $0.95 - $1.05 (expressed as
 *         sUSDS-per-phUSD rates of ~0.8734 - ~0.9654, given sUSDS at $1.0877).
 *
 * @dev    Token ordering (CRITICAL):
 *           token0 = sUSDS (0xa393...) -- lower address
 *           token1 = phUSD (0xf3B5...) -- higher address
 *
 *         DerivedEclpParams were computed off-chain from the base EclpParams
 *         using 200-digit Python `decimal` arithmetic.  See the companion
 *         script at /tmp/compute_eclp_derived_params.py for the full derivation.
 *
 *         Ledger index: 45  (HD path m/44'/60'/45'/0/0)
 */
contract CreateBalancerECLPPool is Script {
    // ──────────────────────────────────────────────
    //  Mainnet addresses
    // ──────────────────────────────────────────────
    address public constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;

    address public constant GYRO_ECLP_POOL_FACTORY = 0x04d584195a96DFfc7F8B695aA3C9D3c1606b69d1;
    address public constant BALANCER_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    address public constant ROUTER = 0xAE563E3f8219521950555F5962419C8919758Ea2;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // ──────────────────────────────────────────────
    //  Pool configuration
    // ──────────────────────────────────────────────
    string public constant POOL_NAME = "Gyro E-CLP phUSD/sUSDS";
    string public constant POOL_SYMBOL = "ECLP-phUSD-sUSDS";

    /// @dev 0.04% swap fee = 4e14 in 18-decimal
    uint256 public constant SWAP_FEE = 400000000000000;

    /// @dev Deterministic salt for reproducible pool address
    bytes32 public constant SALT = keccak256("phUSD-sUSDS-ECLP-v1");

    // ──────────────────────────────────────────────
    //  E-CLP Base Parameters (18-decimal)
    // ──────────────────────────────────────────────
    //  alpha  = lower price bound  (sUSDS/phUSD when phUSD=$0.95)
    //  beta   = upper price bound  (sUSDS/phUSD when phUSD=$1.05)
    //  c      = cos(pi/4)
    //  s      = sin(pi/4)
    //  lambda = 50  (stretching factor)
    int256 internal constant ALPHA  = 873425000000000000;
    int256 internal constant BETA   = 965359000000000000;
    int256 internal constant C      = 707106781186547524;
    int256 internal constant S      = 707106781186547524;
    int256 internal constant LAMBDA = 50000000000000000000;

    // ──────────────────────────────────────────────
    //  Derived E-CLP Parameters (38-decimal)
    //
    //  Computed via Python `decimal` module at 200-digit precision.
    //  See /tmp/compute_eclp_derived_params.py for the full derivation.
    //
    //  Method (from Gyroscope concentrated-lps math):
    //    dSq   = c^2 + s^2                  (at full precision)
    //    d     = sqrt(dSq)
    //    For price p in {alpha, beta}:
    //      dFactor(p) = 1 / sqrt( ((c/d + p*s/d)^2/lam^2) + (p*c/d - s/d)^2 )
    //      tau(p).x   = (p*c - s) * dFactor(p)
    //      tau(p).y   = (c + s*p) * dFactor(p) / lam
    //    w = s*c*(tauBeta.y - tauAlpha.y)
    //    z = c*c*tauBeta.x + s*s*tauAlpha.x
    //    u = s*c*(tauBeta.x - tauAlpha.x)
    //    v = s*s*tauBeta.y + c*c*tauAlpha.y
    //    All values scaled by 1e38 and truncated to integer.
    // ──────────────────────────────────────────────
    int256 internal constant TAU_ALPHA_X = -95887072223554841815617101994534177496;
    int256 internal constant TAU_ALPHA_Y =  28384315746460711756416744112835898317;
    int256 internal constant TAU_BETA_X  = -66117287996822805080314124603435138763;
    int256 internal constant TAU_BETA_Y  =  75023357882363483369325993831865524023;
    int256 internal constant U           =  14884892113366018350775607306971453973;
    int256 internal constant V           =  51703836814412097504251675207093076376;
    int256 internal constant W           =  23319521067951385780015906420446350484;
    int256 internal constant Z           = -81002180110188823356128657186397891735;
    int256 internal constant D_SQ        =  99999999999999999886624093342106115200;

    // ──────────────────────────────────────────────
    //  Seed liquidity
    // ──────────────────────────────────────────────
    //  10 phUSD + ~9.194 sUSDS (equivalent at $1 phUSD / $1.0877 sUSDS)
    //  amounts[0] = sUSDS (token0), amounts[1] = phUSD (token1)
    uint256 internal constant SEED_SUSDS = 9193950000000000000;   // ~9.19395 sUSDS
    uint256 internal constant SEED_PHUSD = 10000000000000000000;  // 10 phUSD

    // ──────────────────────────────────────────────
    //  NOTE: Ledger index 45 address is unknown at script creation time.
    //  The user must determine it via:
    //    cast wallet address --ledger --hd-paths "m/44'/60'/45'/0/0"
    //  and update the dry-run --sender flag in package.json.
    // ──────────────────────────────────────────────

    function run() external {
        console.log("\n=== Create Balancer E-CLP Pool: phUSD/sUSDS ===");
        console.log("Factory:  ", GYRO_ECLP_POOL_FACTORY);
        console.log("Router:   ", ROUTER);
        console.log("Permit2:  ", PERMIT2);
        console.log("token0 (sUSDS):", SUSDS);
        console.log("token1 (phUSD):", PHUSD);
        console.log("Swap fee (wei):", SWAP_FEE);
        console.log("Seed sUSDS (wei):", SEED_SUSDS);
        console.log("Seed phUSD (wei):", SEED_PHUSD);
        console.log("");

        // ── Build EclpParams ──
        IGyroECLPPool.EclpParams memory eclpParams = IGyroECLPPool.EclpParams({
            alpha:  ALPHA,
            beta:   BETA,
            c:      C,
            s:      S,
            lambda: LAMBDA
        });

        // ── Build DerivedEclpParams ──
        IGyroECLPPool.DerivedEclpParams memory derivedParams = IGyroECLPPool.DerivedEclpParams({
            tauAlpha: IGyroECLPPool.Vector2({ x: TAU_ALPHA_X, y: TAU_ALPHA_Y }),
            tauBeta:  IGyroECLPPool.Vector2({ x: TAU_BETA_X,  y: TAU_BETA_Y }),
            u: U,
            v: V,
            w: W,
            z: Z,
            dSq: D_SQ
        });

        // ── Build TokenConfig array (token0=sUSDS, token1=phUSD) ──
        TokenConfig[] memory tokens = new TokenConfig[](2);
        tokens[0] = TokenConfig({
            token: IERC20(SUSDS),
            tokenType: TokenType.STANDARD,
            rateProvider: IRateProvider(address(0)),
            paysYieldFees: false
        });
        tokens[1] = TokenConfig({
            token: IERC20(PHUSD),
            tokenType: TokenType.STANDARD,
            rateProvider: IRateProvider(address(0)),
            paysYieldFees: false
        });

        // ── Build PoolRoleAccounts (all roles -> msg.sender) ──
        PoolRoleAccounts memory roleAccounts = PoolRoleAccounts({
            pauseManager: msg.sender,
            swapFeeManager: msg.sender,
            poolCreator: msg.sender
        });

        vm.startBroadcast();

        // ────────────────────────────────────────
        //  1. Create pool via GyroECLPPoolFactory
        // ────────────────────────────────────────
        console.log("Creating E-CLP pool...");
        address pool = IGyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY).create(
            POOL_NAME,
            POOL_SYMBOL,
            tokens,
            eclpParams,
            derivedParams,
            roleAccounts,
            SWAP_FEE,
            address(0),   // poolHooksContract — none
            false,         // enableDonation
            false,         // disableUnbalancedLiquidity
            SALT
        );
        console.log("Pool created at:", pool);

        // ────────────────────────────────────────
        //  2. Approve Permit2 to spend tokens
        // ────────────────────────────────────────
        console.log("Approving Permit2 for sUSDS and phUSD...");
        IERC20(SUSDS).approve(PERMIT2, type(uint256).max);
        IERC20(PHUSD).approve(PERMIT2, type(uint256).max);

        // ────────────────────────────────────────
        //  3. Approve Router via Permit2
        // ────────────────────────────────────────
        console.log("Granting Router allowance via Permit2...");
        IPermit2(PERMIT2).approve(SUSDS, ROUTER, type(uint160).max, type(uint48).max);
        IPermit2(PERMIT2).approve(PHUSD, ROUTER, type(uint160).max, type(uint48).max);

        // ────────────────────────────────────────
        //  4. Initialize pool with seed liquidity
        // ────────────────────────────────────────
        IERC20[] memory poolTokens = new IERC20[](2);
        poolTokens[0] = IERC20(SUSDS);
        poolTokens[1] = IERC20(PHUSD);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = SEED_SUSDS;
        amounts[1] = SEED_PHUSD;

        console.log("Initializing pool with seed liquidity...");
        uint256 bptOut = IRouter(ROUTER).initialize(
            pool,
            poolTokens,
            amounts,
            0,       // minBptAmountOut — accept any amount for seeding
            false,   // wethIsEth
            ""       // userData
        );

        vm.stopBroadcast();

        console.log("");
        console.log("=== Pool Creation Complete ===");
        console.log("Pool address:", pool);
        console.log("BPT received:", bptOut);
        console.log("Seed sUSDS:  ", SEED_SUSDS);
        console.log("Seed phUSD:  ", SEED_PHUSD);
        console.log("Swap fee:     0.04%");
        console.log("Salt:         keccak256('phUSD-sUSDS-ECLP-v1')");
        console.log("\n");
    }
}
