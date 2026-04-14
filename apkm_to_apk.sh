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
KEYSTORE_TYPE=""  # 자동 감지됨: PKCS12, JKS, BKS

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

# --- 키스토어 형식 자동 감지 함수 ---
detect_keystore_type() {
    local ks_path="$1"
    local ks_pass="$2"
    local bcprov_jar="$3"
    
    # PKCS12 시도 (Bouncy Castle 불필요)
    if keytool -list -keystore "$ks_path" -storepass "$ks_pass" -storetype PKCS12 >/dev/null 2>&1; then
        echo "PKCS12"
        return 0
    fi
    
    # JKS 시도
    if keytool -list -keystore "$ks_path" -storepass "$ks_pass" -storetype JKS >/dev/null 2>&1; then
        echo "JKS"
        return 0
    fi
    
    # BKS 시도 (Bouncy Castle 필요)
    if [ -f "$bcprov_jar" ] && [ -s "$bcprov_jar" ]; then
        if keytool -list -keystore "$ks_path" -storepass "$ks_pass" -storetype BKS \
            -providerclass org.bouncycastle.jce.provider.BouncyCastleProvider \
            -providerpath "$bcprov_jar" >/dev/null 2>&1; then
            echo "BKS"
            return 0
        fi
    fi
    
    return 1
}

# --- 키스토어 준비 (다중 형식 지원) ---
prepare_keystore() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    키스토어 준비 중...${NC}"
    echo -e "${GREEN}========================================${NC}"

    # 0) Bouncy Castle 미리 다운로드 (모든 형식 감지에 필요할 수 있음)
    if [ ! -f "$BCPROV_JAR" ] || [ ! -s "$BCPROV_JAR" ]; then
        echo -e "${YELLOW}[INFO] Bouncy Castle 사전 다운로드 중...${NC}"
        rm -f "$BCPROV_JAR"
        if ! curl -L --max-time 60 --retry 3 --retry-delay 2 \
            -o "$BCPROV_JAR" "$BCPROV_URL" 2>/dev/null; then
            echo -e "${YELLOW}[WARN] Bouncy Castle 다운로드 실패 (BKS 형식 감지 불가)${NC}"
        fi
    fi

    # 1) 로컬 키스토어 확인 및 형식 감지
    local FOUND_LOCAL=0
    local LOCAL_KEYSTORE_PATHS=(
        "$WORK_DIR/my_kakao_key.keystore"
        "$HOME/my_kakao_key.keystore"
        "$BASE_DIR/my_kakao_key.keystore"
    )
    
    for path in "${LOCAL_KEYSTORE_PATHS[@]}"; do
        if [ -f "$path" ] && [ -s "$path" ]; then
            local FILE_SIZE=$(wc -c < "$path")
            echo -e "${BLUE}[INFO] 로컬 파일 발견: $path (${FILE_SIZE} bytes)${NC}"
            
            # 형식 감지 시도
            local DETECTED_TYPE=$( detect_keystore_type "$path" "$KEYSTORE_PASS" "$BCPROV_JAR" 2>/dev/null )
            
            if [ -n "$DETECTED_TYPE" ] && [ "$DETECTED_TYPE" != "UNKNOWN" ]; then
                echo -e "${GREEN}[OK] 키스토어 형식: $DETECTED_TYPE${NC}"
                KEYSTORE_BKS="$path"
                KEYSTORE_TYPE="$DETECTED_TYPE"
                FOUND_LOCAL=1
                break
            else
                echo -e "${YELLOW}[WARN] 로컬 파일 형식 감지 실패 (손상 가능성)${NC}"
            fi
        fi
    done
    
    # 2) 로컬 파일이 유효하지 않으면 GitHub에서 다운로드
    if [ $FOUND_LOCAL -eq 0 ]; then
        echo -e "${YELLOW}[INFO] GitHub에서 신규 키스토어 다운로드 중...${NC}"
        mkdir -p "$WORK_DIR"
        
        rm -f "$WORK_DIR/my_kakao_key_temp.keystore"
        
        if ! curl -L --max-time 30 --retry 3 --retry-delay 2 \
            -o "$WORK_DIR/my_kakao_key_temp.keystore" "$KEYSTORE_URL"; then
            echo -e "${RED}[ERROR] 키스토어 다운로드 실패!${NC}"
            echo -e "${YELLOW}[INFO] URL 확인: $KEYSTORE_URL${NC}"
            return 1
        fi

        if [ ! -s "$WORK_DIR/my_kakao_key_temp.keystore" ]; then
            echo -e "${RED}[ERROR] 다운로드된 키스토어가 비어 있습니다.${NC}"
            rm -f "$WORK_DIR/my_kakao_key_temp.keystore"
            return 1
        fi

        local FILE_SIZE=$(wc -c < "$WORK_DIR/my_kakao_key_temp.keystore")
        echo -e "${BLUE}[INFO] 다운로드 완료 (${FILE_SIZE} bytes)${NC}"
        
        # 파일 형식 검증
        if [ "$FILE_SIZE" -lt 1000 ]; then
            echo -e "${RED}[ERROR] 파일 크기가 너무 작습니다 (손상 가능성)${NC}"
            rm -f "$WORK_DIR/my_kakao_key_temp.keystore"
            return 1
        fi
        
        KEYSTORE_BKS="$WORK_DIR/my_kakao_key_temp.keystore"
        
        # 다운로드된 파일의 형식 감지
        local DETECTED_TYPE=$(detect_keystore_type "$KEYSTORE_BKS" "$KEYSTORE_PASS" "$BCPROV_JAR" 2>/dev/null)
        
        if [ -n "$DETECTED_TYPE" ] && [ "$DETECTED_TYPE" != "UNKNOWN" ]; then
            echo -e "${GREEN}[OK] 다운로드된 키스토어 형식: $DETECTED_TYPE${NC}"
            KEYSTORE_TYPE="$DETECTED_TYPE"
        else
            echo -e "${RED}[ERROR] 다운로드된 키스토어 형식을 읽을 수 없습니다!${NC}"
            echo -e "${YELLOW}[DEBUG] keytool 직접 테스트:${NC}"
            keytool -list -keystore "$KEYSTORE_BKS" -storepass "$KEYSTORE_PASS" -storetype PKCS12 2>&1 | head -5 || true
            keytool -list -keystore "$KEYSTORE_BKS" -storepass "$KEYSTORE_PASS" -storetype JKS 2>&1 | head -5 || true
            rm -f "$KEYSTORE_BKS"
            return 1
        fi
    fi

    # 3) BKS 형식이면 Bouncy Castle 재확인
    if [ "$KEYSTORE_TYPE" = "BKS" ]; then
        if [ ! -f "$BCPROV_JAR" ] || [ ! -s "$BCPROV_JAR" ]; then
            echo -e "${YELLOW}[INFO] BKS 형식: Bouncy Castle 설치 중...${NC}"
            rm -f "$BCPROV_JAR"
            if ! curl -L --max-time 60 --retry 3 --retry-delay 2 \
                -o "$BCPROV_JAR" "$BCPROV_URL" 2>/dev/null; then
                echo -e "${RED}[ERROR] Bouncy Castle 다운로드 실패${NC}"
                return 1
            fi
        fi

        if [ ! -s "$BCPROV_JAR" ]; then
            echo -e "${RED}[ERROR] Bouncy Castle JAR가 비어 있습니다.${NC}"
            return 1
        fi
        echo -e "${GREEN}[OK] Bouncy Castle 준비 완료${NC}"
    fi

    # 4) 최종 검증
    echo -e "${BLUE}[INFO] 최종 키스토어 검증 중 ($KEYSTORE_TYPE)...${NC}"
    
    if [ "$KEYSTORE_TYPE" = "BKS" ]; then
        if ! keytool -list \
            -providerclass org.bouncycastle.jce.provider.BouncyCastleProvider \
            -providerpath "$BCPROV_JAR" \
            -keystore "$KEYSTORE_BKS" \
            -storetype BKS \
            -storepass "$KEYSTORE_PASS" >/dev/null 2>&1; then
            echo -e "${RED}[ERROR] BKS 검증 실패!${NC}"
            return 1
        fi
        echo -e "${GREEN}[OK] BKS 검증 성공${NC}"
    elif [ "$KEYSTORE_TYPE" = "PKCS12" ] || [ "$KEYSTORE_TYPE" = "JKS" ]; then
        if ! keytool -list \
            -keystore "$KEYSTORE_BKS" \
            -storepass "$KEYSTORE_PASS" \
            -storetype "$KEYSTORE_TYPE" >/dev/null 2>&1; then
            echo -e "${RED}[ERROR] $KEYSTORE_TYPE 검증 실패!${NC}"
            return 1
        fi
        echo -e "${GREEN}[OK] $KEYSTORE_TYPE 검증 성공${NC}"
    else
        echo -e "${RED}[ERROR] 알 수 없는 키스토어 형식: $KEYSTORE_TYPE${NC}"
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
    local FINAL_KS="$KEYSTORE_BKS"
    local FINAL_KS_TYPE="$KEYSTORE_TYPE"
    
    rm -f "$SIGNED_APK"

    # BKS 형식이면 PKCS12로 변환
    if [ "$KEYSTORE_TYPE" = "BKS" ]; then
        echo -e "${YELLOW}[INFO] BKS → PKCS12 변환 중...${NC}"
        rm -f "$KEYSTORE_P12"
        
        if ! keytool -importkeystore -noprompt \
            -providerclass org.bouncycastle.jce.provider.BouncyCastleProvider \
            -providerpath "$BCPROV_JAR" \
            -srckeystore "$KEYSTORE_BKS" \
            -srcstoretype BKS \
            -srcstorepass "$KEYSTORE_PASS" \
            -destkeystore "$KEYSTORE_P12" \
            -deststoretype PKCS12 \
            -deststorepass "$KEYSTORE_PASS" \
            -destkeypass "$KEYSTORE_PASS" 2>&1; then
            echo -e "${RED}[ERROR] BKS → PKCS12 변환 실패${NC}"
            return 1
        fi

        if [ ! -s "$KEYSTORE_P12" ]; then
            echo -e "${RED}[ERROR] 변환된 PKCS12가 비어 있습니다.${NC}"
            return 1
        fi

        echo -e "${GREEN}[OK] 변환 완료${NC}"
        FINAL_KS="$KEYSTORE_P12"
        FINAL_KS_TYPE="PKCS12"
    fi
    
    # 최종 keystore 검증
    echo -e "${BLUE}[INFO] 최종 서명용 키스토어 검증 ($FINAL_KS_TYPE)...${NC}"
    if ! keytool -list -keystore "$FINAL_KS" -storepass "$KEYSTORE_PASS" -storetype "$FINAL_KS_TYPE" >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] 서명용 키스토어 검증 실패${NC}"
        return 1
    fi
    echo -e "${GREEN}[OK] 키스토어 준비 완료${NC}"

    echo -e "${BLUE}[INFO] apksigner로 서명 중...${NC}"
    if ! apksigner sign \
        --ks "$FINAL_KS" \
        --ks-pass "pass:$KEYSTORE_PASS" \
        --key-pass "pass:$KEYSTORE_PASS" \
        --ks-type "$FINAL_KS_TYPE" \
        --out "$SIGNED_APK" \
        "$MERGED_APK_PATH" 2>&1; then
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
    rm -f "$KEYSTORE_P12" "$MERGED_APK_PATH" "$WORK_DIR/my_kakao_key_temp.keystore" /tmp/convert_log.txt
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
