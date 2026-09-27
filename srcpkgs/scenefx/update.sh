#!/usr/bin/env bash
set -euo pipefail

TEMPLATE_FILE="template"

if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo "❌ Error: '$TEMPLATE_FILE' not found in $(pwd)" >&2
    exit 1
fi

TMP_DIR=$(mktemp -d /tmp/xbps_update_XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "[INFO] Checking updates for package in '$(pwd)'..."

# Extract exact variable value from template file
get_template_var() {
    local var_name="$1"
    grep -E "^\s*${var_name}=" "$TEMPLATE_FILE" | head -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | xargs || true
}

CURRENT_VER=$(get_template_var "version")
if [[ -z "$CURRENT_VER" ]]; then
    echo "❌ Error: Could not parse 'version=' from $TEMPLATE_FILE" >&2
    exit 1
fi

# Extract primary GitHub repository (owner/repo) directly from template distfiles or URLs
MAIN_REPO=$(grep -oP 'github\.com/\K[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$TEMPLATE_FILE" | head -n1 | sed 's/\.git$//' | xargs || true)

if [[ -z "$MAIN_REPO" ]]; then
    echo "❌ Error: No GitHub repository URL found in $TEMPLATE_FILE" >&2
    exit 1
fi

echo "[INFO] Main Repo     : $MAIN_REPO"
echo "[INFO] Current Ver   : $CURRENT_VER"

# ------------------------------------------------------------------------------
# 1. Fetch Latest Upstream Version Tag
# ------------------------------------------------------------------------------
echo "[INFO] Fetching latest release tag from GitHub..."
LATEST_VER=$(curl -sL "https://api.github.com/repos/$MAIN_REPO/releases/latest" | jq -r '.tag_name // empty' | sed 's/^v//' | xargs || true)

# Fallback to latest tag if no official GitHub release exists
if [[ -z "$LATEST_VER" || "$LATEST_VER" == "null" ]]; then
    echo "[INFO] No official release found. Fetching latest git tag..."
    LATEST_VER=$(curl -sL "https://api.github.com/repos/$MAIN_REPO/tags" | jq -r '.[0].name // empty' | sed 's/^v//' | xargs || true)
fi

if [[ -z "$LATEST_VER" || "$LATEST_VER" == "null" ]]; then
    echo "⚠️ Warning: Failed to fetch latest version for $MAIN_REPO. Keeping current version." >&2
    LATEST_VER="$CURRENT_VER"
fi

echo "[INFO] Latest Ver    : $LATEST_VER"

# ------------------------------------------------------------------------------
# 2. Detect & Query Sub-Module Commit Hashes (e.g., _bamboo_version)
# ------------------------------------------------------------------------------
SUB_VAR_NAMES=$(grep -oP '^\s*\K_[a-zA-Z0-9_]+_version(?==)' "$TEMPLATE_FILE" || true)

HAS_SUB_UPDATES=false
declare -A SUB_NEW_VALS

for sub_var in $SUB_VAR_NAMES; do
    sub_curr_val=$(get_template_var "$sub_var")
    sub_repo=$(grep -oP "github\.com/\K[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+" "$TEMPLATE_FILE" | grep -v "$MAIN_REPO" | head -n1 | sed 's/\.git$//' | xargs || true)
    
    if [[ -n "$sub_repo" && -n "$sub_curr_val" ]]; then
        echo "[INFO] Sub Repo ($sub_repo -> $sub_var): Fetching HEAD commit..."
        sub_latest_val=$(git ls-remote "https://github.com/$sub_repo.git" HEAD | awk '{print $1}' | xargs || true)
        
        echo "[INFO]   Current $sub_var : ${sub_curr_val:-N/A}"
        echo "[INFO]   Latest  $sub_var : ${sub_latest_val:-N/A}"
        
        if [[ -n "$sub_latest_val" && "$sub_curr_val" != "$sub_latest_val" ]]; then
            HAS_SUB_UPDATES=true
            SUB_NEW_VALS["$sub_var"]="$sub_latest_val"
        fi
    fi
done

# ------------------------------------------------------------------------------
# 3. Apply Primary & Sub-Variable Modifications
# ------------------------------------------------------------------------------
if [[ "$CURRENT_VER" == "$LATEST_VER" ]] && [[ "$HAS_SUB_UPDATES" == "false" ]]; then
    echo "☕ Package is already up to date ($CURRENT_VER)."
    exit 0
fi

echo "[INFO] Updates detected! Modifying template file..."

# Use '@' delimiter to safely handle characters like slashes in string replacement
sed -i "s@^\(version=\).*@\1${LATEST_VER}@" "$TEMPLATE_FILE"
sed -i "s@^\(revision=\).*@\11@" "$TEMPLATE_FILE"

for sub_var in "${!SUB_NEW_VALS[@]}"; do
    sub_val="${SUB_NEW_VALS[$sub_var]}"
    sed -i "s@^\(${sub_var}=\).*@\1${sub_val}@" "$TEMPLATE_FILE"
    echo "[INFO] Updated $sub_var to $sub_val"
done

# ------------------------------------------------------------------------------
# 4. Recalculate & Replace SHA256 Checksum In-Place
# ------------------------------------------------------------------------------
echo "[INFO] Recalculating sha256 checksums..."

DISTFILES_RAW=$(grep -E '^\s*distfiles=' "$TEMPLATE_FILE" -A 5 | sed -n '/checksum=/q;p' \
    | sed 's/distfiles=//' | tr -d '"' | tr -d "'")

# Expand variables inside distfiles URL string
EVAL_DISTFILES=$(echo "$DISTFILES_RAW" | sed "s/\${version}/$LATEST_VER/g; s/\$version/$LATEST_VER/g")

for sub_var in "${!SUB_NEW_VALS[@]}"; do
    sub_val="${SUB_NEW_VALS[$sub_var]}"
    EVAL_DISTFILES=$(echo "$EVAL_DISTFILES" | sed "s/\${${sub_var}}/$sub_val/g; s/\$${sub_var}/$sub_val/g")
done

CHECKSUM_ARRAY=()

for url_entry in $EVAL_DISTFILES; do
    clean_url=$(echo "$url_entry" | cut -d'>' -f1 | xargs)
    
    if [[ -n "$clean_url" && "$clean_url" =~ ^https?:// ]]; then
        target_file="$TMP_DIR/distfile_${#CHECKSUM_ARRAY[@]}.tar.gz"
        
        echo "[INFO] Downloading archive: $clean_url"
        if curl -sL "$clean_url" -o "$target_file"; then
            csum=$(sha256sum "$target_file" | awk '{print $1}')
            echo "[INFO]   SHA256: $csum"
            CHECKSUM_ARRAY+=("$csum")
        fi
    fi
done

# Perform in-place replacement while preserving formatting and multi-line alignment
if [[ ${#CHECKSUM_ARRAY[@]} -gt 0 ]]; then
    if [[ ${#CHECKSUM_ARRAY[@]} -eq 1 ]]; then
        # Single checksum: replace matching line directly
        sed -i "s@^\(checksum=\).*@\1\"${CHECKSUM_ARRAY[0]}\"@" "$TEMPLATE_FILE"
    else
        # Multi-checksum: format with indented multi-line structure
        FORMATTED_CSUM="checksum=\"${CHECKSUM_ARRAY[0]}\n"
        for (( i=1; i<${#CHECKSUM_ARRAY[@]}; i++ )); do
            FORMATTED_CSUM="${FORMATTED_CSUM} ${CHECKSUM_ARRAY[$i]}"
            if [[ $i -lt $((${#CHECKSUM_ARRAY[@]} - 1)) ]]; then
                FORMATTED_CSUM="${FORMATTED_CSUM}\n"
            fi
        done
        FORMATTED_CSUM="${FORMATTED_CSUM}\""
        
        # Replace old multi-line checksum block in-place
        awk -v replacement="$FORMATTED_CSUM" '
            /checksum=/ {
                print replacement
                in_checksum = 1
                next
            }
            in_checksum && (/^[a-f0-9]{64}"?/ || /^ /) {
                next
            }
            {
                in_checksum = 0
                print
            }
        ' "$TEMPLATE_FILE" > "$TMP_DIR/template.tmp" && mv "$TMP_DIR/template.tmp" "$TEMPLATE_FILE"
    fi
    echo "[INFO] Updated checksum(s) in-place in $TEMPLATE_FILE"
fi

echo "✨ Successfully updated $TEMPLATE_FILE to version $LATEST_VER!"
