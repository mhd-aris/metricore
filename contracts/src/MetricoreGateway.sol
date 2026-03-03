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
}

// ─────────────────────────────────────────────────────────────────────────────
// Contract
// ─────────────────────────────────────────────────────────────────────────────

/// @title MetricoreGateway
/// @notice Trustless intermediary between the Metricore CRE Sentinel workflow and
///         MockInvalendProtocol. Implements the Propose-Verify-Execute pattern:
///         the Sentinel proposes an action, the Gateway independently re-verifies
///         the risk condition on-chain, then executes (or rejects) accordingly.
///
/// @dev Key architectural properties:
///      - The Gateway never trusts workflow-supplied data for safety decisions.
///        It always re-reads current protocol state from the blockchain.
///      - Cooldown (30 min per action type) prevents proposal spam (Fix #4).
///      - Price snapshots persist Sentinel state across stateless CRE runs (Fix #1).
///      - Threshold failures are soft-rejected (event emitted, tx succeeds) so the
///        Sentinel does not pay gas for reverts on normal oscillation.
///      - Cooldown violations are hard-rejected (revert) to signal a workflow bug.
contract MetricoreGateway is Ownable {
    // ─────────────────────────────────────────────────────────────────────────
    // Structs
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice On-chain price record written by the Sentinel each workflow run.
    ///         Enables the stateless CRE environment to compute hourly price changes.
    /// @dev price uses 2 decimal precision: 300000 = $3000.00 (Fix #1 state persistence)
    struct PriceSnapshot {
        uint256 price;     // USD × 100 (e.g. 300000 = $3000.00)
        uint256 timestamp; // block.timestamp when the snapshot was recorded
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Minimum seconds between successive proposals of the same action type.
    ///         Prevents the Sentinel from spamming proposals during oscillating conditions.
    uint256 public constant COOLDOWN_PERIOD = 30 minutes;

    /// @notice Maximum positions scanned during on-chain threshold verification.
    uint256 private constant VERIFY_BATCH = 50;

    // Threshold values in basis points (10000 = 100%)
    uint256 private constant UTILIZATION_REDUCE_BPS   = 8_500; // 85% → trigger REDUCE_LEVERAGE
    uint256 private constant UTILIZATION_PAUSE_BPS    = 9_000; // 90% → trigger PAUSE_POSITIONS
    uint256 private constant HEALTH_FACTOR_CRITICAL_BPS = 8_000; // 80% → trigger PAUSE_POSITIONS

    /// @notice keccak256 action type used to propose reducing the max leverage tier.
    bytes32 public constant ACTION_REDUCE_LEVERAGE = keccak256("REDUCE_LEVERAGE");

    /// @notice keccak256 action type used to propose pausing new position openings.
    bytes32 public constant ACTION_PAUSE_POSITIONS = keccak256("PAUSE_POSITIONS");

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Address of the authorised CRE Sentinel (the workflow's signing key).
    address public sentinel;

    /// @notice Address of the MockInvalendProtocol contract this Gateway controls.
    address public protocol;

    /// @notice block.timestamp of the last execution per action type.
    ///         Used to enforce the cooldown window.
    mapping(bytes32 => uint256) public lastActionTimestamp;

    /// @notice Most recent price snapshot per asset, written by Sentinel each run.
    ///         Key: asset address (e.g. WETH on Base). Value: PriceSnapshot.
    mapping(address => PriceSnapshot) public lastPriceSnapshot;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Emitted when the Sentinel calls proposeAction (before verification).
    event ActionProposed(bytes32 indexed actionType, address indexed proposer);

    /// @notice Emitted when an action passes threshold verification and is executed.
    event ActionExecuted(bytes32 indexed actionType, bytes actionData);

    /// @notice Emitted when threshold verification fails (soft rejection — tx does not revert).
    event ActionRejected(bytes32 indexed actionType, string reason);

    /// @notice Emitted when the Sentinel updates an asset's price snapshot.
    event SnapshotUpdated(address indexed asset, uint256 price, uint256 timestamp);

    /// @notice Emitted when the owner changes the Sentinel address.
    event SentinelSet(address indexed newSentinel);

    /// @notice Emitted when the owner changes the protocol address.
    event ProtocolSet(address indexed newProtocol);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Caller is not the authorised Sentinel.
    error NotSentinel();

    /// @notice Action was proposed before its cooldown window has elapsed.
    error OnCooldown();

    /// @notice The on-chain risk condition was not met (used for explicit checks).
    error ThresholdNotMet();

    /// @notice A zero address was supplied where a valid address is required.
    error ZeroAddress();

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlySentinel() {
        _checkSentinel();
        _;
    }

    function _checkSentinel() internal view {
        if (msg.sender != sentinel) revert NotSentinel();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ─────────────────────────────────────────────────────────────────────────
    // Owner Configuration
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Sets the CRE Sentinel address (the workflow signing key).
    /// @dev Only callable by the contract owner. Replace when rotating CRE keys.
    /// @param _sentinel New sentinel address. Must be non-zero.
    function setSentinel(address _sentinel) external onlyOwner {
        if (_sentinel == address(0)) revert ZeroAddress();
        sentinel = _sentinel;
        emit SentinelSet(_sentinel);
    }

    /// @notice Sets the MockInvalendProtocol address the Gateway reads and acts on.
    /// @param _protocol New protocol address. Must be non-zero.
    function setProtocol(address _protocol) external onlyOwner {
        if (_protocol == address(0)) revert ZeroAddress();
        protocol = _protocol;
        emit ProtocolSet(_protocol);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Sentinel Functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Records the current price of an asset on-chain.
    ///         Called by the CRE workflow every execution cycle to persist the price
    ///         needed for next-run hourly-change calculations (Fix #1).
    /// @param asset  Asset address used as the mapping key (e.g. WETH on Base Sepolia)
    /// @param price  Current price in USD with 2 decimal precision (e.g. 300000 = $3000.00)
    function updatePriceSnapshot(address asset, uint256 price) external onlySentinel {
        lastPriceSnapshot[asset] = PriceSnapshot({price: price, timestamp: block.timestamp});
        emit SnapshotUpdated(asset, price, block.timestamp);
    }

    /// @notice Entry point for the CRE Sentinel to propose a risk-control action.
    ///
    ///         Flow:
    ///           1. Hard-reject if still on cooldown (revert OnCooldown).
    ///           2. Re-verify risk condition independently from on-chain state.
    ///           3. Soft-reject if condition not met (emit ActionRejected, return).
    ///           4. Execute action, update cooldown timestamp, emit ActionExecuted.
    ///
    /// @dev Soft rejection keeps the Sentinel tx alive so it can proceed to
    ///      updatePriceSnapshot at the end of the workflow run regardless of action outcome.
    ///
    /// @param actionType  One of ACTION_REDUCE_LEVERAGE or ACTION_PAUSE_POSITIONS.
    /// @param actionData  ABI-encoded parameters:
    ///                    - REDUCE_LEVERAGE: abi.encode(uint256 newTier)
    ///                    - PAUSE_POSITIONS: "" (empty bytes)
    function proposeAction(bytes32 actionType, bytes calldata actionData)
        external
        onlySentinel
    {
        if (_isOnCooldown(actionType)) revert OnCooldown();

        emit ActionProposed(actionType, msg.sender);

        if (!_verifyThreshold(actionType)) {
            emit ActionRejected(actionType, "Threshold not met on-chain");
            return;
        }

        _executeAction(actionType, actionData);
        lastActionTimestamp[actionType] = block.timestamp;
        emit ActionExecuted(actionType, actionData);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal — Cooldown
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns true if the action is still within its cooldown window.
    /// @param actionType Action type identifier to check.
    function _isOnCooldown(bytes32 actionType) internal view returns (bool) {
        return block.timestamp < lastActionTimestamp[actionType] + COOLDOWN_PERIOD;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal — Threshold Verification
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Dispatches to the specific threshold check for the given action type.
    ///         The Gateway NEVER trusts the Sentinel's assertion — it re-reads state.
    /// @param actionType Action type to verify.
    /// @return true if the threshold condition is met and action should proceed.
    function _verifyThreshold(bytes32 actionType) internal view returns (bool) {
        if (actionType == ACTION_REDUCE_LEVERAGE) {
            return _checkReduceLeverageThreshold();
        }
        if (actionType == ACTION_PAUSE_POSITIONS) {
            return _checkPausePositionsThreshold();
        }
        return false;
    }

    /// @notice REDUCE_LEVERAGE condition: pool utilization > 8500 bps (85%).
    function _checkReduceLeverageThreshold() private view returns (bool) {
        (uint256 utilization,,) = IMockProtocol(protocol).getPoolStats();
        return utilization > UTILIZATION_REDUCE_BPS;
    }

    /// @notice PAUSE_POSITIONS condition:
    ///         pool utilization > 9000 bps (90%)
    ///         OR any position in the first batch has healthFactor < 8000 bps (80%).
    ///
    /// @dev Scanning the first VERIFY_BATCH (50) positions is sufficient for demo
    ///      and mirrors the workflow's BATCH_SIZE, keeping both layers consistent.
    function _checkPausePositionsThreshold() private view returns (bool) {
        (uint256 utilization,,) = IMockProtocol(protocol).getPoolStats();
        if (utilization > UTILIZATION_PAUSE_BPS) return true;

        (IMockProtocol.Position[] memory batch,) =
            IMockProtocol(protocol).getActivePositions(0, VERIFY_BATCH);

        for (uint256 i = 0; i < batch.length; i++) {
            uint256 hf = IMockProtocol(protocol).getHealthFactor(batch[i].id);
            // hf == 0 means inactive / zero prefunded — skip those
            if (hf > 0 && hf < HEALTH_FACTOR_CRITICAL_BPS) return true;
        }

        return false;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal — Execution
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Calls the appropriate function on MockInvalendProtocol.
    /// @param actionType Identifies which action to run.
    /// @param actionData ABI-encoded parameters for the action.
    function _executeAction(bytes32 actionType, bytes calldata actionData) internal {
        if (actionType == ACTION_REDUCE_LEVERAGE) {
            uint256 newTier = abi.decode(actionData, (uint256));
            IMockProtocol(protocol).reduceMaxLeverage(newTier);
        } else if (actionType == ACTION_PAUSE_POSITIONS) {
            IMockProtocol(protocol).pauseNewPositions();
        }
    }
}
