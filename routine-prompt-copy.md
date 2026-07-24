# Copy of the soccer-blowout alerting routine prompt (for modification)

Copied 2026-07-24 from the hourly scheduled routine. Edit this file, then paste
the final text into a new Trigger / scheduled task in the Claude Code settings UI.
Replace `<GITHUB_PAT>` with the real token (kept out of this file so GitHub
push protection doesn't reject the commit).

## Suggested edits for the new 8-minute cadence

The script was reworked (`cfeb735`) to do exactly ONE poll per invocation and
exit — it no longer sleeps ~9 min between polls internally. So a copy meant to
run every 8 minutes should:

- Change "hourly invocation" to "8-minute invocation".
- Drop the language about the script polling up to 6 times and running for
  close to an hour; it now runs for seconds.
- Keep everything else (clone step, hard rules) as is.

## Original prompt (verbatim, token redacted)

```
You are running the hourly invocation of an unattended soccer-blowout alerting task. Everything you need is scripted — your job is to clone the state repo, run the script, and report briefly. Do NOT improvise, redesign, or add extra API calls.

Steps:
1. Clone the private state repo (token embedded in URL, this is intentional):
   git clone https://<GITHUB_PAT>@github.com/bragg21kb-ux/soccer-blowout-state.git ~/soccer-blowout-state
2. Run the polling script and let it manage everything (it polls the API-Football fixtures endpoint up to 6 times ~9-10 min apart to cover this hour, sends ntfy notifications for qualifying blowouts, and commits/pushes state.json updates back to the repo):
   cd ~/soccer-blowout-state && bash scripts/run.sh
   The script may legitimately run for close to an hour (it sleeps ~9 min between polls). Let it finish; do not kill it early.
3. If the script exits early with a 'dormant' or 'day complete' or 'no games' message, that is normal and correct — just report it and stop.
4. If the script errors (e.g. jq missing, network failure), try to fix the environment minimally (e.g. install jq via apt-get or use a preinstalled equivalent) and re-run ONCE. If it still fails, report the exact error output clearly and stop — do not attempt to reimplement the logic inline.
5. End with a one-paragraph report: which branch the script took (dormant / active polls / day complete / no games), any notifications sent (quote the alert lines), and any anomalies.

Hard rules: never call the API-Football endpoint yourself outside the script (100 req/day cap); never post to ntfy.sh/fcalertjoshbragg except via the script; never print the GitHub token in your report; never force-push or delete anything in the repo.
```

## Modified version (ready for an every-8-minutes trigger)

```
You are running one 8-minute-cadence invocation of an unattended soccer-blowout alerting task. Everything you need is scripted — your job is to clone the state repo, run the script once, and report briefly. Do NOT improvise, redesign, or add extra API calls.

Steps:
1. Clone the private state repo (token embedded in URL, this is intentional):
   git clone https://<GITHUB_PAT>@github.com/bragg21kb-ux/soccer-blowout-state.git ~/soccer-blowout-state
2. Run the polling script and let it manage everything (each invocation does exactly one poll of the API-Football fixtures endpoint, sends ntfy notifications for qualifying blowouts, and commits/pushes state.json updates back to the repo):
   cd ~/soccer-blowout-state && bash scripts/run.sh
   It runs for a few seconds and exits.
3. If the script exits with a 'dormant' or 'day complete' or 'no games' message, that is normal and correct — just report it and stop.
4. If the script errors (e.g. jq missing, network failure), try to fix the environment minimally (e.g. install jq via apt-get or use a preinstalled equivalent) and re-run ONCE. If it still fails, report the exact error output clearly and stop — do not attempt to reimplement the logic inline.
5. End with a one-paragraph report: which branch the script took (dormant / one poll / day complete / no games), any notifications sent (quote the alert lines), and any anomalies.

Hard rules: never call the API-Football endpoint yourself outside the script; never post to ntfy.sh/fcalertjoshbragg except via the script; never print the GitHub token in your report; never force-push or delete anything in the repo.
```
