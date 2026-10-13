# Contracts

`src/ChallengeEscrow.sol` holds equal stakes from two players and releases them on an off-chain verdict.
The full design rationale and risk table are in [`../docs/PLAN.md`](../docs/PLAN.md) §5.

## Guarantees (enforced by tests)

- The resolver can only pay the creator or the opponent, or refund both. It can never send funds elsewhere.
- Every funded challenge has a deadline after which **anyone** can call `refundExpired`. Funds can't get stuck,
  even if the admin disappears.
- Fees are snapshotted per challenge and capped at 10% (`MAX_FEE_BPS`).
- Pausing blocks `create` and `accept` only. Cancels, verdicts, refunds, and withdrawals always work.
- Payouts are pull-based: everything is credited, then each account calls `withdraw()`.
- Neither the creator nor the resolver can accept a challenge as the opponent.
- Not upgradeable.

## Lifecycle

```
create ──► Open ──accept──► Active ──resolve──────► Settled
            │                  ├──resolveDraw──► Drawn
            ├──cancel──► Cancelled
            └──(after acceptBy) refundExpired──► Expired
                               └──(after resolveBy) refundExpired──► Expired
```

## Commands

```bash
forge build
forge test                          # unit + fuzz + invariant
FOUNDRY_PROFILE=ci forge test       # heavier fuzz/invariant settings used in CI
forge coverage --no-match-coverage "test/"
forge fmt
```

Dependencies are git submodules pinned to tags: OpenZeppelin Contracts v5.4.0 and forge-std v1.11.0.
