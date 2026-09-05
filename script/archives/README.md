# Archived scripts

Every script in here was a **one-off**: a single mainnet migration, cutover,
redeploy or interaction that was written, previewed, broadcast once, and never
run again. They predate `script/interactions/Temp.s.sol`, which is now the
scratchpad for that kind of ad-hoc action.

They are kept because they are the best available record of how past problems
were actually solved — parameter sourcing, slippage floors, preview/broadcast
splits, ordering constraints — and that is directly useful when planning a new
script.

**They are excluded from compilation.** `foundry.toml` carries
`skip = ["script/archives/**"]`. Most of them no longer compile: they are
pinned to submodule interfaces that have since moved on, and repairing dead
throwaway code every time a dependency bumps is not worth it. Read them, copy
from them, do not expect `forge build` to typecheck them.

Their npm script keys have been removed from `package.json`. To run one again,
move it back out of this directory, fix whatever the dependency drift broke,
and add a key.

Compiled scripts still live outside this directory:

| Path | Why it stays |
|---|---|
| `script/DeployMocks.s.sol` | the local Anvil deployment |
| `script/interactions/Temp.s.sol` | the scratchpad |
| `script/helpers/UniswapV2Deployer.sol` | imported by `DeployMocks` and `test/UniswapV2Deployer.t.sol` |
| `script/interactions/BalancerECLPInterfaces.sol` | imported by `test/VerifyECLPSymmetry.t.sol` and `test/SimulateECLPRebalance.t.sol` |

Two tests read archived scripts as *source text* rather than importing them —
`test/VerifyPromotionReadyGuards.t.sol` and `test/PhusdMinterDeltaGuards.t.sol`
assert properties of `archives/VerifyPromotionReady.s.sol` and
`archives/DeployMainnetPromotionReady.s.sol`. Those two files must keep their
current paths, or update the `VERIFIER_SRC` / `DEPLOY_SRC` constants.
