# Internal security review

5 November 2026 · commit `2f14085460adaa52766cd09bf7f0c199668be506`

This is the Dark Stonk team's own line-by-line read of both contracts in this repository, every finding checked against the code. **It is not a third-party audit.** It is published so anyone can see what we know about the code and what is still open.

**Result:** no critical issue, and no path in the current code for anyone to take funds out of escrow (an upgrade of the Solana program could change that, see S-1). 2 high, 4 medium, 8 low and 6 informational findings; the high ones are about key custody, not code paths.

Status: **Open** means a fix is planned; **By design** means intended and documented; **Accepted** means the risk is understood and kept; **Not applicable** means the concern doesn't arise for this code.

## Solana program (`solana/programs/darkstonk_escrow/src/lib.rs`)

| ID | Finding | Severity | Status |
| --- | --- | --- | --- |
| S-1 | **The upgrade key and the admin are one wallet**<br>The program can be upgraded, and an upgrade can change what it does with escrow. Until the upgrade key moves to a multisig, trust in this one wallet is trust in the program. | High | Open |
| S-2 | **Every fill needs the one matcher key**<br>If the matcher key is lost or the engine is down, nothing fills until the admin sets a new one. It can't move funds or fill at a price the owner didn't seal, and cancel never needs it. | Medium | Accepted |
| S-3 | **set_config changes the admin in one step, with no empty-key check**<br>A mistyped admin can't be undone, and an empty matcher would stop every fill. Planned: a propose-and-accept admin change and checks against empty keys. | Medium | Open |
| S-4 | **init_config isn't tied to the deployer**<br>Whoever calls it first becomes admin. On mainnet it was called by the deployer at launch, so this only matters for a fresh deployment. Planned: tie it to the upgrade key. | Low | Open |
| S-5 | **Config changes emit no events**<br>A fee, matcher or fee-wallet change is visible only by reading the config account. Planned: a Config event. | Low | Open |
| S-6 | **The fee is read at fill time**<br>An order pays the fee in force when it fills, which is 0.5% today and can never exceed the 1% cap written into the program. | Low | By design |
| S-7 | **Cancelling a sell needs your coin account to exist**<br>The coins go back to your token account for that coin. If you closed it, open it again, then cancel. | Low | By design |
| S-8 | **Coins sent straight into a filled order's vault keep it open**<br>Only possible by sending coins to the vault by hand. The order can no longer fill, and its owner's cancel returns everything. | Low | Accepted |
| S-9 | **The commitment doesn't cover the coin**<br>The sealed hash covers price, payout and a 32-byte random salt. The site makes a fresh salt for every order, so no two orders share a commitment. | Info | Accepted |
| S-10 | **Coin extensions are checked when an order opens**<br>Token-2022 extensions are fixed when a coin is created and can't be added later. The program refuses transfer hooks, permanent delegates, pausable and frozen-by-default coins up front. | Info | Not applicable |

## Robinhood Chain escrow (`evm/src/DarkStonkEscrow.sol`)

The contract can't be upgraded, so open items here are fixed by a new deployment.

| ID | Finding | Severity | Status |
| --- | --- | --- | --- |
| E-1 | **Admin, matcher and fee wallet are single wallets**<br>No multisig and no timelock yet. The contract can't be upgraded and the admin can't move escrow, so the reach is the fee (capped at 1%), the fee wallet, the matcher and pausing. | High | Open |
| E-2 | **setConfig accepts an empty matcher**<br>With the matcher set to the zero address, a malformed approval would pass and anyone could fill. The matcher has never been zero; the contract can't be upgraded, so the next deployment rejects it and until then setting it to zero is ruled out. | Medium | Open |
| E-3 | **The matcher is trusted for liveness and sees sealed prices**<br>Every fill needs a fresh approval from the matcher, which knows the prices it matches. It still can't fill at any price other than the sealed one, or touch a cancel. | Medium | By design |
| E-4 | **Coins sent to the escrow's own address are stranded**<br>If a buyer names the escrow contract as the recipient, the coins land in it with no owner. The site never does; the next deployment rejects it. | Low | Open |
| E-5 | **A payout contract that refuses ETH blocks its own order**<br>Proceeds and refunds are pushed in ETH. Use a wallet, not a contract that rejects ETH, as your payout address. | Low | By design |
| E-6 | **The fee is read at fill time**<br>Same as on Solana: the fee in force when the order fills, never above the 1% cap. | Low | By design |
| E-7 | **Crosses settle at the midpoint**<br>When two resting orders meet, they trade halfway between the two sealed prices: the seller gets at least their ask, the buyer pays at most their bid, and both prices become public. | Info | By design |
| E-8 | **The signing domain is fixed at deployment**<br>Matters only if Robinhood Chain ever split in two; approvals also name this contract and expire within two minutes. | Info | Accepted |
| E-9 | **One dust take fails the whole batch**<br>A fill too small to cover its fee reverts the transaction it is in. Nothing moves, and the fill can be sent again without it. | Info | Accepted |
| E-10 | **Rebasing coins aren't tracked**<br>A coin whose balances change without a transfer would drift from what escrow booked. Pons coins are standard ERC-20s; transfer-tax coins are supported. | Info | Accepted |

