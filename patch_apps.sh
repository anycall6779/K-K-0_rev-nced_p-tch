#!/bin/bash
#
# Multi-app APK/APKM/APKS/XAPK merger + Morphe patcher.
# Supported apps:
#   - KakaoTalk
#   - Unicorn Pro
#   - dcinside
#   - CHZZK
#   - Flexcil
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
EDITOR_JAR="${EDITOR_JAR:-$BASE_DIR/APKEditor-1.4.5.jar}"
MORPHE_CLI_JAR="${MORPHE_CLI_JAR:-$PATCH_SCRIPT_DIR/morphe-cli.jar}"
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
            APP_SUPPORTED="26.4.2"
            APP_FILE_TYPE="APKM"
            ;;
        unicorn)
            APP_KEY="unicorn"
            APP_LABEL="Unicorn Pro"
            APP_PACKAGE="com.unicornsoft.android.unicornpro"
            APP_OUTPUT="unicornpatch.apk"
            APP_MERGED="UnicornPro_Merged.apk"
            APP_SUPPORTED="1.30.467"
            APP_FILE_TYPE="APK"
            ;;
        dcinside)
            APP_KEY="dcinside"
            APP_LABEL="dcinside"
            APP_PACKAGE="com.dcinside.app.android"
            APP_OUTPUT="dcinsidepatch.apk"
            APP_MERGED="dcinside_Merged.apk"
            APP_SUPPORTED="5.2.9"
            APP_FILE_TYPE="XAPK"
            ;;
        chzzk)
            APP_KEY="chzzk"
            APP_LABEL="CHZZK"
            APP_PACKAGE="com.navercorp.game.android.community"
            APP_OUTPUT="chzzkpatch.apk"
            APP_MERGED="CHZZK_Merged.apk"
            APP_SUPPORTED="3.6.0"
            APP_FILE_TYPE="XAPK"
            ;;
        flexcil)
            APP_KEY="flexcil"
            APP_LABEL="Flexcil"
            APP_PACKAGE="com.flexcil.flexcilnote"
            APP_OUTPUT="flexcilpatch.apk"
            APP_MERGED="Flexcil_Merged.apk"
            APP_SUPPORTED="1.4.3.30"
            APP_FILE_TYPE="XAPK"
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
        *)
            echo ""
            ;;
    esac
}

select_app() {
    local app_key
    app_key="$(normalize_app_arg "${1:-}")"
    if [ -n "$app_key" ]; then
        set_app "$app_key"
        return 0
    fi

    echo -e "${YELLOW}Select target app:${NC}"
    echo -e "  ${GREEN}1.${NC} KakaoTalk     (${BLUE}com.kakao.talk${NC}, APKM, supported: 26.4.2)"
    echo -e "  ${GREEN}2.${NC} Unicorn Pro   (${BLUE}com.unicornsoft.android.unicornpro${NC}, APK, supported: 1.30.467)"
    echo -e "  ${GREEN}3.${NC} dcinside      (${BLUE}com.dcinside.app.android${NC}, XAPK, supported: 5.2.9)"
    echo -e "  ${GREEN}4.${NC} CHZZK         (${BLUE}com.navercorp.game.android.community${NC}, XAPK, supported: 3.6.0)"
    echo -e "  ${GREEN}5.${NC} Flexcil       (${BLUE}com.flexcil.flexcilnote${NC}, XAPK, supported: 1.4.3.30)"
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

    mkdir -p "$PATCH_SCRIPT_DIR" "$DOWNLOAD_DIR" "$PATCH_SCRIPT_DIR/work"

    if [ ! -f "$EDITOR_JAR" ]; then
        info "Downloading APKEditor..."
        curl -L --fail --progress-bar \
            -o "$EDITOR_JAR" \
            "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar" || {
            err "Failed to download APKEditor."
            missing=1
        }
    fi

    if [ ! -f "$MORPHE_CLI_JAR" ]; then
        info "Finding latest morphe-cli release..."
        local cli_url
        cli_url="$(curl -fsSL "https://api.github.com/repos/MorpheApp/morphe-cli/releases?per_page=10" \
            | jq -r '[.[] | .assets[] | select(.name | endswith("all.jar"))][0].browser_download_url // empty')"

        if [ -z "$cli_url" ]; then
            warn "Could not find latest morphe-cli release. Falling back to v1.5.0-dev.7."
            cli_url="https://github.com/MorpheApp/morphe-cli/releases/download/v1.5.0-dev.7/morphe-cli-1.5.0-dev.7-all.jar"
        fi

        info "Downloading morphe-cli..."
        curl -L --fail --progress-bar -o "$MORPHE_CLI_JAR" "$cli_url" || {
            err "Failed to download morphe-cli."
            missing=1
        }
    fi

    if [ "$missing" -eq 1 ]; then
        exit 1
    fi

    ok "All required tools are ready."
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
    releases_json="$(curl -fsSL "$GITHUB_API_URL?per_page=50" 2>/dev/null || true)"
    if [ -z "$releases_json" ] || echo "$releases_json" | jq -e 'type != "array"' >/dev/null 2>&1; then
        err "GitHub API request failed. Check your network connection."
        return 1
    fi

    local mpp_lines=()
    while IFS= read -r line; do
        mpp_lines+=("$line")
    done < <(echo "$releases_json" | jq -r '
        .[] as $rel
        | $rel.assets[]
        | select(.name | endswith(".mpp"))
        | select((.name | contains("sources") | not) and (.name | contains("javadoc") | not))
        | "\(.browser_download_url)\t[\(if $rel.prerelease then "Pre-release" else "Release" end)] \($rel.tag_name) - \(.name)"
    ' | head -50)

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
    rm -f "$MPP_FILE"
    curl -L --fail --progress-bar -o "$MPP_FILE" "$selected_url" || {
        err "Failed to download MPP."
        return 1
    }

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
    unzip -l "$path" "AndroidManifest.xml" >/dev/null 2>&1 || {
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

    if [ -f "$LOCAL_KEYSTORE_FILE" ]; then
        cp -f "$LOCAL_KEYSTORE_FILE" "$ORIG_KEYSTORE_FILE"
        cp -f "$ORIG_KEYSTORE_FILE" "$KEYSTORE_FILE"
        ok "Using local BKS-V2 signing keystore: $LOCAL_KEYSTORE_FILE"
        return 0
    fi

    if [ -f "$KEYSTORE_FILE" ]; then
        ok "Using existing signing keystore: $KEYSTORE_FILE"
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
    if not (17 <= major < 25):
        print(f"[ERR] Unsupported Java version: {major}. Use Java 17 through 24.")
        sys.exit(1)


def list_patches(cli_jar, mpp_file):
    cmd = [
        "java", "-jar", cli_jar, "list-patches",
        f"--patches={mpp_file}",
        "--with-packages",
        "--with-versions",
        "--with-options",
    ]
    print("[INFO] Loading patch list...")
    proc = run(cmd, capture_output=True)
    if proc.returncode != 0:
        print(f"[ERR] list-patches failed:\n{proc.stderr}")
        sys.exit(5)
    return proc.stdout


def split_patch_blocks(text):
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
        }

        index = parse_field(block, "Index")
        if index and index.isdigit():
            entry["index"] = int(index)

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
        sys.exit(0)

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
    if args.keystore_password is not None:
        cmd.extend(["--keystore-password", args.keystore_password])
    if args.key_alias:
        cmd.extend(["--keystore-entry-alias", args.key_alias])
    if args.key_password is not None:
        cmd.extend(["--keystore-entry-password", args.key_password])

    cmd.extend(["-o", args.output, args.apk])
    return cmd


def shell_quote(value):
    if not value or re.search(r"\s", value):
        return '"' + value.replace('"', '\\"') + '"'
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True)
    parser.add_argument("--mpp", required=True)
    parser.add_argument("--apk", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--app-label", required=True)
    parser.add_argument("--include-universal", action="store_true")
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

    print(f"[INFO] Package filter: {args.package} + universal patches")
    selected = interactive_select(entries, args.app_label)

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    cmd = build_patch_cmd(args, selected)

    print("\n[CMD] " + " ".join(shell_quote(item) for item in cmd))
    print("\n[RUN] Patching...")
    proc = subprocess.run(cmd)
    if proc.returncode == 0:
        print(f"[DONE] Patched APK: {args.output}")
    else:
        print(f"[ERR] Patch failed with exit code {proc.returncode}")
        sys.exit(proc.returncode)


if __name__ == "__main__":
    main()
PYEOF

    echo "$selector"
}

run_patch() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Starting Morphe patcher for $APP_LABEL${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""

    ensure_questionary
    local selector
    selector="$(write_patch_selector)"

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

    local final_path="$BASE_DIR/$APP_OUTPUT"
    mv -f "$output_tmp" "$final_path"
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Patch complete${NC}"
    echo -e "${GREEN}========================================${NC}"
    ok "Saved: $final_path"
}

main() {
    print_header
    select_app "${1:-}" || exit 1
    echo -e "${GREEN}Selected app:${NC} $APP_LABEL"
    echo -e "${GREEN}Package:${NC} $APP_PACKAGE"
    echo ""

    check_dependencies
    select_input_file || exit 1
    fetch_mpp_from_github || exit 1
    prepare_target_apk || exit 1
    prepare_keystore || exit 1
    run_patch || exit 1

    echo ""
    echo -e "${GREEN}All done.${NC}"
}

main "$@"
