// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TrancheFiVault} from "../src/TrancheFiVault.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";

/**
 * @title  DeployTrancheFi
 * @notice Deploys TrancheFiVault + AaveV3Adapter to Arbitrum One.
 *
 * Usage:
 *   forge script script/Deploy.s.sol:DeployTrancheFi \
 *     --rpc-url $ARBITRUM_RPC \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 *
 * Required environment variables:
 *   DEPLOYER_PRIVATE_KEY  — deployer wallet (becomes admin)
 *   KEEPER_ADDRESS        — keeper bot wallet
 *   USDC_ADDRESS          — USDC on Arbitrum (0xaf88d065e77c8cC2239327C5EDb3A432268e5831)
 *   USDAT_ADDRESS         — USDat token (Saturn)
 *   SUSDAT_ADDRESS        — sUSDat vault (Saturn)
 *   STRC_ORACLE_ADDRESS   — STRC price oracle
 *   CURVE_POOL_ADDRESS    — Curve sUSDat/USDC pool
 *   AAVE_POOL_ADDRESS     — Aave V3 Pool (0x794a61358D6845594F94dc1DB02A252b5b4814aD)
 *   AAVE_DATA_PROVIDER    — Aave V3 PoolDataProvider (0x69FA688f1Dc47d4B5d8029D5a35FC7379531Bd43)
 */
contract DeployTrancheFi is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address keeper = vm.envAddress("KEEPER_ADDRESS");

        // Token addresses
        address usdc = vm.envAddress("USDC_ADDRESS");
        address usdat = vm.envAddress("USDAT_ADDRESS");
        address sUsdat = vm.envAddress("SUSDAT_ADDRESS");
        address strcOracle = vm.envAddress("STRC_ORACLE_ADDRESS");
        address curvePool = vm.envAddress("CURVE_POOL_ADDRESS");

        // Aave addresses
        address aavePool = vm.envAddress("AAVE_POOL_ADDRESS");
        address aaveDataProvider = vm.envAddress("AAVE_DATA_PROVIDER");

        address deployer = vm.addr(deployerKey);

        console.log("=== TrancheFi v2 Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Keeper:", keeper);

        vm.startBroadcast(deployerKey);

        // Step 1: Deploy vault with a placeholder adapter (will set real one after)
        // We need the vault address to create the adapter, and the adapter address for the vault
        // Solution: deploy adapter with vault=deployer temporarily, then redeploy

        // Deploy Aave adapter first (vault address unknown yet, use deployer as temp)
        // We'll use a two-step: deploy vault with address(0) adapter, then set it
        
        // Actually, deploy vault with a dummy adapter address, then deploy adapter, then set
        // The vault constructor requires non-zero adapter, so deploy adapter first pointing to a temp vault

        // Cleaner approach: deploy vault, deploy adapter pointing to vault, then set adapter on vault
        // But vault constructor needs adapter... 
        // Solution: deploy vault with deployer as adapter (it won't be called in constructor)
        // Then deploy real adapter, then call queueSetLendingAdapter + wait + execute

        // For initial deployment, we use a simple approach:
        // 1. Deploy vault with adapter = deployer (placeholder)
        // 2. Deploy AaveV3Adapter with vault address
        // 3. Immediately set the adapter (no timelock on first set since it's initial config)
        
        // Note: In production, the first adapter set should be timelocked too.
        // For deployment, admin sets it directly in the same tx block.

        TrancheFiVault vault = new TrancheFiVault(
            usdc,
            usdat,
            sUsdat,
            strcOracle,
            deployer,    // temporary adapter (will be replaced)
            curvePool,
            deployer,    // admin
            keeper
        );

        console.log("Vault deployed:", address(vault));
        console.log("  sdcSENIOR:", address(vault.sdcSenior()));
        console.log("  sdcJUNIOR:", address(vault.sdcJunior()));

        // Step 2: Deploy Aave adapter pointing to real vault
        AaveV3Adapter adapter = new AaveV3Adapter(
            aavePool,
            aaveDataProvider,
            sUsdat,
            usdc,
            address(vault)
        );

        console.log("AaveV3Adapter deployed:", address(adapter));

        // Step 3: Set real adapter on vault
        // Note: For production, this should go through timelock.
        // For initial deployment, we queue and would need to wait 7 days.
        // The vault starts paused until adapter is properly set.
        uint256 timelockId = vault.queueSetLendingAdapter(address(adapter));
        console.log("Adapter timelock queued, ID:", timelockId);
        console.log("  Execute after 7 days with executeSetLendingAdapter()");

        // Step 4: Set initial TVL cap (Phase 1: $1M)
        vault.setTVLCap(1_000_000e6);
        console.log("TVL cap set: $1M");

        // Step 5: Pause vault until adapter timelock executes
        vault.pause();
        console.log("Vault paused until adapter is set");

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Next steps:");
        console.log("  1. Wait 7 days for adapter timelock");
        console.log("  2. Call executeSetLendingAdapter(", timelockId, ", adapter_address)");
        console.log("  3. Call unpause()");
        console.log("  4. Fund keeper wallet with ETH for gas");
        console.log("  5. Start keeper bot");
        console.log("  6. Bootstrap deposits: depositSenior + depositJunior");
    }
}
