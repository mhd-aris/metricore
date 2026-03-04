// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockInvalendProtocol} from "../src/MockInvalendProtocol.sol";
import {MetricoreGateway} from "../src/MetricoreGateway.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MetricoreGatewayTest is Test {
    // ── Event mirrors (required to emit in vm.expectEmit) ─────────────────────
    event ActionProposed(bytes32 indexed actionType, address indexed proposer);
    event ActionExecuted(bytes32 indexed actionType, bytes actionData);
    event ActionRejected(bytes32 indexed actionType, string reason);
    event SnapshotUpdated(address indexed asset, uint256 price, uint256 timestamp);

    // ── Action type constants (mirrors MetricoreGateway — avoids getter calls
    //    that would consume vm.prank before proposeAction is reached) ──────────
    bytes32 constant REDUCE_LEVERAGE = keccak256("REDUCE_LEVERAGE");
    bytes32 constant PAUSE_POSITIONS = keccak256("PAUSE_POSITIONS");

    MockInvalendProtocol protocol;
    MetricoreGateway     gateway;

    address sentinel;

    uint256 constant PREFUNDED   = 800_000e6;
    uint256 constant LIQ_THRESH  = 640_000e6; // PREFUNDED × 0.8
    address constant WETH        = 0x4200000000000000000000000000000000000006;

    function setUp() public {
        // Foundry default block.timestamp = 1. Advance so lastActionTimestamp=0
        // doesn't trigger false OnCooldown (block.timestamp < 0 + 1800).
        vm.warp(1 days);

        sentinel = makeAddr("sentinel");

        // Deploy
        protocol = new MockInvalendProtocol(address(this));
        gateway  = new MetricoreGateway(address(this));

        // Wire
        protocol.setGateway(address(gateway));
        gateway.setProtocol(address(protocol));
        gateway.setSentinel(sentinel);

        // Seed CRITICAL position: HF = 7800 bps (below 8000 threshold)
        // collateral = 7800 × 640_000e6 / 10_000 = 499_200e6
        uint256 critCollateral = 7800 * LIQ_THRESH / 10_000;
        protocol.addPosition(address(0xCAFE), critCollateral, PREFUNDED);

        // Set pool to CRITICAL utilization: 91% (9100 bps > 9000 threshold)
        protocol.setPoolStats(1_000_000e6, 910_000e6);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// @dev Sets pool utilization to `bps` basis points (totalLiquidity fixed at 1M USDC).
    function _setUtilization(uint256 bps) internal {
        uint256 liquidity = 1_000_000e6;
        uint256 borrowed  = liquidity * bps / 10_000;
        protocol.setPoolStats(liquidity, borrowed);
    }

    // ── Price Snapshot ────────────────────────────────────────────────────────

    function test_UpdatePriceSnapshot_StoresCorrectly() public {
        vm.prank(sentinel);
        gateway.updatePriceSnapshot(WETH, 300_000); // $3000.00

        (uint256 price, uint256 ts) = gateway.lastPriceSnapshot(WETH);
        assertEq(price, 300_000);
        assertEq(ts, block.timestamp);
    }

    function test_UpdatePriceSnapshot_OnlySentinel() public {
        vm.expectRevert(MetricoreGateway.NotSentinel.selector);
        vm.prank(address(1));
        gateway.updatePriceSnapshot(WETH, 300_000);
    }

    // ── Propose: success cases ────────────────────────────────────────────────

    function test_ProposeReduceLeverage_Succeeds() public {
        // setUp util = 9100 bps > 8500 → REDUCE_LEVERAGE threshold met
        bytes memory data = abi.encode(uint256(3));

        vm.expectEmit(true, false, false, true, address(gateway));
        emit ActionExecuted(REDUCE_LEVERAGE, data);

        vm.prank(sentinel);
        gateway.proposeAction(REDUCE_LEVERAGE, data);

        assertEq(protocol.maxLeverageTier(), 3);
    }

    function test_ProposePausePositions_Succeeds() public {
        // setUp: util=9100 bps > 9000 AND position HF=7800 < 8000 → both criteria met
        vm.expectEmit(true, false, false, true, address(gateway));
        emit ActionExecuted(PAUSE_POSITIONS, "");

        vm.prank(sentinel);
        gateway.proposeAction(PAUSE_POSITIONS, "");

        assertTrue(protocol.newPositionsPaused());
    }

    // ── Propose: cooldown ─────────────────────────────────────────────────────

    function test_ProposeAction_Cooldown_HardReverts() public {
        bytes memory data = abi.encode(uint256(3));

        // First propose succeeds
        vm.prank(sentinel);
        gateway.proposeAction(REDUCE_LEVERAGE, data);

        // Second propose immediately → hard revert
        vm.expectRevert(MetricoreGateway.OnCooldown.selector);
        vm.prank(sentinel);
        gateway.proposeAction(REDUCE_LEVERAGE, data);
    }

    function test_ProposeAction_CooldownExpires() public {
        // First propose
        vm.prank(sentinel);
        gateway.proposeAction(PAUSE_POSITIONS, "");

        // Warp 31 minutes — past the 30-minute cooldown window
        vm.warp(block.timestamp + 31 minutes);

        // Second propose should succeed (cooldown expired, threshold still met)
        vm.expectEmit(true, false, false, false, address(gateway));
        emit ActionExecuted(PAUSE_POSITIONS, "");

        vm.prank(sentinel);
        gateway.proposeAction(PAUSE_POSITIONS, "");

        assertEq(gateway.lastActionTimestamp(PAUSE_POSITIONS), block.timestamp);
    }

    // ── Propose: soft rejection ───────────────────────────────────────────────

    function test_ProposeAction_ThresholdNotMet_SoftRejects() public {
        // Set safe utilization (5000 bps = 50%) — below 8500 bps REDUCE_LEVERAGE threshold
        _setUtilization(5000);

        uint256 tierBefore = protocol.maxLeverageTier();

        // Expect ActionRejected event (soft rejection — tx must NOT revert)
        vm.expectEmit(true, false, false, false, address(gateway));
        emit ActionRejected(REDUCE_LEVERAGE, "");

        vm.prank(sentinel);
        gateway.proposeAction(REDUCE_LEVERAGE, abi.encode(uint256(3)));

        // Action was NOT executed — leverage tier unchanged
        assertEq(protocol.maxLeverageTier(), tierBefore);
    }

    // ── Access control ────────────────────────────────────────────────────────

    function test_ProposeAction_OnlySentinel() public {
        vm.expectRevert(MetricoreGateway.NotSentinel.selector);
        vm.prank(address(1));
        gateway.proposeAction(PAUSE_POSITIONS, "");
    }

    function test_SetSentinel_OnlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(1))
        );
        vm.prank(address(1));
        gateway.setSentinel(address(2));
    }

    function test_SetProtocol_OnlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(1))
        );
        vm.prank(address(1));
        gateway.setProtocol(address(2));
    }
}
