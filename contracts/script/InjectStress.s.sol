// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockInvalendProtocol} from "../src/MockInvalendProtocol.sol";

/// @notice Injects a stress scenario into MockInvalendProtocol for the demo video.
///         Pushes positions 5, 6, 7 deeper into HIGH / CRITICAL territory,
///         and raises pool utilization to 87% (HIGH pool stress).
///
/// Run AFTER Seed.s.sol. Revert to normal state by re-running Seed.s.sol.
///
/// Before (Seed state):
///   Position 5 — ELEVATED  HF = 8600 bps (86%)
///   Position 6 — HIGH      HF = 8100 bps (81%)
///   Position 7 — CRITICAL  HF = 7900 bps (79%)
///   Pool — normal           util = 6500 bps (65%)
///
/// After (Stress state):
///   Position 5 — HIGH       HF = 8200 bps (82%) → above REDUCE_LEVERAGE threshold
///   Position 6 — CRITICAL   HF = 8000 bps (80%) → at PAUSE_POSITIONS threshold
///   Position 7 — deep CRIT  HF = 7800 bps (78%) → well below threshold
///   Pool — HIGH stress       util = 8700 bps (87%) → above REDUCE_LEVERAGE threshold
///
/// Usage:
///   forge script script/InjectStress.s.sol \
///     --rpc-url $BASE_SEPOLIA_RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract InjectStressScript is Script {
    // ── Constants ─────────────────────────────────────────────────────────────

    // liquidationThreshold for PREFUNDED = 800_000e6 → 640_000e6
    uint256 private constant LIQ_THRESHOLD = 640_000e6;

    // New collaterals: targetHF_bps × LIQ_THRESHOLD / 10_000
    uint256 private constant NEW_COL_5 = 8200 * 640_000e6 / 10_000; // HF = 8200 bps (82%)
    uint256 private constant NEW_COL_6 = 8000 * 640_000e6 / 10_000; // HF = 8000 bps (80%)
    uint256 private constant NEW_COL_7 = 7800 * 640_000e6 / 10_000; // HF = 7800 bps (78%)

    // Stressed pool stats: 87% utilization
    // utilization = 870_000 × 10_000 / 1_000_000 = 8700 bps
    uint256 private constant STRESS_LIQUIDITY = 1_000_000e6;
    uint256 private constant STRESS_BORROWED  =   870_000e6; // 8700 bps (87%)

    // ── Runner ────────────────────────────────────────────────────────────────

    function run() external {
        string memory json   = vm.readFile("deployments/base-sepolia.json");
        address protocolAddr = vm.parseJsonAddress(json, ".MockProtocol");
        MockInvalendProtocol protocol = MockInvalendProtocol(protocolAddr);

        console.log("=== Metricore InjectStress ===");
        console.log("Protocol:", protocolAddr);

        // ── Read BEFORE state ─────────────────────────────────────────────────
        uint256 hf5Before = protocol.getHealthFactor(5);
        uint256 hf6Before = protocol.getHealthFactor(6);
        uint256 hf7Before = protocol.getHealthFactor(7);
        (uint256 utilBefore,,) = protocol.getPoolStats();

        console.log("--- Before ---");
        console.log("Position 5 HF (bps):", hf5Before);
        console.log("Position 6 HF (bps):", hf6Before);
        console.log("Position 7 HF (bps):", hf7Before);
        console.log("Pool utilization (bps):", utilBefore);

        // ── Apply stress ──────────────────────────────────────────────────────
        vm.startBroadcast();

        // Position 5: ELEVATED → HIGH  (HF 8600 → 8200 bps)
        protocol.setPositionCollateral(5, NEW_COL_5);

        // Position 6: HIGH → CRITICAL  (HF 8100 → 8000 bps)
        protocol.setPositionCollateral(6, NEW_COL_6);

        // Position 7: CRITICAL → deep CRITICAL  (HF 7900 → 7800 bps)
        protocol.setPositionCollateral(7, NEW_COL_7);

        // Pool: 65% → 87% utilization
        protocol.setPoolStats(STRESS_LIQUIDITY, STRESS_BORROWED);

        vm.stopBroadcast();

        // ── Read AFTER state ──────────────────────────────────────────────────
        uint256 hf5After = protocol.getHealthFactor(5);
        uint256 hf6After = protocol.getHealthFactor(6);
        uint256 hf7After = protocol.getHealthFactor(7);
        (uint256 utilAfter,,) = protocol.getPoolStats();

        console.log("--- After ---");
        console.log("Position 5 HF (bps):", hf5After);
        console.log("  target=8200 (82% - HIGH territory, above REDUCE_LEVERAGE threshold)");
        console.log("Position 6 HF (bps):", hf6After);
        console.log("  target=8000 (80% - CRITICAL threshold, triggers PAUSE_POSITIONS)");
        console.log("Position 7 HF (bps):", hf7After);
        console.log("  target=7800 (78% - deep CRITICAL)");
        console.log("Pool utilization (bps):", utilAfter);
        console.log("  target=8700 (87% - HIGH pool stress, above REDUCE_LEVERAGE threshold)");

        console.log("=== Stress injection complete. Run workflow to trigger alerts. ===");
    }
}
