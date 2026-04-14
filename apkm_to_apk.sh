#!/bin/bash
#
# patch5.sh 기반: APKM 병합 후 "패치 없이" 동일 keystore로 서명만 수행
# Termux 전용
#
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

BASE_DIR="/storage/emulated/0/Download"
WORK_DIR="$HOME/patch5-nopatch"
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"

KEYSTORE_URL="https://raw.githubusercontent.com/anycall6779/K-K-0_rev-nced_p-tch/main/my_kakao_key.keystore"
KEYSTORE_FILE="$WORK_DIR/my_kakao_key.keystore"
KEYSTORE_PASS="android"
KEYSTORE_TYPE=""
BCPROV_JAR="$WORK_DIR/bcprov-jdk18on-1.78.1.jar"
BCPROV_URL="https://repo1.maven.org/maven2/org/bouncycastle/bcprov-jdk18on/1.78.1/bcprov-jdk18on-1.78.1.jar"

install_pkg() {
    local cmd="$1"
    local pkg="$1"
    [ "$cmd" = "java" ] && pkg="openjdk-17"
    pkg install -y "$pkg" >/dev/null 2>&1 || apt install -y "$pkg" >/dev/null 2>&1 || true
}

check_dependencies() {
    echo -e "${BLUE}[INFO] 필수 도구 확인 중...${NC}"
    local missing=0
    for cmd in unzip java curl zipalign apksigner keytool; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            install_pkg "$cmd"
            command -v "$cmd" >/dev/null 2>&1 || missing=1
        fi
    done
    [ "$missing" -eq 1 ] && { echo -e "${RED}[ERROR] 필수 도구 설치 실패${NC}"; exit 1; }
    mkdir -p "$WORK_DIR"
    [ -f "$EDITOR_JAR" ] || curl -L -o "$EDITOR_JAR" "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar"
}

ensure_bcprov() {
    [ -s "$BCPROV_JAR" ] && return 0
    curl -L -f --connect-timeout 15 --max-time 60 -o "$BCPROV_JAR" "$BCPROV_URL" >/dev/null 2>&1
}

download_keystore() {
    echo -e "${YELLOW}[INFO] 고정 키스토어 다운로드 중...${NC}"
    rm -f "$KEYSTORE_FILE"
    curl -L -f -A "Mozilla/5.0 (Android; Termux)" -o "$KEYSTORE_FILE" "$KEYSTORE_URL" >/dev/null 2>&1 || {
        echo -e "${RED}[ERROR] 키스토어 다운로드 실패${NC}"
        exit 1
    }
}

prepare_signing_keystore() {
    if keytool -list -keystore "$KEYSTORE_FILE" -storepass "$KEYSTORE_PASS" -storetype PKCS12 >/dev/null 2>&1; then
        KEYSTORE_TYPE="PKCS12"
        return 0
    fi
    if keytool -list -keystore "$KEYSTORE_FILE" -storepass "$KEYSTORE_PASS" -storetype JKS >/dev/null 2>&1; then
        KEYSTORE_TYPE="JKS"
        return 0
    fi

    ensure_bcprov || { echo -e "${RED}[ERROR] bcprov 다운로드 실패${NC}"; exit 1; }
    local converted="$WORK_DIR/my_kakao_key.temp.p12"
    keytool -importkeystore -noprompt \
        -providerclass org.bouncycastle.jce.provider.BouncyCastleProvider \
        -providerpath "$BCPROV_JAR" \
        -srckeystore "$KEYSTORE_FILE" \
        -srcstoretype BKS \
        -srcstorepass "$KEYSTORE_PASS" \
        -destkeystore "$converted" \
        -deststoretype PKCS12 \
        -deststorepass "$KEYSTORE_PASS" \
        -destkeypass "$KEYSTORE_PASS" >/dev/null 2>&1 || {
        echo -e "${RED}[ERROR] keystore 변환 실패${NC}"
        exit 1
    }
    KEYSTORE_FILE="$converted"
    KEYSTORE_TYPE="PKCS12"
}

pick_apkm() {
    local files=()
    while IFS= read -r -d '' file; do
        files+=("$(basename "$file")")
    done < <(find "$BASE_DIR" -maxdepth 1 -name "*.apkm" -print0 2>/dev/null)

    echo -e "${GREEN}변환할 APKM 파일 선택${NC}"
    for i in "${!files[@]}"; do
        echo -e "  ${GREEN}$((i+1)).${NC} ${files[$i]}"
    done
    read -r -p "> 번호 입력 (0=직접 경로): " selection
    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#files[@]} ]; then
        APKM_FILE="$BASE_DIR/${files[$((selection-1))]}"
    else
        read -r -p "> APKM 전체 경로: " APKM_FILE
    fi
    [ -f "$APKM_FILE" ] || { echo -e "${RED}[ERROR] APKM 파일 없음${NC}"; exit 1; }
}

merge_and_sign() {
    local temp_dir="$WORK_DIR/temp_merge"
    local merged="$WORK_DIR/merged_unsigned.apk"
    local aligned="$WORK_DIR/merged_aligned.apk"
    local base_name
    base_name="$(basename "$APKM_FILE" .apkm)"
    local final_apk="$BASE_DIR/${base_name}_NoPatch_Signed.apk"

    rm -rf "$temp_dir" && mkdir -p "$temp_dir"
    unzip -qqo "$APKM_FILE" -d "$temp_dir"
    [ -f "$temp_dir/base.apk" ] || { echo -e "${RED}[ERROR] base.apk 없음${NC}"; exit 1; }

    java -jar "$EDITOR_JAR" m -i "$temp_dir" -o "$merged" >/dev/null 2>&1
    [ -f "$merged" ] || { echo -e "${RED}[ERROR] 병합 실패${NC}"; exit 1; }

    if command -v zipalign >/dev/null 2>&1; then
        zipalign -p -f 4 "$merged" "$aligned" >/dev/null 2>&1 || true
        [ -f "$aligned" ] && mv -f "$aligned" "$merged"
    fi

    apksigner sign \
        --ks "$KEYSTORE_FILE" \
        --ks-pass "pass:$KEYSTORE_PASS" \
        --key-pass "pass:$KEYSTORE_PASS" \
        --ks-type "$KEYSTORE_TYPE" \
        --out "$final_apk" "$merged"

    apksigner verify "$final_apk" >/dev/null 2>&1 || { echo -e "${RED}[ERROR] 서명 검증 실패${NC}"; exit 1; }
    local cert_sha256
    cert_sha256="$(apksigner verify --print-certs "$final_apk" 2>/dev/null | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -n1)"
    echo -e "${GREEN}[SUCCESS] 저장 완료: $final_apk${NC}"
    [ -n "$cert_sha256" ] && echo -e "${BLUE}[INFO] 서명 SHA-256: $cert_sha256${NC}"

    rm -rf "$temp_dir" "$merged" "$aligned" "$WORK_DIR/my_kakao_key.temp.p12"
}

main() {
    clear
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  APKM 병합 + 무패치 서명 (patch5 키)${NC}"
    echo -e "${GREEN}======================================${NC}"
    check_dependencies
    download_keystore
    prepare_signing_keystore
    pick_apkm
    merge_and_sign
}

main

