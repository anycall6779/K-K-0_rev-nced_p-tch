#!/bin/bash
#
# KakaoTalk APKM → 서명된 APK (패치 없음)
# patch5.sh와 동일한 방식으로 키스토어를 사용하여 서명
# 로컬 keystore 또는 GitHub에서 자동 다운로드
#
set -e

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
BASE_DIR="/storage/emulated/0/Download"
WORK_DIR="$HOME/Downloads"
MERGED_APK_PATH="$WORK_DIR/KakaoTalk_Merged.apk"
EDITOR_JAR="$BASE_DIR/APKEditor-1.4.5.jar"

# 키스토어 (patch5.sh 동일 URL)
KEYSTORE_URL="https://github.com/anycall6779/K-K-0_rev-nced_p-tch/raw/refs/heads/main/my_kakao_key.keystore"
KEYSTORE_BKS="$WORK_DIR/my_kakao_key.keystore"
KEYSTORE_PASS="android"
KEYSTORE_TYPE=""  # 자동 감지됨: PKCS12 또는 JKS

# --- 의존성 확인 ---
check_dependencies() {
    echo -e "${BLUE}[INFO] 필수 도구 확인 중...${NC}"
    local MISSING=0

    for cmd in curl unzip java keytool apksigner; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}[ERROR] '$cmd' 없음. 설치: pkg install $cmd${NC}"
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
    mkdir -p "$WORK_DIR"
    echo -e "${GREEN}[OK] 준비 완료${NC}"
}

# --- APKM 파일 선택 ---
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

# --- APKM 병합 ---
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

# --- 키스토어 준비 (patch5.sh와 동일한 방식) ---
prepare_keystore() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    키스토어 준비 중...${NC}"
    echo -e "${GREEN}========================================${NC}"

    mkdir -p "$WORK_DIR"
    
    # 항상 GitHub에서 다운로드 (로컬 손상 파일 무시)
    echo -e "${YELLOW}[INFO] GitHub에서 키스토어 다운로드 중...${NC}"
    
    # 기존 파일 삭제
    rm -f "$KEYSTORE_BKS"
    
    # patch5.sh와 동일한 curl 옵션 사용
    if ! curl -L -o "$KEYSTORE_BKS" "$KEYSTORE_URL"; then
        echo -e "${RED}[ERROR] 키스토어 다운로드 실패!${NC}"
        return 1
    fi

    if [ ! -s "$KEYSTORE_BKS" ]; then
        echo -e "${RED}[ERROR] 다운로드된 키스토어가 비어 있습니다.${NC}"
        rm -f "$KEYSTORE_BKS"
        return 1
    fi

    local FILE_SIZE=$(wc -c < "$KEYSTORE_BKS")
    echo -e "${BLUE}[INFO] 다운로드 완료 (${FILE_SIZE} bytes)${NC}"

    # 키스토어 형식 감지 및 검증 (patch5.sh와 동일)
    echo -e "${BLUE}[INFO] 키스토어 형식 감지 중...${NC}"
    
    if keytool -list -keystore "$KEYSTORE_BKS" -storepass "$KEYSTORE_PASS" -storetype PKCS12 >/dev/null 2>&1; then
        KEYSTORE_TYPE="PKCS12"
        echo -e "${GREEN}[OK] 형식: PKCS12${NC}"
    elif keytool -list -keystore "$KEYSTORE_BKS" -storepass "$KEYSTORE_PASS" -storetype JKS >/dev/null 2>&1; then
        KEYSTORE_TYPE="JKS"
        echo -e "${GREEN}[OK] 형식: JKS${NC}"
    else
        echo -e "${RED}[ERROR] 키스토어 형식을 읽을 수 없습니다!${NC}"
        echo -e "${YELLOW}[DEBUG] keytool 상세 정보:${NC}"
        keytool -list -keystore "$KEYSTORE_BKS" -storepass "$KEYSTORE_PASS" -storetype PKCS12 2>&1 || true
        echo ""
        echo -e "${YELLOW}[솔루션]${NC}"
        echo -e "  GitHub URL에서 새 keystore 다운로드 시도..."
        echo -e "  curl -L -o /tmp/ks_test.keystore \"$KEYSTORE_URL\""
        return 1
    fi

    echo -e "${GREEN}[OK] 키스토어 준비 완료 ($KEYSTORE_TYPE)${NC}"
    return 0
}

# --- APK 서명 (patch5.sh와 동일한 방식) ---
sign_apk() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    APK 서명 중...${NC}"
    echo -e "${GREEN}========================================${NC}"

    local SIGNED_APK="$BASE_DIR/KakaoTalk_Signed.apk"
    rm -f "$SIGNED_APK"

    echo -e "${BLUE}[INFO] apksigner로 서명 중...${NC}"
    
    # patch5.sh와 동일한 방식으로 직접 서명
    if ! apksigner sign \
        --ks "$KEYSTORE_BKS" \
        --ks-pass "pass:$KEYSTORE_PASS" \
        --key-pass "pass:$KEYSTORE_PASS" \
        --ks-type "$KEYSTORE_TYPE" \
        --out "$SIGNED_APK" \
        "$MERGED_APK_PATH"; then
        echo -e "${RED}[ERROR] apksigner 서명 실패${NC}"
        return 1
    fi

    if [ ! -f "$SIGNED_APK" ]; then
        echo -e "${RED}[ERROR] 서명된 APK 생성 실패${NC}"
        return 1
    fi

    echo -e "${BLUE}[INFO] 서명 검증 중...${NC}"
    # 서명 검증
    if apksigner verify "$SIGNED_APK" >/dev/null 2>&1; then
        echo -e "${GREEN}[OK] 서명 검증 통과${NC}"
    else
        echo -e "${YELLOW}[WARN] 서명 검증 경고 (계속 진행)${NC}"
    fi

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    서명 완료!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}[SUCCESS] 저장 완료: $SIGNED_APK${NC}"
}

# --- 임시 파일 정리 ---
cleanup() {
    echo -e "${BLUE}[INFO] 임시 파일 정리 중...${NC}"
    rm -f "$MERGED_APK_PATH"
    echo -e "${BLUE}[INFO] 정리 완료${NC}"
}

# --- Main ---
main() {
    clear
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  APKM → 서명된 APK (패치 없음)${NC}"
    echo -e "${GREEN}  (patch5.sh 동일 키스토어 사용)${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""

    check_dependencies || exit 1
    get_apkm_file || exit 0
    merge_apkm || { cleanup; exit 1; }
    prepare_keystore || { cleanup; exit 1; }
    sign_apk || { cleanup; exit 1; }
    cleanup

    echo ""
    echo -e "${GREEN}✓ 모든 작업이 성공했습니다!${NC}"
}

main
