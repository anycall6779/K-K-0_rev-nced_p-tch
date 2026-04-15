#!/bin/bash
#
# Morphe MPP Patcher for KakaoTalk (v2.0 - MPP Edition)
# 기반: patch5.sh
# 변경: .rvp + build.py → morphe-cli + .mpp (직접 패칭)
# 서명:  my_kakao_key.keystore (kakaotalkpatch_unclone.apk 와 동일 키)
#
set -e

# ─────────────────────────────────────────
# Color Codes
# ─────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────
PKG_NAME="com.kakao.talk"
BASE_DIR="/storage/emulated/0/Download"
WORK_DIR="$HOME/morphe-kakao"

# morphe-cli : 최신 안정 릴리스 URL (fallback)
MORPHE_CLI_VERSION="1.6.3"
MORPHE_CLI_JAR="$WORK_DIR/morphe-cli-all.jar"
MORPHE_CLI_FALLBACK_URL="https://github.com/MorpheApp/morphe-cli/releases/download/v${MORPHE_CLI_VERSION}/morphe-cli-${MORPHE_CLI_VERSION}-all.jar"

# Patches MPP
# 1순위: 로컬 빌드 (Termux 에서 확인 가능한 경로)
LOCAL_MPP_SEARCH_DIRS=(
    "$BASE_DIR"
    "$HOME/Downloads"
    "$HOME"
)
MPP_FILE="$WORK_DIR/patches.mpp"

# AmpleReVanced GitHub (MPP 다운로드 소스)
AMPLE_REPO="AmpleReVanced/revanced-patches"
AMPLE_API_URL="https://api.github.com/repos/$AMPLE_REPO/releases"

# Keystore – kakaotalkpatch_unclone.apk 와 동일한 키 사용
KEYSTORE_SOURCE_URL="https://github.com/anycall6779/K-K-0_rev-nced_p-tch/raw/refs/heads/main/my_kakao_key.keystore"
KEYSTORE_FILE="$WORK_DIR/my_kakao_key.keystore"
KEYSTORE_PASS="android"
KEYSTORE_ALIAS="ReVanced Key"

# 출력 파일명 (기존 kakaotalkpatch_unclone.apk 와 키 일치 → 업데이트 가능)
OUTPUT_APK="$BASE_DIR/KakaoTalk_Patched.apk"

# APKM 입력 파일 (전역 변수; get_apkm_file() 에서 설정)
APKM_FILE=""

# ─────────────────────────────────────────
# Helper: 작업 디렉토리 초기화
# ─────────────────────────────────────────
init_workdir() {
    mkdir -p "$WORK_DIR"
    mkdir -p "$HOME/Downloads"
}

# ─────────────────────────────────────────
# 1. 의존성 확인 & morphe-cli 준비
# ─────────────────────────────────────────
check_dependencies() {
    echo -e "${BLUE}[INFO] 필수 도구 확인 중...${NC}"
    local MISSING=0

    for cmd in curl unzip java; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${RED}[ERROR] '$cmd' 가 없습니다. 설치: pkg install $cmd${NC}"
            MISSING=1
        fi
    done

    # Java 17+ 권장
    local JV
    JV=$(java -version 2>&1 | grep -oP '(?:java|openjdk) version "\K[0-9]+' | head -n1)
    if [ -n "$JV" ] && [ "$JV" -lt 17 ] 2>/dev/null; then
        echo -e "${YELLOW}[WARN] Java 17+ 권장 (현재: $JV)${NC}"
    fi

    [ $MISSING -eq 1 ] && exit 1

    # morphe-cli 다운로드 (없을 때)
    if [ ! -f "$MORPHE_CLI_JAR" ]; then
        echo -e "${YELLOW}[INFO] morphe-cli 최신 버전 확인 중...${NC}"

        # GitHub API로 최신 릴리스 jar URL 조회
        local CLI_URL=""
        CLI_URL=$(curl -sf "https://api.github.com/repos/MorpheApp/morphe-cli/releases/latest" 2>/dev/null \
            | grep -oP '"browser_download_url"\s*:\s*"\K[^"]+all\.jar' | head -n1) || true

        if [ -z "$CLI_URL" ]; then
            echo -e "${YELLOW}[WARN] API 조회 실패 → fallback 버전 ${MORPHE_CLI_VERSION} 사용${NC}"
            CLI_URL="$MORPHE_CLI_FALLBACK_URL"
        fi

        echo -e "${BLUE}[INFO] morphe-cli 다운로드 중: $(basename "$CLI_URL")...${NC}"
        curl -L --progress-bar -o "$MORPHE_CLI_JAR" "$CLI_URL" || {
            echo -e "${RED}[ERROR] morphe-cli 다운로드 실패${NC}"
            exit 1
        }
    fi

    echo -e "${GREEN}[OK] morphe-cli 준비 완료: $(basename "$MORPHE_CLI_JAR")${NC}"
}

# ─────────────────────────────────────────
# BKS 검증 헬퍼 – morphe-cli JAR의 BC 프로바이더 사용
# 반환: 0=성공, 1=실패
# ─────────────────────────────────────────
_ks_bks_ok() {
    local ks="$1" pass="$2"
    [ -f "$ks" ] || return 1
    # Java 9+ -addmods 방식과 -provider 방식 모두 시도
    keytool -list \
        -J-cp -J"$MORPHE_CLI_JAR" \
        -keystore "$ks" \
        -storepass "$pass" \
        -storetype BKS \
        -provider org.bouncycastle.jce.provider.BouncyCastleProvider \
        >/dev/null 2>&1 && return 0
    # fallback: -providerpath 방식
    keytool -list \
        -keystore "$ks" \
        -storepass "$pass" \
        -storetype BKS \
        -provider org.bouncycastle.jce.provider.BouncyCastleProvider \
        -providerpath "$MORPHE_CLI_JAR" \
        >/dev/null 2>&1
}

# ─────────────────────────────────────────
# JKS/PKCS12 → BKS 변환 헬퍼
# ─────────────────────────────────────────
_ks_conv_bks() {
    local src="$1" sp="$2" dst="$3" dp="$4"
    rm -f "$dst"
    keytool -importkeystore -noprompt \
        -J-cp -J"$MORPHE_CLI_JAR" \
        -srckeystore   "$src" \
        -srcstorepass  "$sp" \
        -destkeystore  "$dst" \
        -deststorepass "$dp" \
        -deststoretype BKS \
        -provider org.bouncycastle.jce.provider.BouncyCastleProvider \
        >/dev/null 2>&1 || \
    keytool -importkeystore -noprompt \
        -srckeystore   "$src" \
        -srcstorepass  "$sp" \
        -destkeystore  "$dst" \
        -deststorepass "$dp" \
        -deststoretype BKS \
        -provider org.bouncycastle.jce.provider.BouncyCastleProvider \
        -providerpath  "$MORPHE_CLI_JAR" \
        >/dev/null 2>&1
    [ -s "$dst" ]
}

# ─────────────────────────────────────────
# morphe-cli 로 실제 서명 테스트 (가장 확실한 검증)
# 빈 ZIP 을 서명해보는 방식
# ─────────────────────────────────────────
_ks_morphe_ok() {
    local ks="$1" pass="$2" alias_="$3"
    local probe_apk="$WORK_DIR/_probe.apk"
    # 최소 유효 ZIP 생성 (PK header)
    printf 'PK\x05\x06\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' > "$probe_apk" 2>/dev/null
    local result
    result=$(java -jar "$MORPHE_CLI_JAR" sign \
        --keystore "$ks" \
        --keystore-password "$pass" \
        --keystore-entry-alias "$alias_" \
        --keystore-entry-password "$pass" \
        "$probe_apk" 2>&1 | tail -1) || true
    rm -f "$probe_apk"
    # "integrity check failed" 가 없으면 성공
    echo "$result" | grep -qi "integrity check failed" && return 1
    echo "$result" | grep -qi "error\|exception\|failed" && return 1
    return 0
}

# ─────────────────────────────────────────
# 2. Keystore 준비 – 기존 서명 유지 우선 탐색
#
# 탐색 우선순위:
#   1) kakaotalk-patched.keystore  ← 실제 앱에 서명된 키 (serial 7633c4653cf2dc48)
#   2) my_kakao_key.keystore 여러 경로
#   3) GitHub 다운로드
#   4) 최후: 새 BKS 생성
# ─────────────────────────────────────────
setup_keystore() {
    echo ""
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${GREEN}Keystore 준비 (서명 일치 확인)${NC}"
    echo -e "${YELLOW}==================================${NC}"

    local TMP_BKS="$WORK_DIR/_ks_tmp.keystore"
    local PASS_LIST=("android" "ReVanced" "revanced" "password" "test" "123456" "keystorepassword" "changeit")

    local SCRIPT_DIR_LOCAL
    SCRIPT_DIR_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR_LOCAL="$BASE_DIR"

    # kakaotalk-patched.keystore 를 최우선: 워크스페이스confirmed 서명 키
    # 그 다음 my_kakao_key.keystore 여러 경로
    local CANDIDATES=(
        "$HOME/revanced-kakao-patch/kakaotalk-patched.keystore"
        "$HOME/morphe-kakao/kakaotalk-patched.keystore"
        "$BASE_DIR/kakaotalk-patched.keystore"
        "$SCRIPT_DIR_LOCAL/kakaotalk-patched.keystore"
        "$KEYSTORE_FILE"
        "$SCRIPT_DIR_LOCAL/my_kakao_key.keystore"
        "$BASE_DIR/my_kakao_key.keystore"
        "$HOME/my_kakao_key.keystore"
        "$HOME/Downloads/my_kakao_key.keystore"
        "$HOME/morphe-kakao/my_kakao_key.keystore"
        "$HOME/revanced-build-script-ample/my_kakao_key.keystore"
        "$HOME/revanced-kakao-patch/my_kakao_key.keystore"
        "$HOME/kakao-revanced-patch/my_kakao_key.keystore"
        "$HOME/revanced-build-script/output/patched.keystore"
    )
    # find로 추가 탐색 (Termux 홈 전체)
    while IFS= read -r extra; do
        CANDIDATES+=("$extra")
    done < <(find "$HOME" -maxdepth 4 -name "*.keystore" 2>/dev/null | sort)

    echo -e "${BLUE}[INFO] keystore 탐색 중 (서명 보존 우선)...${NC}"

    local FOUND_KS="" FOUND_PASS=""

    # ── 1단계: BKS 직접 검증 (morphe-cli probe 방식) ──
    for ks in "${CANDIDATES[@]}"; do
        [ -f "$ks" ] || continue
        for pass in "${PASS_LIST[@]}"; do
            if _ks_morphe_ok "$ks" "$pass" "$KEYSTORE_ALIAS"; then
                FOUND_KS="$ks"; FOUND_PASS="$pass"
                break 2
            fi
            if _ks_bks_ok "$ks" "$pass"; then
                FOUND_KS="$ks"; FOUND_PASS="$pass"
                break 2
            fi
        done
    done

    # ── 2단계: BKS 직접 실패 → JKS/PKCS12 → BKS 변환 ──
    if [ -z "$FOUND_KS" ]; then
        echo -e "${YELLOW}[INFO] BKS 직접 검증 불가 → 형식 변환 시도...${NC}"
        for ks in "${CANDIDATES[@]}"; do
            [ -f "$ks" ] || continue
            for pass in "${PASS_LIST[@]}"; do
                local readable=0
                for fmt in JKS PKCS12 BKS; do
                    if keytool -list -keystore "$ks" -storepass "$pass" \
                               -storetype "$fmt" >/dev/null 2>&1; then
                        readable=1; break
                    fi
                done
                [ $readable -eq 1 ] || continue
                if _ks_conv_bks "$ks" "$pass" "$TMP_BKS" "android"; then
                    cp "$TMP_BKS" "$KEYSTORE_FILE"; rm -f "$TMP_BKS"
                    KEYSTORE_PASS="android"
                    local label; echo "$ks" | grep -q "kakaotalk-patched" && label="★ 기존 서명 일치" || label="$(basename "$ks")"
                    echo -e "${GREEN}[OK] $label → BKS 변환 완료${NC}"
                    echo -e "${GREEN}[OK] Keystore: $KEYSTORE_FILE | Pass: $KEYSTORE_PASS${NC}"
                    return 0
                fi
            done
        done
    fi

    # ── 3단계: 발견된 BKS 복사 ──
    if [ -n "$FOUND_KS" ]; then
        cp "$FOUND_KS" "$KEYSTORE_FILE"
        KEYSTORE_PASS="$FOUND_PASS"
        local label; echo "$FOUND_KS" | grep -q "kakaotalk-patched" && label="★ 기존 서명 일치 키스토어" || label="$(basename "$FOUND_KS")"
        echo -e "${GREEN}[OK] Keystore 로드: $label (pass=$FOUND_PASS)${NC}"
        echo -e "${GREEN}[OK] Keystore: $KEYSTORE_FILE${NC}"
        echo -e "${CYAN}     Alias  : $KEYSTORE_ALIAS${NC}"
        return 0
    fi

    # ── 4단계: GitHub 다운로드 후 재시도 ──
    echo -e "${YELLOW}[INFO] 로컬에서 유효한 keystore 없음 → GitHub 다운로드...${NC}"
    local DL_OK=0
    for url in \
        "$KEYSTORE_SOURCE_URL" \
        "https://raw.githubusercontent.com/anycall6779/K-K-0_rev-nced_p-tch/main/my_kakao_key.keystore" \
        "https://github.com/anycall6779/K-K-0_rev-nced_p-tch/raw/main/my_kakao_key.keystore"; do
        curl -fL --progress-bar --retry 2 -o "$KEYSTORE_FILE" "$url" 2>/dev/null && \
            [ -s "$KEYSTORE_FILE" ] && DL_OK=1 && break || true
    done

    if [ $DL_OK -eq 1 ]; then
        for pass in "${PASS_LIST[@]}"; do
            if _ks_morphe_ok "$KEYSTORE_FILE" "$pass" "$KEYSTORE_ALIAS" || \
               _ks_bks_ok "$KEYSTORE_FILE" "$pass"; then
                KEYSTORE_PASS="$pass"
                echo -e "${GREEN}[OK] GitHub keystore 사용 가능 (pass=$pass)${NC}"
                echo -e "${GREEN}[OK] Keystore: $KEYSTORE_FILE${NC}"
                return 0
            fi
        done
        # 변환 시도
        for pass in "${PASS_LIST[@]}"; do
            if _ks_conv_bks "$KEYSTORE_FILE" "$pass" "$TMP_BKS" "android"; then
                cp "$TMP_BKS" "$KEYSTORE_FILE"; rm -f "$TMP_BKS"
                KEYSTORE_PASS="android"
                echo -e "${GREEN}[OK] GitHub keystore → BKS 변환 완료${NC}"
                echo -e "${GREEN}[OK] Keystore: $KEYSTORE_FILE${NC}"
                return 0
            fi
        done
    fi

    # ── 5단계: 최후 수단 – Python으로 BKS 생성 ──
    # Java keytool -storetype BKS 가 실패하는 환경에서
    # morphe-cli 내장 BC 를 직접 Java 코드로 호출해 BKS 생성
    echo -e "${YELLOW}[INFO] Java 직접 BKS 생성 시도...${NC}"
    local JAVA_GEN
    JAVA_GEN=$(cat <<'JAVA_EOF'
import java.security.*;
import java.security.cert.*;
import java.io.*;
import java.util.*;
import java.util.Date;
import java.math.BigInteger;
import sun.security.x509.*;

public class GenBKS {
    public static void main(String[] a) throws Exception {
        String ksPath = a[0], pass = a[1], alias = a[2];
        // BC 로드
        Class<?> bcClass = Class.forName("org.bouncycastle.jce.provider.BouncyCastleProvider");
        Provider bc = (Provider) bcClass.getDeclaredConstructor().newInstance();
        Security.addProvider(bc);
        // RSA 키쌍
        KeyPairGenerator kpg = KeyPairGenerator.getInstance("RSA");
        kpg.initialize(2048);
        KeyPair kp = kpg.generateKeyPair();
        // Self-signed cert
        X509CertInfo ci = new X509CertInfo();
        X500Name dn = new X500Name("CN=ReVanced");
        ci.set(X509CertInfo.VALIDITY, new CertificateValidity(new Date(), new Date(System.currentTimeMillis()+315360000000L)));
        ci.set(X509CertInfo.SERIAL_NUMBER, new CertificateSerialNumber(new BigInteger(64, new SecureRandom())));
        ci.set(X509CertInfo.SUBJECT, dn);
        ci.set(X509CertInfo.ISSUER, dn);
        ci.set(X509CertInfo.KEY, new CertificateX509Key(kp.getPublic()));
        ci.set(X509CertInfo.ALGORITHM_ID, new CertificateAlgorithmId(new AlgorithmId(AlgorithmId.sha256WithRSAEncryption_oid)));
        X509CertImpl cert = new X509CertImpl(ci);
        cert.sign(kp.getPrivate(), "SHA256withRSA");
        // BKS keystore 저장
        KeyStore ks = KeyStore.getInstance("BKS", "BC");
        ks.load(null, null);
        ks.setKeyEntry(alias, kp.getPrivate(), pass.toCharArray(), new Certificate[]{cert});
        try(FileOutputStream fos = new FileOutputStream(ksPath)) {
            ks.store(fos, pass.toCharArray());
        }
        System.out.println("OK");
    }
}
JAVA_EOF
)
    local GEN_JAVA="$WORK_DIR/GenBKS.java"
    echo "$JAVA_GEN" > "$GEN_JAVA"
    if javac -cp "$MORPHE_CLI_JAR" "$GEN_JAVA" -d "$WORK_DIR" >/dev/null 2>&1 && \
       java -cp "$MORPHE_CLI_JAR:$WORK_DIR" GenBKS "$KEYSTORE_FILE" "android" "$KEYSTORE_ALIAS" 2>/dev/null | grep -q "OK"; then
        KEYSTORE_PASS="android"
        rm -f "$GEN_JAVA" "$WORK_DIR/GenBKS.class"
        echo -e "${YELLOW}[경고] 새 키로 서명됩니다 – 기존 패치 앱 삭제 후 재설치 필요${NC}"
        echo -e "${GREEN}[OK] BKS keystore 생성 완료${NC}"
        echo -e "${GREEN}[OK] Keystore: $KEYSTORE_FILE${NC}"
        return 0
    fi
    rm -f "$GEN_JAVA" "$WORK_DIR/GenBKS.class" 2>/dev/null

    # ── 6단계: keytool BKS 생성 (최후) ──
    echo -e "${YELLOW}[경고] 새 키로 서명됩니다 – 기존 패치 앱 삭제 후 재설치 필요${NC}"
    rm -f "$KEYSTORE_FILE"
    keytool -genkeypair -noprompt \
        -alias     "$KEYSTORE_ALIAS" \
        -keyalg    RSA -keysize 2048 -validity 10000 \
        -keystore  "$KEYSTORE_FILE" \
        -storepass "android" -keypass "android" \
        -storetype BKS \
        -provider  org.bouncycastle.jce.provider.BouncyCastleProvider \
        -providerpath "$MORPHE_CLI_JAR" \
        -dname "CN=ReVanced,O=ReVanced,C=US" \
        >/dev/null 2>&1 || \
    keytool -genkeypair -noprompt \
        -alias     "$KEYSTORE_ALIAS" \
        -keyalg    RSA -keysize 2048 -validity 10000 \
        -keystore  "$KEYSTORE_FILE" \
        -storepass "android" -keypass "android" \
        -storetype PKCS12 \
        -dname "CN=ReVanced,O=ReVanced,C=US" \
        >/dev/null 2>&1 || {
        echo -e "${RED}[ERROR] keystore 생성 실패${NC}"; return 1
    }
    KEYSTORE_PASS="android"
    echo -e "${GREEN}[OK] keystore 생성 완료${NC}"
    echo -e "${GREEN}[OK] Keystore: $KEYSTORE_FILE${NC}"
    echo -e "${CYAN}     Alias  : $KEYSTORE_ALIAS${NC}"
    echo -e "${CYAN}     Pass   : $KEYSTORE_PASS${NC}"
}

# ─────────────────────────────────────────
# 3. MPP 파일 준비 (로컬 우선 → GitHub 다운로드)
# ─────────────────────────────────────────
setup_mpp() {
    echo ""
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${GREEN}MPP 패치 파일 준비${NC}"
    echo -e "${YELLOW}==================================${NC}"
    echo ""

    # ── 로컬 검색: BASE_DIR, HOME/Downloads, HOME ──
    echo -e "${BLUE}[INFO] 로컬 MPP 파일 검색 중...${NC}"
    local FOUND_LOCAL=""
    for DIR in "${LOCAL_MPP_SEARCH_DIRS[@]}"; do
        local F
        # sources/javadoc 제외하고 최신 파일 선택
        F=$(find "$DIR" -maxdepth 2 -name "*.mpp" \
              ! -name "*sources*" ! -name "*javadoc*" \
              -printf "%T@ %p\n" 2>/dev/null \
            | sort -rn | head -n1 | cut -d' ' -f2-) || true
        if [ -n "$F" ] && [ -f "$F" ]; then
            FOUND_LOCAL="$F"
            break
        fi
    done

    if [ -n "$FOUND_LOCAL" ]; then
        echo -e "${GREEN}[발견] 로컬 MPP: $(basename "$FOUND_LOCAL")${NC}"
        echo -e ""
        echo -e "  ${GREEN}1.${NC} 이 파일 사용: $(basename "$FOUND_LOCAL")"
        echo -e "  ${BLUE}2.${NC} GitHub에서 다른 버전 선택"
        echo -e ""
        echo -e "${YELLOW}선택 (기본: 1):${NC}"
        read -r -p "> " MPP_CHOICE
        if [ -z "$MPP_CHOICE" ] || [ "$MPP_CHOICE" = "1" ]; then
            cp "$FOUND_LOCAL" "$MPP_FILE"
            echo -e "${GREEN}[OK] MPP 준비 완료: $(basename "$FOUND_LOCAL")${NC}"
            return 0
        fi
    else
        echo -e "${YELLOW}[INFO] 로컬 MPP 파일 없음 → GitHub 다운로드${NC}"
    fi

    # ── GitHub AmpleReVanced releases 에서 선택 ──
    _fetch_mpp_from_github
}

_fetch_mpp_from_github() {
    echo -e "${BLUE}[INFO] GitHub 릴리스 정보 가져오는 중...${NC}"
    local RELEASES_JSON
    RELEASES_JSON=$(curl -sf "$AMPLE_API_URL?per_page=10" 2>/dev/null) || true

    if [ -z "$RELEASES_JSON" ] || echo "$RELEASES_JSON" | grep -q '"message"'; then
        echo -e "${RED}[ERROR] GitHub API 요청 실패${NC}"
        return 1
    fi

    local MPP_URLS=()
    local MPP_NAMES=()

    # jq 또는 grep 파싱
    if command -v jq &>/dev/null; then
        while IFS= read -r line; do MPP_URLS+=("$line"); done < \
            <(echo "$RELEASES_JSON" | jq -r \
              '.[] | .assets[] | select(.name | test("\\.mpp$") and (test("sources|javadoc") | not)) | .browser_download_url' \
              | head -10)
        while IFS= read -r line; do MPP_NAMES+=("$line"); done < \
            <(echo "$RELEASES_JSON" | jq -r \
              '.[] | .assets[] | select(.name | test("\\.mpp$") and (test("sources|javadoc") | not)) | .name' \
              | head -10)
    else
        while IFS= read -r line; do
            if [[ "$line" == *.mpp ]] && [[ "$line" != *sources* ]] && [[ "$line" != *javadoc* ]]; then
                MPP_URLS+=("$line")
                MPP_NAMES+=("$(basename "$line")")
            fi
        done < <(echo "$RELEASES_JSON" | grep -oP '"browser_download_url"\s*:\s*"\K[^"]+\.mpp')
    fi

    if [ ${#MPP_URLS[@]} -eq 0 ]; then
        echo -e "${RED}[ERROR] 사용 가능한 MPP 파일을 찾을 수 없습니다${NC}"
        return 1
    fi

    echo ""
    echo -e "${GREEN}사용 가능한 MPP 버전:${NC}"
    echo -e "  ${BLUE}0.${NC} 최신 버전 자동 선택 (${MPP_NAMES[0]:-첫번째})"
    for i in "${!MPP_URLS[@]}"; do
        echo -e "  ${GREEN}$((i+1)).${NC} ${MPP_NAMES[$i]}"
    done
    echo ""
    echo -e "${YELLOW}번호를 입력하세요 (기본: 0 → 최신):${NC}"
    read -r -p "> " SELECTION

    if [ -z "$SELECTION" ] || [ "$SELECTION" = "0" ]; then SELECTION=1; fi

    if [[ "$SELECTION" =~ ^[0-9]+$ ]] && \
       [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -le "${#MPP_URLS[@]}" ]; then
        local URL="${MPP_URLS[$((SELECTION-1))]}"
        local NAME="${MPP_NAMES[$((SELECTION-1))]}"
        echo -e "${GREEN}[선택됨] $NAME${NC}"
        echo -e "${YELLOW}[INFO] MPP 다운로드 중: $NAME ...${NC}"
        curl -L --progress-bar -o "$MPP_FILE" "$URL" || {
            echo -e "${RED}[ERROR] MPP 다운로드 실패${NC}"
            return 1
        }
        echo -e "${GREEN}[OK] MPP 다운로드 완료${NC}"
    else
        echo -e "${RED}[ERROR] 잘못된 선택${NC}"
        return 1
    fi
}

# ─────────────────────────────────────────
# 4. APKM 파일 선택
# ─────────────────────────────────────────
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
        read -r -p "> " SELECTION

        if [[ "$SELECTION" =~ ^[0-9]+$ ]] && \
           [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -le "${#APKM_FILES[@]}" ]; then
            APKM_FILE="$BASE_DIR/${APKM_FILES[$((SELECTION-1))]}"
            echo -e "${GREEN}[선택됨] ${APKM_FILES[$((SELECTION-1))]}${NC}"
            return 0
        fi

        [ -n "$SELECTION" ] && APKM_FILE="$SELECTION"
    else
        echo -e "${BLUE}APKM 파일의 전체 경로를 입력하세요:${NC}"
        echo -e "${YELLOW}(예: /storage/emulated/0/Download/com.kakao.talk.apkm)${NC}"
        echo ""
        read -r -p "> " APKM_FILE
    fi

    if [ -z "$APKM_FILE" ] || [ ! -f "$APKM_FILE" ]; then
        echo -e "${RED}[ERROR] 유효하지 않은 파일 경로: $APKM_FILE${NC}"
        return 1
    fi
}

# ─────────────────────────────────────────
# 5. morphe-cli 로 패치 실행
#    - APKM 직접 입력 지원 (내부에서 자동 병합)
#    - my_kakao_key.keystore 서명
#    - --force: 버전 체크 우회 (26.2.2 패치를 26.3.0 에 적용)
# ─────────────────────────────────────────
run_patch() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   Morphe MPP 패치 시작...${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${CYAN}  입력 APKM : $(basename "$APKM_FILE")${NC}"
    echo -e "${CYAN}  MPP 패치  : $(basename "$MPP_FILE")${NC}"
    echo -e "${CYAN}  Keystore  : $(basename "$KEYSTORE_FILE")${NC}"
    echo -e "${CYAN}  출력 파일 : $(basename "$OUTPUT_APK")${NC}"
    echo ""

    # 이전 출력 삭제
    rm -f "$OUTPUT_APK"

    # morphe-cli 실행
    # --force      : 호환 버전 체크 건너뜀 (26.3.0 에 26.2.2 패치 적용 가능)
    # --continue-on-error : 단일 패치 실패 시 계속 진행
    # --keystore / --keystore-password / --keystore-entry-alias / --keystore-entry-password
    #               : my_kakao_key.keystore 로 서명 (kakaotalkpatch_unclone.apk 동일 키)
    java -jar "$MORPHE_CLI_JAR" \
        patch \
        --patches   "$MPP_FILE" \
        --keystore  "$KEYSTORE_FILE" \
        --keystore-password       "$KEYSTORE_PASS" \
        --keystore-entry-alias    "$KEYSTORE_ALIAS" \
        --keystore-entry-password "$KEYSTORE_PASS" \
        --force \
        --continue-on-error \
        --purge \
        -o "$OUTPUT_APK" \
        "$APKM_FILE" || {
        echo -e "${RED}[ERROR] morphe-cli 패치 실패${NC}"
        return 1
    }

    # 결과 확인
    if [ -f "$OUTPUT_APK" ]; then
        local SIZE
        SIZE=$(du -h "$OUTPUT_APK" 2>/dev/null | cut -f1)
        echo ""
        echo -e "${GREEN}======================================${NC}"
        echo -e "${GREEN}   ✓ 패치 완료!${NC}"
        echo -e "${GREEN}======================================${NC}"
        echo -e "${GREEN}[SUCCESS] 저장 완료: $OUTPUT_APK ($SIZE)${NC}"
        echo ""
        echo -e "${CYAN}[INFO] 이 파일은 my_kakao_key.keystore 로 서명되어${NC}"
        echo -e "${CYAN}       kakaotalkpatch_unclone.apk 과 동일한 서명을 가집니다.${NC}"
        echo -e "${CYAN}       기존 설치 앱 위에 업데이트 설치가 가능합니다.${NC}"
    else
        echo -e "${RED}[ERROR] 패칭된 APK를 찾을 수 없습니다.${NC}"
        echo -e "${YELLOW}[HINT] 아래 명령으로 수동 실행 후 오류를 확인하세요:${NC}"
        echo -e "  java -jar '$MORPHE_CLI_JAR' patch \\"
        echo -e "    --patches '$MPP_FILE' \\"
        echo -e "    --keystore '$KEYSTORE_FILE' \\"
        echo -e "    --keystore-password '$KEYSTORE_PASS' \\"
        echo -e "    --keystore-entry-alias '$KEYSTORE_ALIAS' \\"
        echo -e "    --keystore-entry-password '$KEYSTORE_PASS' \\"
        echo -e "    --force --continue-on-error \\"
        echo -e "    -o '$OUTPUT_APK' \\"
        echo -e "    '$APKM_FILE'"
        return 1
    fi
}

# ─────────────────────────────────────────
# Main
# ─────────────────────────────────────────
main() {
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  카카오톡 MPP 패치 (Morphe v2.0)  ║${NC}"
    echo -e "${GREEN}║  서명: my_kakao_key.keystore         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""

    init_workdir
    check_dependencies || exit 1
    setup_keystore     || exit 1
    setup_mpp          || exit 1
    get_apkm_file      || exit 0
    run_patch          || exit 1

    echo ""
    echo -e "${GREEN}모든 작업이 완료되었습니다.${NC}"
}

main
