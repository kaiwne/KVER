#!/usr/bin/env bash
# ==============================================================================
# Universal Package Template Updater (update.sh)
# Description:
#   Automatically updates package version and sub-module commit hashes, 
#   recalculates SHA256 checksums, and updates the checksum block in the template.
#   Does NOT modify the distfiles line in the template.
# ==============================================================================

set -euo pipefail

TEMPLATE_FILE="template"

if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo "❌ Error: '$TEMPLATE_FILE' not found in $(pwd)" >&2
    exit 1
fi

TMP_DIR=$(mktemp -d /tmp/xbps_update_XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "[INFO] Checking updates for package in '$(pwd)'..."

# Helper: Extract variable value from template
get_var() {
    local var_name="$1"
    grep -E "^\s*${var_name}=" "$TEMPLATE_FILE" | head -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | xargs || true
}

CURRENT_VER=$(get_var "version")
if [[ -z "$CURRENT_VER" ]]; then
    echo "❌ Error: Could not parse 'version=' from $TEMPLATE_FILE" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. Extract Main Repository & Version
# ------------------------------------------------------------------------------
MAIN_REPO=$(grep -oP 'github\.com/\K[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$TEMPLATE_FILE" | head -n1 | sed 's/\.git$//' | xargs || true)
if [[ -z "$MAIN_REPO" ]]; then
    echo "❌ Error: No GitHub repository URL found in $TEMPLATE_FILE" >&2
    exit 1
fi

LATEST_VER=$(curl -sL "https://api.github.com/repos/$MAIN_REPO/releases/latest" | jq -r '.tag_name // empty' | sed 's/^v//' | xargs || true)
if [[ -z "$LATEST_VER" || "$LATEST_VER" == "null" ]]; then
    LATEST_VER=$(curl -sL "https://api.github.com/repos/$MAIN_REPO/tags" | jq -r '.[0].name // empty' | sed 's/^v//' | xargs || true)
fi
if [[ -z "$LATEST_VER" || "$LATEST_VER" == "null" ]]; then
    LATEST_VER="$CURRENT_VER"
fi

# ------------------------------------------------------------------------------
# 2. Extract Sub-modules & Corresponding Repos from distfiles
# ------------------------------------------------------------------------------
SUB_VARS=($(grep -oP '^\s*\K_[a-zA-Z0-9_]+_version(?==)' "$TEMPLATE_FILE" || true))

declare -A SUB_NEW_VALS
HAS_UPDATES=false

if [[ "$CURRENT_VER" != "$LATEST_VER" ]]; then
    HAS_UPDATES=true
    echo "[INFO] Main version updated: $CURRENT_VER -> $LATEST_VER"
fi

DISTFILES_BLOCK=$(grep -E '^\s*distfiles=' "$TEMPLATE_FILE" -A 25 | sed -n '/checksum=/q;p')

for var_name in "${SUB_VARS[@]}"; do
    curr_val=$(get_var "$var_name")
    
    sub_url_line=$(echo "$DISTFILES_BLOCK" | grep -F "${var_name}" | head -n1 || true)
    if [[ -z "$sub_url_line" ]]; then
        clean_var_name="${var_name#_}"
        clean_var_name="${clean_var_name%_version}"
        sub_url_line=$(echo "$DISTFILES_BLOCK" | grep -i "$clean_var_name" | head -n1 || true)
    fi
    
    sub_repo=$(echo "$sub_url_line" | grep -oP 'github\.com/\K[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' | sed 's/\.git$//' | xargs || true)
    
    if [[ -n "$sub_repo" ]]; then
        echo "[INFO] Checking sub-module ($var_name -> $sub_repo)..."
        latest_val=$(git ls-remote "https://github.com/$sub_repo.git" HEAD | awk '{print $1}' | xargs || true)
        
        if [[ -n "$latest_val" ]]; then
            SUB_NEW_VALS["$var_name"]="$latest_val"
            if [[ "$curr_val" != "$latest_val" ]]; then
                HAS_UPDATES=true
                echo "[INFO]   Updated $var_name: ${curr_val:0:8}... -> ${latest_val:0:8}..."
            fi
        else
            SUB_NEW_VALS["$var_name"]="$curr_val"
        fi
    else
        SUB_NEW_VALS["$var_name"]="$curr_val"
    fi
done

if [[ "$HAS_UPDATES" == "false" ]]; then
    echo "☕ Package is already up to date."
    exit 0
fi

# ------------------------------------------------------------------------------
# 3. Apply Template Modifications (Version & Sub-variables ONLY - DO NOT touch distfiles)
# ------------------------------------------------------------------------------
echo "[INFO] Applying updates to variables in $TEMPLATE_FILE..."
sed -i "s@^\(version=\).*@\1${LATEST_VER}@" "$TEMPLATE_FILE"
sed -i "s@^\(revision=\).*@\11@" "$TEMPLATE_FILE"

for var_name in "${!SUB_NEW_VALS[@]}"; do
    sed -i "s@^\(${var_name}=\).*@\1${SUB_NEW_VALS[$var_name]}@" "$TEMPLATE_FILE"
done

# ------------------------------------------------------------------------------
# 4. Recalculate Checksums & Update Checksum Block (Leave distfiles untouched)
# ------------------------------------------------------------------------------
echo "[INFO] Recalculating checksums..."

DISTFILES_RAW=$(grep -E '^\s*distfiles=' "$TEMPLATE_FILE" -A 25 | sed -n '/checksum=/q;p' \
    | sed 's/distfiles=//' | tr -d '"' | tr -d "'")

EVAL_DISTFILES="$DISTFILES_RAW"
EVAL_DISTFILES="${EVAL_DISTFILES//\$\{version\}/$LATEST_VER}"
EVAL_DISTFILES="${EVAL_DISTFILES//\$version/$LATEST_VER}"

for var_name in "${!SUB_NEW_VALS[@]}"; do
    val="${SUB_NEW_VALS[$var_name]}"
    EVAL_DISTFILES="${EVAL_DISTFILES//\$\{$var_name\}/$val}"
    EVAL_DISTFILES="${EVAL_DISTFILES//\$$var_name/$val}"
done

CHECKSUM_ARRAY=()
idx=0

for url_entry in $EVAL_DISTFILES; do
    clean_url=$(echo "$url_entry" | cut -d'>' -f1 | xargs)
    if [[ -n "$clean_url" && "$clean_url" =~ ^https?:// ]]; then
        target_file="$TMP_DIR/distfile_${idx}.tar.gz"
        echo "[INFO] Downloading: $clean_url"
        if curl -sL "$clean_url" -o "$target_file"; then
            csum=$(sha256sum "$target_file" | awk '{print $1}')
            CHECKSUM_ARRAY+=("$csum")
        else
            echo "❌ Error: Failed to download $clean_url" >&2
            exit 1
        fi
        idx=$((idx + 1))
    fi
done

# Format checksum block: aligned after 'checksum="' (10 spaces indentation)
if [[ ${#CHECKSUM_ARRAY[@]} -gt 0 ]]; then
    formatted_checksum="checksum=\"${CHECKSUM_ARRAY[0]}"
    for (( i=1; i<${#CHECKSUM_ARRAY[@]}; i++ )); do
        formatted_checksum="${formatted_checksum}\n          ${CHECKSUM_ARRAY[$i]}"
    done
    formatted_checksum="${formatted_checksum}\""

    awk -v replacement="$formatted_checksum" '
        /checksum=/ {
            print replacement
            in_csum = 1
            next
        }
        in_csum && (/^[a-f0-9]{64}"?/ || /^ /) {
            next
        }
        {
            in_csum = 0
            print
        }
    ' "$TEMPLATE_FILE" > "$TMP_DIR/template.tmp" && mv "$TMP_DIR/template.tmp" "$TEMPLATE_FILE"
    
    echo "[INFO] Successfully updated checksums in template."
fi

echo "✨ Successfully updated package version and checksums!"
