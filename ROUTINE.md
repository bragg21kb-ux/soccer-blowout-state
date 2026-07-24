# Scheduled routine prompt (canonical)

Trigger cadence: **hourly** — the script itself owns the 8-minute update
interval (7 polls per invocation, ~56 min, covering each hour). Active window
10:00–22:00 America/Chicago; outside it each invocation is a zero-API no-op.
API budget: 12 h × 7 = 84 calls/day, under the 100/day cap.

Paste the block below as the trigger prompt, replacing `<GITHUB_PAT>` with the
real token. This supersedes `routine-prompt-copy.md`.

```
You are running one hourly invocation of an unattended soccer-blowout alerting routine. Everything is scripted — clone the state repo, run the script, report briefly. Do NOT improvise, redesign, or add extra API calls.

1. Clone the private state repo (token embedded in URL, this is intentional):
   git clone https://<GITHUB_PAT>@github.com/bragg21kb-ux/soccer-blowout-state.git ~/soccer-blowout-state
2. Run: cd ~/soccer-blowout-state && bash scripts/run.sh
   Between 10:00 and 22:00 America/Chicago it polls the API-Football fixtures endpoint 7 times, 8 minutes apart (~56 minutes total), sends concise ntfy alerts for qualifying blowouts, and commits/pushes state.json back to the repo. Let it run to completion — do not kill it early. Outside that window it prints "Dormant" and exits immediately.
3. If the script errors (e.g. jq missing, network failure), fix the environment minimally (e.g. install jq via apt-get) and re-run ONCE. If it still fails, report the exact error output and stop — do not reimplement the logic inline.
4. End with a one-paragraph report: dormant or how many polls ran, quote any "Alerted:" lines verbatim, and note anomalies.

Hard rules: never call the API-Football endpoint outside the script (100 req/day cap; the script budgets 84/day); never post to ntfy.sh/fcalertjoshbragg except via the script; never print the GitHub token in your report; never force-push or delete anything in the repo.
```

## Alert format

- New blowout (2nd half, 70'+, up by 2+): `78' chelsea 3 vs 0 fulham 0.12%`
  — game clock, lowercased 7-char team names, score, comeback-win probability
  appended to the trailing side.
- Follow-up only when the game tightens (gap shrinks or leader changes):
  `update: 84' chelsea 3 vs 2 fulham 0.50%`
- Deduplicated per fixture via `state.json`; entries clear when a game
  finishes or the date rolls over.
