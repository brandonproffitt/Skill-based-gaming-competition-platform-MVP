# MVP Plan — Skill-Based Speedrun Wagering (Testnet)

Status: **proposal, awaiting answers to the open questions in §1.** No code until they're answered.
Network: **Base Sepolia only.** No real money until explicitly approved.

---

## 1. Clarifying questions

These are the decisions that change the build. Defaults are in brackets. If a default is fine, you can just say "default".

### A. Money and token
1. **What do players stake: testnet USDC or native ETH?** [USDC. Stakes keep a stable value, the fee math is clean, and it matches the likely real-money path. Circle runs a Base Sepolia USDC faucet.]
2. **Min and max stake? Fixed tiers ($5/$10/$25) or any amount?** [Any amount between a min and max set by the admin. Tiers make matching easier later.]
3. **Fee percentage, and when is it charged?** Only on a decided match, or also on draws and voids? [Default: 5%, charged only when there's a winner. Draws, voids, and unaccepted challenges refund in full with no fee.]
4. **Can a challenge be cancelled after acceptance by mutual agreement?** [No for v1.]

### B. Matching
5. **Open challenges only, or also direct challenges to a specific wallet or username?** [Both. It's one optional `opponent` field.]
6. **Can the creator back out before anyone accepts?** [Yes, full refund.]

### C. Run timing and anti-cheat (biggest product risk)
7. **When must the run happen?** If players can submit any old video, the best existing run always wins. [The run must be recorded **after acceptance** and inside the submission window. The video must show a **per-challenge code** generated at acceptance, either on screen (phone or sticky note in frame) or spoken at the start.]
8. **How long is the submission window after acceptance?** [48 hours]
9. **One attempt, or best of N attempts in the window?** [Players may submit multiple uploads until the deadline; the latest one counts.]
10. **Video requirements:** max length and file size, must be continuous and uncut, must show a timer, must show the game start? [Max 15 min and 500 MB, continuous, start to finish of the objective. Start and stop points defined per game in the rules.]
11. **Whose time counts, the claimed time or the reviewer's measured time? What tolerance counts as a tie?** [The reviewer's measured time is authoritative. Times within 0.10 s count as a tie, configurable.]

### D. Edge-case rules
12. **Only one player submits:** do they win automatically, or must their run still be valid? [It must be valid. If it isn't, the challenge is voided and both are refunded.]
13. **Neither player submits:** [Void, full refund to both.]
14. **Disputes:** who can file, how long is the window, how many appeals? [Either player can file within 24 h of the verdict. One dispute per challenge, your second review is final, and settlement waits for the window to close.]
15. **Penalties for a fraudulent submission** (beyond losing)? [Manual ban flag only for v1.]

### E. Admin and ops
16. **Is the only admin you? Is one admin wallet OK for testnet, with a Safe multisig required before mainnet?** [Yes. Two roles: an **owner** (config) and a **resolver** (settles matches). They can be the same key on testnet.]
17. **Should the app pay gas to settle matches?** A server-held resolver key would let the admin page settle with one click. The alternative is that you sign every settlement in your own wallet. [You sign in your wallet for v1. No server-held private keys means one less thing to secure.]
18. **Notifications (accepted, deadline approaching, verdict)?** [In-app only for v1. Email later.]

### F. Data and identity
19. **Games: a curated list you maintain, or free text?** [Curated list (title + platform) plus free-text objective and rules per challenge.]
20. **User profile beyond the wallet:** display name? email? [Optional display name. Fields stubbed for future KYC, age, and region, but unused.]

### G. Stack preferences
21. **Are you comfortable with TypeScript everywhere plus Solidity?** Any existing accounts (Vercel, Supabase, Cloudflare)? [TypeScript plus the stack in §2.]

---

## 2. Architecture

```
 Browser (Next.js app)
   ├─ RainbowKit/wagmi ──► wallet ──► Escrow contract (Base Sepolia)
   ├─ SIWE sign-in ─────► Next.js API routes (server)
   └─ video upload ─────► Cloudflare R2 (presigned PUT, direct from browser)

 Next.js API routes / server actions (Vercel)
   ├─ Postgres (Supabase or Neon) via Drizzle ORM
   ├─ viem public client: verifies tx receipts + reads contract state
   ├─ Verifier module (ManualVerifier now, AiVerifier later)
   └─ Vercel Cron: deadlines (expire, forfeit, void) + chain reconciliation
```

| Piece | Choice | Why it's cheap and simple |
|---|---|---|
| Frontend + backend | **Next.js (App Router) + TypeScript on Vercel** | One repo, one deploy, free Hobby tier. API routes replace a separate backend. |
| Wallet UI | **RainbowKit + wagmi + viem** | Well-maintained and widely used. Covers wallet connection, chain switching, and contract calls. |
| Auth | **Sign-In with Ethereum (SIWE, EIP-4361)** via the `siwe` library + an HTTP-only session cookie (`iron-session`) | No passwords and no auth vendor. The wallet signature is the login. |
| Database | **Postgres on Supabase or Neon (free tier) + Drizzle ORM** | Managed and free at MVP scale. Relational data fits the challenge lifecycle well. |
| Video storage | **Cloudflare R2** with presigned uploads | 10 GB free and **zero egress fees**, which matters when reviewing videos. Browser uploads directly, so files never pass through Vercel's request-size limits. |
| Smart contract | **Solidity + Foundry + OpenZeppelin** | Foundry gives fast tests, fuzzing, and deploy scripts. OpenZeppelin supplies `SafeERC20`, `ReentrancyGuard`, `Ownable2Step`, and `Pausable`. |
| Chain | **Base Sepolia** (Polygon Amoy fallback) | Free test gas. The same contract deploys unchanged to Base mainnet later. |
| Chain sync | Verify **tx receipt + contract read** on submit, plus a **cron reconciliation** of events | No indexer service (The Graph or Ponder) needed at this scale. Can add one later. |

Key principles:
- **The contract only holds and moves money.** It knows creator, opponent, stake, and deadlines. Game, rules, videos, times, and disputes live off-chain.
- **The DB is never trusted for money state.** Anything involving funds is re-read from the chain before the UI shows it as done.
- **Funds can never get stuck.** Every on-chain state has a timeout that anyone can trigger for a refund, even if the admin or backend disappears.
- **Verification is a plug-in.** The settlement code calls a `Verifier` interface and never knows whether a human or an AI decided.

### Verifier module

```ts
interface Verifier {
  name: 'manual' | 'ai';
  // Start verification. Manual: creates a review task. AI: kicks off analysis.
  requestVerdict(challengeId: string): Promise<void>;
}

type Verdict = {
  challengeId: string;
  outcome: 'creator' | 'opponent' | 'draw' | 'void';
  creatorTimeMs: number | null;   // measured, not claimed
  opponentTimeMs: number | null;
  confidence: number;             // manual = 1.0
  reasoning: string;
  verifier: { type: 'manual' | 'ai'; ref: string }; // admin id or model version
};
```

- Every verifier writes a `Verdict` row. Then **one** shared function, `onVerdict()`, moves the challenge to `decided`, opens the dispute window, and later hands off to settlement.
- Later, AI verdicts below a confidence threshold become `needs_review` and land in the same admin queue. The manual page stays as the fallback and the dispute path.

---

## 3. Data model

```
users
  id (uuid pk), wallet_address (unique, checksummed), display_name,
  is_admin (bool), is_banned (bool), created_at
  -- reserved for later: kyc_status, dob_verified_at, region

auth_nonces
  nonce (pk), wallet_address, expires_at, used_at          -- SIWE replay protection

games
  id, title, platform, slug (unique), is_active

challenges
  id (uuid pk), onchain_id (uint256, unique, nullable until confirmed),
  creator_id, opponent_id (nullable), invited_opponent_id (nullable, direct challenges),
  game_id, objective (text), rules (text), rules_hash (bytes32),
  challenge_code (short random string, shown at acceptance, must appear in video),
  token_address, stake_amount (numeric, base units), fee_bps (snapshot at creation),
  status (enum, see §4),
  accept_by, submit_by, dispute_until, hard_refund_at (mirrors on-chain timeout),
  create_tx, accept_tx, settle_tx, refund_tx,
  winner_id (nullable), outcome (creator|opponent|draw|void, nullable),
  created_at, updated_at

submissions
  id, challenge_id, user_id, claimed_time_ms,
  video_key (R2 object key), video_sha256, video_bytes, duration_s,
  is_current (bool; latest upload counts), submitted_at
  unique (challenge_id, user_id) where is_current

verdicts
  id, challenge_id, verifier_type (manual|ai), verifier_ref,
  outcome, creator_time_ms, opponent_time_ms, confidence, reasoning,
  evidence_hash (bytes32, sha256 of both video hashes + verdict JSON),
  is_final (bool), created_at

disputes
  id, challenge_id, raised_by, reason, status (open|upheld|rejected),
  resolved_by, resolution_note, created_at, resolved_at

challenge_events                      -- append-only audit log
  id, challenge_id, from_status, to_status,
  actor_type (user|admin|system|chain), actor_ref, payload (jsonb), created_at

chain_sync
  key (pk), last_block                 -- reconciliation cursor
```

Notes:
- Store stakes as **integer base units** (numeric or string), never floats.
- The **`evidence_hash` goes on-chain** in the settlement event. It's a cheap, permanent receipt of what the decision was based on, and it satisfies the "only hashes on-chain" rule.
- Videos are **private** in R2, viewable only through short-lived signed URLs for the two players and admins.

---

## 4. Challenge lifecycle (state machine)

Off-chain (DB) statuses are richer than on-chain ones. The contract only tracks the money states.

```
                    create tx confirmed
 pending_deposit ─────────────────────► open
       │ (tx never confirms → deleted by cron)
                                         │  creator cancels / accept_by passes
                                         ├──────────────────────────────► refunded (creator)
                                         │  opponent deposits
                                         ▼
                                       active  (challenge_code issued, submission window open)
                                         │  both submitted, or submit_by passes
                       ┌─────────────────┼──────────────────────┐
           0 submissions│      1 or 2 submissions                │
                        ▼                ▼                       │
                      void ──► refunded (both)                   │
                                       in_review                 │
                                         │ verdict recorded      │
                                         ▼                       │
                                      decided ── dispute filed ─► disputed ─► (admin re-review) ─► decided (final)
                                         │ dispute window closes
                                         ▼
                 outcome = winner ──► settled (winner paid, fee to platform)
                 outcome = draw/void ──► refunded (both, no fee)

 Safety valve, from active/in_review/decided/disputed:
   hard_refund_at passes with no settlement → anyone can call refund on-chain → refunded (both)
```

| On-chain status | DB statuses that map to it |
|---|---|
| `Open` | open |
| `Active` | active, in_review, decided, disputed, void (until the refund tx confirms) |
| `Settled` | settled |
| `Refunded` | refunded |

Edge cases from the brief:
- **Never accepted:** the creator can cancel anytime while it's open. After `accept_by`, anyone (the cron or the creator) can call `refundUnaccepted`.
- **One player doesn't submit:** goes to review. If the one submission is valid, that player wins by forfeit. Otherwise void.
- **Tie:** verdict `draw`, both refunded, no fee (pending your answer to Q3).
- **Dispute:** pauses settlement and gets one re-review, which is final.
- **Admin disappears or the key is lost:** the on-chain `hard_refund_at` timeout returns both stakes.

---

## 5. Escrow contract outline

One small, **non-upgradeable** contract, `ChallengeEscrow.sol`. One stake token (USDC), fixed at deployment.

Inherits from OpenZeppelin: `Ownable2Step`, `ReentrancyGuard`, `Pausable`, and `SafeERC20` (as a library).

```solidity
enum Status { None, Open, Active, Settled, Refunded }

struct Challenge {
    address creator;
    address opponent;        // 0x0 = open to anyone; set = invited-only until accepted
    uint96  stake;           // per player
    uint16  feeBps;          // snapshot at creation
    uint40  acceptBy;
    uint40  resolveBy;       // set on accept: now + submit window + review window + buffer
    Status  status;
}
```

| Function | Caller | Effect |
|---|---|---|
| `create(stake, acceptBy, invitedOpponent, rulesHash)` → `id` | anyone | Pulls `stake` from the creator (needs `approve` first). Stores the challenge with an auto-increment `id` and snapshots `feeBps`. Emits `Created` with `rulesHash`. |
| `cancel(id)` | creator | Only while `Open`. Refunds the creator. |
| `accept(id)` | anyone, or only the invited address | Only while `Open` and before `acceptBy`. Pulls a matching stake and sets `resolveBy`. Emits `Accepted`. |
| `resolve(id, winner, evidenceHash)` | **resolver** | Only while `Active`. `winner` must be the creator or the opponent. Credits the winner with `2*stake - fee` and the platform with `fee`. Emits `Resolved`. |
| `resolveDraw(id, evidenceHash)` | **resolver** | Only while `Active`. Credits both players their stake. Used for draws and voids. |
| `refundExpired(id)` | **anyone** | Covers `Open` past `acceptBy` (refunds the creator) and `Active` past `resolveBy` (refunds both). This is the stuck-funds safety valve. |
| `withdraw()` | anyone with a balance | Pull payment: transfers that caller's credited balance. |
| `setFeeBps(bps)` | owner | Capped by a hardcoded `MAX_FEE_BPS` (e.g. 1000 = 10%). Applies to **new** challenges only. |
| `setResolver(addr)` / `setFeeRecipient(addr)` | owner | Role rotation. |
| `pause()` / `unpause()` | owner | Blocks `create` and `accept` only. **Refunds and withdrawals always work.** |

The per-challenge `challenge_code`, game, rules text, and video hashes are deliberately **not** stored on-chain. Only `rulesHash` (at create) and `evidenceHash` (at resolve) go there, in events.

### Main security risks and mitigations

| Risk | Mitigation |
|---|---|
| **Resolver key compromise or a dishonest resolver** | The resolver can only pick one of the **two players** (or a draw). It can never send funds elsewhere. Use a separate key from the owner, and a Safe multisig before mainnet. |
| **Funds stuck forever** (admin gone, bug in backend) | `refundExpired` is callable by anyone after `resolveBy`. Pause never blocks exits. |
| **Reentrancy** | Checks-effects-interactions, `nonReentrant` on every state-changing function, pull payments. |
| **Push-payment DoS** (e.g. a USDC-blacklisted winner makes `resolve` revert) | Pull pattern: `resolve` only credits balances, and `withdraw` is per-user. |
| **Fee changed mid-match** | `feeBps` is snapshotted per challenge and capped by an immutable `MAX_FEE_BPS`. |
| **Weird tokens** (fee-on-transfer, rebasing) | One token, fixed at deploy (USDC), and `SafeERC20`. |
| **Rounding** | Fee = `pot * feeBps / 10_000`, rounded down. Any remainder goes to the winner. Fuzz-test that `paid out + fee == deposited`. |
| **Accept front-running** on a direct challenge | `invitedOpponent` restricts who can accept. For open challenges, first come first served is fine. |
| **Self-play or collusion** (one person, two wallets, to launder or farm) | Off-chain problem: flag same-IP or linked accounts. With no cash-out on testnet the risk is low. Note it for KYC later. |
| **Upgrade risk** | Not upgradeable. Fixes ship as a new deployment, and old challenges finish on the old contract. |
| **Admin centralization** (legal and trust) | Documented: the platform can decide outcomes but can't take stakes. Revisit with counsel (§7). |

Before mainnet, at minimum: 100% branch coverage in Foundry, fuzz and invariant tests ("contract balance == sum of credited balances + live stakes"), a Slither run, and an **external audit**.

---

## 6. Build order (each milestone ends in something runnable)

| # | Milestone | You can run or test |
|---|---|---|
| **M0** | Monorepo scaffold: `apps/web` (Next.js, Tailwind, Drizzle), `contracts/` (Foundry), CI running lint, typecheck, and tests | `npm run dev` shows a landing page. `forge test` passes. CI is green. |
| **M1** | `ChallengeEscrow.sol` + mock USDC, with full unit, fuzz, and invariant tests | `forge test -vv` covers every lifecycle path, including timeouts and refunds. |
| **M2** | Deploy to Base Sepolia and verify on Basescan. Add a script that runs a full match with `cast` | A real create → accept → resolve → withdraw on testnet, visible on Basescan. |
| **M3** | Wallet connect + SIWE login + `users` table + admin flag | Connect a wallet, sign in, see your profile. Admin routes are blocked for non-admins. |
| **M4** | Create, browse, and accept challenges: DB rows + on-chain deposits, receipt verification, reconciliation cron | Two browser profiles (two wallets) create and accept a challenge, and both deposits show on-chain. |
| **M5** | Video upload (presigned R2) + claimed time + SHA-256 + challenge code display + submission deadline | Both players upload. Uploads are rejected after `submit_by`. Videos play back for the players and the admin. |
| **M6** | `Verifier` interface + `ManualVerifier` + admin review page + settlement (you sign `resolve` in your wallet) + winner withdraw | A full happy path end to end: winner withdraws `pot - fee`, and the fee balance shows for the platform. |
| **M7** | Edge cases: cancel, expire, forfeit, void, draw, dispute flow, `refundExpired` from the UI | A scripted checklist of each edge case passes on testnet. |
| **M8** | Hardening: audit-log views, rate limits, input validation, Slither, a runbook, a seeded demo | An "ops" page lists stuck or overdue challenges. The runbook explains how to recover each one. |

---

## 7. Legal and compliance areas to research before real money

This is a checklist of topics to take to a lawyer who specializes in gaming and payments. It is **not legal advice.**

**Gambling vs. skill**
- State tests for "game of skill" (dominant-factor vs. material-element vs. any-chance tests). Some states restrict or ban paid-entry skill contests altogether. The lists vary by source and change, so verify per state.
- Whether **player-vs-player wagers with a platform fee (rake)** are treated differently from fixed-entry-fee prize contests in each state.
- Speedruns with RNG elements: whether a game's randomness affects the skill analysis.
- Federal: UIGEA (and its skill-game carve-outs), the Wire Act, and the Illegal Gambling Business Act.

**Money handling**
- **Money transmission:** whether holding stakes, even in a smart contract you control the resolver of, makes you a money transmitter. Look at FinCEN's 2019 guidance on convertible virtual currency and the state money transmitter licenses.
- **KYC/AML** obligations, and the thresholds at which they apply.
- **OFAC sanctions screening** of wallet addresses, plus geoblocking of sanctioned jurisdictions.
- **Tax reporting** on winnings (1099 thresholds) and digital-asset broker reporting rules (1099-DA).
- Whether using USDC or other tokens raises securities or commodities questions. It's probably not an issue for a stablecoin used as stakes, but confirm.

**Users**
- **Age verification:** 18+, or 21+ in some states. Also COPPA, which covers users under 13.
- **Geolocation and state blocking:** what level of geofencing is legally sufficient.
- Responsible gaming obligations (deposit limits, self-exclusion) where required.
- Terms of Service, arbitration clause, and dispute policy. Also refund and chargeback policy.

**Content and IP**
- **Game publisher EULAs and tournament policies.** Some publishers restrict or cap monetized competitions using their games (e.g., Nintendo's community tournament guidelines). This could limit which games you can list.
- Rights to store and review user-uploaded gameplay video, and DMCA agent registration.
- Privacy law (CCPA/CPRA, GDPR if you have EU users) for videos, wallet addresses, and any KYC data. Also check biometric rules if face or voice appears in videos.

**Platform**
- Liability for incorrect verdicts. Disclosure that verdicts may be AI-made and how to appeal.
- App store rules (later, if mobile).
- International users: block them or handle per country.

---

## 8. Next step

Answer §1 (or say "defaults"), then I'll start **M0 + M1**: the scaffold and the escrow contract with tests.
