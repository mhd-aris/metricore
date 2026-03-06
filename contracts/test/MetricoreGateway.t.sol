// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockInvalendProtocol} from "../src/MockInvalendProtocol.sol";
import {MetricoreGateway} from "../src/MetricoreGateway.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MetricoreGatewayTest is Test {
    // ── Event mirrors ─────────────────────────────────────────────────────────
    event ActionProposed(bytes32 indexed actionType, address indexed proposer);
    event ActionExecuted(bytes32 indexed actionType, bytes actionData);
    event ActionRejected(bytes32 indexed actionType, string reason);
    event SnapshotUpdated(address indexed asset, uint256 price, uint256 timestamp);

    // ── Action type constants ─────────────────────────────────────────────────
    bytes32 constant REDUCE_LEVERAGE = keccak256("REDUCE_LEVERAGE");
    bytes32 constant PAUSE_POSITIONS = keccak256("PAUSE_POSITIONS");

    MockInvalendProtocol protocol;
    MetricoreGateway     gateway;

    address forwarder;

    uint256 constant PREFUNDED   = 800_000e6;
    uint256 constant LIQ_THRESH  = 640_000e6; // PREFUNDED × 0.8
    address constant WETH        = 0x4200000000000000000000000000000000000006;

    // Simulation forwarder address
    address constant SIM_FORWARDER = 0x82300bd7c3958625581cc2F77bC6464dcEcDF3e5;

    function setUp() public {
        vm.warp(1 days);

        forwarder = SIM_FORWARDER;

        // Deploy — constructor now takes (owner, forwarder)
        protocol = new MockInvalendProtocol(address(this));
        gateway  = new MetricoreGateway(address(this), forwarder);

        // Wire
        protocol.setGateway(address(gateway));
        gateway.setProtocol(address(protocol));

        // Seed CRITICAL position: HF = 7800 bps (below 8000 threshold)
        uint256 critCollateral = 7800 * LIQ_THRESH / 10_000;
        protocol.addPosition(address(0xCAFE), critCollateral, PREFUNDED);

        // Set pool to CRITICAL utilization: 91% (9100 bps > 9000 threshold)
        protocol.setPoolStats(1_000_000e6, 910_000e6);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _setUtilization(uint256 bps) internal {
        uint256 liquidity = 1_000_000e6;
        uint256 borrowed  = liquidity * bps / 10_000;
        protocol.setPoolStats(liquidity, borrowed);
    }

    /// @dev Encode report payload: abi.encode(bytes32 actionType)
    function _encodeReport(bytes32 actionType) internal pure returns (bytes memory) {
        return abi.encode(actionType);
    }

    // ── Price Snapshot ────────────────────────────────────────────────────────

    function test_UpdatePriceSnapshot_StoresCorrectly() public {
        // updatePriceSnapshot has no access control — anyone can call it
        gateway.updatePriceSnapshot(WETH, 300_000); // $3000.00

        (uint256 price, uint256 ts) = gateway.lastPriceSnapshot(WETH);
        assertEq(price, 300_000);
        assertEq(ts, block.timestamp);
    }

    function test_UpdatePriceSnapshot_EmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(gateway));
        emit SnapshotUpdated(WETH, 300_000, block.timestamp);

        gateway.updatePriceSnapshot(WETH, 300_000);
    }

    // ── onReport: success cases ───────────────────────────────────────────────

    function test_OnReport_ReduceLeverage_Succeeds() public {
        // setUp util = 9100 bps > 8500 → REDUCE_LEVERAGE threshold met
        vm.expectEmit(true, false, false, true, address(gateway));
        emit ActionExecuted(REDUCE_LEVERAGE, abi.encode(uint256(3)));

        vm.prank(forwarder);
        gateway.onReport("", _encodeReport(REDUCE_LEVERAGE));

        assertEq(protocol.maxLeverageTier(), 3);
    }

    function test_OnReport_PausePositions_Succeeds() public {
        // setUp: util=9100 bps > 9000 AND position HF=7800 < 8000 → both criteria met
        vm.expectEmit(true, false, false, true, address(gateway));
        emit ActionExecuted(PAUSE_POSITIONS, "");

        vm.prank(forwarder);
        gateway.onReport("", _encodeReport(PAUSE_POSITIONS));

        assertTrue(protocol.newPositionsPaused());
    }

    function test_OnReport_EmitsActionProposed() public {
        vm.expectEmit(true, true, false, false, address(gateway));
        emit ActionProposed(PAUSE_POSITIONS, forwarder);

        vm.prank(forwarder);
        gateway.onReport("", _encodeReport(PAUSE_POSITIONS));
    }

    // ── onReport: cooldown ────────────────────────────────────────────────────

    function test_OnReport_Cooldown_HardReverts() public {
        // First report succeeds
        vm.prank(forwarder);
        gateway.onReport("", _encodeReport(REDUCE_LEVERAGE));

        // Second report immediately → hard revert
        vm.expectRevert(MetricoreGateway.OnCooldown.selector);
        vm.prank(forwarder);
        gateway.onReport("", _encodeReport(REDUCE_LEVERAGE));
    }

    function test_OnReport_CooldownExpires() public {
        vm.prank(forwarder);
        gateway.onReport("", _encodeReport(PAUSE_POSITIONS));

        // Warp 31 minutes — past the 30-minute cooldown window
        vm.warp(block.timestamp + 31 minutes);

        vm.expectEmit(true, false, false, false, address(gateway));
        emit ActionExecuted(PAUSE_POSITIONS, "");

        vm.prank(forwarder);
        gateway.onReport("", _encodeReport(PAUSE_POSITIONS));

        assertEq(gateway.lastActionTimestamp(PAUSE_POSITIONS), block.timestamp);
    }

    // ── onReport: soft rejection ──────────────────────────────────────────────

    function test_OnReport_ThresholdNotMet_SoftRejects() public {
        // Set safe utilization (50%) — below 8500 bps REDUCE_LEVERAGE threshold
        _setUtilization(5000);

        uint256 tierBefore = protocol.maxLeverageTier();

        vm.expectEmit(true, false, false, false, address(gateway));
        emit ActionRejected(REDUCE_LEVERAGE, "");

        vm.prank(forwarder);
        gateway.onReport("", _encodeReport(REDUCE_LEVERAGE));

        assertEq(protocol.maxLeverageTier(), tierBefore);
    }

    // ── Access control ────────────────────────────────────────────────────────

    function test_OnReport_OnlyForwarder() public {
        vm.expectRevert(MetricoreGateway.NotForwarder.selector);
        vm.prank(address(1));
        gateway.onReport("", _encodeReport(PAUSE_POSITIONS));
    }

    function test_SetForwarder_OnlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(1))
        );
        vm.prank(address(1));
        gateway.setForwarder(address(2));
    }

    function test_SetProtocol_OnlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(1))
        );
        vm.prank(address(1));
        gateway.setProtocol(address(2));
    }

    function test_Constructor_ZeroForwarder_Reverts() public {
        vm.expectRevert(MetricoreGateway.ZeroAddress.selector);
        new MetricoreGateway(address(this), address(0));
    }
}
