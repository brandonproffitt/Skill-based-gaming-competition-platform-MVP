# Web app

Next.js 16 (App Router) + Tailwind. API routes are the backend. Database access goes through Drizzle ORM to
Neon Postgres.

```bash
npm run dev            # from the repo root, or here
npm run db:generate    # regenerate SQL migrations after editing src/db/schema.ts (works offline)
npm run db:migrate     # apply migrations (needs DATABASE_URL)
```

- `src/db/schema.ts`: data model (see `docs/PLAN.md` §3).
- `drizzle/`: generated SQL migrations. Commit them.
- `src/lib/env.ts`: validated server config. The app refuses any chain other than Base Sepolia.
- `/api/health`: reports chain ID and whether a database is configured.
