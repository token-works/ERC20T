# Deployments

Ethereum and Robinhood mainnet contract addresses. This list includes the shared platform contracts and token implementations; individual token clones are created through the factory.

## Ethereum mainnet — chain ID 1

| Contract | Address |
| --- | --- |
| ERC20THook | [0x05e1934d8B52a8dED4F3F42AA9a7a12244192544](https://etherscan.io/address/0x05e1934d8B52a8dED4F3F42AA9a7a12244192544#code) |
| ERC20TFactory | [0x801411c6aCeC4Fa80c75c5d3C0eAe13C84f8a173](https://etherscan.io/address/0x801411c6aCeC4Fa80c75c5d3C0eAe13C84f8a173#code) |
| ERC20T implementation | [0x2df7DCf4D19a7924e00AE96629CC1d1261670eEe](https://etherscan.io/address/0x2df7DCf4D19a7924e00AE96629CC1d1261670eEe#code) |
| Global distributor registry (existing TokenWorks contract) | [0xDf99bd1218E7EB288CfFeCF9775385167Bb09B2D](https://etherscan.io/address/0xDf99bd1218E7EB288CfFeCF9775385167Bb09B2D#code) |

## Robinhood mainnet — chain ID 4663

| Contract | Address |
| --- | --- |
| ERC20THook | [0x6e582dcdbb21902080124fc677db1ed8c1596544](https://robin.etherscan.io/address/0x6e582dcdbb21902080124fc677db1ed8c1596544#code) |
| ERC20TFactory | [0x04c8ba34cb3fd5af9db06b8a25eaf1c8fb1ce738](https://robin.etherscan.io/address/0x04c8ba34cb3fd5af9db06b8a25eaf1c8fb1ce738#code) |
| ERC20T implementation | [0x6b8e414bbbad57a9ba1c3828156c56bbcfe2ac8e](https://robin.etherscan.io/address/0x6b8e414bbbad57a9ba1c3828156c56bbcfe2ac8e#code) |
| ERC20TGlobalDistributorRegistry | [0x00df51c981193c701658f3a54af4e256d752d17d](https://robin.etherscan.io/address/0x00df51c981193c701658f3a54af4e256d752d17d#code) |

Ethereum reuses the existing external distributor registry; Robinhood has a separately deployed ERC20T registry. Token implementations are initialization-locked: use the factory to create token clones rather than attempting to initialize these implementation addresses.
