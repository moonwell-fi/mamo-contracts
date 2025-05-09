import { generateMamoAppData, metadataApi } from "./generate-appdata";

async function main() {
  // Example parameters
  const sellToken = "0x1234567890123456789012345678901234567890"; // Example token address
  const feeRecipient = "0xabcdef1234567890abcdef1234567890abcdef12"; // Example fee recipient

  // Calculate fee amount (e.g., 1% of sell amount)
  const sellAmount = "1000000000000000000"; // 1 token with 18 decimals
  const compoundFee = 100; // 1% in basis points (out of 10000)
  const feeAmount = (
    (BigInt(sellAmount) * BigInt(compoundFee)) /
    BigInt(10000)
  ).toString();

  const hookGasLimit = 100000; // Example gas limit

  try {
    // Generate the appData
    const appDataDoc = await generateMamoAppData(
      sellToken,
      feeRecipient,
      feeAmount,
      hookGasLimit
    );

    console.log("Generated appData document:");
    console.log(JSON.stringify(appDataDoc, null, 2));

    // You can also get the appData hash that would be used in the order
    const appDataHash = await metadataApi.hashAppData(appDataDoc);
    console.log("\nAppData hash (to be used in the order):");
    console.log(appDataHash);

    // Verify that the appData matches what the contract expects
    console.log("\nVerify this appData matches the contract's expectations:");
    console.log("- appCode should be 'Mamo'");
    console.log("- hooks.pre[0].target should match the sellToken");
    console.log("- hooks.pre[0].gasLimit should match the hookGasLimit");
    console.log(
      "- hooks.pre[0].callData should be a valid transferFrom calldata"
    );
  } catch (error) {
    console.error("Error generating appData:", error);
  }
}

main().catch(console.error);
