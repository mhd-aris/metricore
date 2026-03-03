// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockInvalendProtocol
/// @notice Simulates an under-collateralized DeFi lending protocol for Metricore demo.
///         Exposes paginated position data and pool stats for CRE workflow reads,
///         and accepts risk-control actions from MetricoreGateway.
contract MockInvalendProtocol is Ownable {
    // ─────────────────────────────────────────────────────────────────────────
    // Structs
    // ─────────────────────────────────────────────────────────────────────────

    struct Position {
        uint256 id;
        address trader;
        uint256 collateralAmount; // USDC, 6 decimals
        uint256 prefundedAmount;  // USDC, 6 decimals — amount prefunded by LP
        bool isActive;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    Position[] private positions;

    uint256 public totalLiquidity = 1_000_000e6; // 1M USDC mock
    uint256 public totalBorrowed  =   650_000e6; // 650k USDC → 65% utilization
    uint256 public maxLeverageTier = 5;
    bool    public newPositionsPaused = false;

    address public gateway;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event PositionAdded(uint256 indexed id, address indexed trader, uint256 collateral, uint256 prefunded);
    event PositionsPaused();
    event PositionsResumed();
    event LeverageReduced(uint256 previousTier, uint256 newTier);
    event GatewaySet(address indexed gateway);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error NotGateway();
    error GatewayNotSet();
    error InvalidLeverageTier();
    error InvalidPositionId();

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyGateway() {
        _checkGateway();
        _;
    }

    function _checkGateway() internal view {
        if (gateway == address(0)) revert GatewayNotSet();
        if (msg.sender != gateway) revert NotGateway();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ─────────────────────────────────────────────────────────────────────────
    // View Functions — consumed by CRE workflow via EVM Read
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns a paginated slice of active positions plus the total count.
    /// @dev Pagination prevents RPC payload bloat for production-scale usage.
    /// @param start Index to start from (0-based)
    /// @param limit Maximum number of positions to return
    /// @return batch  Slice of active positions
    /// @return total  Total number of positions — used for pagination math
    function getActivePositions(uint256 start, uint256 limit)
        external
        view
        returns (Position[] memory batch, uint256 total)
    {
        total = positions.length;

        if (start >= total || limit == 0) {
            return (new Position[](0), total);
        }

        uint256 end = start + limit > total ? total : start + limit;
        uint256 count = 0;

        // First pass: count active positions in range
        for (uint256 i = start; i < end; i++) {
            if (positions[i].isActive) count++;
        }

        batch = new Position[](count);
        uint256 idx = 0;

        // Second pass: fill batch
        for (uint256 i = start; i < end; i++) {
            if (positions[i].isActive) {
                batch[idx++] = positions[i];
            }
        }
    }

    /// @notice Returns current pool statistics.
    /// @return utilization   Utilization rate in basis points (10000 = 100%)
    /// @return liquidity     Total liquidity (USDC, 6 decimals)
    /// @return borrowed      Total borrowed (USDC, 6 decimals)
    function getPoolStats()
        external
        view
        returns (uint256 utilization, uint256 liquidity, uint256 borrowed)
    {
        liquidity   = totalLiquidity;
        borrowed    = totalBorrowed;
        utilization = totalLiquidity == 0 ? 0 : (totalBorrowed * 10_000) / totalLiquidity;
    }

    /// @notice Returns the health factor for a specific position in basis points.
    /// @dev healthFactor = collateral / (prefunded * 0.8), expressed as basis points.
    ///      10000 = 100%. At-threshold = 8000 (80%).
    /// @param positionId The position's array index
    /// @return Health factor in basis points (e.g., 9200 = 92%)
    function getHealthFactor(uint256 positionId)
        external
        view
        returns (uint256)
    {
        if (positionId >= positions.length) revert InvalidPositionId();
        Position storage pos = positions[positionId];
        if (!pos.isActive || pos.prefundedAmount == 0) return 0;

        // liquidationThreshold = prefunded * 0.8 = prefunded * 8000 / 10000
        uint256 liquidationThreshold = (pos.prefundedAmount * 8_000) / 10_000;
        return (pos.collateralAmount * 10_000) / liquidationThreshold;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Gateway Actions — called by MetricoreGateway after threshold verification
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Reduces the maximum leverage tier.
    /// @param newTier New leverage tier (must be less than current and > 0)
    function reduceMaxLeverage(uint256 newTier) external onlyGateway {
        if (newTier == 0 || newTier >= maxLeverageTier) revert InvalidLeverageTier();
        uint256 previous = maxLeverageTier;
        maxLeverageTier = newTier;
        emit LeverageReduced(previous, newTier);
    }

    /// @notice Pauses opening of new positions.
    function pauseNewPositions() external onlyGateway {
        newPositionsPaused = true;
        emit PositionsPaused();
    }

    /// @notice Resumes opening of new positions.
    function resumeNewPositions() external onlyGateway {
        newPositionsPaused = false;
        emit PositionsResumed();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin / Owner Functions — seeding, testing, demo stress injection
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Sets the MetricoreGateway address.
    /// @param _gateway Address of the deployed MetricoreGateway contract
    function setGateway(address _gateway) external onlyOwner {
        gateway = _gateway;
        emit GatewaySet(_gateway);
    }

    /// @notice Adds a new mock position. Used by Seed.s.sol and InjectStress.s.sol.
    /// @param trader     Trader wallet address
    /// @param collateral Collateral amount (USDC, 6 decimals)
    /// @param prefunded  LP prefunded amount (USDC, 6 decimals)
    function addPosition(address trader, uint256 collateral, uint256 prefunded)
        external
        onlyOwner
    {
        uint256 id = positions.length;
        positions.push(Position({
            id:               id,
            trader:           trader,
            collateralAmount: collateral,
            prefundedAmount:  prefunded,
            isActive:         true
        }));
        emit PositionAdded(id, trader, collateral, prefunded);
    }

    /// @notice Overrides pool liquidity and borrow stats. Used by Seed/Stress scripts.
    function setPoolStats(uint256 _totalLiquidity, uint256 _totalBorrowed)
        external
        onlyOwner
    {
        totalLiquidity = _totalLiquidity;
        totalBorrowed  = _totalBorrowed;
    }

    /// @notice Overrides collateral of an existing position.
    ///         Used by InjectStress.s.sol to simulate price-drop scenarios.
    /// @param positionId   Position array index
    /// @param newCollateral New collateral value (USDC, 6 decimals)
    function setPositionCollateral(uint256 positionId, uint256 newCollateral)
        external
        onlyOwner
    {
        if (positionId >= positions.length) revert InvalidPositionId();
        positions[positionId].collateralAmount = newCollateral;
    }
}
