// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Interface
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Minimal interface for reading from and acting on MockInvalendProtocol.
interface IMockProtocol {
    struct Position {
        uint256 id;
        address trader;
        uint256 collateralAmount;
        uint256 prefundedAmount;
        bool isActive;
    }

    function getPoolStats()
        external
        view
        returns (uint256 utilization, uint256 liquidity, uint256 borrowed);

    function getActivePositions(uint256 start, uint256 limit)
        external
        view
        returns (Position[] memory batch, uint256 total);

    function getHealthFactor(uint256 positionId) external view returns (uint256);

    function reduceMaxLeverage(uint256 newTier) external;

    function pauseNewPositions() external;

    function resumeNewPositions() external;
}

// ─────────────────────────────────────────────────────────────────────────────
// Contract
// ─────────────────────────────────────────────────────────────────────────────

/// @title MetricoreGateway
/// @notice Trustless intermediary between the Metricore CRE Sentinel workflow and
///         MockInvalendProtocol. Implements the Propose-Verify-Execute pattern:
///         the Sentinel proposes an action via the Keystone Forwarder, the Gateway
///         independently re-verifies the risk condition on-chain, then executes
///         (or rejects) accordingly.
///
/// @dev Key architectural properties:
///      - The Gateway never trusts workflow-supplied data for safety decisions.
///        It always re-reads current protocol state from the blockchain.
///      - Cooldown (30 min per action type) prevents proposal spam.
///      - Price snapshots persist Sentinel state across stateless CRE runs.
///      - Threshold failures are soft-rejected (event emitted, tx succeeds) so the
///        forwarder does not pay gas for reverts on normal oscillation.
///      - Cooldown violations are hard-rejected (revert) to signal a workflow bug.
///      - CRE write path: workflow → runtime.report() → evmClient.writeReport()
///        → KeystoneForwarder → MetricoreGateway.onReport(metadata, report)
contract MetricoreGateway is Ownable {
    // ─────────────────────────────────────────────────────────────────────────
    // Structs
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice On-chain price record written by the Sentinel each workflow run.
    ///         Enables the stateless CRE environment to compute hourly price changes.
    /// @dev price uses 2 decimal precision: 300000 = $3000.00
    struct PriceSnapshot {
        uint256 price;     // USD × 100 (e.g. 300000 = $3000.00)
        uint256 timestamp; // block.timestamp when the snapshot was recorded
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Minimum seconds between successive proposals of the same action type.
    uint256 public constant COOLDOWN_PERIOD = 30 minutes;

    /// @notice Maximum positions scanned during on-chain threshold verification.
    uint256 private constant VERIFY_BATCH = 50;

    // Threshold values in basis points (10000 = 100%)
    uint256 private constant UTILIZATION_REDUCE_BPS     = 8_500; // 85%
    uint256 private constant UTILIZATION_PAUSE_BPS      = 9_000; // 90%
    uint256 private constant HEALTH_FACTOR_CRITICAL_BPS = 8_000; // 80%

    /// @notice New leverage tier applied when REDUCE_LEVERAGE executes.
    uint256 private constant REDUCE_LEVERAGE_NEW_TIER = 3;

    /// @notice keccak256 action type — reduce the max leverage tier.
    bytes32 public constant ACTION_REDUCE_LEVERAGE = keccak256("REDUCE_LEVERAGE");

    /// @notice keccak256 action type — pause new position openings.
    bytes32 public constant ACTION_PAUSE_POSITIONS = keccak256("PAUSE_POSITIONS");

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Address of the Keystone Forwarder that routes CRE writeReport calls.
    address public forwarder;

    /// @notice Address of the MockInvalendProtocol contract this Gateway controls.
    address public protocol;

    /// @notice block.timestamp of the last execution per action type.
    mapping(bytes32 => uint256) public lastActionTimestamp;

    /// @notice Most recent price snapshot per asset, written each workflow run.
    mapping(address => PriceSnapshot) public lastPriceSnapshot;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Emitted when an action is received via onReport (before verification).
    event ActionProposed(bytes32 indexed actionType, address indexed proposer);

    /// @notice Emitted when an action passes threshold verification and is executed.
    event ActionExecuted(bytes32 indexed actionType, bytes actionData);

    /// @notice Emitted when threshold verification fails (soft rejection — tx does not revert).
    event ActionRejected(bytes32 indexed actionType, string reason);

    /// @notice Emitted when the workflow updates an asset's price snapshot.
    event SnapshotUpdated(address indexed asset, uint256 price, uint256 timestamp);

    /// @notice Emitted when the owner changes the Forwarder address.
    event ForwarderSet(address indexed newForwarder);

    /// @notice Emitted when the owner changes the protocol address.
    event ProtocolSet(address indexed newProtocol);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Caller is not the authorised Keystone Forwarder.
    error NotForwarder();

    /// @notice Action was proposed before its cooldown window has elapsed.
    error OnCooldown();

    /// @notice The on-chain risk condition was not met (used for explicit checks).
    error ThresholdNotMet();

    /// @notice A zero address was supplied where a valid address is required.
    error ZeroAddress();

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyForwarder() {
        if (msg.sender != forwarder) revert NotForwarder();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /// @param initialOwner Owner address (deployer).
    /// @param _forwarder   Keystone Forwarder address that calls onReport().
    constructor(address initialOwner, address _forwarder) Ownable(initialOwner) {
        if (_forwarder == address(0)) revert ZeroAddress();
        forwarder = _forwarder;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Owner Configuration
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Updates the Keystone Forwarder address.
    /// @param _forwarder New forwarder address. Must be non-zero.
    function setForwarder(address _forwarder) external onlyOwner {
        if (_forwarder == address(0)) revert ZeroAddress();
        forwarder = _forwarder;
        emit ForwarderSet(_forwarder);
    }

    /// @notice Resets the cooldown for a given action type. Demo / admin use only.
    function resetCooldown(bytes32 actionType) external onlyOwner {
        lastActionTimestamp[actionType] = 0;
    }

    /// @notice Resumes new positions on the protocol via gateway. Demo / admin use.
    function resumeNewPositions() external onlyOwner {
        IMockProtocol(protocol).resumeNewPositions();
    }

    /// @notice Sets the MockInvalendProtocol address the Gateway reads and acts on.
    /// @param _protocol New protocol address. Must be non-zero.
    function setProtocol(address _protocol) external onlyOwner {
        if (_protocol == address(0)) revert ZeroAddress();
        protocol = _protocol;
        emit ProtocolSet(_protocol);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CRE Receiver — called by KeystoneForwarder
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Entry point called by the Keystone Forwarder when the CRE workflow
    ///         submits a signed report via evmClient.writeReport().
    ///
    ///         Flow:
    ///           1. Decode report payload to extract actionType (bytes32).
    ///           2. Hard-reject if still on cooldown (revert OnCooldown).
    ///           3. Re-verify risk condition independently from on-chain state.
    ///           4. Soft-reject if condition not met (emit ActionRejected, return).
    ///           5. Execute action, update cooldown timestamp, emit ActionExecuted.
    ///
    /// @param metadata Forwarder-supplied metadata (ignored by this contract).
    /// @param report   ABI-encoded action payload: abi.encode(bytes32 actionType).
    function onReport(bytes calldata metadata, bytes calldata report)
        external
        onlyForwarder
    {
        // Suppress unused param warning — metadata is required by the interface
        metadata;

        bytes32 actionType = abi.decode(report, (bytes32));

        if (_isOnCooldown(actionType)) revert OnCooldown();

        emit ActionProposed(actionType, msg.sender);

        if (!_verifyThreshold(actionType)) {
            emit ActionRejected(actionType, "Threshold not met on-chain");
            return;
        }

        lastActionTimestamp[actionType] = block.timestamp;
        bytes memory actionData = _executeAction(actionType);
        emit ActionExecuted(actionType, actionData);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Price Snapshot — written by workflow each run
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Records the current price of an asset on-chain.
    ///         Called by the CRE workflow every execution cycle to persist the price
    ///         needed for next-run hourly-change calculations.
    ///         No access control — price data is not security-critical; it is a
    ///         stateless cache used for market condition comparison only.
    /// @param asset  Asset address used as the mapping key (e.g. WETH on Base Sepolia)
    /// @param price  Current price in USD with 2 decimal precision (e.g. 300000 = $3000.00)
    function updatePriceSnapshot(address asset, uint256 price) external {
        lastPriceSnapshot[asset] = PriceSnapshot({price: price, timestamp: block.timestamp});
        emit SnapshotUpdated(asset, price, block.timestamp);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal — Cooldown
    // ─────────────────────────────────────────────────────────────────────────

    function _isOnCooldown(bytes32 actionType) internal view returns (bool) {
        return block.timestamp < lastActionTimestamp[actionType] + COOLDOWN_PERIOD;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal — Threshold Verification
    // ─────────────────────────────────────────────────────────────────────────

    function _verifyThreshold(bytes32 actionType) internal view returns (bool) {
        if (actionType == ACTION_REDUCE_LEVERAGE) {
            return _checkReduceLeverageThreshold();
        }
        if (actionType == ACTION_PAUSE_POSITIONS) {
            return _checkPausePositionsThreshold();
        }
        return false;
    }

    function _checkReduceLeverageThreshold() private view returns (bool) {
        (uint256 utilization,,) = IMockProtocol(protocol).getPoolStats();
        return utilization > UTILIZATION_REDUCE_BPS;
    }

    function _checkPausePositionsThreshold() private view returns (bool) {
        (uint256 utilization,,) = IMockProtocol(protocol).getPoolStats();
        if (utilization > UTILIZATION_PAUSE_BPS) return true;

        (IMockProtocol.Position[] memory batch,) =
            IMockProtocol(protocol).getActivePositions(0, VERIFY_BATCH);

        for (uint256 i = 0; i < batch.length; i++) {
            uint256 hf = IMockProtocol(protocol).getHealthFactor(batch[i].id);
            if (hf > 0 && hf < HEALTH_FACTOR_CRITICAL_BPS) return true;
        }

        return false;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal — Execution
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Executes the risk-control action and returns the encoded action data
    ///         for inclusion in the ActionExecuted event.
    function _executeAction(bytes32 actionType) internal returns (bytes memory actionData) {
        if (actionType == ACTION_REDUCE_LEVERAGE) {
            IMockProtocol(protocol).reduceMaxLeverage(REDUCE_LEVERAGE_NEW_TIER);
            return abi.encode(REDUCE_LEVERAGE_NEW_TIER);
        }
        if (actionType == ACTION_PAUSE_POSITIONS) {
            IMockProtocol(protocol).pauseNewPositions();
            return "";
        }
    }
}
