#!/usr/bin/env bash
# ==============================================================================
# KVXR Package Template Updater (update.sh)
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Package & Sub-Repository Configuration
# ------------------------------------------------------------------------------
# Main Repository (Owner/Repo)
MAIN_REPO="mangowm/mango"

# Main Fetch Strategy: "release" (latest release tag), "tag", or "commit" (HEAD commit SHA)
MAIN_FETCH_TYPE="release"

# Sub-Repositories Configuration
# Array elements format: "TEMPLATE_VAR|OWNER/REPO|FETCH_TYPE"
# Leave empty SUB_REPOS=() if package has no sub-repositories
SUB_REPOS=()

# Relative path to the XBPS template file
TEMPLATE_FILE="template"

# ------------------------------------------------------------------------------
# Global Setup
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Resolve Authorization token safely for GitHub API
AUTH_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
CURL_AUTH=()
if [ -n "$AUTH_TOKEN" ]; then
    CURL_AUTH=(-H "Authorization: Bearer $AUTH_TOKEN")
fi

log_info()    { echo -e "[\033[34mINFO\033[0m] $*"; }
log_success() { echo -e "[\033[32mOK\033[0m] $*"; }
log_warn()    { echo -e "[\033[33mWARN\033[0m] $*"; }
log_error()   { echo -e "[\033[31mERROR\033[0m] $*" >&2; }

# Verify required CLI dependencies
for cmd in curl jq git python3; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Missing required CLI dependency: '$cmd'"
        exit 1
    fi
done

if [ ! -f "$TEMPLATE_FILE" ]; then
    log_error "Template file '$TEMPLATE_FILE' not found in$SCRIPT_DIR"
    exit 1
fi

# ------------------------------------------------------------------------------
# Core Helper Functions
# ------------------------------------------------------------------------------

# Safely fetches the latest reference (version, tag, or commit SHA) from GitHub
get_latest_ref() {
    local repo="$1"
    local fetch_type="$2"
    local ref=""

    case "$fetch_type" in
        release)
            local res
            res=$(curl -sSL${CURL_AUTH+"${CURL_AUTH[@]}"} "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null || true)
            ref=$(echo "$res" | jq -r '.tag_name // empty' 2>/dev/null || true)
            
            # Fallback to tags if GitHub release is empty
            if [ -z "$ref" ] \vert{}\vert{} [ "$ref" = "null" ]; then
                res=$(curl -sSL${CURL_AUTH+"${CURL_AUTH[@]}"} "https://api.github.com/repos/${repo}/tags" 2>/dev/null || true)
                ref=$(echo "$res" | jq -r '.[0].name // empty' 2>/dev/null || true)
            fi
            ref="${ref#v}" # Strip leading 'v' prefix
            ;;
        tag)
            local res
            res=$(curl -sSL${CURL_AUTH+"${CURL_AUTH[@]}"} "https://api.github.com/repos/${repo}/tags" 2>/dev/null || true)
            ref=$(echo "$res" | jq -r '.[0].name // empty' 2>/dev/null || true)
            ref="${ref#v}"
            ;;
        commit)
            ref=$(git ls-remote "https://github.com/${repo}.git" HEAD 2>/dev/null | awk '{print $1}')
            ;;
        *)
            log_error "Unknown fetch type: '$fetch_type'"
            return 1
            ;;
    esac

    if [ -z "$ref" ] \vert{}\vert{} [ "$ref" = "null" ]; then
        log_error "Failed to fetch reference for repository '$repo' ($fetch_type)"
        return 1
    fi

    echo "$ref"
}

# Reads scalar variable value from the template file
get_template_var() {
    local var_name="$1"
    sed -n -E "s/^${var_name}=[\"']?([^\"'#]+)[\"']?/\1/p" "$TEMPLATE_FILE" | head -n 1 | xargs
}

# Updates scalar variable preserving quotes if originally present
update_template_var() {
    local var_name="$1"
    local new_val="$2"

    python3 -c '
import sys, os, re

var_name = sys.argv[1]
new_val = sys.argv[2]
file_path = sys.argv[3]

with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

pattern = re.compile(rf"^({re.escape(var_name)}=)(\"[^\"]*\"|\x27[^\x27]*\x27|[^\s#]+)", re.MULTILINE)

def replacer(match):
    prefix = match.group(1)
    old_val = match.group(2)
    if old_val.startswith("\"") and old_val.endswith("\""):
        return f"{prefix}\"{new_val}\""
    elif old_val.startswith("\x27") and old_val.endswith("\x27"):
        return f"{prefix}\x27{new_val}\x27"
    else:
        return f"{prefix}{new_val}"

if pattern.search(content):
    updated = pattern.sub(replacer, content, count=1)
else:
    updated = content.rstrip() + f"\n{var_name}={new_val}\n"

with open(file_path, "w", encoding="utf-8") as f:
    f.write(updated)
' "$var_name" "$new_val" "$TEMPLATE_FILE"
}

# Safely evaluates distfiles URLs from template without executing shell/XBPS functions
evaluate_distfiles() {
    python3 -c '
import re, os

with open("template", "r", encoding="utf-8") as f:
    lines = f.readlines()

env = {}
for line in lines:
    line = line.strip()
    if line.startswith("#") or "=" not in line:
        continue
    parts = line.split("=", 1)
    k = parts[0].strip()
    v = parts[1].strip().strip("\"").strip("\x27")
    if re.match(r"^[a-zA-Z_][a-zA-Z0-9_]*$", k):
        env[k] = v

content = "".join(lines)
match = re.search(r"distfiles=\"([^\"]+)\"", content, re.DOTALL)
if not match:
    match = re.search(r"distfiles=\x27([^\x27]+)\x27", content, re.DOTALL)

if not match:
    print("")
    exit(0)

raw_distfiles = match.group(1)

def expand_var(m):
    var_name = m.group(1) or m.group(2)
    return env.get(var_name, m.group(0))

expanded = re.sub(r"\$\{([a-zA-Z_][a-zA-Z0-9_]*)\}|\$([a-zA-Z_][a-zA-Z0-9_]*)", expand_var, raw_distfiles)
print(expanded.strip())
'
}

# Formats array of values into a multiline quote-aligned string
format_multiline_value() {
    local key="$1"
    shift
    local items=("$@")

    local prefix_len=$((${#key} + 2))
    local indent
    indent=$(printf '\%*s' "$prefix_len" '')

    local result=""
    local first=true

    for item in "${items[@]}"; do
        if [ "$first" = true ]; then
            result="$item"
            first=false
        else
            result="${result}
${indent}${item}"
        fi
    done

    echo "$result"
}

# Safely updates multiline fields (checksum/distfiles) in template
update_multiline_field() {
    local key="$1"
    local value="$2"

    python3 -c '
import sys, os, re

key = sys.argv[1]
value = sys.argv[2]
file_path = sys.argv[3]

with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

pattern = re.compile(rf"^{re.escape(key)}=\"[^\"]*\"", re.MULTILINE | re.DOTALL)
replacement = f"{key}=\"{value}\""

if pattern.search(content):
    # Lambda function prevents backslash escape interpretation errors
    updated = pattern.sub(lambda m: replacement, content, count=1)
else:
    updated = content.rstrip() + f"\n{key}=\"{value}\"\n"

with open(file_path, "w", encoding="utf-8") as f:
    f.write(updated)
' "$key" "$value" "$TEMPLATE_FILE"
}

# Computes SHA-256 checksum for a remote URL
calc_sha256() {
    local url="$1"
    local hash=""

    if command -v sha256sum &>/dev/null; then
        hash=$(curl -sSL "$url" | sha256sum | awk '{print $1}')
    else
        hash=$(curl -sSL "$url" | shasum -a 256 | awk '{print $1}')
    fi

    if [ -z "$hash" ] \vert{}\vert{} [ ${#hash} -ne 64 ]; then
        log_error "Failed to calculate SHA-256 for: $url"
        return 1
    fi

    echo "$hash"
}

# ------------------------------------------------------------------------------
# Main Pipeline Execution
# ------------------------------------------------------------------------------
main() {
    log_info "Checking updates for package in '$SCRIPT_DIR'..."

    # 1. Fetch current and latest versions for Main Repository
    local current_version
    current_version=$(get_template_var "version")

    log_info "Main Repo ($MAIN_REPO): Fetching latest$MAIN_FETCH_TYPE..."
    local latest_version
    latest_version=$(get_latest_ref "$MAIN_REPO" "$MAIN_FETCH_TYPE")

    log_info "  Current version : ${current_version:-N/A}"
    log_info "  Latest version  : $latest_version"

    local has_updates=false
    if [ "$current_version" != "$latest_version" ]; then
        has_updates=true
    fi

    # 2. Process Sub-Repositories
    declare -A sub_latest_vals
    declare -A sub_current_vals

    for entry in "${SUB_REPOS[@]}"; do
        [ -z "$entry" ] && continue
        IFS='|' read -r var_name sub_repo sub_fetch_type <<< "$entry"

        local current_sub_val
        current_sub_val=$(get_template_var "$var_name")
        sub_current_vals["$var_name"]="$current_sub_val"

        log_info "Sub Repo ($sub_repo -> $var_name): Fetching latest$sub_fetch_type..."
        local latest_sub_val
        latest_sub_val=$(get_latest_ref "$sub_repo" "$sub_fetch_type")

        sub_latest_vals["$var_name"]="$latest_sub_val"

        log_info "  Current $var_name :${current_sub_val:-N/A}"
        log_info "  Latest $var_name  :$latest_sub_val"

        if [ "$current_sub_val" != "$latest_sub_val" ]; then
            has_updates=true
        fi
    done

    # Exit early if template is up-to-date
    if [ "$has_updates" = false ]; then
        log_success "Package is already up to date!"
        exit 0
    fi

    log_info "Updates detected! Updating template file..."

    # 3. Update main version
    if [ "$current_version" != "$latest_version" ]; then
        update_template_var "version" "$latest_version"
        log_info "Updated 'version' -> $latest_version"
    fi

    # Reset revision=1 on any update
    update_template_var "revision" "1"
    log_info "Reset 'revision' -> 1"

    # 4. Update Sub-repository variables
    for var_name in "${!sub_latest_vals[@]}"; do
        local new_sub_val="${sub_latest_vals[$var_name]}"
        if [ "${sub_current_vals[$var_name]}" != "$new_sub_val" ]; then
            update_template_var "$var_name" "$new_sub_val"
            log_info "Updated '$var_name' ->$new_sub_val"
        fi
    done

    # 5. Safely expand distfiles URLs
    log_info "Evaluating expanded distfiles URLs..."
    local expanded_distfiles
    expanded_distfiles=$(evaluate_distfiles)

    if [ -z "$expanded_distfiles" ]; then
        log_error "Could not evaluate distfiles from template"
        exit 1
    fi

    # 6. Calculate checksums for all URLs
    local checksums=()
    for url in $expanded_distfiles; do
        log_info "Calculating SHA-256 for: $url"
        local hash
        hash=$(calc_sha256 "$url")
        checksums+=("$hash")
    done

    # 7. Format quote-aligned multiline checksum and save to template
    local formatted_checksum
    formatted_checksum=$(format_multiline_value "checksum" "${checksums[@]}")
    update_multiline_field "checksum" "$formatted_checksum"

    log_success "Template successfully updated!"
}

main "$@"
