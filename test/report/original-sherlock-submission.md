# Official Sherlock Submission Archive

* **Contest:** 2026-07-metric (Metric Protocol)
* **Auditor:** `NicingMan-zzz`
* **Title:** `✅ PriceVelocityGuardExtension Enforces Per-Call Rather Than Per-Block Rate Limiting, Allowing Same-Block Bypass of the Configured Velocity Cap`
* **Severity:** Medium (Validated — 1 of 363 valid issues out of 3,307 total submissions)

---

## Summary
The choice to unconditionally overwrite `lastMidPriceX64` and `lastUpdateBlock` on every `beforeSwap` call, rather than anchoring the velocity check to the state at the start of the current block, is a mistake as it causes `PriceVelocityGuardExtension`—a security control the protocol relies on to bound how fast the referenced price can move—to enforce only a per-call limit rather than the documented per-block limit, allowing a caller to walk the tracked price past its configured cap by chaining multiple calls within a single block.

## Root Cause
In [`PriceVelocityGuardExtension.sol#L53-L70`](https://github.com/sherlock-audit/2026-07-metric-NicingMan-zzz/blob/main/metric-periphery/contracts/extensions/PriceVelocityGuardExtension.sol?plain=1#L53-L70):

```solidity
PriceVelocityState storage s = priceVelocityState[pool_];
uint128 prevMid = s.lastMidPriceX64;
uint64 prevBlock = s.lastUpdateBlock;

s.lastMidPriceX64 = midPrice;
s.lastUpdateBlock = uint64(block.number);
...
uint256 blockDiff = block.number - prevBlock;
...
uint256 allowedSq = uint256(maxChange) * uint256(maxChange) * (1 + blockDiff);
```

Because `lastUpdateBlock` is overwritten on every call rather than only when `block.number` actually advances, any second call within the same block sees `blockDiff = block.number - prevBlock = 0`, which grants `allowedSq = maxChange²` — a full fresh single-block allowance — measured only against the immediately preceding call's price, not against the price at the start of the block. The contract's own doc comment states the intended behavior directly in [`PriceVelocityGuardExtension.sol#L9-L10`](https://github.com/sherlock-audit/2026-07-metric-NicingMan-zzz/blob/main/metric-periphery/contracts/extensions/PriceVelocityGuardExtension.sol?plain=1#L9-L10):

```solidity
/// @title PriceVelocityGuardExtension
/// @notice Caps how fast the provided price can move between blocks, per pool.
```

The mechanism, as implemented, does not do this — it caps movement between calls, not between blocks.

## Internal Pre-conditions
1. Pool admin needs to call `setMaxChangePerBlock()` to set `maxChangePerBlockE18` to a nonzero value.
2. `priceVelocityState[pool].lastMidPriceX64` needs to be nonzero (the guard has recorded at least one prior price).
3. A caller needs to trigger $N$ swaps against the same pool within a single block — trivially achievable via a searcher bundle, multicall-style batching, or simply submitting several transactions with sufficient gas priority to land in one block.

## External Pre-conditions
None.

## Attack Path
1. Pool admin configures `maxChangePerBlockE18` (e.g. `1e15`, a strict 0.1%/block cap), intending to limit how far the tracked price can move within any single block.
2. A caller issues a sequence of small swaps within the same block, each moving the pool's reported mid price by an amount within the per-call allowance.
3. Because `lastUpdateBlock` is reset on every call, each successive call sees `blockDiff = 0` and is checked only against the previous call's price rather than the block-start price, so each step passes individually even though the cumulative move across the block exceeds the configured per-block cap.
4. After enough steps, the tracked price has been walked to an arbitrary target within the same block — confirmed directly against the real `MetricOmmPool` (not an isolated mock): 60 sequential 100-wei dust swaps walked the guard's tracked price up ~5% in block 2, entirely within the guard's per-call allowance at each step.
5. As a control, a single call attempting the same ~5% move in one step correctly reverts with `PriceVelocityExceeded` — confirming the guard's underlying check logic is sound in isolation, and the bypass is specifically a same-block, multi-call accounting gap, not a flaw in the comparison arithmetic itself.

## Impact
`PriceVelocityGuardExtension` is a security control pools can attach specifically to bound how fast the referenced price can move within a block, a mechanism relevant to blunting rapid-manipulation and oracle-shock scenarios. This bug means that control is fully bypassable at zero cost beyond ordinary transaction fees, by any party able to land multiple transactions in one block, under entirely non-adversarial admin configuration (the admin set a legitimate cap; nothing about the admin's action is at fault).

We tested whether this bypass translates to a fund-loss outcome against the real `MetricOmmPool`, isolating the guard's specific contribution via a same-notional single-swap control with the guard disabled. In our test configuration (single bin, 1M/1M liquidity, 1.5% combined spread fee), the bypassed two-leg cycle did not produce a net loss to the pool — value increased from `2,049,999` to `2,050,280`, marginally more than the `2,049,999` to `2,050,046` increase seen with the guard fully disabled performing the same notional swap. The spread fee collected across both the dust-ping sequence and the two-leg cycle dominated any drift-based value extraction in this configuration.

We are reporting this as the underlying defect in the security control itself — the guard fails to enforce the invariant it documents and is trivially bypassable under realistic conditions — rather than as a direct fund-loss finding, since our testing did not produce measurable LP loss at this fee level. We note that the 1.5% combined spread fee used in our test configuration is high relative to majors-pool configurations described elsewhere in the protocol's own documentation; whether this bypass produces measurable loss at lower, more realistic fee levels was not established in this testing and would require further work to confirm or rule out.

## Results (against the real deployed pool)
* `test_ControlA_SingleFullShockCallReverts`: **PASS** — reverts with `PriceVelocityExceeded`, confirming the guard blocks a one-shot ~5% shock.
* `test_ControlB_SingleLargeSwapBaselineLoss`: value `2,049,999` to `2,050,046` (guard disabled, baseline).
* `test_Attack_TwoLegCycleBypassesGuardOnRealPool`: value `2,049,999` to `2,050,280` (guard active, bypassed via 60-step dust-ping walk). Both legs of the cycle executed successfully with the guard remaining active throughout, confirming the bypass mechanism itself; no net loss was observed in this fee configuration.

## Mitigation
Only advance the velocity baseline once per block, rather than on every call:

```solidity
if (block.number > s.lastUpdateBlock) {
    s.lastMidPriceX64 = midPrice;
    s.lastUpdateBlock = uint64(block.number);
}
```

This ensures `blockDiff` is computed against the price recorded at the start of the current block, so multiple calls within the same block are all checked against the same baseline rather than each resetting the allowance for the next.

---

## Sherlock Judging & Activity Log

| Date (2026) | Actor | Action | Details |
| :--- | :--- | :--- | :--- |
| **Jul 27, 14:30** | `sherlock-admin3` | Automated Verification | `✅ Your report format is correct and this report will be automatically submitted at the end of the contest.` |
| **Jul 27** | `sherlock-admin4` | Initial Triage | Changed title to `❌ PriceVelocityGuardExtension Enforces Per-Call Rather Than Per-Block Rate Limiting, Allowing Same-Block Bypass of the Configured Velocity Cap` |
| **Jul 27** | `NicingMan-zzz` | Issue Tagging | Added `Medium` severity label and `theBug` issue type |
| **Jul 27** | `sherlock-admin2` | Judge Review & Overturn | Changed title to `✅ PriceVelocityGuardExtension Enforces Per-Call Rather Than Per-Block Rate Limiting, Allowing Same-Block Bypass of the Configured Velocity Cap` |
