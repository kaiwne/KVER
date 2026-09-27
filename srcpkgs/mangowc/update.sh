#!/usr/bin/env bash
# ==============================================================================
# KVXR Package Template Updater (update.sh)
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Package & Sub-Repository Configuration
# ------------------------------------------------------------------------------
# Main Repository
# Format: OWNER/REPO
MAIN_REPO="mangowm/mango"

# Main Fetch Strategy: "release" (latest GitHub release tag) or "commit" (HEAD commit SHA)
MAIN_FETCH_TYPE="release"

# Sub-Repositories Configuration
# Array elements format: "TEMPLATE_VAR|OWNER/REPO|FETCH_TYPE"
#   - TEMPLATE_VAR: Variable name inside 'template' (e.g., "bamboo_version")
#   - OWNER/REPO:   GitHub repository string
#   - FETCH_TYPE:   "release", "tag", or "commit"
#
# Example for package without sub-repos: SUB_REPOS=()
SUB_REPOS=()

# Relative path to the XBPS template file
TEMPLATE_FILE="template"

# ------------------------------------------------------------------------------
# Global Setup & Helper Functions
# ------------------------------------------------------------------------------

# Resolve script directory and switch context to package root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Configure HTTP Authorization header if GitHub Token exists (prevents API rate limits)
AUTH_HEADER=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
    AUTH_HEADER=(-H "Authorization: Bearer $GITHUB_TOKEN")
elif [ -n "${GH_TOKEN:-}" ]; then
    AUTH_HEADER=(-H "Authorization: Bearer $GH_TOKEN")
fi

# Formatted console output helpers
log_info()    { echo -e "[\033[34mINFO\033[0m] $*"; }
log_success() { echo -e "[\033[32mOK\033[0m] $*"; }
log_warn()    { echo -e "[\033[33mWARN\033[0m] $*"; }
log_error()   { echo -e "[\033[31mERROR\033[0m] $*" >&2; }

# Verify required system CLI dependencies
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
# Core Logic Functions
# ------------------------------------------------------------------------------

# Fetches the latest reference (version, tag, or commit SHA) from GitHub
get_latest_ref() {
    local repo="$1"
    local fetch_type="$2"
    local ref=""

    case "$fetch_type" in
        release)
            ref=$(curl -sSL "${AUTH_HEADER[@]}" "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty')
            # Fallback to tags if GitHub release is empty
            if [ -z "$ref" ]; then
                ref=$(curl -sSL "${AUTH_HEADER[@]}" "https://api.github.com/repos/${repo}/tags" 2>/dev/null | jq -r '.[0].name // empty')
            fi
            ref="${ref#v}" # Strip leading 'v' prefix for package version
            ;;
        tag)
            ref=$(curl -sSL "${AUTH_HEADER[@]}" "https://api.github.com/repos/${repo}/tags" 2>/dev/null | jq -r '.[0].name // empty')
            ref="${ref#v}"
            ;;
        commit)
            # Fetch HEAD commit hash directly via Git protocol (Fast & bypasses REST API limits)
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

# Updates simple scalar key=value lines in template
update_template_var() {
    local var_name="$1"
    local new_val="$2"
    if grep -qE "^${var_name}=" "$TEMPLATE_FILE"; then
        sed -i -E "s|^(${var_name}=)[\"']?.*[\"']?|\1${new_val}\vert{}" "$TEMPLATE_FILE"
    else
        echo "${var_name}=${new_val}" >> "$TEMPLATE_FILE"
    fi
}

# Formats array of values into a multiline quote-aligned string
# Indentation equals length of KEY + 2 (for '="'), perfectly aligning line 2+ after quote
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

# Updates multiline or standard fields (like checksum or distfiles) safely using Python
# Prevents shell-escaping bugs while keeping exact formatting structure
update_multiline_field() {
    local key="$1"
    local value="$2"

    KEY="$key" VALUE="$value" FILE="$TEMPLATE_FILE" python3 -c '
import os, re

file_path = os.environ["FILE"]
key = os.environ["KEY"]
value = os.environ["VALUE"]

with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

# Pattern matches key="..." including multiline contents
pattern = re.compile(rf"^{re.escape(key)}=\"[^\"]*\"", re.MULTILINE | re.DOTALL)
replacement = f"{key}=\"{value}\""

if pattern.search(content):
    updated = pattern.sub(replacement, content, count=1)
else:
    updated = content.rstrip() + f"\n{key}=\"{value}\"\n"

with open(file_path, "w", encoding="utf-8") as f:
    f.write(updated)
'
}

# Computes SHA-256 checksum for a given remote URL
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
# Main Execution Pipeline
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

    # Exit early if template is already at latest versions
    if [ "$has_updates" = false ]; then
        log_success "Package is already up to date!"
        exit 0
    fi

    log_info "Updates detected! Updating template file..."

    # 3. Update main version in template
    if [ "$current_version" != "$latest_version" ]; then
        update_template_var "version" "$latest_version"
        log_info "Updated 'version' -> $latest_version"
    fi

    # Reset revision=1 whenever any version/sub-repo changes
    update_template_var "revision" "1"
    log_info "Reset 'revision' -> 1"

    # 4. Update Sub-repository variables in template
    for var_name in "${!sub_latest_vals[@]}"; do
        local new_sub_val="${sub_latest_vals[$var_name]}"
        if [ "${sub_current_vals[$var_name]}" != "$new_sub_val" ]; then
            update_template_var "$var_name" "$new_sub_val"
            log_info "Updated '$var_name' ->$new_sub_val"
        fi
    done

    # 5. Expand distfiles URLs using updated template variables
    log_info "Evaluating expanded distfiles URLs..."
    local expanded_distfiles
    expanded_distfiles=$(bash -c 'source ./template && echo "$distfiles"')

    if [ -z "$expanded_distfiles" ]; then
        log_error "Could not evaluate distfiles from template"
        exit 1
    fi

    # 6. Calculate checksums for all distfiles
    local checksums=()
    for url in $expanded_distfiles; do
        log_info "Calculating SHA-256 for: $url"
        local hash
        hash=$(calc_sha256 "$url")
        checksums+=("$hash")
    done

    # 7. Format quote-aligned multiline checksum and update template
    local formatted_checksum
    formatted_checksum=$(format_multiline_value "checksum" "${checksums[@]}")
    update_multiline_field "checksum" "$formatted_checksum"

    log_success "Template successfully updated!"
}

main "$@"
