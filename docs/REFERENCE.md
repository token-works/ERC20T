# ERC20T reference

[Repository overview](../README.md) · [Contracts](../src/ERC20T) · [Tests](../test/ERC20T) · [Deployment scripts](../script/ERC20T)

Commands below run from the repository root. Chain-specific script addresses and wallet defaults document the original deployments; review them before using those scripts for another deployment.

A small, MIT-licensed adaptation of `FWAToken` and `FWATokenHook`: fixed-supply ERC20s sharing one Uniswap v4 tax hook. Each token has its own owner, total tax rate, regular and launch-decay ETH fee recipients, distributors and liquidity policy. The shared distributor list combines an optional external registry with supplemental approvals maintained by the hook owner. The hook owner also maintains approved external base tokens and the protocol fee destination.

**Scope of the transfer restriction:** this preserves FWA's transfer-guard architecture with an exception for direct, untaxed wallet-to-wallet sends. Unapproved contract transfers and direct deposits into other pools remain restricted. It does **not** guarantee that side markets are impossible. Uniswap v4 can mint transferable ERC6909 claims and net balances between pools without making an ERC20 transfer. A claim-backed side pool therefore bypasses an ERC20 transfer guard. Strict isolation would require a dedicated settlement router and restrictions on every swap and liquidity entry point, changing FWA's router compatibility. See [Uniswap's ERC6909 documentation](https://developers.uniswap.org/docs/protocols/v4/concepts/erc-6909) and the executable regression in [`test/ERC20T/ERC20T.t.sol`](../test/ERC20T/ERC20T.t.sol).

Approved distributors and the token owner are also trusted transfer exceptions. They can distribute tokens to arbitrary wallets or contracts, and can implement alternative trading or wrapping paths. Approve contracts with that power in mind.

## Contracts

| File | Responsibility |
| --- | --- |
| [ERC20T.sol](../src/ERC20T/ERC20T.sol) | Shared implementation for token clones: metadata, fixed supply, owner settings, launch and transfer restrictions |
| [ERC20THook.sol](../src/ERC20T/ERC20THook.sol) | Shared distributor/base registries, canonical pool validation, tax conversion and ETH fee splitting |
| [ERC20TFactory.sol](../src/ERC20T/ERC20TFactory.sol) | Deploys the shared implementation once; permissionless clone creation and pool launch in one transaction |
| [ERC20TGlobalDistributorRegistry.sol](../src/ERC20T/ERC20TGlobalDistributorRegistry.sol) | Independently owned distributor registry for chains without an existing compatible list; supports constructor seeding and owner batch updates |
| [ERC20TInterfaces.sol](../src/ERC20T/ERC20TInterfaces.sol) | Minimal cross-contract interfaces and shared pool constants |

Each token is a minimal proxy with a fixed implementation address. There is no upgrade administrator, extra minting function, protocol buy gate or buyback module. The hook, PoolManager, PositionManager, Permit2 and quote currency are immutable for each token. Any token creator can use an existing compatible hook without registration by its owner. The factory keeps no ownership, supply allocation or fees.

The factory constructor deploys and locks its implementation. Token creation uses Solady `LibClone` with five packed immutable addresses appended to the standard 45-byte delegate runtime, for **145 bytes of deployed code per token**. Balances, allowances, metadata, ownership, settings and transient transfer permissions belong to each clone. `initialize(config)` validates the immutable arguments, enables the shared distributor list, and mints supply exactly once. The factory creates and initializes each clone atomically; the implementation itself cannot be initialized. Renouncing ownership does not allow reinitialization. Calls delegate to shared code, adding runtime gas overhead in exchange for substantially cheaper token deployments.

### Gas comparison

Historical measurements from the clone conversion, before the 0.3% floor and protocol payout changes, against the previous full-token deployment using the same harness and compiler settings:

| Operation | Full token | Clone | Change |
| --- | ---: | ---: | ---: |
| Shared factory deployment (clone version includes its implementation) | 4,218,463 | 4,167,748 | −50,715 |
| Create and launch another token | 3,040,323 | 797,438 | **−73.8%** |
| Buy, cold implementation | 227,617 | 233,451 | +5,834 |
| Sell, cold implementation | 139,599 | 144,217 | +4,618 |

These are pre-refund execution gas measurements, excluding transaction intrinsic/calldata gas. The native-paired fixture uses one million tokens, 20% creator allocation, a starting price of 0.00001 ETH/token and 1% tax. Swap measurements follow an initial 0.1 ETH buy; the measured buy spends another 0.1 ETH, and the measured sell spends half the initial buyer's tokens. External accounts and their storage are reset to cold before each measurement. Warming only the shared implementation reduces each clone swap by 2,500 gas. Results use Solidity 0.8.26, Cancun, optimizer runs 1 and via IR; other routes, settings and pool states will differ. Run `ERC20TGasTest` in [`test/ERC20T/ERC20TGas.t.sol`](../test/ERC20T/ERC20TGas.t.sol) to measure the current implementation.

The current implementation, including the separate decay recipient, measures **854,268** gas for create-and-launch, **4,580,687** for factory deployment, **260,454** for a cold buy, and **170,471** for a cold sell using the same native-ETH fixture. Implementation-warm swaps use 257,954 and 167,971 gas respectively. The fixture disables the launch schedule, sends no decay share, and uses ETH directly, so it does not measure active tax decay, a third recipient payout, or external-base conversion costs.

## Token settings

All amounts use 18-decimal token base units. A single current total tax rate applies to buys and sells. The fixed/resting rate is **0.3% to 5%**; an optional launch decline always starts at **99%** and decreases to that resting rate. Rates below 30 basis points, including zero, are rejected. A fixed **0.15% protocol share is included within that total**, not charged on top. The resting rate minus 0.15% belongs to `feeRecipient`; the excess above the resting rate belongs to `feeDecayRecipient`. The token owner controls both token destinations; the hook owner controls the protocol destination. Neither owner can change the 15-basis-point protocol rate or opt a token out of it.

| Current total tax | Resting rate | Decay recipient share | Regular recipient share | Protocol share |
| --- | --- | --- | --- | --- |
| 99% at launch | 5% | 94% | 4.85% | 0.15% |
| 98% | 5% | 93% | 4.85% | 0.15% |
| 5% | 5% | 0% | 4.85% | 0.15% |
| 1% | 1% | 0% | 0.85% | 0.15% |
| 0.3% | 0.3% | 0% | 0.15% | 0.15% |

These percentages apply to swap output before tax. The hook converts the combined tax to ETH once, then splits the net ETH proceeds proportionally. With current rate `C` and resting rate `R` in basis points, the protocol receives `floor(totalEth * 15 / C)`, the decay recipient receives `floor(totalEth * (C - R) / C)`, and the regular recipient receives the remainder. This shares conversion price impact and external-pool fees across all recipients. Payout rounding dust goes to the regular recipient. Once the current rate reaches the resting rate, no ETH goes to the decay recipient.

Set `config.feeDecayRecipient` to the desired decay address. A zero value copies the initial `config.feeRecipient`, allowing both shares to use the same address. The two settings are independent afterward: changing the regular recipient does not change the decay recipient. The owner can update either recipient before or after launch, including during decay. Recipient setters reject zero, the token itself, the shared hook and PoolManager; factory creation also rejects the factory as a destination.

Each swap snapshots the current/resting rates and all three recipients before converting fees or sending ETH. A recipient callback that changes configuration affects later swaps. Shared destination addresses receive one combined payment each. `HookFee` reports the regular recipient's net ETH and the total token tax collected on a buy; `ProtocolFee` reports the protocol's ETH; `FeeDecay` reports a nonzero decay ETH share. These amounts sum to the complete converted fee even when destinations coincide. `FeeDecayRecipientSet` records initialization and owner changes.

An optional launch schedule always starts at **99% (9,900 basis points)** and drops the total tax by **1 percentage point (100 basis points) every configured interval**, stopping exactly at the resting rate. This is subtraction of one percentage point, not a 1% relative reduction. Set `config.taxBps` to the resting rate (30–500 bps), `config.launchTaxBps` to `9900`, and `config.taxDecayIntervalSeconds` to the interval (1–4,294,967,295 seconds). Other nonzero starting rates are rejected. Set both schedule fields to zero to keep a fixed tax. At 99%, a swap receives 1% of its gross output after the token tax.

```solidity
config.taxBps = 30;                    // Rest at 0.3%.
config.launchTaxBps = 9900;            // Always start at 99% when decay is enabled.
config.taxDecayIntervalSeconds = 60;   // Drop one percentage point every 60 seconds.
config.feeDecayRecipient = decayTreasury; // ETH from tax above the resting 0.3% rate.
```

This example gives 99% at launch, 98% after one minute, 97% after two minutes, and continues down to 1% after 98 minutes and 0.3% after 99 minutes. The last drop clamps to the resting rate. A 5% resting rate is reached after 94 intervals. `launchedAt()` records the successful pool launch time; deploying an unlaunched token earlier does not consume the schedule. A reverted launch also reverts its clock. The first drop occurs at `launchedAt + interval`, using block timestamps. The factory still launches in one transaction, and no keeper or periodic transactions are needed.

`taxBps()` returns the current effective rate; before launch it returns the configured starting rate. `restingTaxBps()` returns the fixed/resting rate, and `taxDecayActive()` reports whether a launched token is still declining. The hook reads the current rate once per swap and uses it for the output tax and all fee shares. Each X/Y token has its own launch clock and decay recipient. Direct wallet transfers remain untaxed. Frontends should query `taxBps()` for quotes: elapsed time changes the result without emitting an event at each step. `TaxBpsSet` reports configured fixed/resting-rate changes, `LaunchTaxConfigured` reports the schedule parameters, and `TaxDecayStarted` records activation.

The starting rate is fixed at 99% and the interval cannot be changed after token creation. Before launch, the owner may adjust the resting rate within 0.3–5%. While the decline is active, all `setTaxBps` calls revert. Once it finishes, the owner can again set any rate within 0.3–5%, including increasing it; this does not restart the launch schedule. A fixed-tax token retains the existing owner controls throughout.

| Owner call | Behavior |
| --- | --- |
| `setDistributors(address[] accounts, bool allowed)` | Add/remove a batch of local distribution contracts |
| `setTaxBps(uint16 bps)` | Set the fixed/resting rate to 30–500 bps; blocked during an active launch decline |
| `setFeeRecipient(address recipient)` | Set the nonzero ETH destination for the resting-rate share after the protocol deduction |
| `setFeeDecayRecipient(address recipient)` | Set the nonzero ETH destination for the excess tax above the resting rate |
| `setUseGlobalDistributors(bool enabled)` | Accept/reject the hook's entire shared distributor list; initially **true** |
| `setExternalLiquidityEnabled(bool enabled)` | Allow/reject new deposits into the canonical pool; initially **false** |
| `setPairingEnabled(bool enabled)` | Allow new tokens to use this ETH-paired token as their quote; initially **false**. Disabling preserves existing pairs |

On Ethereum, the hook reads `isGlobalDistributor(account)` directly from the existing TokenWorks `GlobalDistributorHandler` at `0xDf99bd1218E7EB288CfFeCF9775385167Bb09B2D`. It uses the live list, without copying its entries. This registry is separate from the hook owner. Its address is immutable for each hook and exposed by `globalDistributorRegistry()`; zero disables this external source on other deployments.

The hook owner calls `hook.setDistributors(accounts, allowed)` to maintain supplemental shared approvals, exposed by `isHookDistributor(account)`. `hook.isDistributor(account)` accepts either source. External registry updates and hook-owner changes take effect immediately for tokens still opted in. A token's `setUseGlobalDistributors(false)` disables both shared sources, while its own local approvals remain effective. Removing a supplemental or token-local approval does not veto approval from another enabled source.

Enabling a distributor requires deployed contract code. External approvals for addresses without code, zero addresses, PoolManager and the hook are ignored. The token also rejects itself as a local distributor. A reverting or malformed external response supplies no approval; it does not erase local or supplemental approvals. The constructor rejects an invalid external registry or using the registry itself as hook owner. Removing a local entry remains possible if the distributor no longer has code. ERC20T's lists use public membership getters and `DistributorSet` events rather than an on-chain enumerable array; the external registry's own administration and event behavior are independent.

Direct wallet transfers are untaxed when `msg.sender == from`, `msg.sender == tx.origin`, and both `from.code.length` and `to.code.length` are zero. This lets a holder send directly to another ordinary wallet without approval from the token owner. A third party's `transferFrom` does not qualify. Contract wallets and EIP-7702 delegated accounts do not qualify as either endpoint of this exception. The origin check also excludes constructor calls, where the sending contract has no runtime code yet. A recipient having no code is only a check at transfer time: it can later deploy code or enable delegation. Wallet transfers and private sales therefore cannot be distinguished or taxed by this rule.

The token owner and approved distributor **endpoints** may transfer to/from anyone, including contract wallets and delegated accounts. Merely calling `transferFrom` as a distributor does not exempt two ordinary endpoints. ERC20 allowances still apply. Minting and holder-initiated `burn(amount)` are permitted. All PoolManager transfers consume hook-authorized transient allowances first, even when the other endpoint is the owner or a distributor. The wallet exception does not change canonical buys and sells or their taxes. User swap and LP deltas are netted across the transaction: positive balances authorize withdrawals and negative balances authorize deposits. Opposite intermediate-route deltas cancel without a token transfer. Fee transfers use separate directional allowances that the hook grants immediately before spending; these are consumed before the net user allowance. All allowances expire at transaction end. The net balance is shared across PoolManager callers, so this is not a per-router isolation guarantee.

Standard owner transfer/renunciation comes from Solady `Ownable`. Renouncing token ownership freezes its settings, but the protocol destination and supplemental shared approvals remain controlled by the hook owner, and the external list remains controlled by its own administrator. A fee recipient does not automatically become a distributor.

## Tax and liquidity behavior

- Exactly one canonical pool per token on the shared hook, against **native ETH, an opted-in ERC20T X, or an approved external base such as IMD/FWA**. LP fee is zero and tick spacing is 60. ERC20 currencies sort by address, so the new token can be currency0 or currency1. An ERC20T quote must already have its own ETH/X pool on the same hook and PoolManager. An external base must have a registered direct ETH/base conversion pool on the same PoolManager. Deeper quote chains and unapproved external bases are not supported.
- Exact-input buys take the configured percentage of token output and sell that fee back into the same pool. For ETH/X this produces ETH. For X/Y it produces X, which the hook then sells through the canonical ETH/X pool. The ETH is split between the protocol, regular and decay recipients. These conversions move pool prices; the ETH payout is not an exact percentage of the buyer's input value.
- Exact-input sells take the configured percentage of quote output. X fees from an X/Y sell are converted to ETH through ETH/X before splitting the payout. Owners and distributors pay the same swap tax as everyone else. In ETH → X → Y, each pool applies its configured total rate and included 0.15% protocol share independently. Only Y's tax policy applies inside the X/Y pool; the hook's own fee-conversion swaps bypass its callbacks and incur neither another X tax nor another protocol charge.
- For external bases, buys convert the token tax to the base, then to ETH; sells convert the base tax to ETH. The registered conversion pool retains its own LP fees and external hook behavior. The existing `15 / taxBps` protocol share is applied to the **net ETH received** after those costs. FWA's official conversion hook charges its own 1% sell tax; the configured IMD pool charges a 1% LP fee. These are costs of conversion, not additional ERC20T protocol charges. ETH/base/token routes must quote all hops and conversion price impact.
- Fees round down to whole base units; a sufficiently small trade can have a zero fee despite the 0.3% minimum rate. Transfer restrictions and pairing permissions still apply. Exact-output swaps are rejected in both directions.
- Fee conversion must consume all fee tokens or the entire trade reverts. Recipient contracts that reject ETH receive a forced ETH payment, following FWA's approach.
- When an X/Y trade incurs a nonzero X fee, it requires enough usable ETH/X liquidity to convert that complete fee. A newly launched, entirely X-sided parent position cannot sell X for ETH until trading or external liquidity provides ETH-side liquidity. An ETH → X → Y route supplies ETH to the parent in its first hop, but taxed standalone X/Y trades still depend on that parent pool. An incomplete conversion reverts the entire trade and fee payments; fees are not deferred or paid in X as a fallback. Separately, as in FWA, the hook pays fees before the outer caller settles, so PoolManager must already hold enough physical ETH for the payout. Tests fund the singleton to model an existing native-ETH deployment.
- `launch()` initializes the pool once and seeds a token-only position whose NFT goes to `0x000000000000000000000000000000000000dEaD`. **This initial liquidity is permanently locked.** Choose the reserve and starting price before launching.
- External LPs can add positions only while the primary token's flag is enabled (Y for an X/Y pool). X's own external-liquidity setting applies to ETH/X. Existing positions can always be removed, even after additions or new pair launches are disabled. Liquidity changes are untaxed.
- Supply is minted once: `lpSupply` to the token for launch, and `supply - lpSupply` to the initial token owner. The creator allocation must be **0–20%** of the initial supply; at least 80% is reserved for launch. This is enforced during token initialization. Unused launch ETH returns to the owner. Token rounding dust remains locked in the token contract, so it cannot push the creator above the allocation cap. Launch approvals are revoked afterward.
- Unlike Solady's default implicit infinite Permit2 approval, ERC20T uses explicit, revocable approvals. Users of a Permit2 router must approve Permit2 and then authorize the router through Permit2 as usual.

## Deploy and launch

Use an EVM supporting Cancun transient storage. This repository uses Solidity 0.8.26-compatible dependencies, optimization and `via_ir = true`. Use a matching PoolManager, PositionManager and Permit2 deployment on the chosen chain; token initialization verifies those relationships.

### Replace the original Ethereum hook

The original mainnet hook `0xed9A04Fa6693e754661A22502524DF9b1857e544` was incorrectly deployed with the external registry contract as owner. That registry cannot execute calls on other contracts, leaving hook administration inaccessible. Existing tokens retain their original hook; their owners can still maintain token-local distributors. A replacement hook is for new launches and does not migrate existing pools.

`script/ERC20T/DeployERC20TMainnet.s.sol:DeployERC20THookMainnet` deploys only the corrected hook in **one transaction**, owned by Ledger address `0x019817aD02a31B990433542097bE29D97613E8Cb` and reading the existing TokenWorks list. It preserves the initial IMD/FWA conversion routes and protocol fee recipient. It checks and reuses factory `0x801411c6aCeC4Fa80c75c5d3C0eAe13C84f8a173` and implementation `0x2df7DCf4D19a7924e00AE96629CC1d1261670eEe`; no token is created.

Simulate first, with `MAINNET_RPC_URL` configured in `.env`:

```sh
forge script \
  script/ERC20T/DeployERC20TMainnet.s.sol:DeployERC20THookMainnet \
  --rpc-url mainnet \
  --sender 0x019817aD02a31B990433542097bE29D97613E8Cb \
  --offline -vvv
```

To deploy and verify the replacement:

```sh
forge script \
  script/ERC20T/DeployERC20TMainnet.s.sol:DeployERC20THookMainnet \
  --rpc-url mainnet \
  --sender 0x019817aD02a31B990433542097bE29D97613E8Cb \
  --ledger --hd-paths "m/44'/60'/4'/0/0" \
  --offline --slow --broadcast --verify -vvv
```

Use the returned hook address in new token configurations. Reading the external list needs no seeding transaction. Additional shared approvals can be batched through the new hook's `setDistributors` by its Ledger owner. Supplemental approvals do not modify TokenWorks' registry.

The existing factory/implementation, live registry permissions, token opt-out, pool launch, buy and sell can be checked together on a local mainnet fork:

```sh
forge test --offline \
  --fork-url mainnet --fork-block-number 26220519 \
  --match-contract ERC20TRegistryMainnetTest -vv
```

### Mainnet deployment with Ledger

The Forge script `script/ERC20T/DeployERC20TMainnet.s.sol:DeployERC20TMainnet` deploys the shared hook and factory in one run, with IMD and FWA enabled atomically in the hook constructor. The default configuration in [`foundry.toml`](../foundry.toml) pins the compiler settings (Solidity 0.8.26, Cancun, via IR, optimizer runs 1, no CBOR/compiler metadata hash). No custom profile is required. The Solidity script rejects other chains and uses these fixed addresses:

| Setting | Address |
| --- | --- |
| PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Hook owner | `0x019817aD02a31B990433542097bE29D97613E8Cb` |
| External global distributor registry | `0xDf99bd1218E7EB288CfFeCF9775385167Bb09B2D` |
| Protocol fee recipient (FWABuyAndBurn) | `0x2ABD4B16a9663F4913F35A87A2C3078dF165bF12` |

The initial bases and conversion routes are listed below. Before broadcasting, the script checks FWA's PoolManager distributor permission and external-buy toggle; the constructor validates that both conversion pools are initialized on the selected PoolManager. The final hook owner is set immediately, with no temporary deployer ownership or separate base-registration transactions.

Keep `MAINNET_RPC_URL` and `ETHERSCAN_API_KEY` in the repository `.env`; Foundry reads them automatically. No `source .env` or contract-address exports are needed. Simulate without connecting the Ledger:

```sh
forge script \
  script/ERC20T/DeployERC20TMainnet.s.sol:DeployERC20TMainnet \
  --rpc-url mainnet \
  --sender 0x019817aD02a31B990433542097bE29D97613E8Cb \
  -vvv
```

To deploy, connect the Ledger, open its Ethereum app, and run:

```sh
forge script \
  script/ERC20T/DeployERC20TMainnet.s.sol:DeployERC20TMainnet \
  --rpc-url mainnet \
  --sender 0x019817aD02a31B990433542097bE29D97613E8Cb \
  --ledger \
  --hd-paths "m/44'/60'/4'/0/0" \
  --slow \
  --broadcast \
  --verify \
  -vvv
```

Approve **two transactions** on the Ledger: the hook, then the factory (which deploys its implementation internally). The command waits for each transaction and requests Etherscan verification. It prints the hook, factory and implementation addresses. This creates the shared infrastructure; launching a token is a subsequent creator action. The factory has no owner; the hook is owned by the configured hook owner immediately.

If broadcasting is interrupted or verification fails, rerun the same deployment command with `--resume` and the same Ledger. Resume uses Foundry's saved transactions, skips confirmed transactions, and retries verification. It expects pending transaction nonces to remain valid; do not send unrelated transactions from this wallet before completing pending deployments. Keep `broadcast/DeployERC20TMainnet.s.sol/1/` and `cache/DeployERC20TMainnet.s.sol/1/` locally for recovery; Foundry's cache contains sensitive RPC configuration. Use `--resume` for recovery instead of starting a fresh deployment. The generic scripts below remain available for other chains and configurations.

### Robinhood deployment with Ledger

`script/ERC20T/DeployERC20TRobinhood.s.sol:DeployERC20TRobinhood` deploys a separate global distributor registry, the shared hook, and the factory with its locked implementation on **Robinhood mainnet, chain 4663**, without launching a token. The hook reads the new registry through `isGlobalDistributor(address)`, using the same interface as the existing Ethereum registry.

| Setting | Robinhood address |
| --- | --- |
| PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` |
| PositionManager | `0x58daec3116aae6d93017baaea7749052e8a04fa7` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| Default registry and hook owner | `0x019817aD02a31B990433542097bE29D97613E8Cb` |
| Protocol ETH recipient | `0x3b78975E598731aa04AF1388E4E3BE099a29dC71` |
| IMD | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` |

The script registers the existing native ETH/IMD conversion pool: fee `10000` (1%), tick spacing **100**, and no hook. Its pool ID is `0xd2fc01ee6f8400b6b4ea3b341a188568f2bd6c72b07b96741a82396fa6eb8f02`. This is the external conversion pool's configuration; newly launched ERC20T pools still use fee zero and tick spacing 60. The addresses come from [Uniswap's SDK deployment configuration](https://github.com/Uniswap/sdks/blob/main/sdks/sdk-core/src/addresses.ts) and [IMD's contract documentation](https://imd.fun/docs/#contracts), with the route confirmed by Robinhood PoolManager's `Initialize` event in [transaction 0xb450…9727](https://robin.etherscan.io/tx/0xb450f93901673d7fe88bf3a9ed6230601c930ac958fe374fa0b5a29497189727).

The Ethereum FWA and FWABuyAndBurn addresses are not reused. FWA is not an initial Robinhood base; the hook owner can register a confirmed compatible Robinhood token and ETH conversion pool later. The protocol share goes directly to the address above.

`HOOK_OWNER` optionally overrides the initial owner of both registry and hook; each has independent ownership after deployment. `ROBINHOOD_GLOBAL_DISTRIBUTORS` optionally supplies a comma-separated list that **replaces** the default seeds. An unset or empty value uses the ten addresses below, checked on 2026-10-18. The Ethereum registry address is not reused on Robinhood. The script rejects that address as owner, checks deployed distributor code and forbidden endpoints, and validates the chain, infrastructure relationships and initialized IMD conversion pool before recording deployments.

| Seeded router or executor | Robinhood address |
| --- | --- |
| 0x current taker Settler | `0x24A4d86c8A76B00EE9566eD9C9Ff4f0c3Faf0da7` |
| 0x current gasless Settler | `0x8627977302C8b880F3954F255029c745E94Fc9c4` |
| 0x previous taker Settler | `0x6aa80DbBed9ae5aB45FbF61f9644faDA3b29326E` |
| 0x previous gasless Settler | `0x03390030a8054ceDbf49920A91ec84d3210B2EAE` |
| Kyber KSAggregationRouterV3 | `0x6868D319c8c9A78F7d39DC3602C5c917315132D7` |
| Kyber MetaAggregationRouterV2 | `0x6131B5fae19EA4f9D964eAc0408E4408b66337b5` |
| Kyber AggregationExecutorProxy | `0x8F10B468b06c6FD214B65F87778827F7D113f996` |
| RelayRouterV3 | `0xb92fe925DC43a0ECdE6c8b1a2709c170Ec4fFf4f` |
| RelayRouterV3.2 | `0x0729E2a4716d9f7dD17858d5d504426D228697f7` |
| Routing coordinator observed in a Fomo trade | `0x0da5899dbB36Bd741885D4228f04cD9c6304FC56` |

The first nine addresses come from [0x's deployment registry](https://contracts.0x.org/), [Kyber's Robinhood deployment table](https://docs.kyberswap.com/kyberswap-solutions/kyberswap-aggregator/contracts), and [Relay's chain-specific configuration](https://api.relay.link/chains?includeChains=4663), with deployed code checked on Robinhood. 0x can use its current and previous deployments during transitions; future rotations require registry updates. Approval proxies, AllowanceHolder, account-abstraction EntryPoint and individual smart wallets are not seeded as token endpoints.

The final address is supported by the user-provided [Fomo transaction](https://robin.etherscan.io/tx/0xeed7631c034ddd1237def3648a182a23373e92ac652ec42d75fdf6d97b5e4953). Its observed token path is wallet → Relay V3 → `0x0da589…4FC56` → executor `0x0005Ea…6B5Ef` → PoolManager. The coordinator's explorer source and provider identity are unverified; this is evidence of its use by that Fomo trade, not proof of Fomo ownership or a source audit. Approving Relay and the coordinator covers the ordinary endpoint checks for that path; the executor needs no additional global approval. PoolManager transfers still require hook-authorized settlement.

The registry owner can subsequently call `registry.setDistributor(account, allowed)` or `registry.setDistributors(accounts, allowed)` to update the list. Hook supplemental approvals remain available separately. Token owners can opt out of both shared sources and retain their token-local approvals.

Simulate with the configured public Robinhood RPC:

```sh
forge script \
  script/ERC20T/DeployERC20TRobinhood.s.sol:DeployERC20TRobinhood \
  --rpc-url robinhood \
  --sender 0x019817aD02a31B990433542097bE29D97613E8Cb \
  --offline -vvv
```

Deploy and request verification with the Ledger:

```sh
forge script \
  script/ERC20T/DeployERC20TRobinhood.s.sol:DeployERC20TRobinhood \
  --rpc-url robinhood \
  --sender 0x019817aD02a31B990433542097bE29D97613E8Cb \
  --ledger --hd-paths "m/44'/60'/4'/0/0" \
  --offline --slow --broadcast --verify --verifier etherscan \
  --verifier-url 'https://api.etherscan.io/v2/api?chainid=4663' -vvv
```

This is **three transactions**: (1) deploy the registry with its initial approvals, (2) deploy the hook pointing to that registry, and (3) deploy the factory, which creates its implementation internally. The registry and hook have their final owner from construction, even when the broadcaster differs; there is no separate seeding or ownership-handoff transaction. Verification requests are offchain. A Forge script's multiple transactions are not atomic; after an interruption, inspect receipts and resume the original command with `--resume` instead of starting another deployment.

Foundry reads `ETHERSCAN_API_KEY` from `.env`. The existing Robinhood RPC/verifier entries in `foundry.toml` are used. Foundry 1.5.1 needs `--offline` to avoid unsupported-chain trace lookups and the explicit verifier URL for RobinScan verification. The compiler must already be installed; `--offline` does not disable RPC calls or verification submissions.

### Token launch flows

The factory supports both launch flows:

| Flow | Transaction 1 | Transaction 2 |
| --- | --- | --- |
| Deploy and enable trading immediately | `factory.createAndLaunchAtPrice(config, creatorAllocationBps, startingPriceQuote)` | None |
| Deploy first, enable trading later | `factory.create(config)` | The token owner calls `token.launch(sqrtPriceX96, tickLower, tickUpper)` |

In the two-transaction flow, the intended owner receives ownership and the creator allocation immediately. The canonical pool remains uninitialized until the owner launches it; the owner can choose the starting price at that later time. There is no additional ownership-acceptance or launch-approval transaction. Both flows support the optional tax decline, whose clock starts only when the pool successfully launches. Here, enabling trading means opening the canonical pool; permitted wallet transfers are available before launch too. For X/Y launches, X must still permit new pairs when the second transaction executes.

### Frontend inputs: starting price and creator allocation

The creator chooses native ETH, an eligible ERC20T quote, or an approved external base, enters total supply, a starting price in **quote currency per whole new token**, and the percentage to keep (0–20%). For a native ETH launch, convert the supply to 18-decimal base units, the ETH price to wei, and the kept percentage to basis points (10% = 1,000). For ERC20 quotes, use that base's decimals when converting its price to base units; IMD and FWA both use 18 decimals. Call the factory's read-only preview:

```solidity
ERC20TFactory.LaunchPreview memory preview = factory.previewLaunch(
    1_000_000 ether, // total supply
    1_000,         // creator keeps 10%; 90% goes to launch
    0.0001 ether   // desired starting price: 0.0001 ETH per token
);
```

The returned `creatorSupply`, `lpSupply`, `sqrtPriceX96`, `tickLower`, `tickUpper` and `effectivePriceWei` are ready for the launch form. Show the effective ETH/token price before confirmation. Prices round to tick spacing 60, with the effective price at least the requested price; `effectivePriceWei` itself is rounded down to whole wei for display. The preview accepts prices of at least one wei per whole token and rejects unsupported price/supply combinations.

Call `createAndLaunchAtPrice(config, creatorAllocationBps, startingPriceQuote)` to compute the allocation, token address ordering and launch range atomically. This replaces `config.lpSupply` with the allocation derived from the basis points. The preview is an `eth_call`, so the launch still takes **one transaction**. The lower-level `createAndLaunch(config, sqrtPriceX96, tickLower, tickUpper)` also remains available with an explicit `config.lpSupply`. Initializing exactly at the appropriate boundary (lower for token0, upper for token1) leaves the position entirely in the new token and avoids an inactive gap before the first buy. No ETH liquidity deposit is needed; the creator pays transaction gas. The initial price is a spot price, not a guarantee of execution price for a purchase of arbitrary size.

The CLI uses `STARTING_PRICE_WEI` for native ETH or `STARTING_PRICE_QUOTE` for an ERC20 quote, plus `CREATOR_ALLOCATION_BPS` (default 0). Set `QUOTE_TOKEN` to X, IMD, FWA, or another approved base's address, or omit it for ETH. Set the usual token metadata, infrastructure and `ERC20T_FACTORY` variables; `LP_SUPPLY` and raw ticks are not needed for this helper:

```sh
forge script script/ERC20T/DeployERC20T.s.sol:CreateAndLaunchERC20TAtPrice \
  --rpc-url "$RPC_URL" --account "$DEPLOYER_ACCOUNT"
```

### Pairing Y with X and routing through both pools

X's owner first opts into new pairs:

```solidity
x.setPairingEnabled(true);
```

Anyone can then choose X in Y's configuration and launch Y in one transaction:

```solidity
config.quoteToken = address(x);
ERC20T y = factory.createAndLaunchAtPrice(
    config,
    1_000,       // keep 10% of Y; seed 90%
    0.01 ether   // starting price: 0.01 X per whole Y (both tokens use 18 decimals)
);
```

No X deposit or approval is needed for this single-sided launch. X must already have an ETH/X pool on the same hook, and its pairing toggle must still be enabled when the transaction executes. This is an open opt-in for new child tokens, not an approval list for individual Y tokens. Turning it off later prevents new pairs but does not stop existing X/Y swaps or withdrawals. Tokens already quoted in X cannot themselves enable another level of pairing.

Use `previewQuotedLaunch(supply, creatorAllocationBps, price, tokenIsCurrency0)` to show either possible address ordering. The returned `effectivePriceWei` field contains **X base units per whole Y** for a quoted pool. Address order can change when another factory launch is mined first, so the price-based creation method determines it after deploying Y in the same transaction. Preview both orientations when showing the small tick-rounding difference; the actual launch range can be read from the token's `Launched` event. Both previews round the price upward to an available tick. For Y as currency0, the launch starts at the lower boundary; for Y as currency1 it starts at the upper boundary.

An exact-input v4 route can execute ETH → X → Y in one unlock. The first swap's **post-tax** X output is the second swap's input, and their user settlement allowances cancel. Deliver final Y directly from PoolManager to the buyer; neither the buyer nor router needs distributor approval for that flow. A router that takes Y into custody and then forwards it to the buyer would need a transfer exception for that separate transfer. The hook nets Y's X fee credit against its internal ETH/X conversion without physically withdrawing or redepositing X, then splits the resulting ETH among Y's regular and decay recipients and the protocol recipient. These recipients do not need distributor approval. Reverse Y → X → ETH routing works with the same accounting. Routes must include both hook-bearing canonical pools and account for both taxes and the fee conversions' price impact when quoting minimum output. The internal X-to-ETH fee swap changes the parent pool price before a later route hop uses it.

### IMD, FWA, and additional external bases

The mainnet script enables these external bases, each with a direct native ETH conversion pool on the same PoolManager:

| Base | Token address | ETH conversion pool |
| --- | --- | --- |
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` | Hook `0xc6C965Bd164c483e87d0B550671798e9A3602840`, fee `10000` (1%), tick spacing `60` |
| FWA | `0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845` | Hook `0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444`, fee `0`, tick spacing `60`; the hook separately charges 1% |

Set `config.quoteToken` to the desired base address and call the same factory launch methods. For example, `startingPriceQuote = 0.01 ether` means **0.01 IMD per whole new token** when IMD is selected. The launch seeds only the new token: no IMD/FWA deposit or approval is required. Both immediate and deferred launches work; in a deferred launch, the base must still be enabled when `launch()` executes. Tokens quoted in an external base cannot enable further ERC20T child pairings.

The hook owner can register another compatible base and its complete `PoolKey`:

```solidity
hook.registerExternalBase(baseToken, ethConversionPool);
hook.setExternalBaseEnabled(baseToken, false); // prevent new launches
hook.setExternalBaseEnabled(baseToken, true);  // allow them again
```

Registration enables the base immediately. It requires an initialized direct ETH/base pool on this PoolManager, with a valid key and a different hook (or no hook). A registered conversion key is permanent and cannot be overwritten. Disabling a base affects new launches only: existing swaps, allowed liquidity additions and withdrawals retain their conversion route. Read `externalBases(base)` for registration/enabled status and `externalBasePool(base)` for its route; enumerate registrations using `ExternalBaseRegistered` events. ERC20T tokens bound to this hook cannot be registered as external bases to bypass their own pairing policy.

New bases must support ordinary, exact-amount ERC20 settlement; transfer-tax/rebasing tokens and incompatible external hooks are not supported. Registration does not override a base token's transfer rules. FWA needs `isDistributor(PoolManager) == true` for ordinary router settlement, and its official ETH buy route needs `externalBuysEnabled == true`; both were verified on mainnet at block `26207139`. These permissions remain under FWA's own administrators. Approving ERC20THook alone is insufficient for wallet ↔ PoolManager FWA transfers. The new ERC20T retains its own transfer restrictions and tax policy.

External conversion pools must retain usable ETH liquidity and support the entire exact-input fee swap; otherwise the child trade reverts atomically. Their pool fees, hooks and owner controls continue to apply even though the registry key is fixed. Conversion uses the same unlocked PoolManager and nets base credits/debts without transferring the base through the ERC20T hook. There is no generic router/adapter fallback or WETH/V2/V3 conversion in this version.

The hook constructor takes `ExternalBaseConfig[] initialBases` as its fourth argument and `address registry` as its fifth. The generic `DeployERC20THook` script passes an empty base list; its owner can register bases afterward. The mainnet script supplies IMD and FWA and the existing TokenWorks registry. These constructor arguments change the hook's CREATE2 address; previous dry-run addresses are superseded. Already-created token clones cannot change their immutable hook or quote currency.

### One transaction per token: use the factory

The platform deploys the shared hook and `ERC20TFactory` once. Deploying the factory also deploys its implementation within that transaction; read the address from `factory.implementation()`. After that, a creator makes **one transaction** calling:

```solidity
ERC20T token = factory.createAndLaunchAtPrice(config, creatorAllocationBps, startingPriceQuote);
```

`config` is the same `ERC20T.Config` shown below. `config.owner` is the intended final owner. Within that call, the factory:

1. Creates and initializes a token clone with temporary factory ownership.
2. Initializes the pool and locks the launch liquidity.
3. Sends the creator's selected 0–20% supply allocation to `config.owner`; launch rounding dust stays locked.
4. Transfers token ownership to `config.owner`.
5. Refunds any unused ETH supplied by the caller back to that caller.

There is no separate approval or ownership-acceptance transaction. A failure reverts token creation, initialization, liquidity and handoff together. The caller and final owner may be different addresses. The factory is permissionless and has no administrator. Pre-existing ETH at the factory is excluded from launch refunds; it is not a deposit or custody contract.

Deploy the reusable factory once:

```sh
forge script script/ERC20T/DeployERC20T.s.sol:DeployERC20TFactory \
  --rpc-url "$RPC_URL" --account "$DEPLOYER_ACCOUNT"
```

To create a token, set the token environment variables listed below, plus `ERC20T_FACTORY`, `SQRT_PRICE_X96`, `TICK_LOWER` and `TICK_UPPER`. Optional `LAUNCH_ETH` is a wei amount and defaults to zero. Then run:

```sh
forge script script/ERC20T/DeployERC20T.s.sol:CreateAndLaunchERC20T \
  --rpc-url "$RPC_URL" --account "$DEPLOYER_ACCOUNT"
```

These commands simulate by default; add `--broadcast` to submit. Deploying the hook, deploying the factory and creating the first token takes three transactions total. Each subsequent token takes one. Additional local distributor approvals or changes from the default liquidity/shared-list/pairing flags are separate owner calls. X's owner enables pairing once before anyone can launch Y against X; each Y launch then remains one transaction.

Creating an unlaunched clone and launching it in a separate owner transaction remain available below, using the same factory.

### 1. Deploy the shared hook once

`script/ERC20T/DeployERC20T.s.sol:DeployERC20THook` reads:

| Environment variable | Value |
| --- | --- |
| `POOL_MANAGER` | Uniswap v4 PoolManager address |
| `HOOK_OWNER` | Supplemental shared-list and protocol destination administrator; defaults to the actual Forge broadcaster |
| `GLOBAL_DISTRIBUTOR_REGISTRY` | External `isGlobalDistributor(address)` source; defaults to TokenWorks `0xDf99bd1218E7EB288CfFeCF9775385167Bb09B2D` on chain 1 and zero elsewhere |
| `PROTOCOL_FEE_RECIPIENT` | Initial protocol payout address; defaults to recorded mainnet FWABuyAndBurn `0x2ABD4B16a9663F4913F35A87A2C3078dF165bF12`; override for another destination or chain |

The administrator and external registry are separate addresses. The initial supplemental list is empty, while the external list is read live. Set `HOOK_OWNER` to a controllable wallet or execution-capable multisig to use another administrator. The script rejects the known TokenWorks registry as owner, including when external reads are disabled.

The hook owner may update the protocol destination with `hook.setProtocolFeeRecipient(address)`. The zero address, hook itself and PoolManager are rejected. Sending ETH to FWABuyAndBurn funds it; its separate permissionless `buyAndBurn()` call executes purchases and burns.

The script mines a CREATE2 salt using the standard `0x4e59b44847b379578588920cA78FbF26c0B4956C` deployer. The hook requires `beforeInitialize`, `afterAddLiquidity`, `afterRemoveLiquidity`, `afterSwap` and `afterSwapReturnDelta` permissions. Deploying it to an arbitrary address will revert.

```sh
forge script script/ERC20T/DeployERC20T.s.sol:DeployERC20THook \
  --rpc-url "$RPC_URL" --account "$DEPLOYER_ACCOUNT"
```

This simulates the deployment. Add `--broadcast` when ready to submit it. Keep the returned hook address for every token that should share the registry.

### 2. Create an unlaunched token using the factory

Deploy the factory once using `DeployERC20TFactory` above, then reuse its address.

`script/ERC20T/DeployERC20T.s.sol:DeployERC20T` reads:

| Environment variable | Value |
| --- | --- |
| `ERC20T_FACTORY` | Previously deployed factory; creates and initializes the clone atomically |
| `ERC20T_HOOK` | Previously deployed shared hook |
| `QUOTE_TOKEN` | Defaults to zero for native ETH; otherwise an eligible, pairing-enabled ERC20T X or enabled external base |
| `TOKEN_OWNER` | Administrator and recipient of the non-LP supply |
| `TOKEN_NAME`, `TOKEN_SYMBOL` | Nonempty metadata |
| `TOKEN_SUPPLY`, `LP_SUPPLY` | Integer base-unit amounts; LP supply must reserve at least 80% and cannot exceed total supply |
| `TAX_BPS` | Fixed/resting rate, 30–500 (0.3–5%); defaults to 100 (1%) |
| `TAX_DECAY_INTERVAL_SECONDS` | Seconds between fixed 100-bps drops from 99%, 1–4,294,967,295 when enabled; defaults to zero (fixed tax). A positive interval automatically selects the 99% starting rate |
| `LAUNCH_TAX_BPS` | Legacy optional setting; omit or use zero to select the start automatically from the interval. Explicit `9900` is also accepted with a positive interval; all other values are rejected |
| `FEE_RECIPIENT` | Nonzero native ETH recipient for the resting-rate share after the protocol deduction, for all supported quote types |
| `FEE_DECAY_RECIPIENT` | Optional ETH recipient for the tax above the resting rate. Omit or set to zero to copy the initial `FEE_RECIPIENT`; owner may update it later |
| `POSITION_MANAGER`, `PERMIT2` | Infrastructure matching the hook's PoolManager |

```sh
forge script script/ERC20T/DeployERC20T.s.sol:DeployERC20T \
  --rpc-url "$RPC_URL" --account "$DEPLOYER_ACCOUNT"
```

From Solidity, create an initialized token without launching its pool:

```solidity
ERC20T token = factory.create(ERC20T.Config({
    name: "Example Token",
    symbol: "EXT",
    supply: 1_000_000 ether,
    lpSupply: 900_000 ether,
    owner: tokenOwner,
    hook: sharedHook,
    quoteToken: address(0), // or an eligible ERC20T X / approved external base
    positionManager: positionManager,
    permit2: permit2,
    taxBps: 200,
    feeRecipient: treasury,
    launchTaxBps: 0,                 // Set both fields to zero for a fixed tax.
    taxDecayIntervalSeconds: 0,
    feeDecayRecipient: address(0)    // Copy the initial regular recipient.
}));
```

`new ERC20T()` deploys a locked implementation, not a usable token. Use the factory to create tokens. Custom clone deployers must encode the five addresses in the same order as the factory and initialize within the creation transaction; leaving an uninitialized clone exposed allows anyone to initialize it.

### 3. Launch from the token owner

Call `token.launch(sqrtPriceX96, tickLower, tickUpper)`. The ticks must be multiples of 60. When the new token is currency1, start at or above the upper sqrt-price boundary; when it is currency0, start at or below the lower boundary. This is checked against the exact sqrt price, keeping the seed entirely in the new token. ERC20-quoted launches reject nonzero `msg.value` and spend zero quote tokens. `sqrtPriceX96` encodes the square root of currency1 base units per currency0 base unit, multiplied by 2^96. For native ETH pools this is token base units per wei. Starting away from the active boundary leaves an empty-liquidity gap; use the price helper to start exactly at the appropriate boundary.

The token-only launch normally needs no ETH: call with `value = 0`. In the manual launch, an optional ETH buffer is refunded using PositionManager's ordinary ETH transfer, so a contract owner that rejects ETH must use zero value. The factory accepts the PositionManager refund and forwards it with forced ETH delivery if the caller rejects ETH. The test fixture uses `sqrtPriceX96 = 2^96`, `tickLower = -887220`, `tickUpper = 0`, and tests both zero value and a 2-wei buffer. This is a test price, not an economic recommendation for a real launch. The standalone token-deployment script leaves launch as a separate owner action; the factory script takes an explicit price/range and launches immediately.

For example, batch configuration from the appropriate owner:

```solidity
address[] memory distributors = new address[](2);
distributors[0] = rewardsContract;
distributors[1] = claimContract;
token.setDistributors(distributors, true);
token.setTaxBps(300);
token.setFeeRecipient(treasury);
token.setExternalLiquidityEnabled(true);
token.setUseGlobalDistributors(false);
```

## Verify locally

```sh
forge test --offline -vv
```

Local tests use real PoolManager, PositionManager and Permit2 contracts; no RPC or deployed funds are required. Optional fork tests skip outside their target chain. Run the Ethereum IMD/FWA launch, buy/sell and multihop paths against a pinned block with:

```sh
forge test --fork-url mainnet --fork-block-number 26207139 \
  --match-path test/ERC20T/ERC20TExternalBaseMainnet.t.sol -vv
```

Run the Robinhood deployment and native ETH/IMD trading checks with:

```sh
forge test --offline --fork-url robinhood --fork-block-number 91914836 \
  --match-path test/ERC20T/ERC20TExternalBaseRobinhood.t.sol -vv
```

Fork tests execute locally and do not broadcast. Existing FWA/IMD contracts are not modified on-chain.

## Dependencies and license

This standalone repository includes the contracts, deployment scripts and tests under their `ERC20T` directories. Dependencies are pinned as Git submodules. Initialize them with `git submodule update --init --recursive`. The dependency revisions used here are:

- `foundry-rs/forge-std`: `0258fe875e1d8e207c1eb7175e542ea32356773c`
- `vectorized/solady`: `2afba69bf67b78dd4abeadcc696052b3a6f71499`
- `Uniswap/v4-core`: `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc`
- `Uniswap/v4-periphery`: `60cd93803ac2b7fa65fd6cd351fd5fd4cc8c9db5`

The repository's remappings resolve `solady/`, `@uniswap/v4-core/`, and `@uniswap/v4-periphery/` imports. ERC20T uses the root [MIT license](../LICENSE); dependencies retain their own licenses. The test suite includes integration coverage, but this package has not received an independent security audit.
