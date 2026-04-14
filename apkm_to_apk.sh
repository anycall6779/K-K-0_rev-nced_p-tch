#!/bin/bash
#
# KakaoTalk APKM → 서명된 APK (패치 없음)
# patch5.sh의 키스토어를 그대로 사용하되,
# BKS 형식을 PKCS12로 변환 후 apksigner로 서명
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
KEYSTORE_P12="$WORK_DIR/my_kakao_key.p12"
KEYSTORE_PASS="android"

# Bouncy Castle (BKS→PKCS12 변환에 필요)
BCPROV_JAR="$WORK_DIR/bcprov-jdk18on-1.78.1.jar"
BCPROV_URL="https://repo1.maven.org/maven2/org/bouncycastle/bcprov-jdk18on/1.78.1/bcprov-jdk18on-1.78.1.jar"

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

# --- 키스토어 준비 (BKS → PKCS12 변환) ---
prepare_keystore() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    키스토어 준비 중...${NC}"
    echo -e "${GREEN}========================================${NC}"

    # 1) BKS 키스토어 다운로드 (patch5.sh 동일 URL, 동일 curl 플래그)
    echo -e "${YELLOW}[INFO] 고정 키스토어 다운로드 중...${NC}"
    rm -f "$KEYSTORE_BKS"
    curl -L -o "$KEYSTORE_BKS" "$KEYSTORE_URL" || {
        echo -e "${RED}[ERROR] 키스토어 다운로드 실패!${NC}"
        return 1
    }

    if [ ! -s "$KEYSTORE_BKS" ]; then
        echo -e "${RED}[ERROR] 키스토어 파일이 비어 있습니다.${NC}"
        return 1
    fi

    local FILE_SIZE=$(wc -c < "$KEYSTORE_BKS")
    echo -e "${BLUE}[INFO] 다운로드 완료 (${FILE_SIZE} bytes)${NC}"

    # 2) Bouncy Castle provider 다운로드 (BKS 읽기에 필요)
    if [ ! -f "$BCPROV_JAR" ] || [ ! -s "$BCPROV_JAR" ]; then
        echo -e "${YELLOW}[INFO] Bouncy Castle provider 다운로드 중...${NC}"
        curl -L -o "$BCPROV_JAR" "$BCPROV_URL" 2>/dev/null || {
            echo -e "${RED}[ERROR] Bouncy Castle 다운로드 실패${NC}"
            return 1
        }
    fi

    if [ ! -s "$BCPROV_JAR" ]; then
        echo -e "${RED}[ERROR] Bouncy Castle JAR가 비어 있습니다.${NC}"
        return 1
    fi
    echo -e "${GREEN}[OK] Bouncy Castle 준비됨${NC}"

    # 3) BKS 키스토어 읽기 확인
    echo -e "${BLUE}[INFO] BKS 키스토어 검증 중...${NC}"
    if ! keytool -list \
        -providerclass org.bouncycastle.jce.provider.BouncyCastleProvider \
        -providerpath "$BCPROV_JAR" \
        -keystore "$KEYSTORE_BKS" \
        -storetype BKS \
        -storepass "$KEYSTORE_PASS" >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] BKS 키스토어 읽기 실패${NC}"
        echo -e "${YELLOW}[DEBUG] 상세 오류:${NC}"
        keytool -list \
            -providerclass org.bouncycastle.jce.provider.BouncyCastleProvider \
            -providerpath "$BCPROV_JAR" \
            -keystore "$KEYSTORE_BKS" \
            -storetype BKS \
            -storepass "$KEYSTORE_PASS" 2>&1 || true
        return 1
    fi

    # alias 이름 추출
    local ALIAS_NAME=$(keytool -list \
        -providerclass org.bouncycastle.jce.provider.BouncyCastleProvider \
        -providerpath "$BCPROV_JAR" \
        -keystore "$KEYSTORE_BKS" \
        -storetype BKS \
        -storepass "$KEYSTORE_PASS" 2>/dev/null | grep -oP '^[^,]+(?=,)')
    echo -e "${BLUE}[INFO] 키스토어 별칭(alias): ${ALIAS_NAME:-감지실패}${NC}"

    # 4) BKS → PKCS12 변환
    echo -e "${YELLOW}[INFO] BKS → PKCS12 변환 중...${NC}"
    rm -f "$KEYSTORE_P12"
    keytool -importkeystore -noprompt \
        -providerclass org.bouncycastle.jce.provider.BouncyCastleProvider \
        -providerpath "$BCPROV_JAR" \
        -srckeystore "$KEYSTORE_BKS" \
        -srcstoretype BKS \
        -srcstorepass "$KEYSTORE_PASS" \
        -destkeystore "$KEYSTORE_P12" \
        -deststoretype PKCS12 \
        -deststorepass "$KEYSTORE_PASS" \
        -destkeypass "$KEYSTORE_PASS" 2>&1 || {
        echo -e "${RED}[ERROR] BKS → PKCS12 변환 실패${NC}"
        return 1
    }

    if [ ! -s "$KEYSTORE_P12" ]; then
        echo -e "${RED}[ERROR] 변환된 PKCS12 파일이 비어 있습니다.${NC}"
        return 1
    fi

    # 5) 변환된 PKCS12 검증
    if keytool -list -keystore "$KEYSTORE_P12" -storepass "$KEYSTORE_PASS" -storetype PKCS12 >/dev/null 2>&1; then
        echo -e "${GREEN}[OK] PKCS12 변환 및 검증 성공${NC}"
    else
        echo -e "${RED}[ERROR] 변환된 PKCS12 검증 실패${NC}"
        return 1
    fi

    return 0
}

# --- APK 서명 ---
sign_apk() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    APK 서명 중...${NC}"
    echo -e "${GREEN}========================================${NC}"

    local SIGNED_APK="$BASE_DIR/KakaoTalk_Signed.apk"
    rm -f "$SIGNED_APK"

    echo -e "${BLUE}[INFO] apksigner 서명 실행...${NC}"
    apksigner sign \
        --ks "$KEYSTORE_P12" \
        --ks-pass "pass:$KEYSTORE_PASS" \
        --key-pass "pass:$KEYSTORE_PASS" \
        --ks-type PKCS12 \
        --out "$SIGNED_APK" \
        "$MERGED_APK_PATH" || {
        echo -e "${RED}[ERROR] apksigner 서명 실패${NC}"
        return 1
    }

    if [ ! -f "$SIGNED_APK" ]; then
        echo -e "${RED}[ERROR] 서명된 APK 생성 실패${NC}"
        return 1
    fi

    # 서명 검증
    if apksigner verify "$SIGNED_APK" >/dev/null 2>&1; then
        echo -e "${GREEN}[OK] 서명 검증 통과${NC}"
    else
        echo -e "${RED}[WARN] 서명 검증 실패${NC}"
    fi

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    서명 완료!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}[SUCCESS] 저장 완료: $SIGNED_APK${NC}"
}

# --- 임시 파일 정리 ---
cleanup() {
    rm -f "$KEYSTORE_P12" "$MERGED_APK_PATH"
    echo -e "${BLUE}[INFO] 임시 파일 정리 완료${NC}"
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
    merge_apkm || exit 1
    prepare_keystore || exit 1
    sign_apk || exit 1
    cleanup

    echo ""
    echo -e "${GREEN}모든 작업이 끝났습니다.${NC}"
}

main
