import { MetadataApi } from "@cowprotocol/app-data";
import { generateAppDataFromDoc } from "@cowprotocol/cow-sdk";

// Define a type for the app data document returned by the API
type AppDataDocument = any; // Using 'any' for now since we don't know the exact structure

export const metadataApi = new MetadataApi();

/**
 * Generates appData for Mamo strategy orders.
 *
 * Mamo orders carry NO hooks, so the document depends on nothing about the order. The compound fee
 * is settled on-chain by MamoMultiMarketStrategy.sweepRewardFees before any order can be signed,
 * so the balance an order is allowed to sell is already net of fees. The previous version pinned a
 * `transferFrom(strategy, feeRecipient, fee)` pre-hook, which could never execute — for
 * transferFrom the spender is the caller (HooksTrampoline), and the strategy only approves the CoW
 * vault relayer.
 *
 * @returns The appData hash the strategy pins
 */
export async function generateMamoAppData(): Promise<AppDataDocument> {
  // Use the MetadataApi to generate the appData document in the format CoW Swap expects
  const appDataDoc = await metadataApi.generateAppDataDoc({
    appCode: "Mamo",
    metadata: {},
  });

  const appData = await generateAppDataFromDoc(appDataDoc);

  return appData.appDataKeccak256;
}

// Check if this file is being run directly
if (require.main === module) {
  // Command-line interface. The order-specific flags are accepted and ignored: the Foundry test
  // helper still passes them, and the document no longer varies with the order.
  async function main() {
    const args = process.argv.slice(2);

    if (args.includes("--help") || args.includes("-h")) {
      console.log(`
Usage: ts-node test/utils/generate-appdata.ts

Prints the appData hash every Mamo reward order must carry. The document is constant — it has no
hooks and no order-dependent fields — so no arguments are required. Order-specific flags
(--sell-token, --fee-recipient, --sell-amount, --compound-fee, --hook-gas-limit, --from) are
accepted for call-site compatibility and ignored.
      `);
      process.exit(0);
    }

    try {
      const appData = await generateMamoAppData();
      console.log(appData);
    } catch (error) {
      console.error("Error generating appData:", error);
      process.exit(1);
    }
  }

  main().catch((error) => {
    console.error("Unhandled error:", error);
    process.exit(1);
  });
}
