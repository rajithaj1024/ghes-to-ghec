#!/usr/bin/env bash
set -euo pipefail

# GHES -> GitHub post-migration validation
# repos.csv schema:
#   ghes_org,ghes_repo,repo_url,repo_size_MB,github_org,github_repo,gh_repo_visibility
# Uses only: ghes_org, ghes_repo, github_org, github_repo (ignores rest). 

# ----------------------------
# Required env vars
# ----------------------------
: "${GH_SOURCE_PAT:?Environment variable GH_SOURCE_PAT is not set (source GHES token)}"
: "${GH_PAT:?Environment variable GH_PAT is not set (target GitHub token for gh cli)}"
: "${GHES_API_URL:?Environment variable GHES_API_URL is not set (e.g. https://ghe.example.com/api/v3)}"
GHES_API_URL="${GHES_API_URL%/}"  # trim trailing slash

# ----------------------------
# Logging
# ----------------------------
LOG_FILE="validation-log-$(date +%Y%m%d).txt"
# ----------------------------
# Target
# ----------------------------
TARGET_HOST="${GH_TARGET_HOST:-github.com}"
export GH_HOST="$TARGET_HOST"

write_log() {
  local message="$1"
  echo "$message" | tee -a "$LOG_FILE"
}

# ----------------------------
# Helpers
# ----------------------------
is_json() { jq -e . >/dev/null 2>&1; }

# URL-encode using jq
urlencode() { jq -rn --arg s "$1" '$s|@uri'; }

# Extract "next" URL from Link header (pagination)
get_next_link() {
  local headers_file="$1"
  awk -F': ' 'tolower($1)=="link"{print $2}' "$headers_file" \
    | tr ',' '\n' \
    | sed -n 's/.*<\(.*\)>; rel="next".*/\1/p' \
    | head -n 1
}

# Robust CSV line parser (quoted fields, escaped quotes)
parse_csv_line() {
  local line="$1"
  local -a fields=()
  local field="" in_quotes=false i char next
  for ((i=0; i<${#line}; i++)); do
    char="${line:$i:1}"
    next="${line:$((i+1)):1}"
    if [[ "${char}" == '"' ]]; then
      if [[ "${in_quotes}" == true ]]; then
        if [[ "${next}" == '"' ]]; then
          field+='"'; ((i++))
        else
          in_quotes=false
        fi
      else
        in_quotes=true
      fi
    elif [[ "${char}" == ',' && "${in_quotes}" == false ]]; then
      fields+=("${field}")
      field=""
    else
      field+="${char}"
    fi
  done
  fields+=("${field}")
  printf '%s\n' "${fields[@]}"
}

strip_quotes() {
  local s="$1"
  [[ ${s} == \"* ]] && s="${s#\"}"
  [[ ${s} == *\" ]] && s="${s%\"}"
  printf '%s' "$s"
}

# ----------------------------
# GHES helpers (source)
# ----------------------------
ghes_api_get_to_file() {
  # args: url headers_file body_file
  local url="$1" headers_file="$2" body_file="$3"
  curl -sS -D "$headers_file" -o "$body_file" \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: token ${GH_SOURCE_PAT}" \
    "$url"
}

# Get GHES branches with Link pagination; returns JSON array
get_ghes_branches_json() {
  local org="$1" repo="$2"

  local tmp_headers; tmp_headers="$(mktemp)"
  local tmp_body; tmp_body="$(mktemp)"

  local enc_org enc_repo
  enc_org="$(urlencode "$org")"
  enc_repo="$(urlencode "$repo")"

  local url="${GHES_API_URL}/repos/${enc_org}/${enc_repo}/branches?per_page=100"
  local all='[]'

  while [[ -n "$url" ]]; do
    ghes_api_get_to_file "$url" "$tmp_headers" "$tmp_body"

    if ! cat "$tmp_body" | is_json; then
      # Return raw body for troubleshooting
      cat "$tmp_body"
      rm -f "$tmp_headers" "$tmp_body"
      return 1
    fi

    # Append page array -> accumulator
    local page_json
    page_json="$(cat "$tmp_body")"
    all="$(jq -c -n --argjson a "$all" --argjson b "$page_json" '$a + $b')"

    url="$(get_next_link "$tmp_headers")"
  done

  rm -f "$tmp_headers" "$tmp_body"
  echo "$all"
}

# Get GHES commit count + latest sha for a branch (page/per_page loop)
get_ghes_commit_count_and_latest() {
  local org="$1" repo="$2" branch="$3"
  local page=1 per_page=100
  local count=0 latest=""

  local enc_org enc_repo enc_branch
  enc_org="$(urlencode "$org")"
  enc_repo="$(urlencode "$repo")"
  enc_branch="$(urlencode "$branch")"

  while true; do
    local url="${GHES_API_URL}/repos/${enc_org}/${enc_repo}/commits?sha=${enc_branch}&per_page=${per_page}&page=${page}"
    local resp
    resp="$(curl -sS \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: token ${GH_SOURCE_PAT}" \
      "$url" 2>/dev/null)" || break

    if ! echo "$resp" | is_json; then
      break
    fi

    local batch_len
    batch_len="$(echo "$resp" | jq 'length')" || batch_len=0
    if [[ $page -eq 1 && "$batch_len" -gt 0 ]]; then
      latest="$(echo "$resp" | jq -r '.[0].sha // empty')"
    fi
    count=$((count + batch_len))

    ((page++))
    [[ "$batch_len" -lt "$per_page" ]] && break
  done

  echo "${count}|${latest}"
}

# ----------------------------
# GitHub helpers (target) using gh CLI
# ----------------------------
get_github_branches_json() {
  local org="$1" repo="$2"
  gh api "/repos/$org/$repo/branches" --paginate 2>/dev/null
}

get_github_commit_count_and_latest() {
  local org="$1" repo="$2" branch="$3"
  local page=1 per_page=100
  local count=0 latest=""

  local enc_branch
  enc_branch="$(printf '%s' "$branch" | jq -sRr @uri)"

  while true; do
    local resp
    resp="$(gh api "/repos/$org/$repo/commits?sha=$enc_branch&page=$page&per_page=$per_page" 2>/dev/null)" || break
    if ! echo "$resp" | is_json; then
      break
    fi

    local batch_len
    batch_len="$(echo "$resp" | jq 'length')" || batch_len=0
    if [[ $page -eq 1 && "$batch_len" -gt 0 ]]; then
      latest="$(echo "$resp" | jq -r '.[0].sha // empty')"
    fi
    count=$((count + batch_len))

    ((page++))
    [[ "$batch_len" -lt "$per_page" ]] && break
  done

  echo "${count}|${latest}"
}

# ----------------------------
# Validation logic
# ----------------------------
validate_migration() {
  local ghes_org="$1"
  local ghes_repo="$2"
  local github_org="$3"
  local github_repo="$4"

  write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Validating migration: ${ghes_org}/${ghes_repo} -> ${github_org}/${github_repo}"

  # Optional GitHub repo info
  gh repo view "$github_org/$github_repo" --json createdAt,diskUsage,defaultBranchRef,isPrivate > "validation-$github_repo.json" 2>/dev/null || true

  # Target GitHub branches
  local gh_branches
  gh_branches="$(get_github_branches_json "$github_org" "$github_repo")" || {
    write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: Failed to fetch GitHub branches for $github_org/$github_repo"
    return 1
  }
  if ! echo "$gh_branches" | is_json; then
    write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: GitHub branch response is not JSON. Starts: $(echo "$gh_branches" | head -c 200)"
    return 1
  fi
  mapfile -t gh_branch_array < <(echo "$gh_branches" | jq -r '.[].name')

  # Source GHES branches (fixed pagination)
  local ghes_branches
  ghes_branches="$(get_ghes_branches_json "$ghes_org" "$ghes_repo")" || {
    write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: Failed to fetch GHES branches for $ghes_org/$ghes_repo"
    return 1
  }
  if ! echo "$ghes_branches" | is_json; then
    write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: GHES branch response is not JSON. Starts: $(echo "$ghes_branches" | head -c 200)"
    return 1
  fi
  mapfile -t ghes_branch_array < <(echo "$ghes_branches" | jq -r '.[].name')

  # Compare branch counts
  local gh_branch_count=${#gh_branch_array[@]}
  local ghes_branch_count=${#ghes_branch_array[@]}
  local branch_count_status="❌ Not Matching"
  [[ "$gh_branch_count" -eq "$ghes_branch_count" ]] && branch_count_status="✅ Matching"
  write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Branch Count: GHES=$ghes_branch_count | GitHub=$gh_branch_count | $branch_count_status"

  # Compare branch names
  local missing_in_github=()
  local missing_in_ghes=()
  local ghes_set=" ${ghes_branch_array[*]} "
  local gh_set=" ${gh_branch_array[*]} "

  for b in "${ghes_branch_array[@]}"; do
    [[ "$gh_set" != *" $b "* ]] && missing_in_github+=("$b")
  done
  for b in "${gh_branch_array[@]}"; do
    [[ "$ghes_set" != *" $b "* ]] && missing_in_ghes+=("$b")
  done

  [[ ${#missing_in_github[@]} -gt 0 ]] && write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Branches missing in GitHub: ${missing_in_github[*]}"
  [[ ${#missing_in_ghes[@]} -gt 0 ]] && write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Branches missing in GHES: ${missing_in_ghes[*]}"

  # Validate commit counts and latest commit IDs for branches present in both
  for branch_name in "${gh_branch_array[@]}"; do
    local exists_in_ghes=0
    for sb in "${ghes_branch_array[@]}"; do
      if [[ "$branch_name" == "$sb" ]]; then exists_in_ghes=1; break; fi
    done
    [[ $exists_in_ghes -eq 0 ]] && continue

    # GitHub commits
    local gh_pair gh_commit_count gh_latest_sha
    gh_pair="$(get_github_commit_count_and_latest "$github_org" "$github_repo" "$branch_name")"
    gh_commit_count="${gh_pair%%|*}"
    gh_latest_sha="${gh_pair#*|}"

    # GHES commits
    local ghes_pair ghes_commit_count ghes_latest_sha
    ghes_pair="$(get_ghes_commit_count_and_latest "$ghes_org" "$ghes_repo" "$branch_name")"
    ghes_commit_count="${ghes_pair%%|*}"
    ghes_latest_sha="${ghes_pair#*|}"

    local commit_count_status="❌ Not Matching"
    local sha_status="❌ Not Matching"
    [[ "$gh_commit_count" -eq "$ghes_commit_count" ]] && commit_count_status="✅ Matching"
    [[ -n "$gh_latest_sha" && "$gh_latest_sha" == "$ghes_latest_sha" ]] && sha_status="✅ Matching"

    write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Branch '$branch_name': GHES Commits=$ghes_commit_count | GitHub Commits=$gh_commit_count | $commit_count_status"
    write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Branch '$branch_name': GHES SHA=$ghes_latest_sha | GitHub SHA=$gh_latest_sha | $sha_status"
  done

  write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Validation complete for $github_org/$github_repo"
}

# ----------------------------
# Batch validation from CSV
# ----------------------------
validate_from_csv() {
  local csv_path="${1:-repos.csv}"

  if [[ ! -f "$csv_path" ]]; then
    write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: CSV file not found: $csv_path"
    return 1
  fi

  # Build header index map
  read -r header < "$csv_path"
  mapfile -t H < <(parse_csv_line "$header")

  declare -A IDX=()
  for i in "${!H[@]}"; do
    key="$(strip_quotes "${H[$i]}")"
    IDX["$key"]="$i"
  done

  # Validate required columns exist
  local required=(ghes_org ghes_repo github_org github_repo)
  local miss=()
  for k in "${required[@]}"; do
    [[ -n "${IDX[$k]:-}" ]] || miss+=("$k")
  done
  if [[ ${#miss[@]} -gt 0 ]]; then
    write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: CSV missing required columns: ${miss[*]}"
    return 1
  fi

  tail -n +2 "$csv_path" | while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] && continue

    mapfile -t F < <(parse_csv_line "$line")

    local ghes_org ghes_repo github_org github_repo
    ghes_org="$(strip_quotes "${F[${IDX[ghes_org]}]}")"
    ghes_repo="$(strip_quotes "${F[${IDX[ghes_repo]}]}")"
    github_org="$(strip_quotes "${F[${IDX[github_org]}]}")"
    github_repo="$(strip_quotes "${F[${IDX[github_repo]}]}")"

    write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Processing: ${ghes_org}/${ghes_repo} -> ${github_org}/${github_repo}"
    validate_migration "$ghes_org" "$ghes_repo" "$github_org" "$github_repo"
  done

  write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] All validations from CSV completed"
}

# Run batch mode
validate_from_csv "repos.csv"
