#!/bin/bash
#
# KakaoTalk APKM → 서명된 APK (패치 없음)
# patch5.sh의 키스토어/서명 방식만 그대로 사용
#
set -e

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration (patch5.sh 동일)
BASE_DIR="/storage/emulated/0/Download"
MERGED_APK_PATH="$HOME/Downloads/KakaoTalk_Merged.apk"
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"

# GitHub 키스토어 URL (patch5.sh 동일 + 대체 URL)
KEYSTORE_URL_PRIMARY="https://github.com/anycall6779/K-K-0_rev-nced_p-tch/raw/refs/heads/main/my_kakao_key.keystore"
KEYSTORE_URL_FALLBACK="https://raw.githubusercontent.com/anycall6779/K-K-0_rev-nced_p-tch/main/my_kakao_key.keystore"
KEYSTORE_FILE="my_kakao_key.keystore"
KEYSTORE_PASS="android"

# --- 의존성 확인 ---
check_dependencies() {
    echo -e "${BLUE}[INFO] 필수 도구 확인 중...${NC}"
    local MISSING=0

    for cmd in curl unzip java keytool; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}[ERROR] '$cmd' 가 없습니다. 설치: pkg install $cmd${NC}"
            MISSING=1
        fi
    done

    if [ ! -f "$EDITOR_JAR" ]; then
        echo -e "${YELLOW}[INFO] APKEditor 다운로드 중...${NC}"
        curl -L -o "$EDITOR_JAR" \
            "https://github.com/REAndroid/APKEditor/releases/download/V1.4.5/APKEditor-1.4.5.jar" || {
            echo -e "${RED}[ERROR] APKEditor 다운로드 실패${NC}"
            MISSING=1
        }
    fi

    [ $MISSING -eq 1 ] && exit 1
    mkdir -p "$HOME/Downloads"
    echo -e "${GREEN}[OK] 준비 완료${NC}"
}

# --- APKM 파일 선택 (patch5.sh 동일) ---
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

# --- APKM 병합 (patch5.sh 동일) ---
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

# --- 키스토어 다운로드 및 검증 (patch5.sh 방식 + 디버깅) ---
download_and_verify_keystore() {
    echo -e "${YELLOW}[INFO] 고정 키스토어(my_kakao_key.keystore) 다운로드 중...${NC}"

    # 1차: patch5.sh 동일 URL
    rm -f "$KEYSTORE_FILE"
    curl -L -o "$KEYSTORE_FILE" "$KEYSTORE_URL_PRIMARY" 2>/dev/null

    # 다운로드 실패 시 대체 URL 시도
    if [ ! -f "$KEYSTORE_FILE" ] || [ ! -s "$KEYSTORE_FILE" ]; then
        echo -e "${YELLOW}[WARN] 1차 URL 실패, 대체 URL 시도 중...${NC}"
        rm -f "$KEYSTORE_FILE"
        curl -L -o "$KEYSTORE_FILE" "$KEYSTORE_URL_FALLBACK" 2>/dev/null
    fi

    # 파일 존재/크기 확인
    if [ ! -f "$KEYSTORE_FILE" ]; then
        echo -e "${RED}[ERROR] 키스토어 다운로드 실패 (파일 없음)${NC}"
        return 1
    fi

    local FILE_SIZE=$(wc -c < "$KEYSTORE_FILE" 2>/dev/null || echo 0)
    echo -e "${BLUE}[DEBUG] 다운로드된 파일 크기: ${FILE_SIZE} bytes${NC}"

    if [ "$FILE_SIZE" -lt 100 ]; then
        echo -e "${RED}[ERROR] 파일이 너무 작습니다 (${FILE_SIZE}B). 다운로드 실패로 보입니다.${NC}"
        return 1
    fi

    # HTML 오다운로드 체크
    local HEAD_CONTENT=$(head -c 100 "$KEYSTORE_FILE" 2>/dev/null)
    if echo "$HEAD_CONTENT" | grep -qiE '<!doctype|<html|<head|404|Not Found'; then
        echo -e "${RED}[ERROR] 키스토어 대신 HTML/에러 페이지가 다운로드됨${NC}"
        echo -e "${RED}[DEBUG] 파일 시작 내용: $(head -c 50 "$KEYSTORE_FILE")${NC}"
        return 1
    fi

    # 첫 바이트 hex 확인 (디버깅)
    local HEX_HEAD=$(xxd -l 4 -p "$KEYSTORE_FILE" 2>/dev/null || od -A n -t x1 -N 4 "$KEYSTORE_FILE" 2>/dev/null | tr -d ' ')
    echo -e "${BLUE}[DEBUG] 파일 시작 hex: ${HEX_HEAD}${NC}"

    # patch5.sh 동일: keytool로 타입 감지
    if keytool -list -keystore "$KEYSTORE_FILE" -storepass "$KEYSTORE_PASS" -storetype PKCS12 >/dev/null 2>&1; then
        KEYSTORE_TYPE="PKCS12"
    elif keytool -list -keystore "$KEYSTORE_FILE" -storepass "$KEYSTORE_PASS" -storetype JKS >/dev/null 2>&1; then
        KEYSTORE_TYPE="JKS"
    else
        echo -e "${RED}[ERROR] keytool이 키스토어를 읽지 못했습니다.${NC}"
        echo -e "${YELLOW}[DEBUG] keytool PKCS12 오류:${NC}"
        keytool -list -keystore "$KEYSTORE_FILE" -storepass "$KEYSTORE_PASS" -storetype PKCS12 2>&1 || true
        echo -e "${YELLOW}[DEBUG] keytool JKS 오류:${NC}"
        keytool -list -keystore "$KEYSTORE_FILE" -storepass "$KEYSTORE_PASS" -storetype JKS 2>&1 || true
        return 1
    fi

    echo -e "${GREEN}[OK] 키스토어 타입: $KEYSTORE_TYPE${NC}"
    KEYSTORE_PATH="$(pwd)/$KEYSTORE_FILE"
    return 0
}

# --- 서명 ---
sign_apk() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    APK 서명 시작...${NC}"
    echo -e "${GREEN}========================================${NC}"

    download_and_verify_keystore || {
        echo -e "${RED}[ERROR] 키스토어 준비 실패${NC}"
        return 1
    }

    # apksigner로 서명
    echo -e "${BLUE}[INFO] apksigner로 서명 중...${NC}"
    local SIGNED_APK="/storage/emulated/0/Download/KakaoTalk_Signed.apk"
    rm -f "$SIGNED_APK"

    apksigner sign \
        --ks "$KEYSTORE_PATH" \
        --ks-pass "pass:$KEYSTORE_PASS" \
        --key-pass "pass:$KEYSTORE_PASS" \
        --ks-type "$KEYSTORE_TYPE" \
        --out "$SIGNED_APK" \
        "$MERGED_APK_PATH" || {
        echo -e "${RED}[ERROR] 서명 실패${NC}"
        return 1
    }

    if [ -f "$SIGNED_APK" ]; then
        echo ""
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}    서명 완료!${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}[SUCCESS] 저장 완료: $SIGNED_APK${NC}"
    else
        echo -e "${RED}[ERROR] 서명된 APK 생성 실패${NC}"
        return 1
    fi
}

# --- Main ---
main() {
    clear
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  APKM → 서명된 APK (패치 없음)${NC}"
    echo -e "${GREEN}  (patch5.sh 서명 방식 동일)${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""

    check_dependencies || exit 1
    get_apkm_file || exit 0
    merge_apkm || exit 1
    sign_apk || exit 1

    echo -e "${GREEN}모든 작업이 끝났습니다.${NC}"
}

main
