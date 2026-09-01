#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# GHES -> GHEC: COMPLETE SYNC (ORG, REPO, ENV VARS + RULES)
# Enterprise Version
#
# Features:
#  - Source/target repo existence checks
#  - Centralized API wrapper
#  - Structured logging
#  - DR + Non-DR support
#  - Per-repo + final summary
#  - Safe bash loops
#  - PowerShell-identical behavior
# ============================================================
# ------------------------------------------------------------
# ENV INPUTS
# ------------------------------------------------------------
CSV_FILE="${CSV_FILE:-repos.csv}"
GH_PAT="${GH_PAT:?Set GH_PAT}"
GH_SOURCE_PAT="${GH_SOURCE_PAT:?Set GH_SOURCE_PAT}"
GHES_API_URL="${GHES_API_URL:?Set GHES_API_URL}"
GH_TARGET_HOST="${GH_TARGET_HOST:-github.com}"
GH_HEADERS=(
  -H "Accept: application/vnd.github+json"
  -H "X-GitHub-Api-Version: 2022-11-28"
)
# ------------------------------------------------------------
# LOGGING
# ------------------------------------------------------------
timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}
log_info() {
  echo "[$(timestamp)] [INFO]    $*"
}
log_warn() {
  echo "[$(timestamp)] [WARN]    $*"
}
log_error() {
  echo "[$(timestamp)] [ERROR]   $*" >&2
}
log_success() {
  echo "[$(timestamp)] [SUCCESS] $*"
}
# backward-compatible
log() {
  log_info "$*"
}

# ------------------------------------------------------------
# PARSE SOURCE HOST
# ------------------------------------------------------------
SOURCE_HOST="$GHES_API_URL"

[[ "$SOURCE_HOST" != *"://"* ]] && SOURCE_HOST="https://$SOURCE_HOST"

SOURCE_HOST="${SOURCE_HOST#*://}"
SOURCE_HOST="${SOURCE_HOST%%/*}"

# ------------------------------------------------------------
# URL ENCODE
# ------------------------------------------------------------
urlencode() {
  local s="$1"
  local out=""
  local i c hex

  LC_ALL=C

  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"

    case "$c" in
      [a-zA-Z0-9.~_-])
        out+="$c"
        ;;
      *)
        printf -v hex '%02X' "'$c"
        out+="%$hex"
        ;;
    esac
  done

  printf '%s' "$out"
}

# ------------------------------------------------------------
# CENTRALIZED API WRAPPERS
# ------------------------------------------------------------
api_source() {
  local context="$1"
  shift
  local output rc
  set +e
  output="$(
    GH_TOKEN="$GH_SOURCE_PAT" \
    gh api \
      --hostname "$SOURCE_HOST" \
      "${GH_HEADERS[@]}" \
      "$@" 2>&1
  )"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    log_error "Source API failed [$context] :: $output"
    return $rc
  fi
  printf '%s' "$output"
}
api_target() {
  local context="$1"
  shift
  local output rc
  set +e
  output="$(
    GH_TOKEN="$GH_PAT" \
    gh api \
      --hostname "$GH_TARGET_HOST" \
      "${GH_HEADERS[@]}" \
      "$@" 2>&1
  )"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    log_error "Target API failed [$context] :: $output"
    return $rc
  fi
  printf '%s' "$output"
}

# ------------------------------------------------------------
# REPO EXISTENCE CHECKS
# ------------------------------------------------------------
repo_exists_source() {
  local full="$1"
  api_source \
    "check source repo exists: $full" \
    "/repos/$full" \
    --jq '.id' >/dev/null
}

repo_exists_target() {
  local full="$1"
  api_target \
    "check target repo exists: $full" \
    "/repos/$full" \
    --jq '.id' >/dev/null
}

# ------------------------------------------------------------
# REVIEWER LOOKUP
# ------------------------------------------------------------
get_reviewer_id() {
  local handle="$1"
  local out
  if out="$(
    api_target \
      "get reviewer id: $handle" \
      "/users/$handle" \
      --jq '.id'
  )"; then
    printf '%s' "$out"
  else
    printf ''
    return 1
  fi
}

# ------------------------------------------------------------
# SUMMARY COUNTERS
# ------------------------------------------------------------
TOTAL_REPOS=0
SUCCESS_REPOS=0
FAILED_REPOS=0
SKIPPED_REPOS=0

TOTAL_ORG_VARS_SYNCED=0
TOTAL_REPO_VARS_SYNCED=0
TOTAL_ENVS_SYNCED=0
TOTAL_ENV_VARS_SYNCED=0
TOTAL_ENV_RULES_SYNCED=0

# ------------------------------------------------------------
# SYNC ENVIRONMENT DATA
# ------------------------------------------------------------
sync_environment_data() {
  local src_full="$1"
  local tgt_full="$2"
  local env_name="$3"
  local reviewer_handle="$4"
  local env_enc
  env_enc="$(urlencode "$env_name")"
  local repo_env_rules_synced=0
  local repo_env_vars_synced=0

  # ----------------------------------------------------------
  # 1. SYNC ENVIRONMENT RULES
  # ----------------------------------------------------------
  local src_env_json reviewer_id payload
  if ! src_env_json="$(
    api_source \
      "fetch source environment rules: $src_full / $env_name" \
      "/repos/$src_full/environments/$env_enc"
  )"; then
    log_warn "Skipping environment rules for '$env_name' due to source fetch failure."
  else
    reviewer_id=""
    if [[ -n "${reviewer_handle:-}" ]]; then
      reviewer_id="$(
        get_reviewer_id "$reviewer_handle" || true
      )"
      if [[ -z "$reviewer_id" ]]; then
        log_warn "Reviewer '$reviewer_handle' not found on target host."
      fi
    fi
    payload="$(
      printf '%s' "$src_env_json" |
      jq -c --arg rev_id "$reviewer_id" '
        try (
          (.protection_rules // []) as $rules
          |
          (
            $rules
            | map(select(.type=="wait_timer") | (.wait_timer // 0))
            | .[0]
          ) as $wt
          |
          (
            $rules
            | map(select(.type=="required_reviewers"))
            | .[0]
          ) as $rr
          |
          {}
          +
          (
            if $wt == null
            then {}
            else {wait_timer:$wt}
            end
          )
          +
          (
            if ($rr != null) and ($rev_id|length>0)
            then {
              reviewers: [
                {
                  type:"User",
                  id: ($rev_id|tonumber)
                }
              ],
              prevent_self_review:
                ($rr.prevent_self_review // false)
            }
            else {}
            end
          )
        ) catch {}
      '
    )"
    if api_target \
      "apply environment rules: $tgt_full / $env_name" \
      -X PUT \
      "/repos/$tgt_full/environments/$env_enc" \
      --input - <<< "$payload" >/dev/null; then

      log_success "Env '$env_name' rules synced."

      TOTAL_ENV_RULES_SYNCED=$((TOTAL_ENV_RULES_SYNCED + 1))

      repo_env_rules_synced=1

    else
      log_warn "Failed to sync environment rules for '$env_name'."
    fi
  fi

  # ----------------------------------------------------------
  # 2. SYNC ENVIRONMENT VARIABLES
  # ----------------------------------------------------------
  local src_repo_id tgt_repo_id

  if ! src_repo_id="$(
    api_source \
      "get source repo id: $src_full" \
      "/repos/$src_full" \
      --jq '.id'
  )"; then
    log_warn "Unable to resolve source repo id for '$src_full'. Skipping env vars for '$env_name'."
  elif ! tgt_repo_id="$(
    api_target \
      "get target repo id: $tgt_full" \
      "/repos/$tgt_full" \
      --jq '.id'
  )"; then
    log_warn "Unable to resolve target repo id for '$tgt_full'. Skipping env vars for '$env_name'."
  else
    local env_var_count=0
    while IFS=$'\t' read -r vname vval || [[ -n "${vname:-}" ]]; do
      [[ -z "${vname:-}" ]] && continue

      if api_target \
        "create env var: $tgt_full / $env_name / $vname" \
        -X POST \
        "/repositories/$tgt_repo_id/environments/$env_enc/variables" \
        -f "name=$vname" \
        -f "value=$vval" >/dev/null; then
        log_success "Env Var synced: $env_name / $vname"
        env_var_count=$((env_var_count + 1))
      else

        if api_target \
          "update env var: $tgt_full / $env_name / $vname" \
          -X PATCH \
          "/repositories/$tgt_repo_id/environments/$env_enc/variables/$vname" \
          -f "name=$vname" \
          -f "value=$vval" >/dev/null; then
          log_success "Env Var synced: $env_name / $vname"
          env_var_count=$((env_var_count + 1))
        else
          log_warn "Failed to sync env var: $env_name / $vname"
        fi
      fi
    done < <(
      api_source \
        "fetch source env vars: $src_full / $env_name" \
        "/repositories/$src_repo_id/environments/$env_enc/variables" \
        --jq '.variables[] | "\(.name)\t\(.value)"' \
        2>/dev/null || true
    )
    TOTAL_ENV_VARS_SYNCED=$((TOTAL_ENV_VARS_SYNCED + env_var_count))
    repo_env_vars_synced=$env_var_count
  fi
  TOTAL_ENVS_SYNCED=$((TOTAL_ENVS_SYNCED + 1))
  log_info "Environment summary [$env_name] :: rules_synced=$repo_env_rules_synced env_vars_synced=$repo_env_vars_synced"
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------
main() {
  log_info "Starting GHES -> GHEC Full Migration"
  declare -A seen_orgs
  [[ -f "$CSV_FILE" ]] || {
    log_error "CSV file not found: $CSV_FILE"
    exit 1
  }
  while IFS=',' read -r s_org s_repo r_url r_size t_org t_repo t_vis reviewer_handle; do
    s_org="$(echo "${s_org:-}" | xargs)"
    s_repo="$(echo "${s_repo:-}" | xargs)"
    t_org="$(echo "${t_org:-}" | xargs)"
    t_repo="$(echo "${t_repo:-}" | xargs)"
    reviewer_handle="$(echo "${reviewer_handle:-}" | xargs)"
    [[ -z "$s_org" ]] && continue
    TOTAL_REPOS=$((TOTAL_REPOS + 1))
    local_repo_org_vars=0
    local_repo_repo_vars=0
    local_repo_envs=0
    local_failed=0

    src_full="$s_org/$s_repo"
    tgt_full="$t_org/$t_repo"

    log_info "Processing: $src_full -> $tgt_full"
    # --------------------------------------------------------
    # REPO EXISTENCE CHECKS
    # --------------------------------------------------------
    if ! repo_exists_source "$src_full"; then
      log_error "Source repository not found or inaccessible: $src_full"
      FAILED_REPOS=$((FAILED_REPOS + 1))
      continue
    fi

    if ! repo_exists_target "$tgt_full"; then
      log_error "Target repository not found or inaccessible: $tgt_full"
      FAILED_REPOS=$((FAILED_REPOS + 1))
      continue
    fi

    # --------------------------------------------------------
    # 1. ORG VARIABLES
    # --------------------------------------------------------
    if [[ -z "${seen_orgs["$s_org"]+x}" ]]; then
      log_info "Syncing Org Vars for $t_org"
      local org_var_count=0
      while IFS=$'\t' read -r n v || [[ -n "${n:-}" ]]; do
        [[ -z "${n:-}" ]] && continue
        if api_target \
          "create org var: $t_org / $n" \
          -X POST \
          "/orgs/$t_org/actions/variables" \
          -f "name=$n" \
          -f "value=$v" \
          -f "visibility=all" >/dev/null; then

          org_var_count=$((org_var_count + 1))
        else
          if api_target \
            "update org var: $t_org / $n" \
            -X PATCH \
            "/orgs/$t_org/actions/variables/$n" \
            -f "name=$n" \
            -f "value=$v" >/dev/null; then

            org_var_count=$((org_var_count + 1))
          else
            log_warn "Failed to sync org var: $t_org / $n"
            local_failed=$((local_failed + 1))
          fi
        fi
      done < <(
        api_source \
          "fetch source org vars: $s_org" \
          "/orgs/$s_org/actions/variables" \
          --jq '.variables[] | "\(.name)\t\(.value)"' \
          2>/dev/null || true
      )

      seen_orgs["$s_org"]=1
      TOTAL_ORG_VARS_SYNCED=$((TOTAL_ORG_VARS_SYNCED + org_var_count))
      local_repo_org_vars=$org_var_count
      log_success "Org vars sync completed for $t_org (count=$org_var_count)"
    else
      log_info "Org vars already processed for source org '$s_org'; skipping duplicate org sync."
    fi

    # --------------------------------------------------------
    # 2. REPO VARIABLES
    # --------------------------------------------------------
    log_info "Syncing Repo Vars"
    local repo_var_count=0
    while IFS=$'\t' read -r n v || [[ -n "${n:-}" ]]; do
      [[ -z "${n:-}" ]] && continue
      if api_target \
        "create repo var: $tgt_full / $n" \
        -X POST \
        "/repos/$tgt_full/actions/variables" \
        -f "name=$n" \
        -f "value=$v" >/dev/null; then
        repo_var_count=$((repo_var_count + 1))
      else
        if api_target \
          "update repo var: $tgt_full / $n" \
          -X PATCH \
          "/repos/$tgt_full/actions/variables/$n" \
          -f "name=$n" \
          -f "value=$v" >/dev/null; then
          repo_var_count=$((repo_var_count + 1))
        else
          log_warn "Failed to sync repo var: $tgt_full / $n"
          local_failed=$((local_failed + 1))
        fi
      fi
    done < <(
      api_source \
        "fetch source repo vars: $src_full" \
        "/repos/$src_full/actions/variables" \
        --jq '.variables[] | "\(.name)\t\(.value)"' \
        2>/dev/null || true
    )

    TOTAL_REPO_VARS_SYNCED=$((TOTAL_REPO_VARS_SYNCED + repo_var_count))
    local_repo_repo_vars=$repo_var_count
    log_success "Repo vars sync completed for $tgt_full (count=$repo_var_count)"

    # --------------------------------------------------------
    # 3. ENVIRONMENTS
    # --------------------------------------------------------
    log_info "Syncing Environments"

    envs="$(
      api_source \
        "fetch source environments: $src_full" \
        "/repos/$src_full/environments" \
        --jq '.environments[].name | @text' \
        2>/dev/null || true
    )"

    if [[ -z "${envs:-}" ]]; then
      log_info "No environments found for $src_full"
    else
      while IFS= read -r env || [[ -n "${env:-}" ]]; do
        env="$(echo "$env" | xargs)"
        [[ -z "${env:-}" ]] && continue
        sync_environment_data \
          "$src_full" \
          "$tgt_full" \
          "$env" \
          "$reviewer_handle"
        local_repo_envs=$((local_repo_envs + 1))
      done <<< "$envs"
    fi

    # --------------------------------------------------------
    # REPOSITORY SUMMARY
    # --------------------------------------------------------
    if [[ $local_failed -eq 0 ]]; then
      SUCCESS_REPOS=$((SUCCESS_REPOS + 1))
      log_success \
        "Repository summary [$src_full -> $tgt_full] :: org_vars=$local_repo_org_vars repo_vars=$local_repo_repo_vars envs=$local_repo_envs failures=0"
    else
      FAILED_REPOS=$((FAILED_REPOS + 1))
      log_warn \
        "Repository summary [$src_full -> $tgt_full] :: org_vars=$local_repo_org_vars repo_vars=$local_repo_repo_vars envs=$local_repo_envs failures=$local_failed"
    fi
  done < <(
    sed 's/\r$//' "$CSV_FILE" | tail -n +2
  )

  # ----------------------------------------------------------
  # FINAL SUMMARY
  # ----------------------------------------------------------
  log_success "Migration Complete."
  log_info \
    "Final Summary :: repos_processed=$TOTAL_REPOS repos_succeeded=$SUCCESS_REPOS repos_failed=$FAILED_REPOS repos_skipped=$SKIPPED_REPOS org_vars_synced=$TOTAL_ORG_VARS_SYNCED repo_vars_synced=$TOTAL_REPO_VARS_SYNCED envs_processed=$TOTAL_ENVS_SYNCED env_rules_synced=$TOTAL_ENV_RULES_SYNCED env_vars_synced=$TOTAL_ENV_VARS_SYNCED"
}
main
