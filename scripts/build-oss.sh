#!/usr/bin/env bash
# Rebuilds the "Open source" block in README.md from merged public PRs.
# Repos below MIN_STARS are dropped, which keeps the list to projects worth naming.
set -euo pipefail

USER="${OSS_USER:-luccinmasirika}"
MIN_STARS="${OSS_MIN_STARS:-1000}"
README="${OSS_README:-README.md}"
OVERRIDES="${OSS_OVERRIDES:-oss.json}"

START="<!-- OSS:START -->"
END="<!-- OSS:END -->"

fmt_stars() {
  awk -v n="$1" 'BEGIN { if (n >= 1000) printf "%.1fk", n/1000; else printf "%d", n }'
}

# Public only: private employer repos must never reach a public profile.
prs=$(gh search prs --author="$USER" --merged --visibility public --limit 100 \
  --json repository,number,title,url |
  jq --arg u "$USER" '[.[] | select(.repository.nameWithOwner | startswith($u + "/") | not)]')

overrides='{}'
[ -f "$OVERRIDES" ] && overrides=$(cat "$OVERRIDES")

rows=""
for repo in $(jq -r '[.[].repository.nameWithOwner] | unique[]' <<<"$prs"); do
  meta=$(gh repo view "$repo" --json stargazerCount,primaryLanguage)
  stars=$(jq -r '.stargazerCount' <<<"$meta")
  [ "$stars" -lt "$MIN_STARS" ] && continue
  lang=$(jq -r '.primaryLanguage.name // empty' <<<"$meta")

  line="- **$(fmt_stars "$stars") ★** &nbsp; [${repo}](https://github.com/${repo})"
  [ -n "$lang" ] && line="${line} &nbsp;<sub>\`${lang}\`</sub>"
  line="${line}<br />"

  # Newest PR first, so a fresh contribution leads the repo's line.
  for num in $(jq -r --arg r "$repo" '[.[] | select(.repository.nameWithOwner == $r) | .number] | sort | reverse[]' <<<"$prs"); do
    title=$(jq -r --arg r "$repo" --argjson n "$num" '.[] | select(.repository.nameWithOwner == $r and .number == $n) | .title' <<<"$prs")
    desc=$(jq -r --arg k "${repo}#${num}" --arg t "$title" '.[$k] // $t' <<<"$overrides")
    line="${line}"$'\n'"  ${desc} — [#${num}](https://github.com/${repo}/pull/${num}), merged."
  done

  # Fold the block onto one sortable row; \n placeholders are expanded after sorting.
  rows="${rows}${stars}"$'\t'"$(printf '%s' "$line" | awk '{ printf "%s%s", (NR > 1 ? "\\n" : ""), $0 }')"$'\n'
done

if [ -z "$rows" ]; then
  echo "build-oss: no repo above ${MIN_STARS} stars — refusing to blank the section" >&2
  exit 1
fi

block=$(sort -rn <<<"$rows" | cut -f2- | sed 's/\\n/\n/g')

export BLOCK="$block" START END
python3 - "$README" <<'PY'
import os, re, sys

path = sys.argv[1]
start, end = os.environ["START"], os.environ["END"]
body = open(path, encoding="utf-8").read()
new = f"{start}\n\n{os.environ['BLOCK'].strip()}\n\n{end}"
out, n = re.subn(re.escape(start) + r".*?" + re.escape(end), lambda _: new, body, flags=re.S)
if n != 1:
    sys.exit(f"build-oss: expected 1 marker pair in {path}, found {n}")
open(path, "w", encoding="utf-8").write(out)
PY
