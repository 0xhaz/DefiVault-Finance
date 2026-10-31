# Local dry-run of DeployMainnet.s.sol (no real network)

`run-local.sh` runs the REAL `contracts/script/DeployMainnet.s.sol:DeployMainnet` (no copy, no `--skip`) against two
throwaway local anvil nodes. Nothing touches a real network.

    forge build
    contracts/script/local/run-local.sh      # anvil :8555 (chain id 5042) and :8556 (chain id 31337); runs everything; kills anvil
    rm -rf broadcast/DeployMainnet.s.sol ~/.foundry/cache/rpc/5042    # only if you set KEEP_BROADCAST=1 or the run was interrupted

What it covers, in order:

1. `check()` negatives (wrong chain/sender, missing/zero/placeholder env, EOA governance, fee/gas bounds, missing stubs, wrong CCTP domain) and the positive case.
2. `deployCore()` negatives (nothing is broadcast on a failed validation), `deployCore()`, and state assertions.
3. Scenario A, core only: strict `verify()` and `verifyPendingAcceptance()` fail before `handoff()`; after `handoff()`
   `verifyPendingAcceptance()` passes and strict `verify()` fails; partial acceptance (3 contracts) fails strict `verify()`;
   after every `acceptOwnership()` (by impersonating the multisig) strict `verify()` passes.
4. `deployGold()` negatives, then Scenario B (only XAUT: one adapter), Scenario C (only PAXG: one adapter),
   Scenario D (both). Each scenario repeats the handoff procedure. `handoff()` always runs with no `GOLD_*` variables:
   the gold adapters are read from the vault's linked slots, so they cannot be skipped. Scenario D also checks that
   `verify()` fails when a gold adapter is not handed off, or is owned by the deployer again.

Scenarios branch with `evm_snapshot` / `evm_revert` on the local node.

Stubs: `contracts/test-helpers/DeployMainnetStubs.sol` (runtime code installed with `anvil_setCode`). Uses anvil's unlocked
default accounts (`--unlocked --sender`), no private keys, no .env (forge runs from an empty cwd with a scrubbed env).
