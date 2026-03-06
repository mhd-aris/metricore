// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockInvalendProtocol} from "../src/MockInvalendProtocol.sol";

/// @notice Seeds MockInvalendProtocol with 8 mock positions across all risk tiers.
///         Reads deployed addresses from deployments/base-sepolia.json (written by Deploy.s.sol).
///
/// Collateral formula:
///   liquidationThreshold = prefunded × 8000 / 10000  (= prefunded × 0.8)
///   healthFactor_bps = collateral × 10000 / liquidationThreshold
///   → collateral = targetHF_bps × liquidationThreshold / 10000
///
/// For PREFUNDED = 800_000 USDC:
///   liquidationThreshold = 640_000 USDC
///   collateral = targetHF_bps × 640_000e6 / 10_000
///
/// Usage:
///   forge script script/Seed.s.sol \
///     --rpc-url $BASE_SEPOLIA_RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract SeedScript is Script {
    // ── Constants ─────────────────────────────────────────────────────────────

    uint256 private constant PREFUNDED      = 800_000e6; // 800,000 USDC (6 dec)
    uint256 private constant LIQ_THRESHOLD  = 640_000e6; // PREFUNDED × 0.8

    // Pre-computed collaterals: targetHF_bps × LIQ_THRESHOLD / 10_000
    // Position 0 — SAFE    HF = 9300 bps (93%)
    uint256 private constant COL_0 = 9300 * 640_000e6 / 10_000; // 595_200e6
    // Position 1 — SAFE    HF = 9400 bps (94%)
    uint256 private constant COL_1 = 9400 * 640_000e6 / 10_000; // 601_600e6
    // Position 2 — SAFE    HF = 9500 bps (95%)
    uint256 private constant COL_2 = 9500 * 640_000e6 / 10_000; // 608_000e6
    // Position 3 — ELEVATED  HF = 8400 bps (84%)
    uint256 private constant COL_3 = 8400 * 640_000e6 / 10_000; // 537_600e6
    // Position 4 — ELEVATED  HF = 8500 bps (85%)
    uint256 private constant COL_4 = 8500 * 640_000e6 / 10_000; // 544_000e6
    // Position 5 — ELEVATED  HF = 8600 bps (86%)
    uint256 private constant COL_5 = 8600 * 640_000e6 / 10_000; // 550_400e6
    // Position 6 — HIGH      HF = 8100 bps (81%)
    uint256 private constant COL_6 = 8100 * 640_000e6 / 10_000; // 518_400e6
    // Position 7 — CRITICAL  HF = 7900 bps (79%)
    uint256 private constant COL_7 = 7900 * 640_000e6 / 10_000; // 505_600e6

    // ── Runner ────────────────────────────────────────────────────────────────

    function run() external {
        string memory json     = vm.readFile("deployments/base-sepolia.json");
        address protocolAddr   = vm.parseJsonAddress(json, ".MockProtocol");
        MockInvalendProtocol protocol = MockInvalendProtocol(protocolAddr);

        console.log("=== Metricore Seed ===");
        console.log("Protocol:", protocolAddr);

        vm.startBroadcast();

        protocol.resetPositions();
        console.log("Positions reset.");

        // ── 3 SAFE positions ─────────────────────────────────────────────────

        protocol.addPosition(
            0x1111111111111111111111111111111111111111,
            COL_0,
            PREFUNDED
        );
        console.log("Position 0 [SAFE]     HF=9300 bps  collateral:", COL_0);

        protocol.addPosition(
            0x2222222222222222222222222222222222222222,
            COL_1,
            PREFUNDED
        );
        console.log("Position 1 [SAFE]     HF=9400 bps  collateral:", COL_1);

        protocol.addPosition(
            0x3333333333333333333333333333333333333333,
            COL_2,
            PREFUNDED
        );
        console.log("Position 2 [SAFE]     HF=9500 bps  collateral:", COL_2);

        // ── 3 ELEVATED positions ─────────────────────────────────────────────

        protocol.addPosition(
            0x4444444444444444444444444444444444444444,
            COL_3,
            PREFUNDED
        );
        console.log("Position 3 [ELEVATED] HF=8400 bps  collateral:", COL_3);

        protocol.addPosition(
            0x5555555555555555555555555555555555555555,
            COL_4,
            PREFUNDED
        );
        console.log("Position 4 [ELEVATED] HF=8500 bps  collateral:", COL_4);

        protocol.addPosition(
            0x6666666666666666666666666666666666666666,
            COL_5,
            PREFUNDED
        );
        console.log("Position 5 [ELEVATED] HF=8600 bps  collateral:", COL_5);

        // ── 1 HIGH position ──────────────────────────────────────────────────

        protocol.addPosition(
            0x7777777777777777777777777777777777777777,
            COL_6,
            PREFUNDED
        );
        console.log("Position 6 [HIGH]     HF=8100 bps  collateral:", COL_6);

        // ── 1 CRITICAL position ──────────────────────────────────────────────

        protocol.addPosition(
            0x8888888888888888888888888888888888888888,
            COL_7,
            PREFUNDED
        );
        console.log("Position 7 [CRITICAL] HF=7900 bps  collateral:", COL_7);

        // ── Pool stats: 65% utilization (normal state) ────────────────────────
        // totalLiquidity = 1,000,000 USDC | totalBorrowed = 650,000 USDC
        // utilization = 650_000 * 10_000 / 1_000_000 = 6500 bps (65%)
        protocol.setPoolStats(1_000_000e6, 650_000e6);
        console.log("Pool: liquidity=1,000,000 USDC  borrowed=650,000 USDC  util=6500 bps (65%)");

        vm.stopBroadcast();

        console.log("=== Seed complete. 8 positions added. ===");
    }
}
