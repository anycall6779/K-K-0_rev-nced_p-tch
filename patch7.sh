#!/bin/bash
#
# Simplified APKM Merger + Patcher for KakaoTalk (AmpleReVanced -> Morphe Edition)
# (Modified: Uses morphe-cli and locally transferred .mpp file)
#
set -e

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
PKG_NAME="com.kakao.talk"
BASE_DIR="/storage/emulated/0/Download"
PATCH_SCRIPT_DIR="$HOME/morphe-build-script"
MERGED_APK_PATH="$HOME/Downloads/KakaoTalk_Merged.apk"
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"

# GitHub Setup for Patches
GITHUB_REPO="anycall6779/K-K-0_rev-nced_p-tch"
GITHUB_API_URL="https://api.github.com/repos/$GITHUB_REPO/releases"

# 서명 키스토어 설정
# KakaoTalk_Patched_unclone.apk는 GitHub의 my_kakao_key.keystore로 서명됨
# 업데이트가 되려면 반드시 동일한 원본 키를 사용해야 함
GITHUB_KEYSTORE_URL="https://github.com/anycall6779/K-K-0_rev-nced_p-tch/raw/refs/heads/main/my_kakao_key.keystore"
ORIG_KEYSTORE_FILE="$PATCH_SCRIPT_DIR/my_kakao_key.keystore"   # GitHub 원본 (JKS/PKCS12)
KEYSTORE_FILE="$PATCH_SCRIPT_DIR/kakao_sign_bks.keystore"        # BKS 변환본 (morphe-cli용)
KEY_ALIAS="revanced"
KEY_PASS="android"
STORE_PASS="android"

MORPHE_CLI_JAR="$PATCH_SCRIPT_DIR/morphe-cli.jar"
MPP_FILE="$BASE_DIR/patches-fixed.mpp"

# --- Dependency Check ---
check_dependencies() {
    echo -e "${BLUE}[INFO] 필수 도구 확인 중...${NC}"
    local MISSING=0
    
    for cmd in curl wget unzip java jq; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}[ERROR] '$cmd' 가 없습니다. 설치 명령어: pkg install $cmd${NC}"
            MISSING=1
        fi
    done
    
    mkdir -p "$PATCH_SCRIPT_DIR"
    mkdir -p "$HOME/Downloads"
    
    if [ ! -f "$EDITOR_JAR" ]; then
        echo -e "${YELLOW}[INFO] APKEditor 다운로드 중...${NC}"
        wget --quiet --show-progress -O "$EDITOR_JAR" \
            "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar" || {
            echo -e "${RED}[ERROR] APKEditor 다운로드 실패${NC}"
            MISSING=1
        }
    fi

    if [ ! -f "$MORPHE_CLI_JAR" ]; then
        echo -e "${YELLOW}[INFO] morphe-cli 최신 버전 확인 중...${NC}"
        local CLI_URL=$(curl -s "https://api.github.com/repos/MorpheApp/morphe-cli/releases" | jq -r '.[0].assets[] | select(.name | endswith("all.jar")) | .browser_download_url' | head -n 1)
        if [ -z "$CLI_URL" ] || [ "$CLI_URL" = "null" ]; then
            echo -e "${RED}[ERROR] morphe-cli URL을 가져오지 못했습니다. (dev 릴리스 fallback 사용)${NC}"
            CLI_URL="https://github.com/MorpheApp/morphe-cli/releases/download/v1.5.0-dev.7/morphe-cli-1.5.0-dev.7-all.jar"
        fi
        echo -e "${YELLOW}[INFO] morphe-cli 다운로드 중...${NC}"
        wget --quiet --show-progress -O "$MORPHE_CLI_JAR" "$CLI_URL" || {
            echo -e "${RED}[ERROR] morphe-cli 다운로드 실패${NC}"
            MISSING=1
        }
    fi
    
    [ $MISSING -eq 1 ] && exit 1
    echo -e "${GREEN}[OK] 모든 준비 완료${NC}"
}

# --- Get APKM File Path ---
get_apkm_file() {
    echo ""
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${GREEN}카카오톡 APKM 파일 선택${NC}"
    echo -e "${YELLOW}==================================${NC}"
    echo ""
    
    local APKM_FILES=()
    while IFS= read -r -d '' file; do
        APKM_FILES+=("$(basename "$file")")
    done < <(find "$BASE_DIR" -maxdepth 1 -name "*.apkm" -print0 2>/dev/null)
    
    if [ ${#APKM_FILES[@]} -gt 0 ]; then
        echo -e "${BLUE}다운로드 폴더에서 발견된 APKM 파일:${NC}"
        for i in "${!APKM_FILES[@]}"; do
            echo -e "  ${GREEN}$((i+1)).${NC} ${APKM_FILES[$i]}"
        done
        echo ""
        echo -e "${YELLOW}번호를 입력하거나, 직접 경로를 입력하세요:${NC}"
        read -r -p "> " selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#APKM_FILES[@]} ]; then
            APKM_FILE="$BASE_DIR/${APKM_FILES[$((selection-1))]}"
            echo -e "${GREEN}[선택됨] ${APKM_FILES[$((selection-1))]}${NC}"
            return 0
        fi
        
        if [ -n "$selection" ]; then
            APKM_FILE="$selection"
        fi
    else
        echo -e "${BLUE}APKM 파일의 전체 경로를 입력하세요:${NC}"
        echo -e "${YELLOW}(예: /storage/emulated/0/Download/com.kakao.talk.apkm)${NC}"
        echo ""
        read -r -p "> " APKM_FILE
    fi
    
    if [ -z "$APKM_FILE" ] || [ ! -f "$APKM_FILE" ]; then
        echo -e "${RED}[ERROR] 유효하지 않은 파일 경로입니다.${NC}"
        return 1
    fi
    
    return 0
}

# --- Fetch MPP from GitHub Releases ---
fetch_mpp_from_github() {
    echo ""
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${GREEN}MPP 파일 선택 (GitHub Releases)${NC}"
    echo -e "${YELLOW}==================================${NC}"
    echo ""
    
    echo -e "${BLUE}[INFO] GitHub 릴리스 정보 가져오는 중...${NC}"
    
    # 최근 10개 릴리스 가져오기
    local RELEASES_JSON=$(curl -s "$GITHUB_API_URL?per_page=10" 2>/dev/null)
    
    if [ -z "$RELEASES_JSON" ] || echo "$RELEASES_JSON" | grep -q '"message"'; then
        echo -e "${RED}[ERROR] GitHub API 요청 실패. 인터넷 연결을 확인하세요.${NC}"
        return 1
    fi
    
    # 릴리스 정보 파싱 (tag_name과 .mpp 파일 URL)
    local RELEASE_TAGS=()
    local MPP_URLS=()
    local MPP_NAMES=()
    
    # jq가 있으면 사용, 없으면 grep/sed로 파싱
    if command -v jq &> /dev/null; then
        while IFS= read -r line; do
            RELEASE_TAGS+=("$line")
        done < <(echo "$RELEASES_JSON" | jq -r '.[].tag_name')
        
        while IFS= read -r line; do
            MPP_URLS+=("$line")
        done < <(echo "$RELEASES_JSON" | jq -r '.[] | .assets[] | select(.name | endswith(".mpp") and (contains("sources") | not) and (contains("javadoc") | not)) | .browser_download_url' | head -10)
        
        while IFS= read -r line; do
            MPP_NAMES+=("$line")
        done < <(echo "$RELEASES_JSON" | jq -r '.[] | .assets[] | select(.name | endswith(".mpp") and (contains("sources") | not) and (contains("javadoc") | not)) | .name' | head -10)
    else
        # jq 없을 때 기본 파싱 (간단한 grep 사용)
        while IFS= read -r line; do
            RELEASE_TAGS+=("$line")
        done < <(echo "$RELEASES_JSON" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -10)
        
        while IFS= read -r line; do
            # .mpp로 끝나고 sources/javadoc이 아닌 URL만 필터링
            if [[ "$line" == *.mpp ]] && [[ "$line" != *sources* ]] && [[ "$line" != *javadoc* ]]; then
                MPP_URLS+=("$line")
                MPP_NAMES+=("$(basename "$line")")
            fi
        done < <(echo "$RELEASES_JSON" | grep -oP '"browser_download_url"\s*:\s*"\K[^"]+\.mpp')
    fi
    
    if [ ${#MPP_URLS[@]} -eq 0 ]; then
        echo -e "${RED}[ERROR] 사용 가능한 MPP 파일을 찾을 수 없습니다.${NC}"
        return 1
    fi
    
    echo ""
    echo -e "${GREEN}사용 가능한 MPP 버전:${NC}"
    echo -e "  ${BLUE}0.${NC} 최신 버전 자동 선택 (${MPP_NAMES[0]:-첫번째})"
    for i in "${!MPP_URLS[@]}"; do
        echo -e "  ${GREEN}$((i+1)).${NC} ${MPP_NAMES[$i]}"
    done
    echo ""
    echo -e "${YELLOW}번호를 입력하세요 (기본: 0 - 최신 버전):${NC}"
    read -r -p "> " selection
    
    # 기본값 또는 0 선택 시 최신 버전
    if [ -z "$selection" ] || [ "$selection" = "0" ]; then
        selection=1
    fi
    
    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#MPP_URLS[@]} ]; then
        SELECTED_MPP_URL="${MPP_URLS[$((selection-1))]}"
        SELECTED_MPP_NAME="${MPP_NAMES[$((selection-1))]}"
        echo -e "${GREEN}[선택됨] ${SELECTED_MPP_NAME}${NC}"
    else
        echo -e "${RED}[ERROR] 잘못된 선택입니다. 최신 버전을 사용합니다.${NC}"
        SELECTED_MPP_URL="${MPP_URLS[0]}"
        SELECTED_MPP_NAME="${MPP_NAMES[0]}"
    fi
    
    # MPP 다운로드
    echo -e "${YELLOW}[INFO] MPP 다운로드 중: ${SELECTED_MPP_NAME}...${NC}"
    rm -f "$MPP_FILE"
    curl -L -o "$MPP_FILE" "$SELECTED_MPP_URL" || {
        echo -e "${RED}[ERROR] MPP 다운로드 실패!${NC}"
        return 1
    }
    
    echo -e "${GREEN}[✓] MPP 다운로드 완료: $MPP_FILE${NC}"
    return 0
}

# --- Merge APKM ---
merge_apkm() {
    echo ""
    echo -e "${BLUE}[INFO] APKM 파일 병합 시작...${NC}"
    local TEMP_DIR="$BASE_DIR/kakao_temp_merge"
    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
    
    unzip -qqo "$APKM_FILE" -d "$TEMP_DIR" 2>/dev/null || {
        echo -e "${RED}[ERROR] 압축 해제 실패${NC}"
        rm -rf "$TEMP_DIR"
        return 1
    }
    
    if [ ! -f "$TEMP_DIR/base.apk" ]; then
        echo -e "${RED}[ERROR] base.apk 없음${NC}"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    
    echo -e "${BLUE}[INFO] APKEditor로 병합 중... (잠시만 기다려주세요)${NC}"
    rm -f "$MERGED_APK_PATH"
    java -jar "$EDITOR_JAR" m -i "$TEMP_DIR" -o "$MERGED_APK_PATH" &> /dev/null || {
        echo -e "${RED}[ERROR] 병합 실패${NC}"
        rm -rf "$TEMP_DIR"
        return 1
    }
    
    if [ ! -f "$MERGED_APK_PATH" ]; then
        echo -e "${RED}[ERROR] 병합된 파일 생성 실패${NC}"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    
    echo -e "${GREEN}[SUCCESS] 병합 완료: $(basename "$MERGED_APK_PATH")${NC}"
    rm -rf "$TEMP_DIR"
    return 0
}

# --- Run Patch (Morphe CLI 직접 호출 방식) ---
run_patch() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    Morphe 패치 시작... (패치 메뉴 로딩)${NC}"
    echo -e "${GREEN}========================================${NC}"

    # questionary 설치 확인 (TUI 인터랙션에 필요)
    if ! python -c "import questionary" &>/dev/null; then
        echo -e "${YELLOW}[INFO] questionary 설치 중...${NC}"
        pip install questionary -q || pip3 install questionary -q
    fi

    # ─────────────────────────────────────────────────────────────────────
    # 서명 키스토어 준비
    # KakaoTalk_Patched_unclone.apk와 동일한 서명 → 업데이트 가능
    # 전략: GitHub의 my_kakao_key.keystore(원본) → BKS 변환 → morphe-cli 전달
    # ─────────────────────────────────────────────────────────────────────

    # 1) BC provider JAR 준비 (BKS 변환에 필수)
    local BC_JAR="$PATCH_SCRIPT_DIR/bcprov.jar"
    if [ ! -f "$BC_JAR" ]; then
        echo -e "${YELLOW}[INFO] BouncyCastle 프로바이더 다운로드 중...${NC}"
        curl -L -s -o "$BC_JAR" \
            "https://repo1.maven.org/maven2/org/bouncycastle/bcprov-jdk18on/1.78.1/bcprov-jdk18on-1.78.1.jar" || {
            echo -e "${RED}[ERROR] BC 프로바이더 다운로드 실패${NC}"
            return 1
        }
        echo -e "${GREEN}[OK] BouncyCastle 프로바이더 준비 완료${NC}"
    fi

    # 2) 변환된 BKS 키스토어가 이미 유효하면 재사용 (서명 일관성 유지)
    local KS_VALID=0
    if [ -f "$KEYSTORE_FILE" ]; then
        keytool -list \
            -keystore "$KEYSTORE_FILE" \
            -storetype BKS \
            -provider org.bouncycastle.jce.provider.BouncyCastleProvider \
            -providerpath "$BC_JAR" \
            -storepass "$STORE_PASS" &>/dev/null && KS_VALID=1
    fi

    if [ $KS_VALID -eq 1 ]; then
        echo -e "${GREEN}[OK] 기존 BKS 키스토어 재사용 (업데이트 서명 일관성 유지): $KEYSTORE_FILE${NC}"
    else
        # 3) GitHub에서 원본 키스토어 다운로드 (KakaoTalk_Patched_unclone.apk에 사용된 키)
        echo -e "${BLUE}[INFO] GitHub에서 원본 키스토어 다운로드 중...${NC}"
        echo -e "${YELLOW}[INFO] (이 키가 설치된 APK와 동일한 서명 키입니다)${NC}"
        curl -L -s -o "$ORIG_KEYSTORE_FILE" "$GITHUB_KEYSTORE_URL" || {
            echo -e "${RED}[ERROR] 원본 키스토어 다운로드 실패!${NC}"
            return 1
        }

        if [ ! -s "$ORIG_KEYSTORE_FILE" ]; then
            echo -e "${RED}[ERROR] 다운로드된 키스토어 파일이 비어 있습니다.${NC}"
            return 1
        fi
        echo -e "${GREEN}[OK] 원본 키스토어 다운로드 완료: $ORIG_KEYSTORE_FILE${NC}"

        # 4) 원본이 이미 BKS인지 확인
        local ORIG_IS_BKS=0
        keytool -list \
            -keystore "$ORIG_KEYSTORE_FILE" \
            -storetype BKS \
            -provider org.bouncycastle.jce.provider.BouncyCastleProvider \
            -providerpath "$BC_JAR" \
            -storepass "$STORE_PASS" &>/dev/null && ORIG_IS_BKS=1

        if [ $ORIG_IS_BKS -eq 1 ]; then
            # 원본이 이미 BKS → 그대로 사용
            echo -e "${GREEN}[OK] 원본 키스토어가 이미 BKS 형식입니다. 직접 사용합니다.${NC}"
            cp -f "$ORIG_KEYSTORE_FILE" "$KEYSTORE_FILE"
        else
            # 5) JKS/PKCS12 → PKCS12 임시 변환 → BKS 변환
            echo -e "${YELLOW}[INFO] 원본 키스토어를 BKS 형식으로 변환 중...${NC}"
            local TEMP_P12="$PATCH_SCRIPT_DIR/temp_kakao.p12"
            rm -f "$TEMP_P12" "$KEYSTORE_FILE"

            # Step A: 원본 → PKCS12
            keytool -importkeystore \
                -srckeystore "$ORIG_KEYSTORE_FILE" \
                -destkeystore "$TEMP_P12" \
                -deststoretype PKCS12 \
                -srcalias "$KEY_ALIAS" \
                -destalias "$KEY_ALIAS" \
                -srcstorepass "$STORE_PASS" \
                -deststorepass "$STORE_PASS" \
                -srckeypass "$KEY_PASS" \
                -destkeypass "$KEY_PASS" \
                -noprompt &>/dev/null || {
                echo -e "${RED}[ERROR] PKCS12 변환 실패! alias/password를 확인하세요.${NC}"
                rm -f "$TEMP_P12"
                return 1
            }

            # Step B: PKCS12 → BKS
            keytool -importkeystore \
                -srckeystore "$TEMP_P12" \
                -srcstoretype PKCS12 \
                -destkeystore "$KEYSTORE_FILE" \
                -deststoretype BKS \
                -provider org.bouncycastle.jce.provider.BouncyCastleProvider \
                -providerpath "$BC_JAR" \
                -srcalias "$KEY_ALIAS" \
                -destalias "$KEY_ALIAS" \
                -srcstorepass "$STORE_PASS" \
                -deststorepass "$STORE_PASS" \
                -srckeypass "$KEY_PASS" \
                -destkeypass "$KEY_PASS" \
                -noprompt &>/dev/null || {
                echo -e "${RED}[ERROR] BKS 변환 실패!${NC}"
                rm -f "$TEMP_P12" "$KEYSTORE_FILE"
                return 1
            }
            rm -f "$TEMP_P12"
            echo -e "${GREEN}[OK] BKS 변환 완료: $KEYSTORE_FILE${NC}"
        fi

        # 6) 최종 BKS 유효성 검증
        if ! keytool -list \
                -keystore "$KEYSTORE_FILE" \
                -storetype BKS \
                -provider org.bouncycastle.jce.provider.BouncyCastleProvider \
                -providerpath "$BC_JAR" \
                -storepass "$STORE_PASS" &>/dev/null; then
            echo -e "${RED}[ERROR] BKS 키스토어 검증 실패! 변환이 올바르지 않습니다.${NC}"
            return 1
        fi
        echo -e "${GREEN}[OK] BKS 키스토어 검증 완료. 설치된 APK와 동일한 서명키로 패치합니다.${NC}"
    fi

    # 작업 디렉토리 초기화
    local WORK_DIR="$PATCH_SCRIPT_DIR/work"
    rm -rf "$WORK_DIR" && mkdir -p "$WORK_DIR"

    # morphe-cli 직접 호출하는 독립 TUI 스크립트 생성
    cat << 'PYEOF' > "$PATCH_SCRIPT_DIR/morphe_patch.py"
"""Morphe 패치 TUI - morphe-cli를 직접 호출하는 독립 스크립트."""
import os
import sys
import subprocess

def check_java():
    import re, shutil
    if shutil.which('java') is None:
        print("[ERR] java가 PATH에 없습니다.")
        sys.exit(1)
    r = subprocess.run(['java', '-version'], capture_output=True, text=True, errors='replace')
    out = (r.stdout or r.stderr or "").strip()
    m = re.search(r'version "([^"]+)"', out)
    if not m:
        print(f"[ERR] Java 버전 파싱 실패:\n{out}")
        sys.exit(1)
    parts = m.group(1).split('.')
    major = int(parts[1]) if parts[0] == '1' else int(parts[0].split('-')[0])
    print(f"[OK] Java detected (version {major}):\n{out}")
    if not (17 <= major < 25):
        print(f"[ERR] 지원되지 않는 Java 버전: {major}. 17~24 범위여야 합니다.")
        sys.exit(1)
    print(f"[OK] Java version {major} is supported.")

def list_patches(cli_jar, mpp_file):
    cmd = ['java', '-jar', cli_jar, 'list-patches',
           f'--patches={mpp_file}',
           '--with-packages', '--with-versions', '--with-options']
    print(f"[INFO] 패치 목록 조회 중...")
    proc = subprocess.run(cmd, capture_output=True, text=True, errors='replace')
    if proc.returncode != 0:
        print(f"[ERR] list-patches 실패:\n{proc.stderr}")
        sys.exit(5)
    return proc.stdout

def parse_patches(text, target_pkg=None, include_universal=False):
    import re
    idx_pat = re.compile(r'(?m)^\s*Index:\s*\d+\s*$')
    matches = list(idx_pat.finditer(text))
    blocks = []
    if matches:
        for i, m in enumerate(matches):
            start = m.start()
            end = matches[i+1].start() if i+1 < len(matches) else len(text)
            blocks.append(text[start:end])
    else:
        blocks = [text]

    entries = []
    for block in blocks:
        raw = block.strip('\n')
        if not raw:
            continue
        entry = {'index': None, 'name': None, 'description': None,
                  'enabled': None, 'packages': [], 'is_universal': False}
        m = re.search(r'(?m)^\s*Index:\s*(\d+)\s*$', block)
        if m: entry['index'] = int(m.group(1))
        m = re.search(r'(?m)^\s*Name:\s*(.+?)\s*$', block)
        if m: entry['name'] = m.group(1).strip()
        m = re.search(r'(?m)^\s*Description:\s*(.+?)\s*$', block)
        if m: entry['description'] = m.group(1).strip()
        m = re.search(r'(?m)^\s*Enabled:\s*(true|false)\s*$', block)
        if m: entry['enabled'] = (m.group(1) == 'true')

        # Compatible packages 섹션
        compat_m = re.search(r'(?ms)Compatible packages\s*:\s*\n(.+?)(?=\n\s*[A-Z]|\Z)', block)
        if compat_m:
            pkg_matches = re.findall(r'Package(?:\s+name)?\s*:\s*(.+)', compat_m.group(1))
            for p in pkg_matches:
                if p.strip() and p.strip() not in entry['packages']:
                    entry['packages'].append(p.strip())
        # Packages: 한줄 형태
        m = re.search(r'(?m)^\s*Packages?\s*:\s*(.+?)\s*$', block)
        if m:
            for p in m.group(1).split(','):
                if p.strip() and p.strip() not in entry['packages']:
                    entry['packages'].append(p.strip())

        entry['is_universal'] = (len(entry['packages']) == 0)
        entries.append(entry)

    if target_pkg:
        tp = target_pkg.lower()
        entries = [e for e in entries
                   if tp in [p.lower() for p in e['packages']]
                   or (include_universal and e['is_universal'])]
    return entries

def interactive_select(entries):
    from questionary import checkbox
    if not entries:
        print("[ERR] 필터 조건에 맞는 패치가 없습니다.")
        sys.exit(7)
    choices = []
    for e in entries:
        left = f"[{e['index']}]" if e['index'] is not None else "[—]"
        name = e['name'] or '(이름 없음)'
        tags = []
        if e.get('enabled'): tags.append("기본 활성화")
        if e.get('is_universal'): tags.append("유니버설")
        if e.get('packages'): tags.append(f"패키지: {', '.join(e['packages'])}")
        label = f"{left} {name}" + (f" — {' | '.join(tags)}" if tags else "")
        value = ('idx', e['index']) if e['index'] is not None else ('name', name)
        choices.append({"name": label, "value": value, "checked": bool(e.get('enabled', False))})

    result = checkbox(
        "패치를 선택하세요 (스페이스바로 토글, 엔터로 확인):",
        choices=choices,
        validate=lambda ans: True if len(ans) >= 1 else "최소 1개 이상 선택하세요.",
        qmark="> "
    ).ask()
    if result is None:
        print("[INFO] 취소됨.")
        sys.exit(0)
    return result

def build_cmd(cli_jar, mpp_file, apk_path, out_apk,
              selected, keystore, ks_pass, key_alias, key_pass):
    cmd = ['java', '-jar', cli_jar, 'patch',
           f'--patches={mpp_file}', '--exclusive']
    for kind, val in selected:
        if kind == 'idx':
            cmd.extend(['--ei', str(val)])
        else:
            cmd.extend(['-e', str(val)])
    if keystore:  cmd.extend(['--keystore', keystore])
    if ks_pass:   cmd.extend(['--keystore-password', ks_pass])
    if key_alias: cmd.extend(['--keystore-entry-alias', key_alias])
    if key_pass:  cmd.extend(['--keystore-entry-password', key_pass])
    cmd.extend(['-o', out_apk, apk_path])
    return cmd

def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--cli',           required=True)
    parser.add_argument('--mpp',           required=True)
    parser.add_argument('--apk',           required=True)
    parser.add_argument('--output',        default='output/patched.apk')
    parser.add_argument('--package',       default=None)
    parser.add_argument('--include-universal', action='store_true')
    parser.add_argument('--keystore',      default=None)
    parser.add_argument('--keystore-password', default=None)
    parser.add_argument('--key-alias',     default=None)
    parser.add_argument('--key-password',  default=None)
    args = parser.parse_args()

    check_java()

    if not os.path.isfile(args.apk):
        print(f"[ERR] APK 파일을 찾을 수 없습니다: {args.apk}")
        sys.exit(3)
    print(f"[OK] Target APK: {args.apk}")

    if not os.path.isfile(args.cli):
        print(f"[ERR] morphe-cli.jar를 찾을 수 없습니다: {args.cli}")
        sys.exit(3)

    if not os.path.isfile(args.mpp):
        print(f"[ERR] MPP 파일을 찾을 수 없습니다: {args.mpp}")
        sys.exit(3)

    list_text = list_patches(args.cli, args.mpp)
    entries = parse_patches(list_text,
                            target_pkg=args.package,
                            include_universal=args.include_universal)

    if args.package:
        print(f"[INFO] 패키지 필터: '{args.package}'" +
              (" + 유니버설 포함" if args.include_universal else ""))
    else:
        print("[INFO] 패키지 필터 없음. 모든 패치 표시.")

    selected = interactive_select(entries)

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    cmd = build_cmd(
        cli_jar=args.cli, mpp_file=args.mpp,
        apk_path=args.apk, out_apk=args.output,
        selected=selected,
        keystore=args.keystore,
        ks_pass=args.keystore_password,
        key_alias=args.key_alias,
        key_pass=args.key_password
    )

    print("\n[CMD] 실행할 패치 커맨드:")
    print(' '.join(f'"{c}"' if ' ' in c else c for c in cmd))
    print("\n[RUN] 패치 실행 중...")
    proc = subprocess.run(cmd)
    if proc.returncode == 0:
        print(f"[DONE] 패치 완료: {args.output}")
    else:
        print(f"[ERR] 패치 실패 (exit code {proc.returncode})")
        sys.exit(proc.returncode)

if __name__ == '__main__':
    main()
PYEOF

    echo -e "${BLUE}[INFO] 패치 선택 메뉴를 엽니다...${NC}"

    local OUTPUT_APK="$WORK_DIR/patched.apk"

    python "$PATCH_SCRIPT_DIR/morphe_patch.py" \
        --cli "$MORPHE_CLI_JAR" \
        --mpp "$MPP_FILE" \
        --apk "$MERGED_APK_PATH" \
        --output "$OUTPUT_APK" \
        --package "$PKG_NAME" \
        --include-universal \
        --keystore "$KEYSTORE_FILE" \
        --key-alias "$KEY_ALIAS" \
        --keystore-password "$STORE_PASS" \
        --key-password "$KEY_PASS" || {
        echo -e "${RED}[ERROR] 패치 과정 중 오류 발생${NC}"
        return 1
    }

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    패치 완료!${NC}"
    echo -e "${GREEN}========================================${NC}"

    if [ -f "$OUTPUT_APK" ]; then
        echo -e "${BLUE}[INFO] 결과물을 다운로드 폴더로 이동합니다...${NC}"
        mv -f "$OUTPUT_APK" "$BASE_DIR/kakaotalkpatch.apk"
        echo -e "${GREEN}[SUCCESS] 저장 완료: $BASE_DIR/kakaotalkpatch.apk${NC}"
    else
        echo -e "${RED}[ERROR] 결과물 파일을 찾을 수 없습니다.${NC}"
        return 1
    fi
}

# --- Main ---
main() {
    clear
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  카카오톡 APKM 병합 & Morphe 패치${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    
    check_dependencies || exit 1
    get_apkm_file || exit 0
    fetch_mpp_from_github || exit 1
    merge_apkm || exit 1
    run_patch || exit 1
    
    echo -e "${GREEN}모든 작업이 끝났습니다.${NC}"
}

main
