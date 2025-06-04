# Mamo AppData Generator

This utility generates appData for CowProtocol orders that will pass validation in the `isValidSignature` function of the `ERC20MoonwellMorphoStrategy.sol` contract.

## Installation

Make sure you have the required dependencies installed:

```bash
npm install
```

## Usage

### Command Line Interface

You can generate appData directly from the command line:

```bash
npm run generate-appdata -- --sell-token <SELL_TOKEN_ADDRESS> --fee-recipient <FEE_RECIPIENT_ADDRESS> --sell-amount <SELL_AMOUNT> --compound-fee <COMPOUND_FEE_BPS>
```

#### Options:

- `--sell-token, -s`: The address of the token being sold (required)
- `--fee-recipient, -r`: The address that will receive the fee (required)
- `--sell-amount, -a`: The amount being sold (required)
- `--compound-fee, -c`: The compound fee in basis points (e.g., 100 = 1%) (required)
- `--hook-gas-limit, -g`: The gas limit for the pre-hook (default: 100000)
- `--verbose, -v`: Show detailed output with formatting and hash
- `--help, -h`: Show help message

By default, the script outputs only the JSON document for easier parsing in automated tools. Use the `--verbose` flag to see more detailed output including the formatted JSON and the appData hash.

#### Example:

```bash
npm run generate-appdata -- \
  --sell-token 0x1234567890123456789012345678901234567890 \
  --fee-recipient 0xabcdef1234567890abcdef1234567890abcdef12 \
  --sell-amount 1000000000000000000 \
  --compound-fee 100
```

### Programmatic Usage

You can also use the utility programmatically in your TypeScript/JavaScript code:

```typescript
import { generateMamoAppData, calculateFeeAmount } from "./generate-appdata";

async function example() {
  const sellToken = "0x1234567890123456789012345678901234567890";
  const feeRecipient = "0xabcdef1234567890abcdef1234567890abcdef12";
  
  // Calculate fee amount (e.g., 1% of sell amount)
  const sellAmount = "1000000000000000000"; // 1 token with 18 decimals
  const compoundFeeBps = 100; // 1% in basis points
  const feeAmount = calculateFeeAmount(sellAmount, compoundFeeBps);
  
  const hookGasLimit = 100000;
  
  // Generate the appData
  const appDataDoc = await generateMamoAppData(
    sellToken,
    feeRecipient,
    feeAmount,
    hookGasLimit
  );
  
  console.log(JSON.stringify(appDataDoc, null, 2));
}
```

## How It Works

The utility generates appData that matches the format expected by the `isValidSignature` function in the `ERC20MoonwellMorphoStrategy.sol` contract:

1. It sets the appCode to "Mamo"
2. It creates a pre-hook with the correct transferFrom calldata format
3. It includes the gasLimit parameter and target token address

The generated appData will be properly validated by the contract, allowing orders to be executed successfully.