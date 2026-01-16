#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""ReVanced Build Script."""

import os
import re
import sys
import argparse
import subprocess
from shutil import which
from typing import List, Dict, Tuple, Optional

CLI_RELEASE_URL = 'https://api.github.com/repos/AmpleReVanced/revanced-cli/releases/latest'
PATCHES_RELEASE_URL = 'https://api.github.com/repos/AmpleReVanced/revanced-patches/releases/latest'

# 로컬 RVP 파일 경로 (버그 수정 버전)
LOCAL_RVP_PATHS = [
    '/storage/emulated/0/Download/patches-fixed.rvp',
    './patches-fixed.rvp',
    './output/patches-fixed.rvp',
    './patches/build/libs/patches-5.47.0.rvp',
]

# 한국어 메시지
MSG_KO = {
    'welcome': '\n🔧 카카오톡 ReVanced 빌드 스크립트\n',
    'local_rvp_found': '[✓] 로컬 RVP 파일 발견: {}',
    'local_rvp_prompt': '로컬 RVP 파일을 사용하시겠습니까? (버그 수정 버전)',
    'downloading': '[↓] 다운로드 중: {}',
    'patch_select': '패치 선택 (Space로 선택, Enter로 확인):',
    'patching': '[⚙] 패치 적용 중...',
    'done': '[✓] 완료! 패치된 APK: {}',
    'apk_prompt': 'APK 파일 경로를 입력하세요:',
}

# Helpful guidance for users when Java checks fail. Recommend Azul Zulu (OpenJDK builds).
ZULU_INSTALL_GUIDANCE = (
    "Recommended: install Azul Zulu (OpenJDK builds) or another OpenJDK 17+ distribution:\n"
    "  - Azul Zulu downloads: https://www.azul.com/downloads/?package=jdk\n"
    "  - Install examples (may require adding Azul repos per distro):\n"
    "      Debian/Ubuntu: sudo apt update && sudo apt install -y openjdk-17-jdk\n"
    "      Fedora: sudo dnf install -y java-17-openjdk-devel\n"
    "      Arch: sudo pacman -Syu jdk-openjdk\n"
    "  - For Azul Zulu packages and platform-specific instructions, see: https://www.azul.com/downloads/\n"
    "After installing, ensure the 'java' command is available on your PATH or set JAVA_HOME to the JDK location."
)


def check_java_environment() -> None:
    if which('java') is None:
        raise EnvironmentError(
            "Java is not installed or not found in PATH.\n" + ZULU_INSTALL_GUIDANCE
        )
    result = subprocess.run(['java', '-version'], capture_output=True, text=True, encoding='utf-8', errors='replace')
    if result.returncode != 0:
        raise EnvironmentError(
            "Failed to execute 'java -version' (return code != 0).\n" + ZULU_INSTALL_GUIDANCE
        )
    output = (result.stdout or result.stderr or "").strip()

    major_version = None
    # Regex to find version string like "1.8.0_341" or "17.0.5"
    match = re.search(r'version "([^"]+)"', output)
    if match:
        version_str = match.group(1)
        parts = version_str.split('.')
        if parts[0] == '1':
            # Legacy version format: 1.x.y... -> major is x
            if len(parts) > 1:
                major_version = int(parts[1])
        else:
            # Modern version format: xx.y.z... -> major is xx
            major_version_str_match = re.match(r'\d+', parts[0])
            if major_version_str_match:
                major_version = int(major_version_str_match.group(0))

    if major_version is None:
        raise EnvironmentError(
            f"Could not parse Java version from output:\n{output}\n" + ZULU_INSTALL_GUIDANCE
        )

    print(f"[OK] Java detected (version {major_version}):\n{output}")

    if not (17 <= major_version < 25):
        raise EnvironmentError(
            f"Unsupported Java version: {major_version}. Please use a Java version that is >= 17 and < 25.\n"
            + ZULU_INSTALL_GUIDANCE
        )
    
    print(f"[OK] Java version {major_version} is supported.")


def get_latest_release(url: str):
    import requests
    try:
        resp = requests.get(url, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        tag = data.get('tag_name') or ''
        assets = data.get('assets') or []
        if not tag:
            raise ConnectionError("Latest release did not include a tag_name.")
        return tag, assets
    except Exception as e:
        raise ConnectionError(f"Failed to fetch latest release: {url}") from e


def _asset_download_url(asset: dict) -> str:
    return asset.get('browser_download_url') or asset.get('url') or ''


def pick_cli_jar_download_url(assets):
    jar_assets = [a for a in assets if str(a.get('name', '')).lower().endswith('.jar')]
    cli_jars = [a for a in jar_assets if 'cli' in str(a.get('name', '')).lower()]
    chosen = (cli_jars or jar_assets or [None])[0]
    if not chosen:
        return None, None
    url = _asset_download_url(chosen)
    name = chosen.get('name') or os.path.basename(url) or 'revanced-cli.jar'
    if not url:
        return None, None
    return url, name


def pick_patches_rvp_download_url(assets):
    rvp_assets = [a for a in assets if str(a.get('name', '')).lower().endswith('.rvp')]
    if not rvp_assets:
        return None, None
    preferred = [a for a in rvp_assets if 'patch' in str(a.get('name', '')).lower()]
    chosen = (preferred or rvp_assets)[0]
    url = _asset_download_url(chosen)
    name = chosen.get('name') or os.path.basename(url) or 'patches.rvp'
    if not url:
        return None, None
    return url, name


def download_file(url: str, dest_path: str) -> None:
    import requests
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    with requests.get(url, stream=True, timeout=60) as r:
        r.raise_for_status()
        total = int(r.headers.get('Content-Length', 0))
        downloaded = 0
        chunk_size = 1024 * 64
        with open(dest_path, 'wb') as f:
            for chunk in r.iter_content(chunk_size=chunk_size):
                if not chunk:
                    continue
                f.write(chunk)
                downloaded += len(chunk)
                if total:
                    pct = downloaded * 100 // total
                    print(f"\r[DL] {downloaded}/{total} bytes ({pct}%)", end='', flush=True)
        print()
    print(f"[OK] Downloaded: {dest_path}")


def find_local_rvp() -> Optional[str]:
    """로컬에 있는 RVP 파일 찾기 (버그 수정 버전 우선)"""
    for path in LOCAL_RVP_PATHS:
        if os.path.isfile(path):
            return path
    return None


def prompt_apk_path(initial=None) -> str:
    if initial and os.path.isfile(initial):
        return initial
    
    # 다운로드 폴더에서 APK/APKM 자동 검색
    download_dirs = [
        '/storage/emulated/0/Download',
        os.path.expanduser('~/Downloads'),
        '.',
    ]
    apk_files = []
    for d in download_dirs:
        if os.path.isdir(d):
            for f in os.listdir(d):
                if f.lower().endswith(('.apk', '.apkm')) and 'kakao' in f.lower():
                    apk_files.append(os.path.join(d, f))
    
    if apk_files:
        print(f"\n[INFO] 발견된 카카오톡 APK 파일:")
        for i, f in enumerate(apk_files[:5], 1):
            print(f"  {i}. {os.path.basename(f)}")
        try:
            sel = input("\n번호를 선택하거나 직접 경로 입력: ").strip()
            if sel.isdigit() and 1 <= int(sel) <= len(apk_files):
                return apk_files[int(sel) - 1]
            elif os.path.isfile(sel):
                return sel
        except:
            pass
    
    tries = 3
    candidate = initial
    while tries > 0:
        if not candidate:
            candidate = input(MSG_KO['apk_prompt'] + " ").strip()
        if os.path.isfile(candidate):
            return candidate
        print(f"[WARN] 파일을 찾을 수 없음: {candidate}")
        candidate = None
        tries -= 1
    print("[ERR] APK 경로 확인 실패. 종료합니다.")
    sys.exit(3)


def run_cli_list_patches(cli_jar: str, rvp_path: str,
                         with_packages=True, with_versions=True, with_options=True) -> str:
    cmd = ['java', '-jar', cli_jar, 'list-patches']
    if with_packages:
        cmd.append('--with-packages')
    if with_versions:
        cmd.append('--with-versions')
    if with_options:
        cmd.append('--with-options')
    cmd.append(rvp_path)
    print(f"[INFO] Listing patches via CLI:\n{' '.join(cmd)}")
    proc = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')
    if proc.returncode != 0:
        err = (proc.stderr or '').strip()
        out = (proc.stdout or '').strip()
        print(f"[ERR] list-patches failed.\nSTDERR:\n{err}\nSTDOUT:\n{out}")
        sys.exit(5)
    return proc.stdout


def parse_patches_from_text(text: str,
                            target_package: str | None = None,
                            include_universal: bool = False):
    """Parse revanced-cli 'list-patches' output into structured entries.

    Returns a list of entries with keys:
      - index, name, description, enabled
      - packages, compatible_versions
      - options_struct (detailed option dicts) and options_lines (raw lines)
      - is_universal (True when no packages are declared)
      - raw (original block text)
    """
    import re

    idx_pat = re.compile(r'(?m)^\s*Index:\s*\d+\s*$')
    matches = list(idx_pat.finditer(text))
    blocks = []
    if matches:
        for i, m in enumerate(matches):
            start = m.start()
            end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
            blocks.append(text[start:end])
    else:
        blocks = [text]

    name_re = re.compile(r'(?m)^\s*Name:\s*(.+?)\s*$')
    index_re = re.compile(r'(?m)^\s*Index:\s*(\d+)\s*$')
    desc_re = re.compile(r'(?m)^\s*Description:\s*(.+?)\s*$')
    en_re = re.compile(r'(?m)^\s*Enabled:\s*(true|false)\s*$')
    packages_line_re = re.compile(r'(?m)^\s*Packages?:\s*(.+?)\s*$')

    opt_hdr_re = re.compile(r'(?m)^\s*Options?\s*:\s*$')
    opt_key_re = re.compile(r'(?m)^\s*Key:\s*(.+?)\s*$')
    opt_def_re = re.compile(r'(?m)^\s*Default:\s*(.+?)\s*$')
    opt_type_re = re.compile(r'(?m)^\s*Type:\s*(.+?)\s*$')
    opt_req_re = re.compile(r'(?m)^\s*Required:\s*(true|false)\s*$')
    opt_title_re = re.compile(r'(?m)^\s*Title:\s*(.+?)\s*$')
    opt_desc2_re = re.compile(r'(?m)^\s*Description:\s*(.+?)\s*$')
    opt_possible_hdr_re = re.compile(r'(?m)^\s*Possible values\s*:\s*$')

    compat_hdr_re = re.compile(r'(?m)^\s*Compatible packages\s*:\s*$')
    compat_pkg_re = re.compile(r'(?m)^\s*Package(?:\s+name)?\s*:\s*(.+?)\s*$')
    compat_versions_hdr_re = re.compile(r'(?m)^\s*Compatible versions\s*:\s*$')

    entries: List[dict] = []

    for block in blocks:
        raw = block.strip("\n")
        if not raw:
            continue

        entry = {
            'index': None, 'name': None, 'description': None, 'enabled': None,
            'packages': [], 'compatible_versions': {},
            'options_struct': [], 'options_lines': [],
            'is_universal': False, 'raw': raw
        }

        mi = index_re.search(block)
        if mi:
            entry['index'] = int(mi.group(1))
        mn = name_re.search(block)
        if mn:
            entry['name'] = mn.group(1).strip()
        md = desc_re.search(block)
        if md:
            entry['description'] = md.group(1).strip()
        me = en_re.search(block)
        if me:
            entry['enabled'] = (me.group(1).lower() == 'true')

        mp = packages_line_re.search(block)
        if mp:
            pkgs = [p.strip() for p in mp.group(1).split(',') if p.strip()]
            for p in pkgs:
                if p not in entry['packages']:
                    entry['packages'].append(p)
                entry['compatible_versions'].setdefault(p, [])

        lines = block.splitlines()
        i = 0
        in_options = False
        in_possible_values = False
        cur_opt = None

        def flush_opt():
            nonlocal cur_opt
            if cur_opt and cur_opt.get('key'):
                entry['options_struct'].append(cur_opt)
            cur_opt = None

        in_compat = False
        cur_pkg = None
        in_compat_versions = False

        while i < len(lines):
            line = lines[i]

            if opt_hdr_re.match(line):
                in_options = True
                in_possible_values = False
                flush_opt()
                i += 1
                continue

            if compat_hdr_re.match(line):
                in_compat = True
                in_compat_versions = False
                cur_pkg = None
                in_options = False
                in_possible_values = False
                flush_opt()
                i += 1
                continue

            if in_options:
                stripped = line.strip()
                if stripped:
                    entry['options_lines'].append(stripped)

                if opt_key_re.match(line):
                    flush_opt()
                    cur_opt = {
                        'key': opt_key_re.match(line).group(1).strip(),
                        'default': None, 'type': None, 'required': None,
                        'title': None, 'description': None, 'possible_values': []
                    }
                    in_possible_values = False
                    i += 1
                    continue

                if cur_opt is not None:
                    if opt_def_re.match(line):
                        cur_opt['default'] = opt_def_re.match(line).group(1).strip()
                        i += 1
                        continue
                    if opt_type_re.match(line):
                        cur_opt['type'] = opt_type_re.match(line).group(1).strip()
                        i += 1
                        continue
                    if opt_req_re.match(line):
                        cur_opt['required'] = (opt_req_re.match(line).group(1).lower() == 'true')
                        i += 1
                        continue
                    if opt_title_re.match(line):
                        cur_opt['title'] = opt_title_re.match(line).group(1).strip()
                        i += 1
                        continue
                    if opt_desc2_re.match(line):
                        cur_opt['description'] = opt_desc2_re.match(line).group(1).strip()
                        i += 1
                        continue
                    if opt_possible_hdr_re.match(line):
                        in_possible_values = True
                        i += 1
                        continue
                    if in_possible_values:
                        pv = line.strip()
                        if pv:
                            cur_opt['possible_values'].append(pv)
                        i += 1
                        continue

                i += 1
                continue

            if in_compat:
                if compat_pkg_re.match(line):
                    cur_pkg = compat_pkg_re.match(line).group(1).strip()
                    if cur_pkg and cur_pkg not in entry['packages']:
                        entry['packages'].append(cur_pkg)
                    entry['compatible_versions'].setdefault(cur_pkg, [])
                    in_compat_versions = False
                    i += 1
                    continue
                if compat_versions_hdr_re.match(line):
                    in_compat_versions = True
                    i += 1
                    continue
                if in_compat_versions and cur_pkg:
                    v = line.strip()
                    if v:
                        entry['compatible_versions'][cur_pkg].append(v)
                    i += 1
                    continue

            i += 1

        flush_opt()
        entry['is_universal'] = (len(entry['packages']) == 0)
        entries.append(entry)

    if target_package:
        tp = target_package.strip().lower()
        filtered = []
        for e in entries:
            pkgs_lower = [p.lower() for p in (e['packages'] or [])]
            if tp in pkgs_lower or (include_universal and e['is_universal']):
                filtered.append(e)
        entries = filtered

    return entries


def interactive_select_patches(entries, min_choices=1, show_versions_for: Optional[str] = None):
    from questionary import checkbox
    if not entries:
        print("[ERR] No patches parsed from list-patches output (after filtering).")
        sys.exit(7)
    tp = (show_versions_for or "").lower() if show_versions_for else None

    choices = []
    for e in entries:
        left = f"[{e['index']}]" if e['index'] is not None else "[—]"
        name = e['name'] or '(Unnamed patch)'
        tags = []
        if e.get('enabled'):
            tags.append("default: enabled")
        if e.get('is_universal'):
            tags.append("universal")
        if e.get('packages'):
            tags.append(f"Packages: {', '.join(e['packages'])}")
        if tp:
            for pkg, vers in (e.get('compatible_versions') or {}).items():
                if pkg.lower() == tp and vers:
                    preview = ", ".join(vers[:3]) + ("…" if len(vers) > 3 else "")
                    tags.append(f"Compat for {pkg}: {preview}")
                    break
        tag_text = f" — {' | '.join(tags)}" if tags else ""
        label = f"{left} {name}{tag_text}"
        value = ('idx', e['index']) if e['index'] is not None else ('name', name)
        choices.append({"name": label, "value": value, "checked": bool(e.get('enabled', False))})

    result = checkbox(
        "Select patches (Space to toggle, Enter to confirm):",
        choices=choices,
        validate=lambda ans: True if len(ans) >= min_choices else "Select at least one patch.",
        instruction="",
        qmark="> "
    ).ask()

    if result is None:
        print("[INFO] Selection cancelled.")
        sys.exit(0)
    return result


def parse_option_keys_from_lines(options_lines: List[str]) -> List[Tuple[str, Optional[str], Optional[str]]]:
    """Heuristic extraction of option keys from raw option lines.

    Used when structured option metadata is not available.
    """
    import re
    keys = []
    seen = set()
    pat = re.compile(
        r'^\s*(?:[-*]\s*)?([A-Za-z0-9_.-]+)'            # key
        r'(?:\s*\(\s*([A-Za-z0-9_\[\]., ]+?)\s*\))?'     # (Type)
        r'(?:.*?\bdefault\s*[:=]\s*([^\s,]+))?',         # default=VALUE
        re.IGNORECASE
    )
    for ln in options_lines:
        m = pat.match(ln.strip())
        if not m:
            continue
        key = m.group(1)
        type_hint = m.group(2)
        default = m.group(3)
        if key and key not in seen:
            seen.add(key)
            keys.append((key, type_hint, default))
    return keys


def _split_kv_pairs(s: str) -> List[Tuple[str, Optional[str]]]:
    """
    Split comma-separated key=val items, ignoring commas inside [].
    """
    items = []
    buf = []
    depth = 0
    for ch in s:
        if ch == '[':
            depth += 1
        elif ch == ']':
            depth = max(0, depth - 1)
        if ch == ',' and depth == 0:
            token = "".join(buf).strip()
            if token:
                items.append(token)
            buf = []
        else:
            buf.append(ch)
    if buf:
        items.append("".join(buf).strip())

    pairs = []
    for token in items:
        if '=' in token:
            k, v = token.split('=', 1)
            pairs.append((k.strip(), v.strip()))
        else:
            pairs.append((token.strip(), None))
    return pairs


def prompt_options_for_selected(selected_ids: List[Tuple[str, object]], entries: List[dict]):
    """Prompt for option values for selected patches.

    Uses structured option metadata when present, otherwise falls back to
    heuristic parsing of raw option lines.
    """
    try:
        from questionary import text, confirm, select
    except Exception:
        print("[ERR] 'questionary' is required for interactive selection.")
        print("      Install it with: pip install questionary")
        sys.exit(6)

    by_idx = {e['index']: e for e in entries if e['index'] is not None}
    by_name = {e['name']: e for e in entries if e.get('name')}

    result = []
    for kind, val in selected_ids:
        entry = by_idx.get(val) if kind == 'idx' else by_name.get(val)
        opts_map = {}

        if entry:
            name = entry.get('name') or str(val)
            if entry.get('options_struct'):
                print("\n" + "=" * 60)
                print(f"Options for patch: {name}")
                print("-" * 60)
                for opt in entry['options_struct']:
                    k = opt.get('key')
                    t = opt.get('type')
                    d = opt.get('default')
                    req = opt.get('required')
                    pv = opt.get('possible_values') or []

                    print(f"Key: {k}")
                    if t: print(f"  Type: {t}")
                    if d is not None: print(f"  Default: {d}")
                    if req is not None: print(f"  Required: {req}")
                    if pv: print(f"  Possible values: {', '.join(pv)}")

                    set_it = confirm(f"Set option '{k}'?", default=bool(req)).ask()
                    if not set_it:
                        continue

                    if pv:
                        choices = list(pv) + ["<custom>"]
                        sel = select(f"Choose value for '{k}'", choices=choices, default=d if d in pv else (pv[0] if pv else "<custom>")).ask()
                        if sel == "<custom>":
                            val_input = text(f"Enter custom value for '{k}'", default=d or "").ask()
                            if (val_input or "") == "" and not d:
                                opts_map[k] = None
                            else:
                                opts_map[k] = val_input
                        else:
                            opts_map[k] = sel
                    else:
                        prompt = f"Value for '{k}'"
                        if t:
                            prompt += f" (type: {t})"
                        if d is not None:
                            prompt += f" [default: {d}]"
                        prompt += " (leave empty to set null):"
                        val_input = text(prompt, default=d or "").ask()
                        if (val_input or "") == "" and d is None:
                            opts_map[k] = None
                        else:
                            opts_map[k] = val_input
                print("-" * 60)
            elif entry.get('options_lines'):
                print("\n" + "=" * 60)
                print(f"Options (raw) for patch: {name}")
                print("-" * 60)
                for ln in entry['options_lines']:
                    print(ln)
                print("-" * 60)
                keys = parse_option_keys_from_lines(entry['options_lines'])
                if keys:
                    for k, t, d in keys:
                        set_it = confirm(f"Set option '{k}'?", default=False).ask()
                        if set_it:
                            prompt = f"Value for '{k}'"
                            if t: prompt += f" (type: {t})"
                            if d: prompt += f" [default: {d}]"
                            prompt += " (leave empty to set null):"
                            val_input = text(prompt, default=d or "").ask()
                            if (val_input or "") == "" and not d:
                                opts_map[k] = None
                            else:
                                opts_map[k] = val_input
                else:
                    ans = text(
                        "Enter -O options as comma-separated key=value (e.g., key1=val1,key2=val2). Leave blank to skip:",
                        default=""
                    ).ask()
                    if ans:
                        for k, v in _split_kv_pairs(ans):
                            opts_map[k] = v

        result.append({'by': kind, 'value': val, 'options': opts_map})

    return result


def build_patch_command(cli_jar: str, rvp_path: str, apk_path: str,
                        out_apk: str, exclusive: bool,
                        selected_with_opts: List[Dict],
                        keystore_path: Optional[str] = None,
                        keystore_pass: Optional[str] = None,
                        key_alias: Optional[str] = None,
                        key_pass: Optional[str] = None,
                        extra_args: Optional[List[str]] = None):
    """
    Build the revanced-cli patch command.
    Keep -e/--ei adjacent to its -O options for clarity.
    """
    cmd = ['java', '-jar', cli_jar, 'patch', '-p', rvp_path]
    if exclusive:
        cmd.append('--exclusive')

    for sel in selected_with_opts:
        kind, val = sel['by'], sel['value']
        if kind == 'idx':
            cmd.extend(['--ei', str(val)])
        else:
            cmd.extend(['-e', str(val)])
        for k, v in (sel.get('options') or {}).items():
            if v is None or v == "":
                cmd.append(f"-O{k}")
            else:
                cmd.append(f"-O{k}={v}")

    # Add signing options if provided
    if keystore_path:
        cmd.extend(['--keystore', keystore_path])
    if keystore_pass:
        cmd.extend(['--keystore-password', keystore_pass])
    if key_alias:
        cmd.extend(['--keystore-entry-alias', key_alias])
    if key_pass:
        cmd.extend(['--keystore-entry-password', key_pass])

    if extra_args:
        cmd.extend(extra_args)
    cmd.extend(['-o', out_apk, apk_path])
    return cmd


def main():
    print(MSG_KO['welcome'])
    
    parser = argparse.ArgumentParser(description="ReVanced 빌드 스크립트 (카카오톡 버그 수정 포함)")
    parser.add_argument('--output', type=str, default='output', help='출력 디렉토리')
    parser.add_argument('--apk', type=str, help='패치할 APK 파일 경로')
    parser.add_argument('--rvp', type=str, help='로컬 RVP 파일 경로 (지정시 다운로드 생략)')
    parser.add_argument('--package', type=str, default='com.kakao.talk', help='패치 필터링할 패키지명 (기본: com.kakao.talk)')
    parser.add_argument('--include-universal', action='store_true', default=True, help='유니버설 패치 포함 (기본: 활성화)')
    parser.add_argument('--exclusive', dest='exclusive', action='store_true', default=True, help='선택한 패치만 적용')
    parser.add_argument('--no-exclusive', dest='exclusive', action='store_false', help='--exclusive 비활성화')
    parser.add_argument('--run', action='store_true', help='패치 명령 실제 실행')
    parser.add_argument('--keystore', type=str, help='서명용 키스토어 파일')
    parser.add_argument('--keystore-password', type=str, help='키스토어 비밀번호')
    parser.add_argument('--key-alias', type=str, help='키 별칭')
    parser.add_argument('--key-password', type=str, help='키 비밀번호')
    parser.add_argument('--use-local-rvp', action='store_true', help='로컬 RVP 파일 자동 사용 (버그 수정 버전)')
    args = parser.parse_args()

    try:
        check_java_environment()
    except EnvironmentError as e:
        print(f"[ERR] {e}")
        sys.exit(1)

    os.makedirs(args.output, exist_ok=True)

    try:
        tag_cli, assets_cli = get_latest_release(CLI_RELEASE_URL)
        print(f"[INFO] Latest ReVanced CLI release: {tag_cli}")
        url_cli, name_cli = pick_cli_jar_download_url(assets_cli)
        if not url_cli:
            print("[ERR] Could not find a CLI .jar asset in the latest release.")
            sys.exit(2)
        dest_cli = os.path.join(args.output, name_cli)
        print(f"[INFO] Downloading CLI:\n{url_cli}\n-> {dest_cli}")
        download_file(url_cli, dest_cli)
    except ConnectionError as e:
        print(f"[ERR] {e}")
        sys.exit(2)

    # RVP 파일 처리: 로컬 우선, 없으면 다운로드
    dest_rvp = None
    
    # 1. 명시적으로 지정된 RVP
    if args.rvp and os.path.isfile(args.rvp):
        dest_rvp = args.rvp
        print(MSG_KO['local_rvp_found'].format(dest_rvp))
    
    # 2. --use-local-rvp 옵션 또는 자동 검색
    if not dest_rvp:
        local_rvp = find_local_rvp()
        if local_rvp:
            print(MSG_KO['local_rvp_found'].format(local_rvp))
            if args.use_local_rvp:
                dest_rvp = local_rvp
            else:
                try:
                    use_local = input(f"{MSG_KO['local_rvp_prompt']} (y/n): ").strip().lower()
                    if use_local in ('y', 'yes', '예', 'ㅇㅇ'):
                        dest_rvp = local_rvp
                except:
                    pass
    
    # 3. 다운로드 필요
    if not dest_rvp:
        try:
            tag_patches, assets_patches = get_latest_release(PATCHES_RELEASE_URL)
            print(f"[INFO] 최신 ReVanced 패치 릴리스: {tag_patches}")
            url_rvp, name_rvp = pick_patches_rvp_download_url(assets_patches)
            if not url_rvp:
                print("[ERR] RVP 파일을 찾을 수 없습니다.")
                sys.exit(2)
            dest_rvp = os.path.join(args.output, name_rvp)
            print(MSG_KO['downloading'].format(url_rvp))
            download_file(url_rvp, dest_rvp)
        except ConnectionError as e:
            print(f"[ERR] {e}")
            sys.exit(2)

    apk_path = prompt_apk_path(args.apk)
    print(f"[OK] Target APK: {apk_path}")

    list_text = run_cli_list_patches(dest_cli, dest_rvp, with_packages=True, with_versions=True, with_options=True)
    entries = parse_patches_from_text(
        list_text,
        target_package=args.package,
        include_universal=bool(args.include_universal)
    )
    if args.package:
        print(f"[INFO] Filter: Packages contains '{args.package}'" + (" + include universal" if args.include_universal else ""))
    else:
        print("[INFO] No --package filter given. Showing all patches as returned by CLI.")

    selected_ids = interactive_select_patches(entries)

    selected_with_opts = prompt_options_for_selected(selected_ids, entries)

    patched_out = os.path.join(args.output, 'patched.apk')
    cmd = build_patch_command(
        cli_jar=dest_cli,
        rvp_path=dest_rvp,
        apk_path=apk_path,
        out_apk=patched_out,
        exclusive=args.exclusive,
        selected_with_opts=selected_with_opts,
        keystore_path=args.keystore,
        keystore_pass=args.keystore_password,
        key_alias=args.key_alias,
        key_pass=args.key_password,
        extra_args=None
    )

    print("\n[CMD] ReVanced patch command:")
    print(" ".join(f"\"{c}\"" if " " in c else c for c in cmd))

    if args.run:
        print("[RUN] Executing patch command...")
        if sys.platform == 'win32':
            try:
                import ctypes
                kernel32 = ctypes.windll.kernel32
                kernel32.SetConsoleOutputCP(65001)  # UTF-8
            except:
                pass
        proc = subprocess.run(cmd)
        if proc.returncode == 0:
            print(f"[DONE] Patched APK saved at: {patched_out}")
            
            # Download 폴더로 자동 복사
            download_dest = '/storage/emulated/0/Download/kakaotalkpatch.apk'
            try:
                import shutil
                shutil.copy2(patched_out, download_dest)
                print(f"[✓] 다운로드 폴더에 복사됨: {download_dest}")
            except Exception as e:
                print(f"[WARN] 다운로드 폴더 복사 실패: {e}")
                print(f"       수동으로 복사하세요: cp {patched_out} {download_dest}")
        else:
            print(f"[ERR] Patch command failed with exit code {proc.returncode}")
            sys.exit(proc.returncode)
    else:
        print("\\n[INFO] Not executed. Re-run with --run to execute the command.")

if __name__ == "__main__":
    main()
