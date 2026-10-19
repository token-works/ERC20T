# ERC20T

Fixed-supply ERC20 tokens with a shared Uniswap v4 tax hook, adapted from FWA. A permissionless factory creates inexpensive token clones and can launch each token's pool in the same transaction. Tokens have independent owners, fees and transfer settings; fees are paid in native ETH.

## Contracts

| Contract | Purpose |
| --- | --- |
| [ERC20T](src/ERC20T/ERC20T.sol) | Token implementation: fixed supply, launch, ownership, tax settings and transfer restrictions |
| [ERC20THook](src/ERC20T/ERC20THook.sol) | Shared pool validation, fee conversion, ETH payouts and distributor/base configuration |
| [ERC20TFactory](src/ERC20T/ERC20TFactory.sol) | Deploys the implementation once, creates clones and optionally launches their pools |
| [ERC20TGlobalDistributorRegistry](src/ERC20T/ERC20TGlobalDistributorRegistry.sol) | Optional independently owned shared distributor list |
| [ERC20TInterfaces](src/ERC20T/ERC20TInterfaces.sol) | Interfaces and pool constants |

Clones use a fixed implementation and immutable hook, quote currency and Uniswap infrastructure. There is no upgrade administrator or additional minting function. The factory has no administrator and charges no fee.

## Fees and launch

- A token's fixed/resting tax is **0.3–5%**, applied to the output of exact-input buys and sells. Exact-output swaps are rejected.
- An optional launch schedule starts at **99%**, drops by **one percentage point per configured interval**, and stops at the resting rate. The clock starts when the pool launches; no keeper is needed.
- The **0.15% protocol share is included in the total tax**. The resting rate minus 0.15% belongs to the regular recipient; any excess launch tax belongs to a separate decay recipient. For example, 99% current tax with 5% resting tax allocates 94% to decay, 4.85% to regular fees and 0.15% to the protocol.
- Buy fees are withheld in the new token and sold back into its pool. Quote-token fees are converted through their configured ETH pool. The hook divides the resulting ETH proportionally, so payouts reflect conversion fees, price impact and rounding; they are not an exact percentage of the buyer's input value.
- A creator keeps **0–20%** of initial supply. At least 80% seeds a token-only position, whose liquidity NFT is sent to the dead address and permanently locked. Launch requires no quote tokens. Use the factory's price preview before choosing the starting price.

Use `createAndLaunchAtPrice` for one-transaction token creation and launch, or `create` followed by the token owner's `launch` for two transactions. Platform hook/factory deployment is separate. See the [configuration and deployment reference](docs/REFERENCE.md#deploy-and-launch).

## Pairing and administration

Each token has one canonical pool against native ETH, an existing ETH-paired ERC20T whose owner enables pairing, or a registered external base. ERC20T quote chains are one level deep. Canonical pools use zero LP fee and tick spacing 60. External conversion pools retain their own fees and hook behavior.

The token owner can change regular/decay recipients, local distributors, acceptance of the shared distributor list, new external liquidity additions and permission for new tokens to pair against it. The resting tax can be changed within 0.3–5%, except during active decay. The starting rate and decay interval cannot be changed. External liquidity and pairing are disabled initially; shared distributor approvals are enabled. Existing LPs can still withdraw after additions are disabled, and existing pairs survive pairing being disabled.

The hook owner controls the protocol recipient, supplemental distributors and registration of external bases. The **protocol rate cannot change**. A registered base's conversion route cannot be replaced; disabling a base prevents new launches and preserves existing pools. The external distributor registry has its own owner and an immutable address in the hook. Approval from either shared source is sufficient, so removing one approval does not override the other. Token owners can opt out of both shared sources together.

## Transfer restrictions and limits

Direct transfers between ordinary wallets are untaxed when the sender calls directly and both endpoints have no code. Contract wallets, delegated accounts and third-party `transferFrom` calls do not qualify for that exception. Owners and approved distributor endpoints have broader transfer permissions. PoolManager transfers always require hook-authorized settlement allowances, including transfers involving an owner or distributor.

**These restrictions do not make side markets impossible.** Uniswap v4 ERC6909 claims and internal settlement can move value without calling the ERC20 transfer guard. Trusted distributors can also enable wrapping or other trading paths, and wallet transfers cannot distinguish gifts from private sales. The [test suite](test/ERC20T/ERC20T.t.sol) includes an executable claim-backed side-market example.

Fee conversions must fill completely or the entire swap reverts. Conversions need usable ETH liquidity, and immediate payouts require sufficient physical ETH already in PoolManager before the outer caller settles. External tokens and hooks must remain compatible. Quotes must account for every user swap, tax and internal fee-conversion swap.

## Build and test

Install Foundry and Solidity 0.8.26. Clone with dependencies, replacing the repository URL below:

```sh
git clone --recurse-submodules "YOUR_REPOSITORY_URL" ERC20T
cd ERC20T
forge build --offline
forge test --offline
```

For an existing checkout, run `git submodule update --init --recursive`. Offline builds require the pinned compiler and dependencies to be available locally; run `forge build` once with network access if Foundry needs to fetch the compiler. The default [Foundry configuration](foundry.toml) uses Solidity 0.8.26, Cancun, via IR, optimizer runs 1 and no CBOR/compiler metadata hash. No custom profile is required.

Local tests use actual Uniswap v4 and Permit2 contracts without an RPC. Optional fork tests require the relevant RPC endpoint and historical state:

```sh
forge test --offline --fork-url "$MAINNET_RPC_URL" --fork-block-number 26207139 \
  --match-path test/ERC20T/ERC20TExternalBaseMainnet.t.sol -vv

forge test --offline --fork-url https://rpc.mainnet.chain.robinhood.com \
  --fork-block-number 91914836 \
  --match-path test/ERC20T/ERC20TExternalBaseRobinhood.t.sol -vv
```

Fork tests run locally and do not broadcast. Deployment scripts are in [script/ERC20T](script/ERC20T); chain-specific scripts contain project-specific owner and protocol-recipient defaults. Use the generic scripts for custom deployments, or explicitly review those constants first. The [detailed reference](docs/REFERENCE.md) covers environment variables, launch prices, historical deployment context and integration behavior.

## License

ERC20T is [MIT licensed](LICENSE). Dependencies retain their respective licenses. This package has not received an independent security audit.
