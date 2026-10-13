CREATE TYPE "public"."actor_type" AS ENUM('user', 'admin', 'system', 'chain');--> statement-breakpoint
CREATE TYPE "public"."challenge_outcome" AS ENUM('creator', 'opponent', 'draw', 'void');--> statement-breakpoint
CREATE TYPE "public"."challenge_status" AS ENUM('pending_deposit', 'open', 'active', 'in_review', 'decided', 'disputed', 'settled', 'refunded');--> statement-breakpoint
CREATE TYPE "public"."dispute_status" AS ENUM('open', 'upheld', 'rejected');--> statement-breakpoint
CREATE TYPE "public"."flag_reason" AS ENUM('repeat_matchup', 'shared_ip', 'manual');--> statement-breakpoint
CREATE TYPE "public"."publisher_policy_status" AS ENUM('unreviewed', 'allowed', 'restricted', 'prohibited');--> statement-breakpoint
CREATE TYPE "public"."verifier_type" AS ENUM('manual', 'ai');--> statement-breakpoint
CREATE TABLE "auth_nonces" (
	"nonce" text PRIMARY KEY NOT NULL,
	"wallet_address" text NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"used_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "chain_sync" (
	"key" text PRIMARY KEY NOT NULL,
	"last_block" bigint NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "challenge_events" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"challenge_id" uuid NOT NULL,
	"from_status" "challenge_status",
	"to_status" "challenge_status" NOT NULL,
	"actor_type" "actor_type" NOT NULL,
	"actor_ref" text,
	"payload" jsonb,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "challenges" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"onchain_id" bigint,
	"creator_id" uuid NOT NULL,
	"opponent_id" uuid,
	"invited_opponent_id" uuid,
	"game_id" uuid NOT NULL,
	"objective" text NOT NULL,
	"rules" text NOT NULL,
	"rules_hash" text NOT NULL,
	"challenge_code" text,
	"token_address" text NOT NULL,
	"stake_amount" numeric(78, 0) NOT NULL,
	"fee_bps" integer NOT NULL,
	"status" "challenge_status" DEFAULT 'pending_deposit' NOT NULL,
	"outcome" "challenge_outcome",
	"winner_id" uuid,
	"accept_by" timestamp with time zone NOT NULL,
	"submit_by" timestamp with time zone,
	"dispute_until" timestamp with time zone,
	"resolve_by" timestamp with time zone,
	"create_tx" text,
	"accept_tx" text,
	"settle_tx" text,
	"refund_tx" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "challenges_onchain_id_unique" UNIQUE("onchain_id"),
	CONSTRAINT "challenges_no_self_match" CHECK ("challenges"."opponent_id" is null or "challenges"."opponent_id" <> "challenges"."creator_id"),
	CONSTRAINT "challenges_stake_positive" CHECK ("challenges"."stake_amount" > 0)
);
--> statement-breakpoint
CREATE TABLE "collusion_flags" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"challenge_id" uuid,
	"user_a_id" uuid NOT NULL,
	"user_b_id" uuid NOT NULL,
	"reason" "flag_reason" NOT NULL,
	"details" jsonb,
	"reviewed_by" uuid,
	"reviewed_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "dispute_reviews" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"dispute_id" uuid NOT NULL,
	"reviewer_id" uuid NOT NULL,
	"decision" "dispute_status" NOT NULL,
	"outcome" "challenge_outcome",
	"note" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "dispute_reviews_decided" CHECK ("dispute_reviews"."decision" <> 'open')
);
--> statement-breakpoint
CREATE TABLE "disputes" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"challenge_id" uuid NOT NULL,
	"verdict_id" uuid NOT NULL,
	"raised_by" uuid NOT NULL,
	"reason" text NOT NULL,
	"status" "dispute_status" DEFAULT 'open' NOT NULL,
	"required_reviews" integer DEFAULT 1 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"resolved_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "games" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"slug" text NOT NULL,
	"title" text NOT NULL,
	"platform" text NOT NULL,
	"publisher" text NOT NULL,
	"publisher_policy_status" "publisher_policy_status" DEFAULT 'unreviewed' NOT NULL,
	"publisher_policy_url" text,
	"publisher_policy_notes" text,
	"is_active" boolean DEFAULT true NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "games_slug_unique" UNIQUE("slug")
);
--> statement-breakpoint
CREATE TABLE "submissions" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"challenge_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"claimed_time_ms" integer NOT NULL,
	"video_key" text NOT NULL,
	"video_sha256" text NOT NULL,
	"video_bytes" bigint NOT NULL,
	"duration_s" integer,
	"is_current" boolean DEFAULT true NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "submissions_time_positive" CHECK ("submissions"."claimed_time_ms" > 0)
);
--> statement-breakpoint
CREATE TABLE "users" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"wallet_address" text NOT NULL,
	"display_name" text,
	"is_admin" boolean DEFAULT false NOT NULL,
	"is_banned" boolean DEFAULT false NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"kyc_status" text,
	"dob_verified_at" timestamp with time zone,
	"region" text,
	CONSTRAINT "users_wallet_address_unique" UNIQUE("wallet_address")
);
--> statement-breakpoint
CREATE TABLE "verdicts" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"challenge_id" uuid NOT NULL,
	"verifier_type" "verifier_type" NOT NULL,
	"verifier_ref" text NOT NULL,
	"outcome" "challenge_outcome" NOT NULL,
	"creator_time_ms" integer,
	"opponent_time_ms" integer,
	"confidence" real NOT NULL,
	"reasoning" text NOT NULL,
	"evidence_hash" text NOT NULL,
	"is_final" boolean DEFAULT false NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "challenge_events" ADD CONSTRAINT "challenge_events_challenge_id_challenges_id_fk" FOREIGN KEY ("challenge_id") REFERENCES "public"."challenges"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "challenges" ADD CONSTRAINT "challenges_creator_id_users_id_fk" FOREIGN KEY ("creator_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "challenges" ADD CONSTRAINT "challenges_opponent_id_users_id_fk" FOREIGN KEY ("opponent_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "challenges" ADD CONSTRAINT "challenges_invited_opponent_id_users_id_fk" FOREIGN KEY ("invited_opponent_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "challenges" ADD CONSTRAINT "challenges_game_id_games_id_fk" FOREIGN KEY ("game_id") REFERENCES "public"."games"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "challenges" ADD CONSTRAINT "challenges_winner_id_users_id_fk" FOREIGN KEY ("winner_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "collusion_flags" ADD CONSTRAINT "collusion_flags_challenge_id_challenges_id_fk" FOREIGN KEY ("challenge_id") REFERENCES "public"."challenges"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "collusion_flags" ADD CONSTRAINT "collusion_flags_user_a_id_users_id_fk" FOREIGN KEY ("user_a_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "collusion_flags" ADD CONSTRAINT "collusion_flags_user_b_id_users_id_fk" FOREIGN KEY ("user_b_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "collusion_flags" ADD CONSTRAINT "collusion_flags_reviewed_by_users_id_fk" FOREIGN KEY ("reviewed_by") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "dispute_reviews" ADD CONSTRAINT "dispute_reviews_dispute_id_disputes_id_fk" FOREIGN KEY ("dispute_id") REFERENCES "public"."disputes"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "dispute_reviews" ADD CONSTRAINT "dispute_reviews_reviewer_id_users_id_fk" FOREIGN KEY ("reviewer_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "disputes" ADD CONSTRAINT "disputes_challenge_id_challenges_id_fk" FOREIGN KEY ("challenge_id") REFERENCES "public"."challenges"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "disputes" ADD CONSTRAINT "disputes_verdict_id_verdicts_id_fk" FOREIGN KEY ("verdict_id") REFERENCES "public"."verdicts"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "disputes" ADD CONSTRAINT "disputes_raised_by_users_id_fk" FOREIGN KEY ("raised_by") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "submissions" ADD CONSTRAINT "submissions_challenge_id_challenges_id_fk" FOREIGN KEY ("challenge_id") REFERENCES "public"."challenges"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "submissions" ADD CONSTRAINT "submissions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "verdicts" ADD CONSTRAINT "verdicts_challenge_id_challenges_id_fk" FOREIGN KEY ("challenge_id") REFERENCES "public"."challenges"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "challenge_events_challenge_idx" ON "challenge_events" USING btree ("challenge_id");--> statement-breakpoint
CREATE INDEX "challenges_status_idx" ON "challenges" USING btree ("status");--> statement-breakpoint
CREATE INDEX "challenges_creator_idx" ON "challenges" USING btree ("creator_id");--> statement-breakpoint
CREATE INDEX "challenges_opponent_idx" ON "challenges" USING btree ("opponent_id");--> statement-breakpoint
CREATE INDEX "collusion_flags_pair_idx" ON "collusion_flags" USING btree ("user_a_id","user_b_id");--> statement-breakpoint
CREATE UNIQUE INDEX "dispute_reviews_one_per_reviewer" ON "dispute_reviews" USING btree ("dispute_id","reviewer_id");--> statement-breakpoint
CREATE UNIQUE INDEX "disputes_one_per_challenge" ON "disputes" USING btree ("challenge_id");--> statement-breakpoint
CREATE UNIQUE INDEX "submissions_one_current_per_player" ON "submissions" USING btree ("challenge_id","user_id") WHERE "submissions"."is_current";--> statement-breakpoint
CREATE INDEX "verdicts_challenge_idx" ON "verdicts" USING btree ("challenge_id");