#!/usr/bin/env python3
"""
Compute Gyro E-CLP DerivedEclpParams at 200-digit precision using Python's
decimal module.

Derivation follows the Gyroscope concentrated-lps math as documented in
CreateBalancerECLPPool.s.sol:

    dSq   = c^2 + s^2
    d     = sqrt(dSq)
    For price p in {alpha, beta}:
        dFactor(p) = 1 / sqrt( ((c/d + p*s/d)^2 / lam^2) + (p*c/d - s/d)^2 )
        tau(p).x   = (p*c - s) * dFactor(p)
        tau(p).y   = (c + s*p) * dFactor(p) / lam
    w = s*c*(tauBeta.y - tauAlpha.y)
    z = c*c*tauBeta.x + s*s*tauAlpha.x
    u = s*c*(tauBeta.x - tauAlpha.x)
    v = s*s*tauBeta.y + c*c*tauAlpha.y

All output values are scaled by 1e38 and truncated to integer.
"""
from decimal import Decimal, getcontext

getcontext().prec = 200

# ── Base E-CLP Parameters (18-decimal) ──
# Values taken from CreateBalancerECLPPool.s.sol.
# c=1, s=0 (phi=0) for symmetric liquidity distribution.
#
# CONVENTION: alpha and beta are the price of token0 (sUSDS) denominated in
#   token1 (phUSD), i.e. "phUSD per sUSDS".  A higher value means sUSDS is
#   worth more phUSD.
#
#   alpha (lower bound) = sUSDS_rate / phUSD_price_high = $1.0877 / $1.05
#   beta  (upper bound) = sUSDS_rate / phUSD_price_low  = $1.0877 / $0.95
#
alpha  = Decimal("1035905000000000000")  / Decimal("1000000000000000000")
beta   = Decimal("1144947000000000000")  / Decimal("1000000000000000000")
c      = Decimal("1000000000000000000") / Decimal("1000000000000000000")  # cos(0) = 1
s      = Decimal("0")                   / Decimal("1000000000000000000")  # sin(0) = 0
lam    = Decimal("50000000000000000000") / Decimal("1000000000000000000")

SCALE_38 = Decimal(10) ** 38

print("=== E-CLP Derived Parameter Computation ===")
print(f"alpha  = {alpha}")
print(f"beta   = {beta}")
print(f"c      = {c}")
print(f"s      = {s}")
print(f"lambda = {lam}")
print()

# ── Step 1: dSq and d ──
dSq = c * c + s * s
d   = dSq.sqrt()
print(f"dSq = {dSq}")
print(f"d   = {d}")
print()

# ── Step 2: tau vectors ──
def compute_tau(p):
    """Compute tau(p).x and tau(p).y for a given price bound p."""
    c_over_d = c / d
    s_over_d = s / d

    # dFactor(p) = 1 / sqrt( ((c/d + p*s/d)^2 / lam^2) + (p*c/d - s/d)^2 )
    term1 = (c_over_d + p * s_over_d) ** 2 / (lam ** 2)
    term2 = (p * c_over_d - s_over_d) ** 2
    dFactor = Decimal(1) / (term1 + term2).sqrt()

    tau_x = (p * c - s) * dFactor
    tau_y = (c + s * p) * dFactor / lam

    return tau_x, tau_y

tauAlpha_x, tauAlpha_y = compute_tau(alpha)
tauBeta_x, tauBeta_y   = compute_tau(beta)

print(f"tauAlpha.x = {tauAlpha_x}")
print(f"tauAlpha.y = {tauAlpha_y}")
print(f"tauBeta.x  = {tauBeta_x}")
print(f"tauBeta.y  = {tauBeta_y}")
print()

# ── Step 3: u, v, w, z ──
u = s * c * (tauBeta_x - tauAlpha_x)
v = s * s * tauBeta_y + c * c * tauAlpha_y
w = s * c * (tauBeta_y - tauAlpha_y)
z = c * c * tauBeta_x + s * s * tauAlpha_x

print(f"u = {u}")
print(f"v = {v}")
print(f"w = {w}")
print(f"z = {z}")
print()

# ── Step 4: Scale to 38-decimal integers ──
def to_int38(val):
    """Scale by 1e38 and truncate toward zero."""
    scaled = val * SCALE_38
    return int(scaled)

tauAlpha_x_38 = to_int38(tauAlpha_x)
tauAlpha_y_38 = to_int38(tauAlpha_y)
tauBeta_x_38  = to_int38(tauBeta_x)
tauBeta_y_38  = to_int38(tauBeta_y)
u_38          = to_int38(u)
v_38          = to_int38(v)
w_38          = to_int38(w)
z_38          = to_int38(z)
dSq_38        = to_int38(dSq)

print("=== Solidity Constants (38-decimal, int256) ===")
print()
print(f"    int256 internal constant TAU_ALPHA_X = {tauAlpha_x_38};")
print(f"    int256 internal constant TAU_ALPHA_Y = {tauAlpha_y_38};")
print(f"    int256 internal constant TAU_BETA_X  = {tauBeta_x_38};")
print(f"    int256 internal constant TAU_BETA_Y  = {tauBeta_y_38};")
print(f"    int256 internal constant U           = {u_38};")
print(f"    int256 internal constant V           = {v_38};")
print(f"    int256 internal constant W           = {w_38};")
print(f"    int256 internal constant Z           = {z_38};")
print(f"    int256 internal constant D_SQ        = {dSq_38};")
print()

# ── Sanity checks ──
print("=== Sanity Checks ===")
# tau vectors should be unit-ish (x^2 + y^2 close to 1 when accounting for lambda)
print(f"|tauAlpha| = {(tauAlpha_x**2 + (tauAlpha_y * lam)**2).sqrt()}")
print(f"|tauBeta|  = {(tauBeta_x**2 + (tauBeta_y * lam)**2).sqrt()}")
print(f"dSq ~= 1?  {dSq}")
