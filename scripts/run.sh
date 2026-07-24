#!/usr/bin/env bash
# kalshi-soccer-blowout-watch — cloud version
# Ported from the local PowerShell SKILL.md logic. Runs from within the
# soccer-blowout-state repo checkout (state.json lives at repo root).
#
# Designed to be invoked externally every 8 minutes; each invocation does
# exactly one poll and exits. Outside the active window it's a no-op with
# zero API calls.
set -uo pipefail

API_KEY="31a5749aaa40879147b7ac6dd16d1783"
NTFY_TOPIC="fcalertjoshbragg"
TZ_NAME="America/Chicago"
ACTIVE_START_HOUR=10   # inclusive, local TZ_NAME time
ACTIVE_END_HOUR=22     # exclusive, local TZ_NAME time (i.e. up to 10pm)

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$REPO_DIR/state.json"
cd "$REPO_DIR"

api_call() {
  curl -s -H "x-apisports-key: $API_KEY" "https://v3.football.api-sports.io/fixtures?date=$1&timezone=America/Chicago"
}

send_ntfy() {
  curl -s -X POST --data-binary "$1" -H "Content-Type: text/plain; charset=utf-8" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null
}

# lowercase, then truncate to 8 chars (trim a trailing space left by the cut)
fmt_name() {
  local n
  n=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  if [ "${#n}" -gt 8 ]; then
    n="${n:0:8}"
    n="${n% }"
  fi
  echo "$n"
}

commit_state() {
  git add state.json
  if ! git diff --cached --quiet; then
    git -c user.email="cloud-agent@local" -c user.name="soccer-blowout-cloud-agent" commit -q -m "state update $(date -u +%FT%TZ)"
    for attempt in 1 2 3; do
      git pull --rebase -q origin main && git push -q origin main && break
      sleep 3
    done
  fi
}

DONE_SET="FT AET PEN CANC ABD AWD WO PST"

today_central=$(TZ="$TZ_NAME" date +%Y-%m-%d)
hour_central=$(TZ="$TZ_NAME" date +%H)
hour_central=$((10#$hour_central))

if [ "$hour_central" -lt "$ACTIVE_START_HOUR" ] || [ "$hour_central" -ge "$ACTIVE_END_HOUR" ]; then
  echo "Outside active window (${ACTIVE_START_HOUR}:00-${ACTIVE_END_HOUR}:00 $TZ_NAME) — dormant."
  exit 0
fi

if [ ! -f "$STATE_FILE" ] || ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
  echo '{"date":null,"alerted":{}}' > "$STATE_FILE"
fi

state_date=$(jq -r '.date' "$STATE_FILE")
if [ "$state_date" != "$today_central" ]; then
  jq -n --arg d "$today_central" '{date:$d, alerted:{}}' > "$STATE_FILE"
  commit_state
fi

resp=$(api_call "$today_central")
lines=()
now_epoch=$(date -u +%s)

while IFS=$'\t' read -r fid status elapsed home away gh ga fdate; do
  [ -z "$fid" ] && continue
  is_done=false
  for s in $DONE_SET; do [ "$status" = "$s" ] && is_done=true; done
  if [ "$is_done" = false ]; then
    fdate_epoch=$(date -u -d "$fdate" +%s)
    age=$(( now_epoch - fdate_epoch ))
    [ "$age" -gt $((5*3600)) ] && is_done=true
  fi

  already=$(jq -c --arg id "$fid" '.alerted[$id] // empty' "$STATE_FILE")
  gap=$(( gh > ga ? gh - ga : ga - gh ))

  if [ -z "$already" ]; then
    if [ "$status" = "2H" ] && [ "$elapsed" -ge 70 ] 2>/dev/null && [ "$gap" -ge 2 ]; then
      h_s=$(fmt_name "$home")
      a_s=$(fmt_name "$away")
      lines+=("$(printf "%s' %s (%s) vs (%s) %s" "$elapsed" "$h_s" "$gh" "$ga" "$a_s")")
      jq --arg id "$fid" --arg h "$home" --arg a "$away" --argjson gh "$gh" --argjson ga "$ga" \
        '.alerted[$id] = {home:$h, away:$a, goalsHome:$gh, goalsAway:$ga}' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    fi
  else
    prev_gh=$(echo "$already" | jq -r '.goalsHome')
    prev_ga=$(echo "$already" | jq -r '.goalsAway')
    prev_gap=$(( prev_gh > prev_ga ? prev_gh - prev_ga : prev_ga - prev_gh ))
    prev_leader="tie"; [ "$prev_gh" -gt "$prev_ga" ] && prev_leader="home"; [ "$prev_ga" -gt "$prev_gh" ] && prev_leader="away"
    cur_leader="tie"; [ "$gh" -gt "$ga" ] && cur_leader="home"; [ "$ga" -gt "$gh" ] && cur_leader="away"
    if [ "$gap" -lt "$prev_gap" ] || [ "$cur_leader" != "$prev_leader" ]; then
      h_s=$(fmt_name "$home")
      a_s=$(fmt_name "$away")
      lines+=("$(printf "update: %s' %s (%s) vs (%s) %s" "$elapsed" "$h_s" "$gh" "$ga" "$a_s")")
    fi
    if [ "$gh" != "$prev_gh" ] || [ "$ga" != "$prev_ga" ]; then
      jq --arg id "$fid" --arg h "$home" --arg a "$away" --argjson gh "$gh" --argjson ga "$ga" \
        '.alerted[$id] = {home:$h, away:$a, goalsHome:$gh, goalsAway:$ga}' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    fi
    [ "$is_done" = true ] && { jq --arg id "$fid" 'del(.alerted[$id])' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"; }
  fi
done < <(echo "$resp" | jq -r '.response[] | [.fixture.id, .fixture.status.short, (.fixture.status.elapsed // 0), .teams.home.name, .teams.away.name, .goals.home, .goals.away, .fixture.date] | @tsv')

if [ "${#lines[@]}" -gt 0 ]; then
  body=$(printf '%s\n' "${lines[@]}")
  body="${body%$'\n'}"
  send_ntfy "$body"
  echo "Alerted: $body"
fi

commit_state
echo "Poll complete for $today_central."
