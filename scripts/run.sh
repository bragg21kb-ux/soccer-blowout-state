#!/usr/bin/env bash
# soccer-blowout-watch
# End goal: concise ntfy alerts for blowout games — second half, 70'+,
# leading by 2+ goals — refreshed every 8 minutes, 10:00-22:00 America/Chicago.
#
# Invoked hourly by the scheduled routine. Each run polls POLLS times,
# 8 minutes apart (~56 min, covering its hour), then exits. Outside the
# active window it exits immediately with zero API calls.
# API budget: 12 active hours x 7 polls = 84 calls/day (cap 100).
set -uo pipefail

API_KEY="31a5749aaa40879147b7ac6dd16d1783"
NTFY_TOPIC="fcalertjoshbragg"
TZ_NAME="America/Chicago"
START_HOUR=10   # inclusive, local time
END_HOUR=22     # exclusive, local time
POLLS="${1:-7}" # override for testing or partial-hour runs, e.g. `run.sh 1`
INTERVAL=480    # 8 minutes
DONE_STATUSES=" FT AET PEN CANC ABD AWD WO PST "

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$REPO/state.json"
cd "$REPO"

in_window() {
  local h=$((10#$(TZ="$TZ_NAME" date +%H)))
  [ "$h" -ge "$START_HOUR" ] && [ "$h" -lt "$END_HOUR" ]
}

short() { # team name -> lowercase, max 7 chars, no trailing space
  local n="${1,,}"
  n="${n:0:7}"
  echo "${n% }"
}

leader() { # gh ga -> home|away|tie
  if   [ "$1" -gt "$2" ]; then echo home
  elif [ "$2" -gt "$1" ]; then echo away
  else echo tie
  fi
}

# P(losing team comes back to WIN) by minutes elapsed and goal deficit.
# Skellam model calibrated to historical down-2/down-3 comeback rates.
# Alerts only fire at 2H/70'+, so buckets start at 70.
cb_prob() {
  local elapsed=$1 gap=$2 row
  if   [ "$elapsed" -ge 90 ]; then row="0.18 0.01 0.00"
  elif [ "$elapsed" -ge 85 ]; then row="0.50 0.04 0.00"
  elif [ "$elapsed" -ge 80 ]; then row="1.00 0.12 0.01"
  elif [ "$elapsed" -ge 75 ]; then row="1.67 0.24 0.03"
  else                             row="2.49 0.43 0.06"
  fi
  set -- $row
  case "$gap" in
    0|1|2) echo "$1" ;;
    3)     echo "$2" ;;
    4)     echo "$3" ;;
    *)     echo "0.00" ;;
  esac
}

# elapsed gh ga home away gap [prefix] -> one concise alert line,
# comeback-win % appended to the trailing side's name
line_for() {
  local el=$1 gh=$2 ga=$3 gap=$6 prefix="${7:-}" h a cb
  h=$(short "$4"); a=$(short "$5")
  if [ "$gap" -ge 2 ]; then
    cb=$(cb_prob "$el" "$gap")
    if [ "$gh" -gt "$ga" ]; then a="$a ${cb}%"; else h="$h ${cb}%"; fi
  fi
  printf "%s%s' %s %s vs %s %s" "$prefix" "$el" "$h" "$gh" "$ga" "$a"
}

remember() { # id home away gh ga
  jq --arg id "$1" --arg h "$2" --arg a "$3" --argjson gh "$4" --argjson ga "$5" \
    '.alerted[$id] = {home:$h, away:$a, goalsHome:$gh, goalsAway:$ga}' \
    "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

forget() { # id
  jq --arg id "$1" 'del(.alerted[$id])' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

push_state() {
  git add state.json
  git diff --cached --quiet && return 0
  git -c user.email="cloud-agent@local" -c user.name="soccer-blowout-cloud-agent" \
    commit -q -m "state update $(date -u +%FT%TZ)"
  local i
  for i in 1 2 3; do
    git pull --rebase -q origin main && git push -q origin main && return 0
    sleep 3
  done
}

poll_once() {
  local today resp lines=()
  today=$(TZ="$TZ_NAME" date +%F)
  jq -e --arg d "$today" '.date == $d' "$STATE" >/dev/null 2>&1 ||
    jq -n --arg d "$today" '{date:$d, alerted:{}}' > "$STATE"

  resp=$(curl -s -H "x-apisports-key: $API_KEY" \
    "https://v3.football.api-sports.io/fixtures?date=$today&timezone=$TZ_NAME")

  local id st el home away gh ga gap prev finished pgh pga pgap
  while IFS=$'\t' read -r id st el home away gh ga; do
    [ -z "$id" ] && continue
    gap=$(( gh > ga ? gh - ga : ga - gh ))
    finished=false
    case "$DONE_STATUSES" in *" $st "*) finished=true ;; esac
    prev=$(jq -c --arg id "$id" '.alerted[$id] // empty' "$STATE")

    if [ -z "$prev" ]; then
      # new blowout: second half, 70'+, up by 2+
      if [ "$st" = "2H" ] && [ "$el" -ge 70 ] && [ "$gap" -ge 2 ]; then
        lines+=("$(line_for "$el" "$gh" "$ga" "$home" "$away" "$gap")")
        remember "$id" "$home" "$away" "$gh" "$ga"
      fi
    else
      pgh=$(jq -r '.goalsHome' <<<"$prev")
      pga=$(jq -r '.goalsAway' <<<"$prev")
      pgap=$(( pgh > pga ? pgh - pga : pga - pgh ))
      # follow-up only when the game tightens: gap shrank or leader changed
      if [ "$gap" -lt "$pgap" ] || [ "$(leader "$gh" "$ga")" != "$(leader "$pgh" "$pga")" ]; then
        lines+=("$(line_for "$el" "$gh" "$ga" "$home" "$away" "$gap" "update: ")")
      fi
      if [ "$gh" -ne "$pgh" ] || [ "$ga" -ne "$pga" ]; then
        remember "$id" "$home" "$away" "$gh" "$ga"
      fi
      [ "$finished" = true ] && forget "$id"
    fi
  done < <(jq -r '.response[] | [.fixture.id, .fixture.status.short,
      (.fixture.status.elapsed // 0), .teams.home.name, .teams.away.name,
      (.goals.home // 0), (.goals.away // 0)] | @tsv' <<<"$resp")

  if [ "${#lines[@]}" -gt 0 ]; then
    local body
    body=$(printf '%s\n' "${lines[@]}")
    curl -s -X POST --data-binary "$body" \
      -H "Content-Type: text/plain; charset=utf-8" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null
    echo "Alerted: $body"
  fi
  push_state
}

if ! in_window; then
  echo "Dormant — outside ${START_HOUR}:00-${END_HOUR}:00 $TZ_NAME."
  exit 0
fi

[ -f "$STATE" ] && jq -e . "$STATE" >/dev/null 2>&1 || echo '{"date":null,"alerted":{}}' > "$STATE"

for (( i=1; i<=POLLS; i++ )); do
  poll_once
  echo "Poll $i/$POLLS complete at $(TZ="$TZ_NAME" date +%H:%M) $TZ_NAME."
  if [ "$i" -lt "$POLLS" ]; then
    sleep "$INTERVAL"
    in_window || { echo "Active window closed — stopping."; break; }
  fi
done
echo "Run complete for $(TZ="$TZ_NAME" date +%F)."
