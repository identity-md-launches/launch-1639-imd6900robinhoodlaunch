# Adaptation notes: IMD6900RobinhoodLaunch on Robinhood Chain (evm_contracts launch)

The project arrived launchable as the brief describes: one contract, `IMD6900RobinhoodLaunch`, four constructor
arguments (owner, PoolManager, IMDSTR, timelock), a nonpayable constructor that creates `IMD6900LockedPool` and calls
nothing that existed before it (test_DeploysOnAFreshChain, test_FitsOneTransaction, test_PassesTheAdmissionScan all
pass unchanged). Nothing about the launch rules required a change: no initializer, no proxy, no `msg.sender` owner,
no forbidden opcode, the hook created by the pool at a salt mined off-chain (never by the factory), the compiler
settings untouched (solc 0.8.26, via-IR, 200 runs, cancun, bytecode_hash none; foundry.toml not changed).

Every change below is a reproduced finding of the imported audit, each with a test. The source, constructor, hook
permissions, 4.44% static fee, lowerFee's lower-only move, the refund pair, the coin, the 0x6900 rule, the fee split's
defaults and the timelock's roles are as they were.

## Changes

| # | Finding | File | Change | Test |
|---|---------|------|--------|------|
| 1 | high: `ENGINE_CODE_HASH` was not the hash of the PerpEngine this tree builds, so `createPerps` could never create the perps (test/Perps.t.sol failed in setUp with `NotThePerpsCode()`) | `src/IMD6900LockedPool.sol` | `ENGINE_CODE_HASH` set to the keccak256 of the built creation code, `0x136b10b3…0651` (reproduced: `cast keccak` of `out/PerpEngine.sol/PerpEngine.json` bytecode; the audit's value). `VAULT_CODE_HASH` matched and is unchanged. Nothing in `src/perps` was changed, so the engine's and vault's bytecode, and their hashes, are what the audit read. | `test_ThePerpsCodeIsTheAuditedCode`, and the whole of test/Perps.t.sol now runs (15 tests) |
| 2 | medium: the launch's `sellHeld` skipped the hook's pre-trade liquidation sweep, so a long it sank was liquidated only by the next trade, at the price the sale left (bad debt on the stakers) | `src/IMD6900Hook.sol` `_sweep` | The launcher skips only the post-trade sweep (`spec == 0`); its swaps get the pre-trade sweep like any trade. Safe: the checkpoints are per caller (transient, keyed by `msg.sender`) and at beforeSwap the sale's swap has earned nothing yet, so a nested liquidation takes nothing of the sale's refund (the test checks the sale is still fee-free). The post-trade skip stays for the reason the old comment gave: a liquidation between the sale's swap and its refund would book the sale's fee away from it. Consequence: a sale that would sink more positions than one transaction can liquidate is refused (`SweepTradeTooLarge`), like any trade; the timelock sells smaller. | `test_TheTimelocksSaleLiquidatesWhatItSinksFirst` (fails on the old sweep: the long stays open through the sale; passes now: closed inside the sale, no `BadDebt`, stakers and insurance whole) |
| 3 | low: after `lowerFee` the perps were stranded for good (`createPerps` one-shot, the engine bound to the drained pool) | `src/IMD6900LockedPool.sol` `createPerps`; `src/IMD6900Hook.sol` `initPerpEngine` (+ `poolEngine`) | `createPerps` refuses (`PerpsExist`) only while the pool's engine is bound to the current pool (`engine.poolId() == poolKey().toId()`); after a move it makes a fresh pair from the same audited code (same hashes) on the new pool, the timelock owning it, and wires it. The hook accepts the pool's re-wiring only when no engine is set or the one set is the pool's own last (`poolEngine`) and it reports no open positions (`PerpsOpen` otherwise, `EngineSet` for an engine the timelock chose). Positions can't exist on the old engine after a move: `lowerFee` refuses with any open, and nothing opens on the drained pool. The old vault's stakers withdraw as before. | `test_ThePerpsAreRecreatedAfterAFeeMove`, `test_TheHookReplacesOnlyThePoolsOwnEngine`; the fork test re-creates the perps on the 3.33% pool after the move (runs only with `ROBINHOOD_RPC_URL`, not run here) |
| 4 | low: `setImdBurn` to a payee holding an owed share stranded that ETH out of every split | `src/IMD6900RobinhoodLaunch.sol` `setImdBurn` | What the new executor was owed is cancelled (`owedTotal`, `_owed`), as `setPayees` cancels a dropped payee's: the next split divides it again. | `test_RepointingTheBurnExecutorCancelsWhatItWasOwed` |
| 5 | low: `setPerpEngine` left `perpRefunded` on for a replacement engine | `src/IMD6900Hook.sol` `setPerpEngine` | Any change of engine (to another or to zero) resets `perpRefunded` to false (`PerpRefundedSet(false)` emitted): a replacement assumes the pool's fee until the timelock says it refunds (`setPerpRefunded`). Setting the same engine again changes nothing. `initPerpEngine` (the pool's audited engine) still sets it true. | `test_AReplacementEngineIsNotReportedFeeFree`, `test_AReplacementEngineStartsNotRefunded` |

Test helper change: `test/HookSalt.sol` now hashes each CREATE2 try in place instead of allocating per try (the hook's
new code hash made one of the test launches' salt searches long enough to run out of memory before gas). Same salts
as before for the same inputs; the scripts mine with `cast`, unchanged.

## Findings left alone, and why

- info: `burnImd`'s one-per-block throttle keys on `block.number`, the L1 number on Robinhood Chain. Reproduced by
  reading (no loss: one 0.1 ETH buy per Ethereum block of ~12s rather than per Robinhood block; the engine's own
  throttle keys on the timestamp). Left as it is: the stricter throttle is the safe side of its purpose (bounding what
  sandwiching one buy is worth), and changing the throttle's key would change the burn's pace, a choice the brief
  doesn't make. The NatSpec now says what the block is.
- info: coverage statement. Not a defect.

## What was checked

- `forge build` with the project's configuration (clean build 1m37s), `forge test`: 64 tests, all passing
  (48 in test/IMD6900RobinhoodLaunch.t.sol, 15 in test/Perps.t.sol, the fork test skipping without an RPC).
- The engine's and vault's creation code hashes after every change: `0x136b10b3b461616f618358a9d4ad7fff26b80ac920c5d8092be808bdb60c0651`
  and `0x20845fd74bc9ce4b2c159a32d2d0fb7328ceceb4dbb1557b6b7d9e16d8934d57` (the engine imports only v4-core,
  OpenZeppelin and PerpSwapLib, so the hook and pool changes don't touch it).
- The hook's permissions are unchanged (`FLAGS`; test_TheHooksAddressAndPermissions); its creation code changed, so
  its salt is mined at launch time as before (`script/launch.sh hook`).
- No DELEGATECALL, CALLCODE or SELFDESTRUCT anywhere, creation code included (test_PassesTheAdmissionScan,
  test_ThePerpsPassTheAdmissionScan); the engine under EIP-170.
- launch.json is not written here (the manifest step's).
