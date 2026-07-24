#!/usr/bin/env bash
# kalshi-soccer-blowout-watch — cloud version
# Ported from the local PowerShell SKILL.md logic. Runs from within the
# soccer-blowout-state repo checkout (state.json lives at repo root).
set -uo pipefail

API_KEY="31a5749aaa40879147b7ac6dd16d1783"
NTFY_TOPIC="fcalertjoshbragg"
TZ_NAME="America/Chicago"

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

now_epoch=$(date -u +%s)
today_central=$(TZ="$TZ_NAME" date +%Y-%m-%d)

DONE_SET="FT AET PEN CANC ABD AWD WO PST"

# True (exit 0) if the fixtures response has any fixture that isn't
# finished/abandoned and isn't just a stale (>5h old) record. Used to avoid
# trusting a stale dayComplete=true flag: different leagues kick off at very
# different times across the same Central-time calendar date, so games can
# still be live or yet to start even after an earlier batch finished.
has_pending_fixtures() {
  local resp="$1" now="$2" pending=1
  while IFS=$'\t' read -r fid status elapsed home away gh ga fdate; do
    [ -z "$fid" ] && continue
    local is_done=false
    for s in $DONE_SET; do [ "$status" = "$s" ] && is_done=true; done
    if [ "$is_done" = false ]; then
      local fdate_epoch age
      fdate_epoch=$(date -u -d "$fdate" +%s)
      age=$(( now - fdate_epoch ))
      [ "$age" -gt $((5*3600)) ] && is_done=true
    fi
    [ "$is_done" = false ] && pending=0
  done < <(echo "$resp" | jq -r '.response[] | [.fixture.id, .fixture.status.short, (.fixture.status.elapsed // 0), .teams.home.name, .teams.away.name, .goals.home, .goals.away, .fixture.date] | @tsv')
  return $pending
}

if [ ! -f "$STATE_FILE" ] || ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
  echo '{"date":null,"firstGameStartUtc":null,"dayComplete":true,"alerted":{}}' > "$STATE_FILE"
fi

state_date=$(jq -r '.date' "$STATE_FILE")
day_complete=$(jq -r '.dayComplete' "$STATE_FILE")

if [ "$day_complete" = "false" ]; then
  tracked_date="$state_date"
elif [ "$state_date" = "$today_central" ]; then
  recheck_resp=$(api_call "$today_central")
  if has_pending_fixtures "$recheck_resp" "$now_epoch"; then
    tracked_date="$today_central"
    jq '.dayComplete = false' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    commit_state
    echo "Stale dayComplete flag for $today_central — pending fixtures found, resuming polling."
  else
    echo "Day already closed out for $today_central — dormant, nothing to do."
    exit 0
  fi
else
  tracked_date="$today_central"
  resp=$(api_call "$tracked_date")
  results=$(echo "$resp" | jq -r '.results')
  if [ "$results" = "0" ]; then
    jq -n --arg d "$tracked_date" '{date:$d, firstGameStartUtc:null, dayComplete:true, alerted:{}}' > "$STATE_FILE"
    commit_state
    echo "No games on $tracked_date — dormant."
    exit 0
  fi
  first_kick=$(echo "$resp" | jq -r '[.response[].fixture.date] | sort | .[0]')
  first_kick_utc=$(date -u -d "$first_kick" +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg d "$tracked_date" --arg f "$first_kick_utc" '{date:$d, firstGameStartUtc:$f, dayComplete:false, alerted:{}}' > "$STATE_FILE"
  commit_state
fi

first_kick_utc=$(jq -r '.firstGameStartUtc' "$STATE_FILE")
first_kick_epoch=$(date -u -d "$first_kick_utc" +%s)
plus70_epoch=$((first_kick_epoch + 70*60))
central_date_of_kick=$(TZ="$TZ_NAME" date -d "@$first_kick_epoch" +%Y-%m-%d)
eightam_central_epoch=$(TZ="$TZ_NAME" date -d "$central_date_of_kick 08:00" +%s)
activation_epoch=$plus70_epoch
[ "$eightam_central_epoch" -gt "$activation_epoch" ] && activation_epoch=$eightam_central_epoch

if [ "$now_epoch" -lt "$activation_epoch" ]; then
  echo "Dormant until activation at $(date -u -d "@$activation_epoch" +%Y-%m-%dT%H:%M:%SZ)"
  exit 0
fi

for i in $(seq 1 6); do
  resp=$(api_call "$tracked_date")
  lines=()
  all_done=true
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
    [ "$is_done" = false ] && all_done=false

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

  if [ "$all_done" = true ]; then
    jq '.dayComplete = true' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    commit_state
    echo "Day complete as of $(date -u +%Y-%m-%dT%H:%M:%SZ)."
    break
  else
    commit_state
    echo "Poll $i/6 done, no day-complete yet."
    [ "$i" -lt 6 ] && sleep 540
  fi
done

echo "Invocation finished."
