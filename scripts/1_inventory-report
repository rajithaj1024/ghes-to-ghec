#!/usr/bin/env bash
set -euo pipefail

# ------------------------------
# Config
# ------------------------------
read -r -p "Enter the ORG name: " ORG
ORG="${ORG%\"}"
ORG="${ORG#\"}"

: "${GH_SOURCE_PAT:?Environment variable GH_SOURCE_PAT is not set}"
: "${GHES_API_URL:?Environment variable GHES_API_URL is not set}"

GH_SOURCE_PAT="${GH_SOURCE_PAT}"
API_BASE="${GHES_API_URL%/}"
OUT_FILE="repos.csv"

# ------------------------------
# Logging helpers
# ------------------------------
log_info() {
  echo "[INFO]    $*"
}

log_warn() {
  echo "[WARN]    $*" >&2
}

log_error() {
  echo "[ERROR]   $*" >&2
}

log_success() {
  echo "[SUCCESS] $*"
}

# ------------------------------
# Extract next page URL from Link header
# ------------------------------
get_next_link() {
  local link_header="${1:-}"

  [[ -z "$link_header" ]] && return 0

  printf '%s\n' "$link_header" \
    | tr ',' '\n' \
    | sed -n 's/.*<\(.*\)>;[[:space:]]*rel="next".*/\1/p' \
    | head -n 1
}

# ------------------------------
# Make API call
# Returns:
#   stdout: status|body_file|headers_file
# ------------------------------
call_api() {
  local url="$1"
  local body_file headers_file status

  body_file="$(mktemp)"
  headers_file="$(mktemp)"

  status="$(
    curl -sS \
      -D "$headers_file" \
      -o "$body_file" \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GH_SOURCE_PAT}" \
      -w "%{http_code}" \
      "$url"
  )"

  printf '%s|%s|%s\n' "$status" "$body_file" "$headers_file"
}

# ------------------------------
# Cleanup temp files
# ------------------------------
cleanup_files() {
  local body_file="${1:-}"
  local headers_file="${2:-}"

  [[ -n "$body_file" && -f "$body_file" ]] && rm -f "$body_file"
  [[ -n "$headers_file" && -f "$headers_file" ]] && rm -f "$headers_file"
}

# ------------------------------
# Validate org
# ------------------------------
validate_org() {
  local url="${API_BASE}/orgs/${ORG}/repos?per_page=1&type=all"
  local result status body_file headers_file

  result="$(call_api "$url")"
  IFS='|' read -r status body_file headers_file <<< "$result"

  if [[ "$status" == "404" ]]; then
    cleanup_files "$body_file" "$headers_file"
    log_error "Org not found: $ORG"
    exit 1
  fi

  if [[ "$status" == "401" || "$status" == "403" ]]; then
    cleanup_files "$body_file" "$headers_file"
    log_error "Authentication failed or access denied for org: $ORG"
    exit 1
  fi

  if [[ "$status" != "200" ]]; then
    cleanup_files "$body_file" "$headers_file"
    log_error "Failed to validate org: $ORG (HTTP $status)"
    exit 1
  fi

  cleanup_files "$body_file" "$headers_file"
}

# ------------------------------
# Main
# ------------------------------
log_info "Validating organization '$ORG'..."
validate_org

# Keep old header exactly same
echo "ghes_org,ghes_repo,repo_url,repo_size_MB" > "$OUT_FILE"

url="${API_BASE}/orgs/${ORG}/repos?per_page=100&type=all"
repo_count=0

while [[ -n "${url}" ]]; do
  result="$(call_api "$url")"
  IFS='|' read -r status body_file headers_file <<< "$result"

  if [[ "$status" == "404" ]]; then
    cleanup_files "$body_file" "$headers_file"
    log_error "Org not found: $ORG"
    exit 1
  fi

  if [[ "$status" != "200" ]]; then
    cleanup_files "$body_file" "$headers_file"
    log_error "Failed while retrieving repositories for org: $ORG (HTTP $status)"
    exit 1
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    echo "$line" >> "$OUT_FILE"
    repo_count=$((repo_count + 1))
  done < <(
    jq -r '
      .[] |
      "\(.owner.login),\(.name),\(.html_url // ""),\((.size / 1024) | tonumber | . * 100 | round / 100)"
    ' "$body_file"
  )

  link_header="$(awk -F': ' 'tolower($1)=="link"{print $2}' "$headers_file" | tr -d '\r')"
  cleanup_files "$body_file" "$headers_file"

  url="$(get_next_link "$link_header")"
done

if [[ "$repo_count" -eq 0 ]]; then
  log_warn "Organization '$ORG' is valid, but no repositories were found."
else
  log_success "Inventory report generated successfully. Repositories found: $repo_count"
fi

log_info "Output file: $OUT_FILE"
 
