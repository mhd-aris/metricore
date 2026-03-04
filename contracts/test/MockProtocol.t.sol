// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockInvalendProtocol} from "../src/MockInvalendProtocol.sol";

contract MockProtocolTest is Test {
    MockInvalendProtocol protocol;

    uint256 constant PREFUNDED   = 800_000e6;
    uint256 constant LIQ_THRESH  = 640_000e6; // PREFUNDED × 0.8

    function setUp() public {
        // address(this) is owner and acts as gateway for gated action tests
        protocol = new MockInvalendProtocol(address(this));
        protocol.setGateway(address(this));
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _addPosition(address trader, uint256 hfBps) internal {
        uint256 collateral = hfBps * LIQ_THRESH / 10_000;
        protocol.addPosition(trader, collateral, PREFUNDED);
    }

    // ── Tests ─────────────────────────────────────────────────────────────────

    function test_AddPosition_StoresCorrectly() public {
        uint256 collateral = 9300 * LIQ_THRESH / 10_000; // 595_200e6
        protocol.addPosition(address(0x1111), collateral, PREFUNDED);

        (MockInvalendProtocol.Position[] memory batch, uint256 total) =
            protocol.getActivePositions(0, 10);

        assertEq(total, 1);
        assertEq(batch.length, 1);
        assertEq(batch[0].id, 0);
        assertEq(batch[0].trader, address(0x1111));
        assertEq(batch[0].collateralAmount, collateral);
        assertEq(batch[0].prefundedAmount, PREFUNDED);
        assertTrue(batch[0].isActive);
    }

    function test_GetActivePositions_Paginated() public {
        // Add 5 positions
        for (uint256 i = 0; i < 5; i++) {
            _addPosition(address(uint160(i + 1)), 9000 + i * 10);
        }

        (MockInvalendProtocol.Position[] memory batch, uint256 total) =
            protocol.getActivePositions(0, 3);

        assertEq(total, 5);
        assertEq(batch.length, 3);
        assertEq(batch[0].id, 0);
        assertEq(batch[1].id, 1);
        assertEq(batch[2].id, 2);
    }

    function test_GetActivePositions_SecondPage() public {
        // Add 5 positions
        for (uint256 i = 0; i < 5; i++) {
            _addPosition(address(uint160(i + 1)), 9000 + i * 10);
        }

        (MockInvalendProtocol.Position[] memory batch, uint256 total) =
            protocol.getActivePositions(3, 3);

        assertEq(total, 5);
        assertEq(batch.length, 2); // only 2 remaining (indices 3 and 4)
        assertEq(batch[0].id, 3);
        assertEq(batch[1].id, 4);
    }

    function test_GetPoolStats_CorrectUtilization() public {
        // Default state: 650_000 borrowed / 1_000_000 liquidity = 6500 bps
        (uint256 utilization, uint256 liquidity, uint256 borrowed) = protocol.getPoolStats();
        assertEq(utilization, 6500);
        assertEq(liquidity, 1_000_000e6);
        assertEq(borrowed, 650_000e6);
    }

    function test_GetHealthFactor_BasisPoints() public {
        // HF = 9300 bps: collateral = 9300 × 640_000e6 / 10_000 = 595_200e6
        // liquidationThreshold = 800_000e6 × 8000 / 10000 = 640_000e6
        // healthFactor = 595_200e6 × 10_000 / 640_000e6 = 9300
        uint256 collateral = 9300 * LIQ_THRESH / 10_000;
        protocol.addPosition(address(0xBEEF), collateral, PREFUNDED);

        uint256 hf = protocol.getHealthFactor(0);
        assertEq(hf, 9300);
    }

    function test_ReduceMaxLeverage_OnlyGateway() public {
        vm.expectRevert(MockInvalendProtocol.NotGateway.selector);
        vm.prank(address(1));
        protocol.reduceMaxLeverage(3);
    }

    function test_ReduceMaxLeverage_Succeeds() public {
        // address(this) is the gateway
        assertEq(protocol.maxLeverageTier(), 5);
        protocol.reduceMaxLeverage(3);
        assertEq(protocol.maxLeverageTier(), 3);
    }

    function test_PauseNewPositions_Succeeds() public {
        assertFalse(protocol.newPositionsPaused());
        protocol.pauseNewPositions();
        assertTrue(protocol.newPositionsPaused());
    }

    function test_ResumeNewPositions_Succeeds() public {
        protocol.pauseNewPositions();
        assertTrue(protocol.newPositionsPaused());
        protocol.resumeNewPositions();
        assertFalse(protocol.newPositionsPaused());
    }
}
