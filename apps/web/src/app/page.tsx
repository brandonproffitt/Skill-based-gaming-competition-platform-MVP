const steps = [
  ["Challenge", "Pick a game, an objective, and a stake. Your stake goes into escrow."],
  ["Match", "An opponent accepts and puts up the same stake."],
  ["Run", "Both players record their run with the challenge code visible at the start and the end."],
  ["Review", "Runs are reviewed and the faster valid time wins the pot, minus a small fee."],
];

export default function Home() {
  return (
    <main className="mx-auto flex w-full max-w-2xl flex-1 flex-col gap-10 px-4 py-16">
      <header className="flex flex-col gap-3">
        <span className="w-fit rounded-full border border-amber-500/40 bg-amber-500/10 px-3 py-1 text-xs font-medium text-amber-600 dark:text-amber-400">
          Testnet prototype. No real money.
        </span>
        <h1 className="text-4xl font-semibold tracking-tight">Skill Duel</h1>
        <p className="text-lg text-muted">
          Head-to-head speedrun challenges on games you already own, with stakes held in an escrow contract on
          Base Sepolia.
        </p>
      </header>

      <ol className="flex flex-col gap-4">
        {steps.map(([title, body], i) => (
          <li key={title} className="flex gap-4">
            <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full border border-foreground/20 text-sm font-medium">
              {i + 1}
            </span>
            <div>
              <h2 className="font-medium">{title}</h2>
              <p className="text-muted">{body}</p>
            </div>
          </li>
        ))}
      </ol>

      <p className="text-sm text-muted">Wallet sign-in and challenges are coming in the next milestones.</p>
    </main>
  );
}
