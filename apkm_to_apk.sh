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
# 비밀번호: 빈 문자열 "" (store 및 key entry 모두)
KEYSTORE_SOURCE_URL="https://github.com/anycall6779/K-K-0_rev-nced_p-tch/raw/refs/heads/main/my_kakao_key.keystore"
KEYSTORE_FILE="$WORK_DIR/my_kakao_key.keystore"
KEYSTORE_PASS=""
KEYSTORE_ALIAS="ReVanced Key"

# 출력 파일명 (기존 kakaotalkpatch_unclone.apk 와 키 일치 → 업데이트 가능)
OUTPUT_APK="$BASE_DIR/KakaoTalk_Patched.apk"

# APKM 입력 파일 (전역 변수; get_apkm_file() 에서 설정)
APKM_FILE=""

# 패치 선택 추가 인자 (select_patches() 에서 설정)
PATCH_EXTRA_ARGS=()

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
# BKS 검증 헬퍼
#
# 핵심: morphe-cli JAR 안의 BouncyCastle을 javac/java -cp 로 직접 사용
# VerifyBKS.java 를 컴파일해서 실제 KeyStore.load() 성공 여부를 확인
# → keytool -storetype BKS 가 JDK 환경에 따라 실패하는 문제를 완전히 우회
# ─────────────────────────────────────────

# VerifyBKS.class + ResignAPK.class 컴파일 (최초 1회)
_init_bks_checker() {
    local need=0
    [ -f "$WORK_DIR/VerifyBKS.class" ] || need=1
    [ -f "$WORK_DIR/ResignAPK.class" ] || need=1
    [ $need -eq 0 ] && return 0

    cat > "$WORK_DIR/VerifyBKS.java" << 'JEOF'
import java.io.*;
import java.security.*;
import java.util.*;
import org.bouncycastle.jce.provider.BouncyCastleProvider;
public class VerifyBKS {
    public static void main(String[] a) throws Exception {
        Security.addProvider(new BouncyCastleProvider());
        KeyStore ks = KeyStore.getInstance("BKS", "BC");
        try (FileInputStream f = new FileInputStream(a[0])) {
            ks.load(f, a[1].toCharArray());
        }
        Enumeration<String> al = ks.aliases();
        System.out.println(al.hasMoreElements() ? al.nextElement() : "alias");
    }
}
JEOF
    javac -cp "$MORPHE_CLI_JAR" -d "$WORK_DIR" "$WORK_DIR/VerifyBKS.java" >/dev/null 2>&1

    # ResignAPK: 이미 서명된 APK 를 올바른 키로 재서명
    cat > "$WORK_DIR/ResignAPK.java" << 'JEOF'
import java.io.*;
import java.security.*;
import java.security.cert.*;
import java.util.*;
import com.android.apksig.ApkSigner;
import org.bouncycastle.jce.provider.BouncyCastleProvider;
public class ResignAPK {
    public static void main(String[] args) throws Exception {
        // args: <input.apk> <output.apk> <keystore.bks> <storepass> <alias> <keypass>
        Security.addProvider(new BouncyCastleProvider());
        KeyStore ks = KeyStore.getInstance("BKS", "BC");
        try (FileInputStream fis = new FileInputStream(args[2])) {
            ks.load(fis, args[3].toCharArray());
        }
        PrivateKey pk = (PrivateKey) ks.getKey(args[4], args[5].toCharArray());
        java.security.cert.Certificate[] chain = ks.getCertificateChain(args[4]);
        List<X509Certificate> certs = new ArrayList<>();
        for (java.security.cert.Certificate c : chain) certs.add((X509Certificate) c);
        ApkSigner.SignerConfig sc = new ApkSigner.SignerConfig.Builder("CERT", pk, certs).build();
        ApkSigner.Builder b = new ApkSigner.Builder(Collections.singletonList(sc));
        b.setInputApk(new File(args[0]));
        b.setOutputApk(new File(args[1]));
        b.setV1SigningEnabled(true);
        b.setV2SigningEnabled(true);
        b.setV3SigningEnabled(true);
        b.build().sign();
        System.out.println("OK");
    }
}
JEOF
    javac -cp "$MORPHE_CLI_JAR" -d "$WORK_DIR" "$WORK_DIR/ResignAPK.java" >/dev/null 2>&1
}

# BKS 검증: 성공 시 alias 출력(exit 0), 실패 시 exit 1
# 사용법: alias=$(_check_bks ks.file password) && echo "유효"
_check_bks() {
    local ks="$1" pass="$2"
    [ -f "$ks" ] || return 1
    [ -f "$WORK_DIR/VerifyBKS.class" ] || return 1
    java -cp "$MORPHE_CLI_JAR:$WORK_DIR" VerifyBKS "$ks" "$pass" 2>/dev/null
}

# APK 서명을 올바른 키로 교체 (morphe-cli 가 엉뚱한 키로 서명했을 때)
_resign_apk() {
    local apk="$1"
    [ -f "$apk" ] || return 1
    [ -f "$WORK_DIR/ResignAPK.class" ] || return 1
    [ -f "$KEYSTORE_FILE" ] || return 1

    local tmp="${apk%.apk}_resign_tmp.apk"
    echo -e "${YELLOW}[INFO] 서명 교체 중 (→ my_kakao_key.keystore)...${NC}"
    if java -cp "$MORPHE_CLI_JAR:$WORK_DIR" ResignAPK \
           "$apk" "$tmp" "$KEYSTORE_FILE" "$KEYSTORE_PASS" "$KEYSTORE_ALIAS" "$KEYSTORE_PASS" \
           2>/dev/null | grep -q "OK"; then
        mv "$tmp" "$apk"
        echo -e "${GREEN}[OK] 서명 교체 완료${NC}"
        return 0
    fi
    rm -f "$tmp"
    echo -e "${RED}[WARN] 서명 교체 실패 (javac 미설치 가능성)${NC}"
    return 1
}

# JKS/PKCS12 → BKS 변환 (src, src_pass, dst, dst_pass)
_conv_to_bks() {
    local src="$1" sp="$2" dst="$3" dp="$4"
    rm -f "$dst"
    keytool -importkeystore -noprompt \
        -srckeystore  "$src" -srcstorepass  "$sp" \
        -destkeystore "$dst" -deststorepass "$dp" \
        -deststoretype BKS \
        -provider org.bouncycastle.jce.provider.BouncyCastleProvider \
        -providerpath "$MORPHE_CLI_JAR" >/dev/null 2>&1 ||
    keytool -importkeystore -noprompt \
        -J-cp -J"$MORPHE_CLI_JAR" \
        -srckeystore  "$src" -srcstorepass  "$sp" \
        -destkeystore "$dst" -deststorepass "$dp" \
        -deststoretype BKS \
        -provider org.bouncycastle.jce.provider.BouncyCastleProvider \
        >/dev/null 2>&1
    [ -s "$dst" ]
}

# 새 BKS keystore 생성 (서명 변경 수반)
_gen_new_bks() {
    rm -f "$KEYSTORE_FILE"
    # 방법1: keytool + -providerpath
    keytool -genkeypair -noprompt \
        -alias "$KEYSTORE_ALIAS" -keyalg RSA -keysize 2048 -validity 10000 \
        -keystore "$KEYSTORE_FILE" -storepass "android" -keypass "android" \
        -storetype BKS \
        -provider org.bouncycastle.jce.provider.BouncyCastleProvider \
        -providerpath "$MORPHE_CLI_JAR" \
        -dname "CN=ReVanced,O=ReVanced,C=US" >/dev/null 2>&1 && { KEYSTORE_PASS="android"; return 0; }
    # 방법2: keytool + -J-cp
    keytool -genkeypair -noprompt \
        -J-cp -J"$MORPHE_CLI_JAR" \
        -alias "$KEYSTORE_ALIAS" -keyalg RSA -keysize 2048 -validity 10000 \
        -keystore "$KEYSTORE_FILE" -storepass "android" -keypass "android" \
        -storetype BKS \
        -provider org.bouncycastle.jce.provider.BouncyCastleProvider \
        -dname "CN=ReVanced,O=ReVanced,C=US" >/dev/null 2>&1 && { KEYSTORE_PASS="android"; return 0; }
    # 방법3: PKCS12 fallback (morphe-cli가 지원하는지 미확인이나 최후 수단)
    keytool -genkeypair -noprompt \
        -alias "$KEYSTORE_ALIAS" -keyalg RSA -keysize 2048 -validity 10000 \
        -keystore "$KEYSTORE_FILE" -storepass "android" -keypass "android" \
        -storetype PKCS12 \
        -dname "CN=ReVanced,O=ReVanced,C=US" >/dev/null 2>&1 && { KEYSTORE_PASS="android"; return 0; }
    return 1
}

# ─────────────────────────────────────────
# 2. Keystore 준비
# ─────────────────────────────────────────
setup_keystore() {
    echo ""
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${GREEN}Keystore 준비 (서명 일치 확인)${NC}"
    echo -e "${YELLOW}==================================${NC}"

    # VerifyBKS.class 컴파일 (morphe-cli JAR 준비 이후 호출됨)
    if ! _init_bks_checker; then
        echo -e "${YELLOW}[WARN] VerifyBKS 컴파일 실패 (javac 미설치?): pkg install default-jdk${NC}"
    fi

    local TMP_BKS="$WORK_DIR/_ks_tmp.keystore"

    # 빈 문자열을 1순위로 – my_kakao_key.keystore store/key 패스워드 모두 빈 문자열
    local PASS_LIST=("" "android" "ReVanced Key" "revanced" "ReVanced" "password" "test" "123456" "changeit")

    local SCRIPT_DIR_LOCAL
    SCRIPT_DIR_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR_LOCAL="$BASE_DIR"

    local CANDIDATES=(
        "$KEYSTORE_FILE"
        "$SCRIPT_DIR_LOCAL/my_kakao_key.keystore"
        "$BASE_DIR/my_kakao_key.keystore"
        "$HOME/my_kakao_key.keystore"
        "$HOME/morphe-kakao/my_kakao_key.keystore"
        "$HOME/revanced-build-script-ample/my_kakao_key.keystore"
        "$HOME/revanced-kakao-patch/my_kakao_key.keystore"
        "$HOME/kakao-revanced-patch/my_kakao_key.keystore"
        "$HOME/Downloads/my_kakao_key.keystore"
        "$HOME/revanced-kakao-patch/kakaotalk-patched.keystore"
        "$HOME/morphe-kakao/kakaotalk-patched.keystore"
        "$BASE_DIR/kakaotalk-patched.keystore"
        "$SCRIPT_DIR_LOCAL/kakaotalk-patched.keystore"
        "$HOME/revanced-build-script/output/patched.keystore"
    )
    # Termux 홈 전체 스캔 (깊이 4)
    while IFS= read -r extra; do
        CANDIDATES+=("$extra")
    done < <(find "$HOME" -maxdepth 4 -name "*.keystore" 2>/dev/null | sort)

    echo -e "${BLUE}[INFO] keystore 탐색 중...${NC}"
    local FOUND_KS="" FOUND_PASS="" FOUND_ALIAS=""

    # ── 1단계: VerifyBKS.class 로 BKS 직접 검증 ──
    for ks in "${CANDIDATES[@]}"; do
        [ -f "$ks" ] || continue
        for pass in "${PASS_LIST[@]}"; do
            local got_alias
            got_alias=$(_check_bks "$ks" "$pass") || continue
            [ -n "$got_alias" ] || continue
            FOUND_KS="$ks"; FOUND_PASS="$pass"; FOUND_ALIAS="$got_alias"
            break 2
        done
    done

    # ── 2단계: BKS 직접 로드 불가 → JKS/PKCS12 → BKS 변환 ──
    if [ -z "$FOUND_KS" ]; then
        echo -e "${YELLOW}[INFO] BKS 직접 로드 불가 → 형식 변환 시도...${NC}"
        for ks in "${CANDIDATES[@]}"; do
            [ -f "$ks" ] || continue
            for pass in "${PASS_LIST[@]}"; do
                # keytool 로 JKS/PKCS12 읽기 가능 여부 확인
                local readable=0
                for fmt in PKCS12 JKS; do
                    keytool -list -keystore "$ks" -storepass "$pass" \
                            -storetype "$fmt" >/dev/null 2>&1 && { readable=1; break; }
                done
                [ $readable -eq 1 ] || continue
                # BKS 로 변환
                if _conv_to_bks "$ks" "$pass" "$TMP_BKS" "android"; then
                    local got_alias
                    got_alias=$(_check_bks "$TMP_BKS" "android") || got_alias="$KEYSTORE_ALIAS"
                    cp "$TMP_BKS" "$KEYSTORE_FILE"; rm -f "$TMP_BKS"
                    KEYSTORE_PASS="android"
                    KEYSTORE_ALIAS="${got_alias:-$KEYSTORE_ALIAS}"
                    local label
                    echo "$ks" | grep -q "kakaotalk-patched" \
                        && label="★ 기존 서명 일치 → BKS 변환" \
                        || label="$(basename "$ks") → BKS 변환"
                    echo -e "${GREEN}[OK] $label 완료${NC}"
                    echo -e "${GREEN}[OK] Keystore: $KEYSTORE_FILE  Pass: $KEYSTORE_PASS  Alias: $KEYSTORE_ALIAS${NC}"
                    return 0
                fi
            done
        done
    fi

    # ── 3단계: 유효한 BKS 발견 → WORK_DIR 에 복사 ──
    if [ -n "$FOUND_KS" ]; then
        cp "$FOUND_KS" "$KEYSTORE_FILE"
        KEYSTORE_PASS="$FOUND_PASS"
        KEYSTORE_ALIAS="$FOUND_ALIAS"
        local label
        echo "$FOUND_KS" | grep -q "kakaotalk-patched" \
            && label="★ 기존 서명 일치 키스토어" \
            || label="$(basename "$FOUND_KS")"
        echo -e "${GREEN}[OK] Keystore 로드: $label${NC}"
        echo -e "${GREEN}[OK] Keystore: $KEYSTORE_FILE${NC}"
        echo -e "${CYAN}     Pass  : $KEYSTORE_PASS${NC}"
        echo -e "${CYAN}     Alias : $KEYSTORE_ALIAS${NC}"
        return 0
    fi

    # ── 4단계: 로컬 실패 → GitHub 다운로드 후 재검증 ──
    echo -e "${YELLOW}[INFO] 로컬 keystore 없음 → GitHub 다운로드...${NC}"
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
            local got_alias
            got_alias=$(_check_bks "$KEYSTORE_FILE" "$pass") || continue
            [ -n "$got_alias" ] || continue
            KEYSTORE_PASS="$pass"; KEYSTORE_ALIAS="$got_alias"
            echo -e "${GREEN}[OK] GitHub keystore 검증 완료 (pass=$pass alias=$got_alias)${NC}"
            echo -e "${GREEN}[OK] Keystore: $KEYSTORE_FILE${NC}"
            return 0
        done
        # 변환 시도
        for pass in "${PASS_LIST[@]}"; do
            if _conv_to_bks "$KEYSTORE_FILE" "$pass" "$TMP_BKS" "android"; then
                local got_alias
                got_alias=$(_check_bks "$TMP_BKS" "android") || got_alias="$KEYSTORE_ALIAS"
                cp "$TMP_BKS" "$KEYSTORE_FILE"; rm -f "$TMP_BKS"
                KEYSTORE_PASS="android"; KEYSTORE_ALIAS="${got_alias:-$KEYSTORE_ALIAS}"
                echo -e "${GREEN}[OK] GitHub keystore → BKS 변환 완료${NC}"
                return 0
            fi
        done
    fi

    # ── 5단계: 최후 수단 – 새 BKS 생성 (서명 변경 경고) ──
    echo ""
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}[경고] 기존 서명 키를 찾을 수 없습니다.${NC}"
    echo -e "${RED}       새 키 생성 → 기존 앱 삭제 후 재설치 필요${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}계속하려면 Enter, 중단하려면 Ctrl+C${NC}"
    read -r
    if _gen_new_bks; then
        echo -e "${GREEN}[OK] 새 keystore 생성 완료${NC}"
        echo -e "${GREEN}[OK] Keystore: $KEYSTORE_FILE  Pass: $KEYSTORE_PASS  Alias: $KEYSTORE_ALIAS${NC}"
        return 0
    fi
    echo -e "${RED}[ERROR] keystore 준비 완전 실패${NC}"
    return 1
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
# 5b. 패치 항목 선택 (개별 활성화/비활성화)
# ─────────────────────────────────────────
select_patches() {
    echo ""
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${GREEN}패치 항목 선택${NC}"
    echo -e "${YELLOW}==================================${NC}"
    echo ""

    # morphe-cli list-patches 로 패치 목록 조회
    echo -e "${BLUE}[INFO] 패치 목록 조회 중...${NC}"
    local LIST_OUT
    LIST_OUT=$(java -jar "$MORPHE_CLI_JAR" list-patches \
        --patches "$MPP_FILE" \
        -f "$PKG_NAME" 2>/dev/null) || true

    if [ -z "$LIST_OUT" ]; then
        echo -e "${YELLOW}[INFO] 패치 목록 조회 불가 → 전체 패치 적용${NC}"
        return 0
    fi

    # 패치 이름 파싱: "숫자. 패치명 - 설명" 형식
    local PATCH_NAMES=()
    local PATCH_INDICES=()
    while IFS= read -r line; do
        local idx name
        if [[ "$line" =~ ^[[:space:]]*([0-9]+)\.[[:space:]]+(.+)$ ]]; then
            idx="${BASH_REMATCH[1]}"
            name="${BASH_REMATCH[2]}"
            # 설명 부분(" - ...") 제거하여 깔끔하게 표시
            name="${name%% - *}"
            PATCH_INDICES+=("$idx")
            PATCH_NAMES+=("$name")
        fi
    done <<< "$LIST_OUT"

    if [ ${#PATCH_NAMES[@]} -eq 0 ]; then
        echo -e "${YELLOW}[INFO] 파싱된 패치 없음 → 전체 적용${NC}"
        return 0
    fi

    echo -e "${CYAN}사용 가능한 패치 목록 (${PKG_NAME}):${NC}"
    echo ""
    for i in "${!PATCH_NAMES[@]}"; do
        printf "  ${GREEN}%3s.${NC} %s\n" "${PATCH_INDICES[$i]}" "${PATCH_NAMES[$i]}"
    done
    echo ""

    echo -e "${YELLOW}적용 방식을 선택하세요:${NC}"
    echo -e "  ${GREEN}1.${NC} 전체 패치 적용 (기본값 – Enter)"
    echo -e "  ${BLUE}2.${NC} 일부 패치 비활성화  (나머지 전부 적용)"
    echo -e "  ${BLUE}3.${NC} 선택한 패치만 활성화 (나머지 전부 비활성)"
    echo ""
    read -r -p "> " MODE_SEL
    [ -z "$MODE_SEL" ] && MODE_SEL="1"

    case "$MODE_SEL" in
        2)
            echo ""
            echo -e "${YELLOW}비활성화할 패치 번호를 입력하세요 (쉼표로 구분, 예: 1,3,5):${NC}"
            read -r -p "> " DISABLE_INPUT
            local count=0
            for num in $(echo "$DISABLE_INPUT" | tr ',' ' '); do
                num="${num// /}"
                [[ "$num" =~ ^[0-9]+$ ]] || continue
                PATCH_EXTRA_ARGS+=("--di=$num")
                (( count++ ))
            done
            echo -e "${GREEN}[OK] ${count}개 패치 비활성화 예약${NC}"
            ;;
        3)
            echo ""
            echo -e "${YELLOW}활성화할 패치 번호를 입력하세요 (쉼표로 구분, 예: 1,3,5):${NC}"
            read -r -p "> " ENABLE_INPUT
            PATCH_EXTRA_ARGS+=("--exclusive")
            local count=0
            for num in $(echo "$ENABLE_INPUT" | tr ',' ' '); do
                num="${num// /}"
                [[ "$num" =~ ^[0-9]+$ ]] || continue
                PATCH_EXTRA_ARGS+=("--ei=$num")
                (( count++ ))
            done
            echo -e "${GREEN}[OK] ${count}개 패치만 활성화 예약 (나머지 비활성)${NC}"
            ;;
        *)
            echo -e "${GREEN}[OK] 전체 패치 적용${NC}"
            ;;
    esac
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
        "${PATCH_EXTRA_ARGS[@]}" \
        -o "$OUTPUT_APK" \
        "$APKM_FILE" || {
        echo -e "${RED}[ERROR] morphe-cli 패치 실패${NC}"
        return 1
    }

    # 결과 확인
    if [ -f "$OUTPUT_APK" ]; then
        # ── 서명 검증 후 필요시 재서명 ──
        local ACTUAL_SERIAL
        ACTUAL_SERIAL=$(keytool -printcert -jarfile "$OUTPUT_APK" 2>/dev/null \
            | grep -i 'serial\|일련' | grep -oP '[0-9a-f]{8,}' | head -n1) || ACTUAL_SERIAL=""
        local WANT_SERIAL="19f687f04ccebf6b"
        if [ "$ACTUAL_SERIAL" != "$WANT_SERIAL" ]; then
            echo -e "${YELLOW}[INFO] 서명 serial 불일치 ($ACTUAL_SERIAL) → 재서명 시도...${NC}"
            _resign_apk "$OUTPUT_APK" || \
                echo -e "${YELLOW}[WARN] 재서명 실패 – 서명이 다를 수 있음${NC}"
        fi

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
    select_patches
    run_patch          || exit 1

    echo ""
    echo -e "${GREEN}모든 작업이 완료되었습니다.${NC}"
}

main
