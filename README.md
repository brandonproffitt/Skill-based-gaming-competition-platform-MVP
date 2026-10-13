# Skill Duel (testnet prototype)

Head-to-head speedrun challenges with stakes held in an escrow contract. Players run games on their own devices
and upload a video; a reviewer (manual now, AI later) picks the winner and the contract pays out minus a small fee.

**Base Sepolia testnet only. No real money.**

The design, data model, state machine, and milestones are in [`docs/PLAN.md`](docs/PLAN.md).

## Layout

| Path | What |
|---|---|
| `contracts/` | `ChallengeEscrow.sol` (Foundry + OpenZeppelin) and its tests |
| `apps/web/` | Next.js app: UI, API routes, Drizzle schema for Neon Postgres |
| `docs/PLAN.md` | Architecture, decisions, and build order |

## Quick start

Requirements: Node 22 and [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone --recurse-submodules <repo-url>
cd skill-based-gaming-competition-platform-mvp
# If you cloned without --recurse-submodules:
git submodule update --init

npm install
npm run dev              # http://localhost:3000, health check at /api/health

npm run contracts:test   # escrow unit, fuzz, and invariant tests
npm test                 # web unit tests
npm run lint && npm run typecheck && npm run build
```

No accounts are needed to run anything above. A Neon database (`DATABASE_URL` in `apps/web/.env.local`, see
`apps/web/.env.example`) is needed from milestone M3 onward.

## Status

- [x] M0: monorepo scaffold, CI
- [x] M1: escrow contract with unit, fuzz, and invariant tests
- [ ] M2: Base Sepolia deployment
- [ ] M3–M8: see `docs/PLAN.md`
