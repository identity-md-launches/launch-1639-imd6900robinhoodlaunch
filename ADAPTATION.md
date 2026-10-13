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

### Revision (the independent review's findings)

| # | Finding | File | Change | Test |
|---|---------|------|--------|------|
| 6 | medium: `PerpVault`'s token-side yield index (`ACC` 1e18 over shares minted at 1e6 x the token amount) floored small short-side yield to zero and, the watermark advancing regardless, orphaned it in the engine's pot; a 1 wei deposit after each short stripped the stakers of up to one step. Reproduced with the reviewer's proof (pending yield 0 of 1.48e14 wei with 300M coins staked). | `src/perps/PerpVault.sol` | `ACC` is 1e36 (OFFSET x 1e18): the one constant every fold, debt and settle uses, so `pendingTokYield` mirrors by construction. A fold's residue is now under `tokShares / 1e36` wei, below a wei for any stake the supply allows; `mulDiv` carries the 512-bit intermediate, and the index cannot overflow for any yield the chain can hold (checked at a single share with the whole supply's yield). Nothing else in the vault changed. **`VAULT_CODE_HASH` re-pinned** to the new vault's creation code, `0x229927c6…e751` (`ENGINE_CODE_HASH` unchanged: the engine's source is untouched). | `test/PerpVaultYield.t.sol` (3 tests, the proof's shape: a minimum short's yield to the wei, 50 folds strip nothing, the scale's ends), `test_AMinimumShortsFeeReachesTheTokenStakers` through the real engine, `test_ThePerpsCodeIsTheAuditedCode` for the hashes; the reviewer's proof passes |
| 7 | low: `releaseUnclaimed(address(this))` was a self-transfer that set `unclaimedReleased` and booked nothing: the unclaimed reserve stayed here out of `excessHeld`'s reach for good. Reproduced by reading (no guard, no booking). | `src/IMD6900RobinhoodLaunch.sol` `releaseUnclaimed` | `to == address(this)` books the amount into `excessHeld`, as `endClaims` and launch()'s `excessTo` do: the coins stay here as the timelock's to sell or release. Chosen over `BadTo` because the launch already gives that address that meaning. | `test_TheUnclaimedRestKeptHereIsTheTimelocksToSell` |

Script change: `script/launch.sh perps` runs `forge clean` before the build it hashes. Found while re-pinning: the
engine's via-IR bytecode depends on which files share its compile job (an incremental build after a partial one gave
the author's original `0x3ce566f9…` hash; a clean full build gives the pinned `0x136b10b3…`, the audit's and the
verifier's). The vault's hash was the same both ways. Documented in the README.

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

The independent review's advisory findings, each traced against the code (none changed; the README's trust notes say
them):

- low: one minimum-size position vetoes `lowerFee` / `setPerpEngine` / `initPerpEngine` for as long as it stays open
  (funding never makes a flat-price position liquidatable). Reproduces as described. Left: the refusal while positions
  are open is the brief's own rule for `lowerFee`, and the proposed remedies (a timelock forced close of a healthy
  third-party position, or a clock on the veto) are new timelock powers over traders the brief does not give, and a
  change to the audited engine. Documented as a trust/griefing assumption.
- low: `_syncEthQueue` scales the ETH exit queue by `backing / mark` with a mark that includes yield the queue never
  received, so after yield, a re-mark and a realised PLV loss the queue bears a share of a loss on value it had no part
  in. Reproduces by tracing. Left: this is the vault's documented pari-passu rule (its "PARI PASSU, NOT SENIOR" note,
  a red-team fix of the opposite bias); making the queue senior ("only when backing < claims") reverses that decision,
  and a yield-net mark needs new engine accounting. Conditional on a realised loss beyond insurance, which the no-bad-debt
  sweep keeps rare; bounded to the loss's share of accrued yield.
- low: `burnImd`'s only floor is the caller's `minImd`, so the keeper key can sandwich the burn's 0.1 ETH buys.
  Reproduces by reading (`burnImd(0)` passes). Left: the keeper is the timelock's to name and revoke and quotes the buy
  by design; the $IMD pool is an outside v4 pool with no on-chain TWAP, and a slippage bound against spot is defeated
  by the same pump. Bounded to 0.1 ETH per Ethereum block, visible on chain, stopped by `setImdKeeper`.
- info: the sweep names `tx.origin` the liquidator. Intended ("the EOA that sent the transaction", as the hook's NatSpec
  says): the swap's `sender` is the router, which could not take an ETH payout, and the cut stays inside the engine's
  accounting. Documented.
- info: `setPerpEngine` makes any address the timelock names a fee-refunded trader. The timelock's documented role;
  behind its public delay. Documented.
- info: a vault whose engine a fee move unwired keeps taking deposits that cannot earn. Funds withdrawable in full at
  once (nothing is lent); a vault gate would bind the vault to the hook and change the audited vault. Documented.

## What was checked

- `forge build` with the project's configuration (clean build 40s), `forge test` with the verifier's fuzz seed: 69 tests,
  all passing (49 in test/IMD6900RobinhoodLaunch.t.sol, 16 in test/Perps.t.sol, 3 in test/PerpVaultYield.t.sol, the
  fork test skipping without an RPC), plus the reviewer's proof.
- The engine's and vault's creation code hashes after every change, from a clean full build:
  `0x136b10b3b461616f618358a9d4ad7fff26b80ac920c5d8092be808bdb60c0651` and
  `0x229927c61e4727a8b1f81407e23ba2c71df10cfd978aa613011f31e9c917e751` (the engine imports only v4-core,
  OpenZeppelin and PerpSwapLib, so the hook, pool and vault changes don't touch it).
- The hook's permissions are unchanged (`FLAGS`; test_TheHooksAddressAndPermissions); its creation code changed, so
  its salt is mined at launch time as before (`script/launch.sh hook`).
- No DELEGATECALL, CALLCODE or SELFDESTRUCT anywhere, creation code included (test_PassesTheAdmissionScan,
  test_ThePerpsPassTheAdmissionScan); the engine under EIP-170.
- launch.json is not written here (the manifest step's).
