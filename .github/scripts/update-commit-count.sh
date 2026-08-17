#!/usr/bin/env bash
set -euo pipefail

# 안전한 total-commits 계산 스크립트 (private 포함하려면 GH_PAT에 repo 권한)
API="https://api.github.com"

# Accept GH_PAT or GH_TOKEN
if [ -n "${GH_PAT:-}" ]; then
  AUTH_TOKEN="$GH_PAT"
elif [ -n "${GH_TOKEN:-}" ]; then
  AUTH_TOKEN="$GH_TOKEN"
else
  echo "GH_PAT or GH_TOKEN is not set. Exiting. Add a repository secret named GH_PAT (or GH_TOKEN)."
  exit 0
fi

AUTH_HEADER="Authorization: token ${AUTH_TOKEN}"

# Get authenticated user login
user=$(curl -s -H "$AUTH_HEADER" "$API/user" | jq -r .login)
if [ -z "$user" ] || [ "$user" = "null" ]; then
  echo "Failed to determine authenticated user. Check token permissions."
  exit 1
fi

page=1
total=0

while :; do
  repos_json=$(curl -s -H "$AUTH_HEADER" "$API/user/repos?per_page=100&affiliation=owner&page=${page}")
  # If response not array, stop
  repo_count=$(echo "$repos_json" | jq 'if (type == "array") then length else 0 end' 2>/dev/null || echo 0)
  repo_count=${repo_count:-0}
  repo_count=$(echo "$repo_count" | tr -d '\r\n" ')
  if ! [[ "$repo_count" =~ ^[0-9]+$ ]]; then
    echo "Warning: repo_count is not an integer ('$repo_count'), stopping."
    break
  fi
  if [ "$repo_count" -eq 0 ]; then
    break
  fi

  for i in $(seq 0 $((repo_count-1))); do
    repo_name=$(echo "$repos_json" | jq -r ".[$i].name")
    owner_login=$(echo "$repos_json" | jq -r ".[$i].owner.login")

    # contributors endpoint (requires token for private repos)
    contribs_json=$(curl -s -H "$AUTH_HEADER" "$API/repos/${owner_login}/${repo_name}/contributors?per_page=100")
    contrib_count=$(echo "$contribs_json" | jq --arg user "$user" -r 'map(select(.login == $user))[0].contributions // 0')
    total=$((total + contrib_count))
  done

  page=$((page + 1))
done

echo "Calculated total commits (from contributors endpoint): $total"

# Update README: prefer replacing the <!-- TOTAL_COMMITS --> block if present
if grep -q "<!-- TOTAL_COMMITS -->" README.md; then
  tmp=$(mktemp)
  awk -v val="Total Commits: ${total}" '
    BEGIN{inside=0}
    /<!-- TOTAL_COMMITS -->/ { print; print val; inside=1; next }
    /<!-- \/TOTAL_COMMITS -->/ { print; inside=0; next }
    { if (!inside) print }
  ' README.md > "$tmp"
  mv "$tmp" README.md
else
  # Fallback: replace first "Total Commits: <num>" line or insert after "My GitHub Stats"
  if grep -qE "Total Commits:\\s*[0-9]+" README.md; then
    tmp=$(mktemp)
    sed -E "0,/Total Commits:\\s*[0-9]+/s//Total Commits: ${total}/" README.md > "$tmp"
    mv "$tmp" README.md
  elif grep -q "My GitHub Stats" README.md; then
    tmp=$(mktemp)
    awk -v k="Total Commits: ${total}" '1 { print } /My GitHub Stats/ && !x { print "\n" k; x=1 }' README.md > "$tmp"
    mv "$tmp" README.md
  else
    echo -e "\nTotal Commits: ${total}" >> README.md
  fi
fi

echo "README updated with total commits: ${total}"