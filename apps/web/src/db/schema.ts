import { sql } from "drizzle-orm";
import {
  bigint,
  boolean,
  check,
  index,
  integer,
  jsonb,
  numeric,
  pgEnum,
  pgTable,
  real,
  text,
  timestamp,
  uniqueIndex,
  uuid,
} from "drizzle-orm/pg-core";

// Wallet addresses and hashes are stored as lowercase 0x-prefixed hex strings.
// Token amounts are stored in base units (USDC has 6 decimals) as numeric, never floats.

const createdAt = () => timestamp("created_at", { withTimezone: true }).notNull().defaultNow();
const updatedAt = () =>
  timestamp("updated_at", { withTimezone: true })
    .notNull()
    .defaultNow()
    .$onUpdate(() => new Date());

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/** Off-chain lifecycle. See docs/PLAN.md §4 for the state machine. */
export const challengeStatus = pgEnum("challenge_status", [
  "pending_deposit", // row created, create tx not yet confirmed
  "open", // creator staked, waiting for an opponent
  "active", // both staked, submission window open
  "in_review", // waiting for a verdict
  "decided", // verdict recorded, dispute window open
  "disputed", // dispute filed, waiting for re-review
  "settled", // winner paid on-chain
  "refunded", // cancelled, expired, drawn, or voided; stakes returned on-chain
]);

export const challengeOutcome = pgEnum("challenge_outcome", ["creator", "opponent", "draw", "void"]);

export const verifierType = pgEnum("verifier_type", ["manual", "ai"]);

export const disputeStatus = pgEnum("dispute_status", ["open", "upheld", "rejected"]);

/** Whether the game publisher's rules allow wagered competitions with the game. Reviewed per game. */
export const publisherPolicyStatus = pgEnum("publisher_policy_status", [
  "unreviewed",
  "allowed",
  "restricted",
  "prohibited",
]);

export const flagReason = pgEnum("flag_reason", ["repeat_matchup", "shared_ip", "manual"]);

export const actorType = pgEnum("actor_type", ["user", "admin", "system", "chain"]);

// ---------------------------------------------------------------------------
// Users and auth
// ---------------------------------------------------------------------------

export const users = pgTable("users", {
  id: uuid("id").primaryKey().defaultRandom(),
  walletAddress: text("wallet_address").notNull().unique(),
  displayName: text("display_name"),
  isAdmin: boolean("is_admin").notNull().default(false),
  isBanned: boolean("is_banned").notNull().default(false),
  createdAt: createdAt(),
  // Reserved for real-money compliance work (KYC, age, region). Unused on testnet.
  kycStatus: text("kyc_status"),
  dobVerifiedAt: timestamp("dob_verified_at", { withTimezone: true }),
  region: text("region"),
});

/** Sign-In with Ethereum nonces. Single use, short-lived. */
export const authNonces = pgTable("auth_nonces", {
  nonce: text("nonce").primaryKey(),
  walletAddress: text("wallet_address").notNull(),
  expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
  usedAt: timestamp("used_at", { withTimezone: true }),
});

// ---------------------------------------------------------------------------
// Games
// ---------------------------------------------------------------------------

export const games = pgTable("games", {
  id: uuid("id").primaryKey().defaultRandom(),
  slug: text("slug").notNull().unique(),
  title: text("title").notNull(),
  platform: text("platform").notNull(),
  publisher: text("publisher").notNull(),
  publisherPolicyStatus: publisherPolicyStatus("publisher_policy_status").notNull().default("unreviewed"),
  publisherPolicyUrl: text("publisher_policy_url"),
  publisherPolicyNotes: text("publisher_policy_notes"),
  isActive: boolean("is_active").notNull().default(true),
  createdAt: createdAt(),
});

// ---------------------------------------------------------------------------
// Challenges
// ---------------------------------------------------------------------------

export const challenges = pgTable(
  "challenges",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    onchainId: bigint("onchain_id", { mode: "bigint" }).unique(), // null until the create tx confirms
    creatorId: uuid("creator_id")
      .notNull()
      .references(() => users.id),
    opponentId: uuid("opponent_id").references(() => users.id),
    invitedOpponentId: uuid("invited_opponent_id").references(() => users.id),
    gameId: uuid("game_id")
      .notNull()
      .references(() => games.id),
    objective: text("objective").notNull(),
    rules: text("rules").notNull(),
    rulesHash: text("rules_hash").notNull(), // bytes32 passed to create()
    // Shown at acceptance. Must be visible at both the start and the end of the run video.
    challengeCode: text("challenge_code"),

    tokenAddress: text("token_address").notNull(),
    stakeAmount: numeric("stake_amount", { precision: 78, scale: 0 }).notNull(),
    feeBps: integer("fee_bps").notNull(), // snapshot, mirrors the contract

    status: challengeStatus("status").notNull().default("pending_deposit"),
    outcome: challengeOutcome("outcome"),
    winnerId: uuid("winner_id").references(() => users.id),

    acceptBy: timestamp("accept_by", { withTimezone: true }).notNull(),
    submitBy: timestamp("submit_by", { withTimezone: true }), // set on accept
    disputeUntil: timestamp("dispute_until", { withTimezone: true }), // set when decided
    resolveBy: timestamp("resolve_by", { withTimezone: true }), // on-chain hard deadline, set on accept

    createTx: text("create_tx"),
    acceptTx: text("accept_tx"),
    settleTx: text("settle_tx"),
    refundTx: text("refund_tx"),

    createdAt: createdAt(),
    updatedAt: updatedAt(),
  },
  (t) => [
    index("challenges_status_idx").on(t.status),
    index("challenges_creator_idx").on(t.creatorId),
    index("challenges_opponent_idx").on(t.opponentId),
    // Basic anti-collusion: a wallet can't accept its own challenge (also enforced on-chain).
    check("challenges_no_self_match", sql`${t.opponentId} is null or ${t.opponentId} <> ${t.creatorId}`),
    check("challenges_stake_positive", sql`${t.stakeAmount} > 0`),
  ],
);

// ---------------------------------------------------------------------------
// Submissions
// ---------------------------------------------------------------------------

export const submissions = pgTable(
  "submissions",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    challengeId: uuid("challenge_id")
      .notNull()
      .references(() => challenges.id),
    userId: uuid("user_id")
      .notNull()
      .references(() => users.id),
    claimedTimeMs: integer("claimed_time_ms").notNull(),
    videoKey: text("video_key").notNull(), // R2 object key, private bucket
    videoSha256: text("video_sha256").notNull(),
    videoBytes: bigint("video_bytes", { mode: "number" }).notNull(),
    durationS: integer("duration_s"),
    isCurrent: boolean("is_current").notNull().default(true), // latest upload counts
    submittedAt: createdAt(),
  },
  (t) => [
    uniqueIndex("submissions_one_current_per_player")
      .on(t.challengeId, t.userId)
      .where(sql`${t.isCurrent}`),
    check("submissions_time_positive", sql`${t.claimedTimeMs} > 0`),
  ],
);

// ---------------------------------------------------------------------------
// Verdicts, disputes, reviews
// ---------------------------------------------------------------------------

/** Output of any Verifier (manual now, AI later). */
export const verdicts = pgTable(
  "verdicts",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    challengeId: uuid("challenge_id")
      .notNull()
      .references(() => challenges.id),
    verifierType: verifierType("verifier_type").notNull(),
    verifierRef: text("verifier_ref").notNull(), // admin user id, or model + version
    outcome: challengeOutcome("outcome").notNull(),
    creatorTimeMs: integer("creator_time_ms"), // measured, not claimed
    opponentTimeMs: integer("opponent_time_ms"),
    confidence: real("confidence").notNull(), // manual = 1.0
    reasoning: text("reasoning").notNull(),
    evidenceHash: text("evidence_hash").notNull(), // bytes32 passed to resolve()
    isFinal: boolean("is_final").notNull().default(false),
    createdAt: createdAt(),
  },
  (t) => [index("verdicts_challenge_idx").on(t.challengeId)],
);

export const disputes = pgTable(
  "disputes",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    challengeId: uuid("challenge_id")
      .notNull()
      .references(() => challenges.id),
    verdictId: uuid("verdict_id")
      .notNull()
      .references(() => verdicts.id),
    raisedBy: uuid("raised_by")
      .notNull()
      .references(() => users.id),
    reason: text("reason").notNull(),
    status: disputeStatus("status").notNull().default("open"),
    // How many independent reviews must agree to close the dispute. 1 on testnet; raise to 2 before real money.
    requiredReviews: integer("required_reviews").notNull().default(1),
    createdAt: createdAt(),
    resolvedAt: timestamp("resolved_at", { withTimezone: true }),
  },
  (t) => [
    // One dispute per challenge for v1.
    uniqueIndex("disputes_one_per_challenge").on(t.challengeId),
  ],
);

/** One row per reviewer per dispute, so a second reviewer can be added without schema changes. */
export const disputeReviews = pgTable(
  "dispute_reviews",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    disputeId: uuid("dispute_id")
      .notNull()
      .references(() => disputes.id),
    reviewerId: uuid("reviewer_id")
      .notNull()
      .references(() => users.id),
    decision: disputeStatus("decision").notNull(), // upheld | rejected
    outcome: challengeOutcome("outcome"), // the corrected outcome if upheld
    note: text("note").notNull(),
    createdAt: createdAt(),
  },
  (t) => [
    uniqueIndex("dispute_reviews_one_per_reviewer").on(t.disputeId, t.reviewerId),
    check("dispute_reviews_decided", sql`${t.decision} <> 'open'`),
  ],
);

// ---------------------------------------------------------------------------
// Anti-collusion and audit
// ---------------------------------------------------------------------------

/** Accounts or challenges flagged for manual review (e.g. the same two wallets playing repeatedly). */
export const collusionFlags = pgTable(
  "collusion_flags",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    challengeId: uuid("challenge_id").references(() => challenges.id),
    userAId: uuid("user_a_id")
      .notNull()
      .references(() => users.id),
    userBId: uuid("user_b_id")
      .notNull()
      .references(() => users.id),
    reason: flagReason("reason").notNull(),
    details: jsonb("details"),
    reviewedBy: uuid("reviewed_by").references(() => users.id),
    reviewedAt: timestamp("reviewed_at", { withTimezone: true }),
    createdAt: createdAt(),
  },
  (t) => [index("collusion_flags_pair_idx").on(t.userAId, t.userBId)],
);

/** Append-only audit log of every status change. */
export const challengeEvents = pgTable(
  "challenge_events",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    challengeId: uuid("challenge_id")
      .notNull()
      .references(() => challenges.id),
    fromStatus: challengeStatus("from_status"),
    toStatus: challengeStatus("to_status").notNull(),
    actorType: actorType("actor_type").notNull(),
    actorRef: text("actor_ref"),
    payload: jsonb("payload"),
    createdAt: createdAt(),
  },
  (t) => [index("challenge_events_challenge_idx").on(t.challengeId)],
);

/** Cursor for the chain reconciliation cron. */
export const chainSync = pgTable("chain_sync", {
  key: text("key").primaryKey(),
  lastBlock: bigint("last_block", { mode: "bigint" }).notNull(),
  updatedAt: updatedAt(),
});
