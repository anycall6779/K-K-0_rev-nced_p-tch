#!/bin/bash
#
# Multi-app APK/APKM/APKS/XAPK merger + Morphe patcher.
# Supported apps:
#   - KakaoTalk
#   - Unicorn Pro
#   - dcinside
#   - CHZZK
#   - Flexcil
#   - SOOP
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

BASE_DIR="${BASE_DIR:-/storage/emulated/0/Download}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
PATCH_SCRIPT_DIR="${PATCH_SCRIPT_DIR:-$HOME/morphe-build-script}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
EDITOR_JAR="${EDITOR_JAR:-$BASE_DIR/APKEditor-1.4.9.jar}"
MORPHE_CLI_JAR="${MORPHE_CLI_JAR:-$PATCH_SCRIPT_DIR/morphe-cli.jar}"
MORPHE_CLI_URL_FILE="${MORPHE_CLI_URL_FILE:-$MORPHE_CLI_JAR.url}"
MORPHE_CLI_FALLBACK_VERSION="1.18.2-dev.4"
MORPHE_CLI_FALLBACK_URL="https://github.com/MorpheApp/morphe-desktop/releases/download/v${MORPHE_CLI_FALLBACK_VERSION}/morphe-desktop-${MORPHE_CLI_FALLBACK_VERSION}-all.jar"
MPP_FILE="${MPP_FILE:-$PATCH_SCRIPT_DIR/patches-current.mpp}"

GITHUB_REPO="${GITHUB_REPO:-AmpleReVanced/revanced-patches}"
GITHUB_API_URL="https://api.github.com/repos/$GITHUB_REPO/releases"

GITHUB_KEYSTORE_URL="https://github.com/anycall6779/K-K-0_rev-nced_p-tch/raw/refs/heads/main/my_kakao_key.keystore"
LOCAL_KEYSTORE_FILE="${LOCAL_KEYSTORE_FILE:-$SCRIPT_DIR/my_kakao_key.keystore}"
KEYSTORE_FILE="${SIGNING_KEYSTORE:-$PATCH_SCRIPT_DIR/kakao_sign_bks.keystore}"
ORIG_KEYSTORE_FILE="$PATCH_SCRIPT_DIR/my_kakao_key.keystore"
KEY_ALIAS="${SIGNING_ALIAS:-ReVanced Key}"
STORE_PASS="${SIGNING_STORE_PASS:-}"
KEY_PASS="${SIGNING_KEY_PASS:-}"

APP_KEY=""
APP_LABEL=""
APP_PACKAGE=""
APP_OUTPUT=""
APP_MERGED=""
APP_SUPPORTED=""
APP_FILE_TYPE=""

INPUT_FILE=""
TARGET_APK_PATH=""

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Do not use /releases/latest: GitHub excludes pre-releases there.
# GITHUB_TOKEN is optional and is never printed.
github_api() {
    local args=(-fsSL --retry 3 --connect-timeout 20 --max-time 120
        -H "Accept: application/vnd.github+json")
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi
    curl "${args[@]}" "$1"
}

latest_morphe_cli_asset() {
    local asset_info
    asset_info="$(github_api "https://api.github.com/repos/MorpheApp/morphe-desktop/releases?per_page=30" \
        | jq -er '[.[] | select(.draft == false)] | sort_by(.published_at) | reverse
            | [.[] | .assets[] | select(.name | test("^morphe-desktop-.*-all\\.jar$"))][0]
            | select(.browser_download_url != null)
            | "\(.browser_download_url)\t\(.name)"' || true)"
    if [ -z "$asset_info" ]; then
        warn "GitHub API unavailable; using pinned Desktop $MORPHE_CLI_FALLBACK_VERSION." >&2
        asset_info="${MORPHE_CLI_FALLBACK_URL}"$'\t'"morphe-desktop-${MORPHE_CLI_FALLBACK_VERSION}-all.jar"
    fi
    printf '%s\n' "$asset_info"
}

ensure_morphe_cli() {
    info "Checking latest morphe-cli..."
    local cli_info cli_url cli_name recorded_url tmp_file
    cli_info="$(latest_morphe_cli_asset)"
    cli_url="${cli_info%%$'\t'*}"
    cli_name="${cli_info#*$'\t'}"
    recorded_url=""
    tmp_file="$MORPHE_CLI_JAR.tmp"
    mkdir -p "$(dirname "$MORPHE_CLI_JAR")" "$(dirname "$MORPHE_CLI_URL_FILE")"

    [ -f "$MORPHE_CLI_URL_FILE" ] && recorded_url="$(cat "$MORPHE_CLI_URL_FILE" 2>/dev/null || true)"
    if [ -f "$MORPHE_CLI_JAR" ] && [ "$recorded_url" = "$cli_url" ]; then
        ok "Morphe Desktop CLI is current: $cli_name"
        return 0
    fi

    info "Downloading morphe-cli: $cli_name"
    rm -f "$tmp_file"
    curl -L --fail --progress-bar -o "$tmp_file" "$cli_url" || {
        rm -f "$tmp_file"
        err "Failed to download morphe-cli."
        return 1
    }
    validate_zip_file "$tmp_file" "Desktop JAR" || return 1
    mv -f "$tmp_file" "$MORPHE_CLI_JAR"
    printf '%s\n' "$cli_url" > "$MORPHE_CLI_URL_FILE"
    ok "morphe-cli ready: $cli_name"
}

print_header() {
    clear || true
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  Multi-app APK/APKM/APKS/XAPK Morphe Patcher${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
}

set_app() {
    local key="$1"

    case "$key" in
        kakaotalk)
            APP_KEY="kakaotalk"
            APP_LABEL="KakaoTalk"
            APP_PACKAGE="com.kakao.talk"
            APP_OUTPUT="kakaotalkpatch.apk"
            APP_MERGED="KakaoTalk_Merged.apk"
            APP_SUPPORTED="read from selected MPP (not hard-coded)"
            APP_FILE_TYPE="APKM"
            ;;
        unicorn)
            APP_KEY="unicorn"
            APP_LABEL="Unicorn Pro"
            APP_PACKAGE="com.unicornsoft.android.unicornpro"
            APP_OUTPUT="unicornpatch.apk"
            APP_MERGED="UnicornPro_Merged.apk"
            APP_SUPPORTED="read from selected MPP (not hard-coded)"
            APP_FILE_TYPE="APK"
            ;;
        dcinside)
            APP_KEY="dcinside"
            APP_LABEL="dcinside"
            APP_PACKAGE="com.dcinside.app.android"
            APP_OUTPUT="dcinsidepatch.apk"
            APP_MERGED="dcinside_Merged.apk"
            APP_SUPPORTED="read from selected MPP (not hard-coded)"
            APP_FILE_TYPE="XAPK"
            ;;
        chzzk)
            APP_KEY="chzzk"
            APP_LABEL="CHZZK"
            APP_PACKAGE="com.navercorp.game.android.community"
            APP_OUTPUT="chzzkpatch.apk"
            APP_MERGED="CHZZK_Merged.apk"
            APP_SUPPORTED="read from selected MPP (not hard-coded)"
            APP_FILE_TYPE="XAPK"
            ;;
        flexcil)
            APP_KEY="flexcil"
            APP_LABEL="Flexcil"
            APP_PACKAGE="com.flexcil.flexcilnote"
            APP_OUTPUT="flexcilpatch.apk"
            APP_MERGED="Flexcil_Merged.apk"
            APP_SUPPORTED="read from selected MPP (not hard-coded)"
            APP_FILE_TYPE="XAPK"
            ;;
        soop)
            APP_KEY="soop"
            APP_LABEL="SOOP"
            APP_PACKAGE="kr.co.nowcom.mobile.afreeca"
            APP_OUTPUT="sooppatch.apk"
            APP_MERGED="SOOP_Merged.apk"
            APP_SUPPORTED="read from selected MPP (not hard-coded)"
            APP_FILE_TYPE="APK"
            ;;
        *)
            err "Unknown app key: $key"
            return 1
            ;;
    esac
}

normalize_app_arg() {
    local raw="${1:-}"
    raw="${raw,,}"
    raw="${raw// /}"
    raw="${raw//-/}"
    raw="${raw//_/}"

    case "$raw" in
        1|kakao|kakaotalk|talk|com.kakao.talk)
            echo "kakaotalk"
            ;;
        2|unicorn|unicornpro|uni|com.unicornsoft.android.unicornpro)
            echo "unicorn"
            ;;
        3|dc|dcinside|dcins|dci|com.dcinside.app.android)
            echo "dcinside"
            ;;
        4|chzzk|chijijik|naverchzzk|com.navercorp.game.android.community)
            echo "chzzk"
            ;;
        5|flexcil|flex|flexcilnote|com.flexcil.flexcilnote)
            echo "flexcil"
            ;;
        6|soop|afreeca|afreecatv|afreecatvapp|kr.co.nowcom.mobile.afreeca)
            echo "soop"
            ;;
        *)
            echo ""
            ;;
    esac
}

select_app() {
    local app_key
    app_key="$(normalize_app_arg "${1:-}")"
    if [ -n "${1:-}" ] && [ -z "$app_key" ]; then
        err "Unknown app: $1"
        return 1
    fi
    if [ -n "$app_key" ]; then
        set_app "$app_key"
        return 0
    fi

    echo -e "${YELLOW}Select target app:${NC}"
    echo -e "  ${GREEN}1.${NC} KakaoTalk     (${BLUE}com.kakao.talk${NC}, APKM, versions: selected MPP)"
    echo -e "  ${GREEN}2.${NC} Unicorn Pro   (${BLUE}com.unicornsoft.android.unicornpro${NC}, APK, versions: selected MPP)"
    echo -e "  ${GREEN}3.${NC} dcinside      (${BLUE}com.dcinside.app.android${NC}, XAPK, versions: selected MPP)"
    echo -e "  ${GREEN}4.${NC} CHZZK         (${BLUE}com.navercorp.game.android.community${NC}, XAPK, versions: selected MPP)"
    echo -e "  ${GREEN}5.${NC} Flexcil       (${BLUE}com.flexcil.flexcilnote${NC}, XAPK, versions: selected MPP)"
    echo -e "  ${GREEN}6.${NC} SOOP          (${BLUE}kr.co.nowcom.mobile.afreeca${NC}, APK, versions: selected MPP)"
    echo ""
    read -r -p "> " selection

    app_key="$(normalize_app_arg "$selection")"
    if [ -z "$app_key" ]; then
        err "Invalid app selection."
        return 1
    fi

    set_app "$app_key"
}

check_dependencies() {
    info "Checking required tools..."
    local missing=0

    for cmd in curl unzip java jq python; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            err "'$cmd' is missing. On Termux, install it with: pkg install $cmd"
            missing=1
        fi
    done

    [ "$missing" -eq 0 ] || return 1
    # Fail before downloads when Termux still has Java 17 installed.
    local java_version java_major
    java_version="$(java -version 2>&1)"
    java_major="$(printf '%s' "$java_version" | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -n 1)"
    if ! [[ "$java_major" =~ ^[0-9]+$ ]] || [ "$java_major" -lt 21 ]; then
        err "Morphe Desktop needs Java 21+. Termux: pkg install openjdk-21"
        return 1
    fi
    mkdir -p "$BASE_DIR" "$PATCH_SCRIPT_DIR" "$DOWNLOAD_DIR" "$PATCH_SCRIPT_DIR/work"


    ensure_morphe_cli || missing=1

    if [ "$missing" -eq 1 ]; then
        exit 1
    fi

    ok "All required tools are ready."
}

ensure_apkeditor() {
    [ -f "$EDITOR_JAR" ] && return 0
    info "Downloading APKEditor 1.4.9 (needed only for split bundles)..."
    mkdir -p "$(dirname "$EDITOR_JAR")"
    curl -L --fail --retry 3 --connect-timeout 20 --progress-bar \
        -o "$EDITOR_JAR.tmp" \
        "https://github.com/REAndroid/APKEditor/releases/download/V1.4.9/APKEditor-1.4.9.jar" || {
        err "Failed to download APKEditor."
        return 1
    }
    validate_zip_file "$EDITOR_JAR.tmp" "APKEditor JAR" || return 1
    mv -f "$EDITOR_JAR.tmp" "$EDITOR_JAR"
}

select_input_file() {
    echo ""
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${GREEN}$APP_LABEL input file selection${NC}"
    echo -e "${YELLOW}==================================${NC}"
    echo ""
    echo "Target package: $APP_PACKAGE"
    echo "Expected file type: $APP_FILE_TYPE (also accepts APK/APKM/APKS/XAPK)"
    echo "Supported version in this patch set: $APP_SUPPORTED"
    echo ""

    local files=()
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(find "$BASE_DIR" -maxdepth 1 -type f \( \
        -iname "*.apk" -o -iname "*.apkm" -o -iname "*.apks" -o -iname "*.xapk" \
    \) -print0 2>/dev/null | sort -z)

    if [ "${#files[@]}" -gt 0 ]; then
        echo -e "${BLUE}Files found in $BASE_DIR:${NC}"
        local i
        for i in "${!files[@]}"; do
            echo -e "  ${GREEN}$((i + 1)).${NC} $(basename "${files[$i]}")"
        done
        echo ""
        echo -e "${YELLOW}Enter a number, or paste a full file path:${NC}"
        read -r -p "> " selection

        if [[ "$selection" =~ ^[0-9]+$ ]] \
            && [ "$selection" -ge 1 ] \
            && [ "$selection" -le "${#files[@]}" ]; then
            INPUT_FILE="${files[$((selection - 1))]}"
        else
            INPUT_FILE="$selection"
        fi
    else
        echo -e "${BLUE}Enter the full path to an .apk/.apkm/.apks/.xapk file:${NC}"
        read -r -p "> " INPUT_FILE
    fi

    if [ -z "$INPUT_FILE" ] || [ ! -f "$INPUT_FILE" ]; then
        err "Invalid file path: ${INPUT_FILE:-empty}"
        return 1
    fi

    ok "Selected: $(basename "$INPUT_FILE")"
}

fetch_mpp_from_github() {
    echo ""
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${GREEN}MPP file selection (Release + Pre-release)${NC}"
    echo -e "${YELLOW}==================================${NC}"
    echo ""

    info "Fetching release and pre-release information from $GITHUB_REPO..."

    local releases_json
    releases_json="$(github_api "$GITHUB_API_URL?per_page=50")" || return 1
    if ! printf '%s' "$releases_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
        err "GitHub API request failed. Check your network connection."
        return 1
    fi

    local mpp_lines=()
    while IFS= read -r line; do
        mpp_lines+=("$line")
    done < <(echo "$releases_json" | jq -r '
        [.[] | select(.draft == false)] | sort_by(.published_at) | reverse | .[] as $rel
        | $rel.assets[]
        | select(.name | endswith(".mpp"))
        | select((.name | contains("sources") | not) and (.name | contains("javadoc") | not))
        | "\(.browser_download_url)\t[\(if $rel.prerelease then "Pre-release" else "Release" end)] \($rel.tag_name) - \(.name)"
    ')

    if [ "${#mpp_lines[@]}" -eq 0 ]; then
        err "No usable .mpp assets found in GitHub releases."
        return 1
    fi

    echo -e "${GREEN}Available MPP versions (Pre-release included):${NC}"
    echo -e "  ${BLUE}0.${NC} Auto-select newest release/pre-release (${mpp_lines[0]#*$'\t'})"
    local i
    for i in "${!mpp_lines[@]}"; do
        echo -e "  ${GREEN}$((i + 1)).${NC} ${mpp_lines[$i]#*$'\t'}"
    done
    echo ""
    echo -e "${YELLOW}Enter a number (default: 0):${NC}"
    read -r -p "> " selection

    if [ -z "${selection:-}" ] || [ "$selection" = "0" ]; then
        selection=1
    fi

    if ! [[ "$selection" =~ ^[0-9]+$ ]] \
        || [ "$selection" -lt 1 ] \
        || [ "$selection" -gt "${#mpp_lines[@]}" ]; then
        warn "Invalid selection. Using newest MPP."
        selection=1
    fi

    local selected_line="${mpp_lines[$((selection - 1))]}"
    local selected_url="${selected_line%%$'\t'*}"
    local selected_name="${selected_line#*$'\t'}"

    info "Downloading MPP: $selected_name"
    mkdir -p "$(dirname "$MPP_FILE")"
    curl -L --fail --retry 3 --connect-timeout 20 --progress-bar -o "$MPP_FILE.tmp" "$selected_url" || {
        err "Failed to download MPP."
        return 1
    }

    validate_zip_file "$MPP_FILE.tmp" "MPP" || return 1
    mv -f "$MPP_FILE.tmp" "$MPP_FILE"
    printf '%s\n' "$selected_url" > "$MPP_FILE.url"
    ok "MPP ready: $MPP_FILE"
}

get_file_type() {
    local lower="${1,,}"

    case "$lower" in
        *.apk) echo "APK" ;;
        *.apkm) echo "APKM" ;;
        *.apks) echo "APKS" ;;
        *.xapk) echo "XAPK" ;;
        *) echo "" ;;
    esac
}

validate_zip_file() {
    local path="$1"
    local label="$2"

    unzip -tq "$path" >/dev/null 2>&1 || {
        err "$label is not a valid ZIP/APK container: $path"
        return 1
    }
}

validate_apk_file() {
    local path="$1"

    validate_zip_file "$path" "APK" || return 1
    local zip_entries
    zip_entries="$(unzip -Z1 "$path")" || return 1
    grep -Fxq "AndroidManifest.xml" <<< "$zip_entries" || {
        err "Converted file is not a valid APK. AndroidManifest.xml was not found: $path"
        return 1
    }
}

find_metadata_base_apk() {
    local extract_dir="$1"

    python - "$extract_dir" <<'PYEOF'
import json
import os
import sys

root = sys.argv[1]
apk_by_name = {}
for dirpath, _, filenames in os.walk(root):
    for filename in filenames:
        if filename.lower().endswith(".apk"):
            apk_by_name.setdefault(filename.lower(), os.path.join(dirpath, filename))

def walk(value):
    if isinstance(value, dict):
        yield value
        for item in value.values():
            yield from walk(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk(item)

for dirpath, _, filenames in os.walk(root):
    for filename in filenames:
        if filename.lower() not in ("manifest.json", "info.json"):
            continue
        path = os.path.join(dirpath, filename)
        try:
            with open(path, "r", encoding="utf-8") as handle:
                data = json.load(handle)
        except Exception:
            continue

        for item in walk(data):
            lowered = {str(k).lower(): v for k, v in item.items()}
            marker = " ".join(
                str(lowered.get(key, "")).lower()
                for key in ("id", "type", "name", "split", "split_id")
            )
            if "base" not in marker and "master" not in marker:
                continue

            for key in ("file", "path", "apk", "apk_file", "name"):
                value = lowered.get(key)
                if not isinstance(value, str) or not value.lower().endswith(".apk"):
                    continue
                candidate = os.path.basename(value).lower()
                if candidate in apk_by_name:
                    print(apk_by_name[candidate])
                    sys.exit(0)
PYEOF
}

score_base_candidate() {
    local apk_file="$1"
    local apk_name="${2,,}"
    local score=0

    case "$apk_name" in
        base.apk) score=$((score + 1000)) ;;
        *base*.apk|*master*.apk) score=$((score + 700)) ;;
        *universal*.apk|*standalone*.apk) score=$((score + 650)) ;;
    esac

    case "$apk_name" in
        split_config.*|config.*|*split_config*|*config.*|*dpi.apk|*dpi_*.apk|*lang*.apk)
            score=$((score - 500))
            ;;
        *)
            score=$((score + 300))
            ;;
    esac

    local package_hint="${APP_PACKAGE//./}"
    local compact_name="${apk_name//./}"
    compact_name="${compact_name//_/}"
    compact_name="${compact_name//-/}"
    if [ -n "$package_hint" ] && [[ "$compact_name" == *"$package_hint"* ]]; then
        score=$((score + 150))
    fi

    local size
    size="$(wc -c < "$apk_file" 2>/dev/null || echo 0)"
    score=$((score + size / 1048576))

    echo "$score"
}

copy_apks_for_merge() {
    local extract_dir="$1"
    local merge_dir="$2"
    local apk_files=()

    while IFS= read -r -d '' apk_file; do
        apk_files+=("$apk_file")
    done < <(find "$extract_dir" -type f -iname "*.apk" -print0 2>/dev/null | sort -z)

    if [ "${#apk_files[@]}" -eq 0 ]; then
        err "No APK files were found inside $(basename "$INPUT_FILE")."
        return 1
    fi

    mkdir -p "$merge_dir"

    local base_source=""
    base_source="$(find_metadata_base_apk "$extract_dir" || true)"
    if [ -n "$base_source" ] && [ -f "$base_source" ]; then
        info "Base APK detected from metadata: $(basename "$base_source")" >&2
    else
        base_source=""
    fi

    local best_score=-999999
    local apk_file
    if [ -z "$base_source" ]; then
        for apk_file in "${apk_files[@]}"; do
            local apk_name score
            apk_name="$(basename "$apk_file")"
            score="$(score_base_candidate "$apk_file" "$apk_name")"
            if [ "$score" -gt "$best_score" ]; then
                best_score="$score"
                base_source="$apk_file"
            fi
        done

        if [ -n "$base_source" ]; then
            info "Base APK selected by structure: $(basename "$base_source")" >&2
        fi
    fi

    if [ -z "$base_source" ]; then
        err "Could not choose a base APK from $(basename "$INPUT_FILE")."
        return 1
    fi

    local base_name_lower
    base_name_lower="$(basename "$base_source")"
    base_name_lower="${base_name_lower,,}"

    case "$base_name_lower" in
        *standalone*.apk|*universal*.apk)
            cp -f "$base_source" "$merge_dir/base.apk"
            info "Standalone/universal APK selected. Split merge is not needed: $(basename "$base_source")" >&2
            echo "1"
            return 0
            ;;
    esac

    cp -f "$base_source" "$merge_dir/base.apk"

    local index=0
    for apk_file in "${apk_files[@]}"; do
        if [ "$apk_file" = "$base_source" ]; then
            continue
        fi

        local apk_name target_name
        apk_name="$(basename "$apk_file")"
        target_name="$apk_name"
        if [ -e "$merge_dir/$target_name" ]; then
            target_name="split_${index}.apk"
        fi

        cp -f "$apk_file" "$merge_dir/$target_name"
        index=$((index + 1))
    done

    echo "${#apk_files[@]}"
}

prepare_target_apk() {
    local file_type
    file_type="$(get_file_type "$INPUT_FILE")"
    local merged_path="$DOWNLOAD_DIR/$APP_MERGED"

    if [ -z "$file_type" ]; then
        err "Unsupported input extension. Use .apk, .apkm, .apks, or .xapk."
        return 1
    fi

    info "Detected input type: $file_type"

    case "$file_type" in
        APK)
            validate_apk_file "$INPUT_FILE" || return 1
            TARGET_APK_PATH="$INPUT_FILE"
            ok "Plain APK selected. Merge step skipped."
            ;;
        APKM|APKS|XAPK)
            ensure_apkeditor || return 1
            echo ""
            info "Converting $file_type to a patchable APK..."
            local temp_dir="$PATCH_SCRIPT_DIR/work/${APP_KEY}_extract"
            local merge_dir="$PATCH_SCRIPT_DIR/work/${APP_KEY}_merge"
            rm -rf "$temp_dir"
            rm -rf "$merge_dir"
            mkdir -p "$temp_dir" "$merge_dir"

            validate_zip_file "$INPUT_FILE" "$file_type package" || {
                rm -rf "$temp_dir" "$merge_dir"
                return 1
            }

            unzip -qqo "$INPUT_FILE" -d "$temp_dir" 2>/dev/null || {
                err "Failed to unzip $(basename "$INPUT_FILE")."
                rm -rf "$temp_dir" "$merge_dir"
                return 1
            }

            local apk_count
            apk_count="$(copy_apks_for_merge "$temp_dir" "$merge_dir")" || {
                rm -rf "$temp_dir" "$merge_dir"
                return 1
            }

            rm -f "$merged_path"

            if [ "$apk_count" -eq 1 ]; then
                cp -f "$merge_dir/base.apk" "$merged_path" || {
                    err "Failed to extract APK from $(basename "$INPUT_FILE")."
                    rm -rf "$temp_dir" "$merge_dir"
                    return 1
                }
                ok "Single APK extracted from $file_type."
            else
                info "Found $apk_count APK splits. Merging with APKEditor..."
                java -jar "$EDITOR_JAR" m -i "$merge_dir" -o "$merged_path" >/dev/null 2>&1 || {
                    warn "APKEditor merge failed with normalized split folder. Retrying with original package layout..."
                    java -jar "$EDITOR_JAR" m -i "$temp_dir" -o "$merged_path" >/dev/null 2>&1 || {
                        err "APKEditor merge failed."
                        rm -rf "$temp_dir" "$merge_dir"
                        return 1
                    }
                }
            fi

            rm -rf "$temp_dir" "$merge_dir"

            if [ ! -f "$merged_path" ]; then
                err "Converted APK was not created."
                return 1
            fi

            validate_apk_file "$merged_path" || return 1
            TARGET_APK_PATH="$merged_path"
            ok "Patchable APK ready: $TARGET_APK_PATH"
            ;;
        *)
            err "Unsupported input extension. Use .apk, .apkm, .apks, or .xapk."
            return 1
            ;;
    esac
}

prepare_keystore() {
    if [ "${NO_KEYSTORE:-0}" = "1" ]; then
        warn "NO_KEYSTORE=1 set. Morphe CLI will use its default signing behavior."
        KEYSTORE_FILE=""
        return 0
    fi

    if [ -n "${SIGNING_KEYSTORE:-}" ]; then
        [ -f "$SIGNING_KEYSTORE" ] || { err "Signing keystore not found: $SIGNING_KEYSTORE"; return 1; }
        ok "Using explicit signing keystore: $SIGNING_KEYSTORE"
        return 0
    fi

    if [ -f "$KEYSTORE_FILE" ]; then
        ok "Using existing signing keystore: $KEYSTORE_FILE"
        return 0
    fi

    if [ -f "$LOCAL_KEYSTORE_FILE" ]; then
        cp -f "$LOCAL_KEYSTORE_FILE" "$ORIG_KEYSTORE_FILE"
        cp -f "$ORIG_KEYSTORE_FILE" "$KEYSTORE_FILE"
        ok "Using local BKS-V2 signing keystore: $LOCAL_KEYSTORE_FILE"
        return 0
    fi

    if [ -f "$ORIG_KEYSTORE_FILE" ]; then
        cp -f "$ORIG_KEYSTORE_FILE" "$KEYSTORE_FILE"
        ok "Copied cached BKS-V2 signing keystore: $KEYSTORE_FILE"
        return 0
    fi

    info "Downloading signing keystore from GitHub..."
    curl -L --fail --progress-bar -o "$ORIG_KEYSTORE_FILE" "$GITHUB_KEYSTORE_URL" || {
        err "Failed to download signing keystore."
        return 1
    }

    if [ ! -s "$ORIG_KEYSTORE_FILE" ]; then
        err "Downloaded keystore is empty."
        return 1
    fi

    cp -f "$ORIG_KEYSTORE_FILE" "$KEYSTORE_FILE"
    ok "Signing keystore ready: $KEYSTORE_FILE"
}

ensure_questionary() {
    if python -c "import questionary" >/dev/null 2>&1; then
        return 0
    fi

    info "Installing Python package: questionary"
    if python -m pip install --user questionary -q >/dev/null 2>&1; then
        return 0
    fi
    if command -v pip >/dev/null 2>&1 && pip install questionary -q >/dev/null 2>&1; then
        return 0
    fi
    if command -v pip3 >/dev/null 2>&1 && pip3 install questionary -q >/dev/null 2>&1; then
        return 0
    fi

    err "Failed to install questionary. Install it manually with: python -m pip install questionary"
    return 1
}

write_patch_selector() {
    local selector="$PATCH_SCRIPT_DIR/morphe_patch_selector.py"

    cat > "$selector" <<'PYEOF'
import argparse
import os
import re
import shutil
import subprocess
import sys


def run(cmd, **kwargs):
    return subprocess.run(cmd, text=True, errors="replace", **kwargs)


def check_java():
    if shutil.which("java") is None:
        print("[ERR] java is not in PATH.")
        sys.exit(1)

    proc = run(["java", "-version"], capture_output=True)
    output = (proc.stdout or proc.stderr or "").strip()
    match = re.search(r'version "([^"]+)"', output)
    if not match:
        print(f"[ERR] Could not parse Java version:\n{output}")
        sys.exit(1)

    parts = match.group(1).split(".")
    major = int(parts[1]) if parts[0] == "1" else int(parts[0].split("-")[0])
    print(f"[OK] Java detected: {major}")
    if major < 21:
        print(f"[ERR] Unsupported Java version: {major}. Use Java 21 or newer.")
        sys.exit(1)


def list_patches(cli_jar, mpp_file):
    # File output has no logging prefixes (the first Index can be logged as
    # "INFO: Index: 0"). Also independent of stdout/stderr logging changes.
    import tempfile
    with tempfile.TemporaryDirectory(prefix="morphe-list-") as temp_dir:
        output = os.path.join(temp_dir, "patches.txt")
        cmd = ["java", "-jar", cli_jar, "list-patches",
               f"--patches={mpp_file}", "--with-packages", "--with-versions",
               "--with-options", f"--out={output}"]
        print("[INFO] Loading patch list...")
        proc = run(cmd, capture_output=True, timeout=180)
        if proc.returncode != 0:
            raise RuntimeError(f"list-patches failed:\n{proc.stdout}\n{proc.stderr}")
        if not os.path.isfile(output):
            raise RuntimeError("CLI produced no patch list. Check MPP/CLI compatibility.")
        with open(output, encoding="utf-8") as handle:
            return handle.read()


def split_patch_blocks(text):
    text = re.sub(r"(?m)^INFO: (?=Index:)", "", text)
    matches = list(re.finditer(r"(?m)^\s*Index:\s*\d+\s*$", text))
    if not matches:
        return [text]

    blocks = []
    for index, match in enumerate(matches):
        start = match.start()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        blocks.append(text[start:end])
    return blocks


def parse_field(block, name):
    match = re.search(rf"(?m)^\s*{re.escape(name)}:\s*(.+?)\s*$", block)
    return match.group(1).strip() if match else None


def parse_patches(text, target_pkg=None, include_universal=False):
    entries = []

    for block in split_patch_blocks(text):
        block = block.strip()
        if not block:
            continue

        entry = {
            "index": None,
            "name": parse_field(block, "Name"),
            "description": parse_field(block, "Description"),
            "enabled": None,
            "packages": [],
            "is_universal": False,
            "versions": {},
            "raw": block,
        }

        index = parse_field(block, "Index")
        if index and index.isdigit():
            entry["index"] = int(index)

        if entry["index"] is None or not entry["name"]:
            continue

        enabled = parse_field(block, "Enabled")
        if enabled:
            entry["enabled"] = enabled.lower() == "true"

        for package in re.findall(r"(?im)^\s*Package(?:\s+name)?\s*:\s*([A-Za-z0-9_.]+)\s*$", block):
            if package not in entry["packages"]:
                entry["packages"].append(package)

        inline_packages = parse_field(block, "Packages") or parse_field(block, "Package")
        if inline_packages:
            for package in re.split(r"[, ]+", inline_packages):
                package = package.strip()
                if re.fullmatch(r"[A-Za-z0-9_.]+", package) and "." in package:
                    if package not in entry["packages"]:
                        entry["packages"].append(package)

        current_package = None
        in_versions = False
        for line in block.splitlines():
            package_match = re.match(r"\s*Package name:\s*([A-Za-z0-9_.]+)\s*$", line)
            if package_match:
                current_package = package_match.group(1)
                entry["versions"].setdefault(current_package, [])
                in_versions = False
            elif line.strip() == "Compatible versions:":
                in_versions = True
            elif in_versions and current_package:
                if line.startswith("\t\t") and line.strip():
                    entry["versions"][current_package].append(line.strip())
                elif line.strip():
                    in_versions = False

        entry["is_universal"] = len(entry["packages"]) == 0
        entries.append(entry)

    if target_pkg:
        target = target_pkg.lower()
        entries = [
            entry for entry in entries
            if target in [package.lower() for package in entry["packages"]]
            or (include_universal and entry["is_universal"])
        ]

    return entries


def interactive_select(entries, app_label):
    from questionary import checkbox

    if not entries:
        print("[ERR] No patches match this app/package filter.")
        sys.exit(7)

    choices = []
    for entry in entries:
        index = f"[{entry['index']}]" if entry["index"] is not None else "[name]"
        name = entry["name"] or "(unnamed patch)"
        tags = []
        if entry.get("enabled"):
            tags.append("default")
        if entry.get("is_universal"):
            tags.append("universal")
        if entry.get("packages"):
            tags.append(", ".join(entry["packages"]))

        label = f"{index} {name}"
        if tags:
            label += f"  ({' | '.join(tags)})"

        value = ("idx", entry["index"]) if entry["index"] is not None else ("name", name)
        choices.append({
            "name": label,
            "value": value,
            "checked": bool(entry.get("enabled", False)),
        })

    result = checkbox(
        f"Select patches for {app_label} (space: toggle, enter: run):",
        choices=choices,
        validate=lambda selected: True if selected else "Select at least one patch.",
        qmark=">",
    ).ask()

    if result is None:
        print("[INFO] Cancelled.")
        sys.exit(130)

    return result


def build_patch_cmd(args, selected):
    cmd = [
        "java", "-jar", args.cli, "patch",
        f"--patches={args.mpp}",
        "--exclusive",
    ]

    for kind, value in selected:
        if kind == "idx":
            cmd.extend(["--ei", str(value)])
        else:
            cmd.extend(["-e", str(value)])

    if args.keystore:
        cmd.extend(["--keystore", args.keystore])
    if args.keystore and args.keystore_password is not None:
        cmd.extend(["--keystore-password", args.keystore_password])
    if args.keystore and args.key_alias:
        cmd.extend(["--keystore-entry-alias", args.key_alias])
    if args.keystore and args.key_password is not None:
        cmd.extend(["--keystore-entry-password", args.key_password])

    cmd.extend(["--result-file", args.output + ".result.json",
                "-t", args.output + ".tmp", "-o", args.output, args.apk])
    return cmd


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True)
    parser.add_argument("--mpp", required=True)
    parser.add_argument("--apk", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--app-label", required=True)
    parser.add_argument("--include-universal", action="store_true")
    parser.add_argument("--list-only", action="store_true")
    parser.add_argument("--resource-guard", default="")
    parser.add_argument("--keystore", default="")
    parser.add_argument("--keystore-password", default=None)
    parser.add_argument("--key-alias", default="")
    parser.add_argument("--key-password", default=None)
    args = parser.parse_args()

    check_java()

    for path_name in ("cli", "mpp", "apk"):
        path = getattr(args, path_name)
        if not os.path.isfile(path):
            print(f"[ERR] Missing {path_name}: {path}")
            sys.exit(3)

    print(f"[OK] Target APK: {args.apk}")
    patch_text = list_patches(args.cli, args.mpp)
    entries = parse_patches(
        patch_text,
        target_pkg=args.package,
        include_universal=args.include_universal,
    )

    if not any(args.package in entry["packages"] for entry in entries):
        raise RuntimeError(f"Selected MPP has no app-specific patches for {args.package}. "
                           "Choose a different release or app. Universal-only patching is stopped.")
    versions = sorted({version for entry in entries
                       for version in entry["versions"].get(args.package, [])})
    print(f"[INFO] Package filter: {args.package}")
    print("[INFO] Supported versions from selected MPP: " +
          (", ".join(versions) or "No explicit version restriction listed"))
    if args.list_only:
        for entry in entries:
            print(f"[{entry['index']}] {entry['name']}")
        return
    selected = interactive_select(entries, args.app_label)

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    cmd = build_patch_cmd(args, selected)

    display_cmd = list(cmd)
    for secret_flag in ("--keystore-password", "--keystore-entry-password"):
        if secret_flag in display_cmd:
            display_cmd[display_cmd.index(secret_flag) + 1] = "<redacted>"
    import shlex
    print("\n[CMD] " + shlex.join(display_cmd))
    print("\n[RUN] Patching...")
    log_path = args.output + ".log"
    print(f"[INFO] Patch log: {log_path}")
    with open(log_path, "w", encoding="utf-8") as log:
        with subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, encoding="utf-8", errors="replace") as process:
            for line in process.stdout:
                print(line, end="", flush=True)
                log.write(line)
                log.flush()
            returncode = process.wait()
    if returncode == 0 and os.path.isfile(args.output):
        if not args.resource_guard:
            raise RuntimeError("Resource guard is required; run patch9.sh or patch_apps.sh")
        keystore, alias = args.keystore, args.key_alias
        store_password, key_password = args.keystore_password or "", args.key_password or ""
        if not keystore:
            data_root = os.environ.get("MORPHE_DATA_DIR") or os.path.join(
                os.path.dirname(os.path.abspath(args.cli)), "morphe-data")
            keystore = os.path.join(data_root, "morphe.keystore")
            alias, key_password = "Morphe", "Morphe"
        env = os.environ.copy()
        env["RESOURCE_STORE_PASS"] = store_password
        env["RESOURCE_KEY_PASS"] = key_password
        guard_command = [sys.executable, args.resource_guard, "--apk", args.output,
                         "--cli", args.cli, "--keystore", keystore, "--alias", alias]
        subprocess.run(guard_command, check=True, env=env)
        print(f"[DONE] Patched APK: {args.output}")
    else:
        print(f"[ERR] Patch failed (exit={returncode}); see {log_path}")
        sys.exit(returncode or 1)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"[ERR] {exc}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
PYEOF

    echo "$selector"
}

write_resource_guard() {
    local guard="$PATCH_SCRIPT_DIR/morphe_resource_guard.py"
    cat > "$guard" <<'RESOURCE_PYEOF'
import argparse
import copy
import os
import shutil
import struct
import subprocess
import tempfile
import zipfile
from pathlib import Path

SIGNER_SOURCE = 'import java.io.*;\nimport java.security.*;\nimport java.security.cert.X509Certificate;\nimport java.util.*;\nimport com.android.apksig.ApkSigner;\nimport com.android.apksig.ApkVerifier;\nimport org.bouncycastle.jce.provider.BouncyCastleProvider;\nclass RepairSigner {\n public static void main(String[] args) throws Exception {\n  Security.addProvider(new BouncyCastleProvider());\n  byte[] header;\n  try (var input=new FileInputStream(args[3])) { header=input.readNBytes(4); }\n  String format=Arrays.equals(header,new byte[]{0,0,0,2})||Arrays.equals(header,new byte[]{0,0,0,1})?"BKS":\n    Arrays.equals(header,new byte[]{(byte)0xfe,(byte)0xed,(byte)0xfe,(byte)0xed})?"JKS":"PKCS12";\n  KeyStore ks=KeyStore.getInstance(format);\n  try (var in=new FileInputStream(args[3])) { ks.load(in,System.getenv().getOrDefault("RESOURCE_STORE_PASS", "").toCharArray()); }\n  String alias=args[4];\n  var cert=(X509Certificate)ks.getCertificate(alias);\n  var old=new ApkVerifier.Builder(new File(args[0])).build().verify();\n  if(!old.isVerified())throw new Exception("Original signature did not verify: "+old.getErrors());\n  if(cert==null || old.getSignerCertificates().size()!=1 || !Arrays.equals(cert.getEncoded(),old.getSignerCertificates().get(0).getEncoded()))\n   throw new Exception("Signing certificate mismatch: refusing to change installed identity");\n  PrivateKey key=(PrivateKey)ks.getKey(alias,System.getenv().getOrDefault("RESOURCE_KEY_PASS", "").toCharArray());\n  var config=new ApkSigner.SignerConfig.Builder("ReVanced",new com.android.apksig.KeyConfig.Jca(key),List.of(cert)).build();\n  new ApkSigner.Builder(List.of(config)).setInputApk(new File(args[1])).setOutputApk(new File(args[2]))\n   .setV1SigningEnabled(true).setV2SigningEnabled(true).setV3SigningEnabled(true)\n   .setAlignmentPreserved(false).setLibraryPageAlignmentBytes(16384).build().sign();\n  var result=new ApkVerifier.Builder(new File(args[2])).build().verify();\n  if(!result.isVerified())throw new Exception("Signature verification failed: "+result.getErrors());\n  System.out.println("Verified signed APK; same certificate SHA256="+HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(cert.getEncoded())));\n }\n}\n'


def chunks(data, start, end):
    while start < end:
        if start + 8 > end:
            raise ValueError("Truncated ARSC chunk")
        kind, header, size = struct.unpack_from("<HHI", data, start)
        if header < 8 or size < header or start + size > end:
            raise ValueError("Invalid ARSC chunk size")
        yield start, kind, header, size
        start += size
    if start != end:
        raise ValueError("ARSC size mismatch")


def fix_sparse_order(data):
    if len(data) < 12:
        raise ValueError("Truncated resource table")
    kind, header, size = struct.unpack_from("<HHI", data)
    if kind != 2 or size != len(data):
        raise ValueError("Invalid resource table")
    output = bytearray(data)
    changed = 0
    for pos, kind, package_header, package_size in chunks(data, header, size):
        if kind != 0x200:
            continue
        for position, kind, type_header, type_size in chunks(
                data, pos + package_header, pos + package_size):
            if kind != 0x201:
                continue
            if type_header < 20:
                raise ValueError("Truncated resource type header")
            if not data[position + 9] & 1:
                continue
            count, entries_start = struct.unpack_from("<II", data, position + 12)
            if type_header + count * 4 > entries_start or entries_start > type_size:
                raise ValueError("Invalid sparse index boundaries")
            pairs = [struct.unpack_from("<HH", data, position + type_header + i * 4)
                     for i in range(count)]
            if len({entry_id for entry_id, _ in pairs}) != count:
                raise ValueError("Duplicate sparse resource IDs")
            if any(entries_start + offset * 4 >= type_size for _, offset in pairs):
                raise ValueError("Invalid sparse entry offset")
            ordered = sorted(pairs, key=lambda pair: pair[0])
            if ordered != pairs:
                for i, pair in enumerate(ordered):
                    struct.pack_into("<HH", output, position + type_header + i * 4, *pair)
                changed += 1
    return bytes(output), changed


def rewrite_apk(source, destination, resource_table):
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(destination, "w") as output:
        for entry in original.infolist():
            upper = entry.filename.upper()
            if upper.startswith("META-INF/") and upper.endswith((".SF", ".RSA", ".DSA", ".EC")):
                continue
            info = copy.copy(entry)
            data = resource_table if entry.filename == "resources.arsc" else original.read(entry)
            if entry.filename == "resources.arsc":
                info.compress_type = zipfile.ZIP_STORED
            if info.compress_type == zipfile.ZIP_STORED:
                filename = info.filename.encode("utf-8" if any(ord(c) > 127 for c in info.filename) else "ascii")
                offset = output.fp.tell() + 30 + len(filename) + len(info.extra)
                padding = (-offset) % 4
                if padding:
                    info.extra += struct.pack("<HH", 0xd935, padding) + bytes(padding)
            output.writestr(info, data)


def repair(args):
    apk = Path(args.apk).resolve()
    with zipfile.ZipFile(apk) as source:
        fixed, changed = fix_sparse_order(source.read("resources.arsc"))
    print(f"[RESOURCE] Unsorted sparse type chunks: {changed}")
    if args.check:
        return 2 if changed else 0
    if not changed:
        return 0
    if not args.keystore or not Path(args.keystore).is_file():
        raise RuntimeError("Resource repair requires the same signing keystore used for this APK.")
    # Do not replace the signed APK unless repaired output verifies with exactly
    # the same certificate. Never uninstall the app or clear app data.
    with tempfile.TemporaryDirectory(prefix="resource-repair-", dir=apk.parent) as work:
        work = Path(work)
        unsigned, signed = work / "unsigned.apk", work / "signed.apk"
        rewrite_apk(apk, unsigned, fixed)
        signer = work / "RepairSigner.java"
        signer.write_text(SIGNER_SOURCE, encoding="utf-8")
        command = ["java", "--class-path", args.cli, str(signer), str(apk),
                   str(unsigned), str(signed), args.keystore, args.alias]
        subprocess.run(command, check=True, timeout=300)
        with zipfile.ZipFile(signed) as source:
            _, remaining = fix_sparse_order(source.read("resources.arsc"))
        if remaining:
            raise RuntimeError("Sparse resource order is still invalid after signing")
        os.replace(signed, apk)
    print("[RESOURCE] Corrected indices and verified same-certificate signing")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk", required=True)
    parser.add_argument("--cli", default="")
    parser.add_argument("--keystore", default="")
    parser.add_argument("--alias", default="ReVanced Key")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        return repair(args)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError,
            zipfile.BadZipFile) as exc:
        print(f"[RESOURCE ERROR] {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
RESOURCE_PYEOF
    echo "$guard"
}

run_patch() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Starting Morphe patcher for $APP_LABEL${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""

    ensure_questionary || return 1
    local selector
    selector="$(write_patch_selector)" || return 1
    local resource_guard
    resource_guard="$(write_resource_guard)" || return 1

    local work_dir="$PATCH_SCRIPT_DIR/work/$APP_KEY"
    local output_tmp="$work_dir/patched.apk"
    mkdir -p "$work_dir"
    rm -f "$output_tmp"

    local args=(
        "$selector"
        --cli "$MORPHE_CLI_JAR"
        --mpp "$MPP_FILE"
        --apk "$TARGET_APK_PATH"
        --output "$output_tmp"
        --package "$APP_PACKAGE"
        --app-label "$APP_LABEL"
        --resource-guard "$resource_guard"
        --include-universal
    )

    if [ -n "$KEYSTORE_FILE" ]; then
        args+=(
            --keystore "$KEYSTORE_FILE"
            --keystore-password "$STORE_PASS"
            --key-alias "$KEY_ALIAS"
            --key-password "$KEY_PASS"
        )
    fi

    python "${args[@]}" || {
        err "Patch process failed."
        return 1
    }

    if [ ! -f "$output_tmp" ]; then
        err "Patched output was not created."
        return 1
    fi

    validate_apk_file "$output_tmp" || return 1
    local final_path="$BASE_DIR/$APP_OUTPUT"
    if [ -e "$final_path" ]; then
        cp -p "$final_path" "$final_path.previous"
        warn "Previous output backed up: $final_path.previous"
    fi
    mv -f "$output_tmp" "$final_path"
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Patch complete${NC}"
    echo -e "${GREEN}========================================${NC}"
    ok "Saved: $final_path"
}

repair_existing_apk() {
    local input="${1:-}" guard work="$PATCH_SCRIPT_DIR/work/repair" output="$BASE_DIR/kakaotalkpatch_repaired.apk"
    [ -f "$input" ] || { err "Usage: bash patch9.sh --repair /path/to/patched.apk"; return 1; }
    check_dependencies || return 1
    prepare_keystore || return 1
    [ -n "$KEYSTORE_FILE" ] || { err "Repair mode requires SIGNING_KEYSTORE or the existing repository key."; return 1; }
    guard="$(write_resource_guard)" || return 1
    mkdir -p "$work"
    validate_apk_file "$input" || return 1
    cp -f "$input" "$work/repaired.apk" || return 1
    RESOURCE_STORE_PASS="$STORE_PASS" RESOURCE_KEY_PASS="$KEY_PASS" \
        python "$guard" --apk "$work/repaired.apk" --cli "$MORPHE_CLI_JAR" \
            --keystore "$KEYSTORE_FILE" --alias "$KEY_ALIAS" || return 1
    [ ! -e "$output" ] || cp -p "$output" "$output.previous"
    mv -f "$work/repaired.apk" "$output"
    ok "Repaired APK: $output (original preserved: $input)"
}

main() {
    if [ "${1:-}" = "--repair" ]; then
        repair_existing_apk "${2:-}"
        return $?
    fi
    print_header
    select_app "${1:-}" || exit 1
    echo -e "${GREEN}Selected app:${NC} $APP_LABEL"
    echo -e "${GREEN}Package:${NC} $APP_PACKAGE"
    echo ""

    check_dependencies || exit 1
    if [ -n "${2:-}" ]; then
        INPUT_FILE="$2"
        [ -f "$INPUT_FILE" ] || { err "Input file not found: $INPUT_FILE"; exit 1; }
    else
        select_input_file || exit 1
    fi
    fetch_mpp_from_github || exit 1
    prepare_target_apk || exit 1
    prepare_keystore || exit 1
    run_patch || exit 1

    echo ""
    echo -e "${GREEN}All done.${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
