// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/MockInvalendProtocol.sol";
import "../src/MetricoreGateway.sol";

contract Reset is Script {
    bytes32 constant PAUSE_POSITIONS =
        0x8e6c1f8d118e3b2b2134314d9109d09eac06816d1e60cdf6ff3ace2b9b35ce6a;
    bytes32 constant REDUCE_LEVERAGE =
        0xd490a29c3eef0ab146e48c53e346c3115536112e333fab711e86c347c4f5a439;

    function run() external {
        string memory json = vm.readFile("deployments/base-sepolia.json");
        address protocolAddr = vm.parseJsonAddress(json, ".MockProtocol");
        address gatewayAddr  = vm.parseJsonAddress(json, ".MetricoreGateway");

        MockInvalendProtocol protocol = MockInvalendProtocol(protocolAddr);
        MetricoreGateway gateway      = MetricoreGateway(gatewayAddr);

        vm.startBroadcast();

        // 1. Reset positions to seed state
        protocol.resetPositions();
        _seedPositions(protocol);

        // 2. Resume new positions
        gateway.resumeNewPositions();

        // 3. Reset cooldowns
        gateway.resetCooldown(PAUSE_POSITIONS);
        gateway.resetCooldown(REDUCE_LEVERAGE);

        // 4. Reset pool stats to normal (65% utilization)
        protocol.setPoolStats(1_000_000e6, 650_000e6);

        vm.stopBroadcast();

        console.log("=== Metricore Demo Reset ===");
        console.log("Protocol:", protocolAddr);
        console.log("Gateway:", gatewayAddr);
        console.log("Positions: reset to 8 seeded positions");
        console.log("Pool utilization: 65%");
        console.log("newPositionsPaused: false");
        console.log("Cooldowns: cleared");
        console.log("=== Ready for demo ===");
    }

    function _seedPositions(MockInvalendProtocol protocol) internal {
        uint256 prefunded     = 800_000e6;
        uint256 liqThreshold  = 640_000e6; // prefunded × 0.8

        // SAFE positions (93–95%)
        protocol.addPosition(address(0x1111111111111111111111111111111111111111), 9300 * liqThreshold / 10_000, prefunded);
        protocol.addPosition(address(0x2222222222222222222222222222222222222222), 9400 * liqThreshold / 10_000, prefunded);
        protocol.addPosition(address(0x3333333333333333333333333333333333333333), 9500 * liqThreshold / 10_000, prefunded);
        // ELEVATED positions (84–86%)
        protocol.addPosition(address(0x4444444444444444444444444444444444444444), 8400 * liqThreshold / 10_000, prefunded);
        protocol.addPosition(address(0x5555555555555555555555555555555555555555), 8500 * liqThreshold / 10_000, prefunded);
        protocol.addPosition(address(0x6666666666666666666666666666666666666666), 8600 * liqThreshold / 10_000, prefunded);
        // HIGH position (81%)
        protocol.addPosition(address(0x7777777777777777777777777777777777777777), 8100 * liqThreshold / 10_000, prefunded);
        // CRITICAL position (79%)
        protocol.addPosition(address(0x8888888888888888888888888888888888888888), 7900 * liqThreshold / 10_000, prefunded);
    }
}
