// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/VeylaVault.sol";

/// @notice Deploy VeylaVault to Passet Hub Testnet
///
/// Usage:
///   cp .env.example .env
///   # Fill in PRIVATE_KEY in .env
///   source .env
///
///   forge script script/Deploy.s.sol \
///     --rpc-url https://eth-rpc-testnet.polkadot.io \
///     --private-key $PRIVATE_KEY \
///     --broadcast
///
/// Verify on Blockscout after deploy:
///   forge verify-contract <VAULT_ADDRESS> VeylaVault \
///     --chain-id 420420417 \
///     --verifier blockscout \
///     --verifier-url https://blockscout-testnet.polkadot.io/api

contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Veyla Vault Deploy ===");
        console.log("Deployer:   ", deployer);
        console.log("Chain ID:   ", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        VeylaVault vault = new VeylaVault();

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployed Addresses ===");
        console.log("VeylaVault: ", address(vault));
        console.log("DOT token:  ", vault.DOT(),  " (address(0) sentinel - native asset via msg.value)");
        console.log("USDT token: ", vault.USDT(), " (pallet-assets ERC-20 precompile)");
        console.log("XCM precompile used: 0x00000000000000000000000000000000000a0000");
        console.log("Owner:      ", vault.owner());
        console.log("");
        console.log("=== Add to frontend/.env.local ===");
        console.log("NEXT_PUBLIC_VAULT_ADDRESS=", address(vault));
        console.log("NEXT_PUBLIC_DOT_TOKEN_ADDRESS=0x0000000000000000000000000000000000000000");
        console.log("NEXT_PUBLIC_USDT_TOKEN_ADDRESS=", vault.USDT());
        console.log("");
        console.log("=== Verify on Blockscout ===");
        console.log("forge verify-contract", address(vault), "VeylaVault \\");
        console.log("  --chain-id 420420417 \\");
        console.log("  --verifier blockscout \\");
        console.log("  --verifier-url https://blockscout-testnet.polkadot.io/api");
    }
}
