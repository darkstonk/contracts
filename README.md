# Dark Stonk contracts

The escrow contracts behind [darkstonk.cash](https://darkstonk.cash): a dark pool for memecoins on Solana and Robinhood Chain. Orders rest with a sealed price, fill wallet to wallet, and never touch the coin's chart.

## Deployed

| Chain | Contract | Address |
| --- | --- | --- |
| Solana mainnet | `darkstonk_escrow` (Anchor) | [`245nAukK64UpLis3BrrjAK46imdA85ESCqBoARgp5T94`](https://solscan.io/account/245nAukK64UpLis3BrrjAK46imdA85ESCqBoARgp5T94) |
| Robinhood Chain (4663) | `DarkStonkEscrow` | [`0x5ffd957587F92a9014e3734fa85fC0260f0B9Bc4`](https://robinhoodchain.blockscout.com/address/0x5ffd957587F92a9014e3734fa85fC0260f0B9Bc4), source [verified on Sourcify](https://repo.sourcify.dev/4663/0x5ffd957587F92a9014e3734fa85fC0260f0B9Bc4) |

Both have been live since 5 November 2026.

## How it works

- **Sealing an order.** A seller locks coins in escrow, a buyer locks SOL or ETH. The order stores only a commitment: a hash of the price, the payout wallet and a random salt. The price itself isn't on chain.
- **Filling it.** The matching engine co-signs a fill and reveals the price to the contract. The contract checks it against the commitment, moves the coin wallet to wallet and pays the seller. The coin's own pool is never touched, so no swap shows on its chart.
- **Getting out.** The owner of an order can cancel it at any time, even while the pool is paused. After 7 days an order stops filling and the owner withdraws what's left.
- **Transfer-tax coins.** Coins that keep a cut of every transfer are supported: escrow books what actually arrived, and a buyer pays only for what reaches them. On Solana the vault's withheld tax is harvested to the mint before the vault closes.
- **Fees.** The fee is taken from the seller's proceeds, 0.5% today, capped at 1% in the contract.

## Who can do what

| Role | Can | Can't |
| --- | --- | --- |
| Admin | Pause new orders and fills, set the fee up to the 1% cap | Move funds held in escrow |
| Matcher | Co-sign fills, so the book stays sealed | Fill an order at a price its owner didn't seal |
| Order owner | Cancel or withdraw their own order, any time | |
| Solana upgrade authority | Replace the program's code | |

The Solana program is upgradeable; its current upgrade authority is shown on chain. The Robinhood Chain escrow can't be upgraded.

## Building and checking

### Solana

Anchor 1.2, built for SBPF v0 with `opt-level = "z"` (see `solana/Cargo.toml`):

```sh
cd solana
anchor build --arch v0
```

The deployed program, with its trailing zero padding trimmed, has the same SHA-256 as a build of this source:

```
34ff2f414eaaa9206d98c8b1d2369110c647ad54aaf7e650a14588fb58452fd6
```

To check it yourself:

```sh
solana program dump 245nAukK64UpLis3BrrjAK46imdA85ESCqBoARgp5T94 onchain.so --url mainnet-beta
python3 -c "import hashlib,sys; [print(hashlib.sha256(open(f,'rb').read().rstrip(b'\0')).hexdigest(), f) for f in sys.argv[1:]]" onchain.so target/deploy/darkstonk_escrow.so
```

This was built on macOS, not with a Docker-reproducible pipeline, so another toolchain can give a different binary.

### Robinhood Chain

Foundry. The tests run against a fork of Robinhood Chain mainnet with a real Pons coin:

```sh
cd evm
forge install foundry-rs/forge-std --no-git
forge test --fork-url https://robinhood.drpc.org
```

## Status

No third-party audit yet. The contracts have their own test suites (30 Foundry tests; the Solana program is tested end to end, including a coin with a 3% transfer tax, on mainnet). Keep sizes small until an audit is published.

## License

MIT
