// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockInvalendProtocol} from "../src/MockInvalendProtocol.sol";
import {MetricoreGateway} from "../src/MetricoreGateway.sol";

/// @notice Deploys MockInvalendProtocol and MetricoreGateway, wires them together,
///         then writes both addresses to deployments/base-sepolia.json.
///
/// Usage:
///   forge script script/Deploy.s.sol \
///     --rpc-url $BASE_SEPOLIA_RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast \
///     --verify \
///     --etherscan-api-key $BASESCAN_API_KEY
contract DeployScript is Script {
    function run() external {
        vm.startBroadcast();

        // 1. Deploy MockInvalendProtocol (msg.sender = deployer = owner)
        MockInvalendProtocol protocol = new MockInvalendProtocol(msg.sender);

        // 2. Deploy MetricoreGateway (msg.sender = deployer = owner)
        MetricoreGateway gateway = new MetricoreGateway(msg.sender);

        // 3. Wire protocol → gateway (protocol accepts actions from this gateway)
        protocol.setGateway(address(gateway));

        // 4. Wire gateway → protocol (gateway reads from and acts on this protocol)
        gateway.setProtocol(address(protocol));

        // NOTE: gateway.setSentinel() must be called separately after the
        // CRE workflow signing address is known (Task 4.1).

        vm.stopBroadcast();

        // ── Logging ──────────────────────────────────────────────────────────
        console.log("=== Metricore Deployment ===");
        console.log("MockInvalendProtocol:", address(protocol));
        console.log("MetricoreGateway:    ", address(gateway));
        console.log("Owner:               ", msg.sender);

        // ── Persist addresses ─────────────────────────────────────────────────
        // JSON path: deployments/base-sepolia.json (relative to contracts/)
        // Seed.s.sol and InjectStress.s.sol read from this file.
        string memory json = string.concat(
            '{"MockProtocol":"',
            vm.toString(address(protocol)),
            '","MetricoreGateway":"',
            vm.toString(address(gateway)),
            '"}'
        );
        vm.writeFile("deployments/base-sepolia.json", json);
        console.log("Addresses saved to deployments/base-sepolia.json");
    }
}
