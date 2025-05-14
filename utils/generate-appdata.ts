import { MetadataApi } from "@cowprotocol/app-data";
import { generateAppDataFromDoc } from "@cowprotocol/cow-sdk";

// Define a type for the app data document returned by the API
type AppDataDocument = any; // Using 'any' for now since we don't know the exact structure

export const metadataApi = new MetadataApi();

/**
 * Generates appData for Mamo strategy orders
 * @param sellToken The address of the token being sold
 * @param feeRecipient The address that will receive the fee
 * @param feeAmount The amount of fee to be taken (as a string)
 * @param hookGasLimit The gas limit for the pre-hook
 * @param from The address from which the transfer is made
 * @returns The generated appData document
 */
export async function generateMamoAppData(
  sellToken: string,
  feeRecipient: string,
  feeAmount: string,
  hookGasLimit: number,
  from: string
): Promise<AppDataDocument> {
  // Create the transferFrom calldata for the pre-hook
  // IERC20.transferFrom selector is 0x23b872dd
  // We need to encode: transferFrom(from, feeRecipient, feeAmount)

  const hooks = {
    pre: [
      {
        // Create a placeholder for the callData that matches the format expected by the contract
        // Use FEE_RECIPIENT constant instead of the feeRecipient parameter
        callData: createTransferFromCalldata(from, feeRecipient, feeAmount),
        gasLimit: hookGasLimit.toString(),
        target: sellToken.toLowerCase(),
      },
    ],
    version: "0.1.0",
  };

  // Use the MetadataApi to generate the appData document in the format CoW Swap expects
  // Register the appData with CoW Swap's API
  const appDataDoc = await metadataApi.generateAppDataDoc({
    appCode: "Mamo",
    metadata: {
      hooks,
    },
  });

  // generate app data
  const appData = await generateAppDataFromDoc(appDataDoc);

  return appData.appDataKeccak256;
}

/**
 * Creates a transferFrom calldata string
 * @param from The address from which the transfer is made
 * @param recipient The recipient address
 * @param feeAmount The amount to transfer as fee
 * @returns The calldata as a hex string
 */
function createTransferFromCalldata(
  from: string,
  recipient: string,
  feeAmount: string
): string {
  // IERC20.transferFrom selector is 0x23b872dd
  // We need to encode: transferFrom(from, recipient, amount)

  // Pad addresses to 32 bytes (64 hex chars)
  const paddedFrom = padAddress(from);
  const paddedTo = padAddress(recipient);

  // Convert amount to hex and pad to 32 bytes
  const paddedAmount = padUint256(feeAmount);

  // Combine the parts
  const calldata = "0x23b872dd" + paddedFrom + paddedTo + paddedAmount;

  return calldata;
}

/**
 * Pads an address to 32 bytes (64 hex chars)
 * @param addr The address to pad
 * @returns The padded address
 */
function padAddress(addr: string): string {
  // Remove '0x' prefix if present
  const cleanAddress = addr.startsWith("0x") ? addr.slice(2) : addr;

  // Pad to 64 characters (32 bytes)
  return "0".repeat(64 - cleanAddress.length) + cleanAddress;
}

/**
 * Pads a uint256 to 32 bytes (64 hex chars)
 * @param value The value to pad
 * @returns The padded value
 */
function padUint256(value: string): string {
  // Convert to hex
  const hexValue = BigInt(value).toString(16);
  // Pad to 64 characters (32 bytes)
  return "0".repeat(64 - hexValue.length) + hexValue;
}

/**
 * Calculate fee amount based on sell amount and compound fee
 * @param sellAmount The amount being sold
 * @param compoundFeeBps The compound fee in basis points (e.g., 100 = 1%)
 * @returns The fee amount as a string
 */
export function calculateFeeAmount(
  sellAmount: string,
  compoundFeeBps: number
): string {
  return (
    (BigInt(sellAmount) * BigInt(compoundFeeBps)) /
    BigInt(10000)
  ).toString();
}

// Check if this file is being run directly
if (require.main === module) {
  // Command-line interface
  async function main() {
    const args = process.argv.slice(2);

    // Display help if requested or if no arguments provided
    if (args.includes("--help") || args.includes("-h") || args.length === 0) {
      console.log(`
Usage: ts-node utils/generate-appdata.ts [options]

Options:
  --sell-token, -s      The address of the token being sold (required)
  --fee-recipient, -r   The address that will receive the fee (required)
  --sell-amount, -a     The amount being sold (required)
  --compound-fee, -c    The compound fee in basis points (e.g., 100 = 1%) (required)
  --hook-gas-limit, -g  The gas limit for the pre-hook (default: 100000)
  --verbose, -v         Show detailed output with formatting and hash
  --help, -h            Show this help message

Example:
  ts-node utils/generate-appdata.ts \\
    --sell-token 0x1234567890123456789012345678901234567890 \\
    --fee-recipient 0xabcdef1234567890abcdef1234567890abcdef12 \\
    --sell-amount 1000000000000000000 \\
    --compound-fee 100
      `);
      process.exit(0);
    }

    // Parse arguments
    let sellToken = "";
    let feeRecipient = "";
    let sellAmount = "";
    let compoundFeeBps = 0;
    let hookGasLimit = 100000; // Default value
    let from = "";

    for (let i = 0; i < args.length; i++) {
      const arg = args[i];
      const nextArg = args[i + 1];

      if ((arg === "--sell-token" || arg === "-s") && nextArg) {
        sellToken = nextArg;
        i++;
      } else if ((arg === "--fee-recipient" || arg === "-r") && nextArg) {
        feeRecipient = nextArg;
        i++;
      } else if ((arg === "--sell-amount" || arg === "-a") && nextArg) {
        sellAmount = nextArg;
        i++;
      } else if ((arg === "--compound-fee" || arg === "-c") && nextArg) {
        compoundFeeBps = parseInt(nextArg, 10);
        i++;
      } else if ((arg === "--hook-gas-limit" || arg === "-g") && nextArg) {
        hookGasLimit = parseInt(nextArg, 10);
        i++;
      } else if ((arg === "--from" || arg === "-f") && nextArg) {
        from = nextArg;
        i++;
      }
    }

    // Validate required arguments
    const missingArgs = [];
    if (!sellToken) missingArgs.push("--sell-token");
    if (!feeRecipient) missingArgs.push("--fee-recipient");
    if (!sellAmount) missingArgs.push("--sell-amount");
    if (!compoundFeeBps) missingArgs.push("--compound-fee");
    if (!from) missingArgs.push("--from");

    if (missingArgs.length > 0) {
      console.error(
        `Error: Missing required arguments: ${missingArgs.join(", ")}`
      );
      console.error("Use --help for usage information");
      process.exit(1);
    }

    // Calculate fee amount
    const feeAmount = calculateFeeAmount(sellAmount, compoundFeeBps);

    try {
      // Generate the appData document
      const appDataDoc = await generateMamoAppData(
        sellToken,
        feeRecipient.toLowerCase(),
        feeAmount,
        hookGasLimit,
        from.toLowerCase()
      );

      // Output the result as JSON only (for easier parsing in tests)
      console.log(JSON.stringify(appDataDoc));
    } catch (error) {
      console.error("Error generating appData:", error);
      process.exit(1);
    }
  }

  // Run the main function
  main().catch((error) => {
    console.error("Unhandled error:", error);
    process.exit(1);
  });
}
