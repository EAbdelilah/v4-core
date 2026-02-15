# Deployment Instructions for SpotMarginHook

Deploying a Uniswap v4 hook requires careful address management because the hook's address must encode the permissions (flags) that it uses.

## 1. Required Permissions
The `SpotMarginHook` uses the following flags:
- `BEFORE_SWAP_FLAG` (bit 7)
- `AFTER_SWAP_FLAG` (bit 6)
- `BEFORE_SWAP_RETURNS_DELTA_FLAG` (bit 3)
- `AFTER_SWAP_RETURNS_DELTA_FLAG` (bit 2)

These flags must be represented in the first byte of the hook's address.

## 2. Address Mining
You must use `CREATE2` to deploy the hook at an address that matches these flags.
In a production environment, you would use a tool like `v4-periphery/contracts/libraries/Hooks.sol` or a dedicated mining script to find a `salt` such that:
`uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(bytecode)))))`
has the correct flags set.

For `SpotMarginHook`, the flags are:
- `BEFORE_SWAP`: `0x80`
- `AFTER_SWAP`: `0x40`
- `BEFORE_SWAP_RETURNS_DELTA`: `0x08`
- `AFTER_SWAP_RETURNS_DELTA`: `0x04`
Combined: `0xCC`

The address must start with `0xCC...` (in the first byte).

## 3. Deployment Steps
1.  **Prepare the Bytecode:** Ensure your `SpotMarginHook` is compiled.
2.  **Mine the Salt:** Use a script to find a salt that results in an address where the top bits match the required flags.
3.  **Deploy via HookFactory:** Use a `HookFactory` or a custom deployer that utilizes `CREATE2` with the mined salt.
4.  **Initialize Pool:** When creating a pool on `PoolManager`, use the deployed hook address in the `PoolKey`.
5.  **Set Oracle:** Call `setOracle(address)` on the deployed hook to provide a reliable price source.
6.  **Provide Liquidity:** Lenders should call `deposit(currency, amount)` to provide depth for margin traders.

## 4. Production Security Considerations
- **Oracle:** The `IOracle` used must be robust against manipulation. Using a Uniswap v4 TWAP oracle (via another hook or a separate contract) is recommended.
- **LTV/Thresholds:** Currently, LTV and Liquidation thresholds are `constant` in this POC. For a production-ready contract, consider making these state variables adjustable by the `Owner` or a DAO.
- **Insurance Fund:** Monitor the `insuranceFund` to ensure it can cover potential bad debt during extreme volatility.
- **Contract Ownership:** Transfer ownership to a Multi-sig or a Governance contract.
