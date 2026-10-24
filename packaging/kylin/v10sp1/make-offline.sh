#!/usr/bin/env bash
# 组装 engrampa-offline 离线安装包(面向银河麒麟 V10 SP1 arm64)
#
# 运行环境: ubuntu:20.04 (focal) 容器, root, 在 build-main.sh 成功之后。
# 离线包 = engrampa 主 deb + 运行时依赖闭包(deps/*.deb) + 只装缺失的安装脚本。
#
# 闭包算法(与项目麒麟适配指南一致):
#   种子 = 主包 Depends 的 ELF 依赖 + 外部工具包(engrampa 以子进程方式调用,
#          ldd 闭包带不上,必须显式列清单) ;
#   展开 = apt-cache depends --recurse 递归取全量传递依赖 ;
#   剔除 = Essential=yes + 系统核心黑名单(glibc/systemd/dbus/PAM/udev/login/passwd),
#          这些包目标机必已安装且版本同源,带进离线包只会有"升级系统件"的翻车风险。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="${1:-$SCRIPT_DIR/../../..}"
SRC_ROOT="$(cd "$SRC_ROOT" && pwd)"

VERSION="${ENGRAMPA_PKG_VERSION:-1.28.5-1kylin1}"
ARCH="$(dpkg --print-architecture)"
MAIN_DEB="$SRC_ROOT/dist/engrampa_${VERSION}_${ARCH}.deb"
DIST_OUT="$SRC_ROOT/dist"
OFFLINE_ROOT="$SRC_ROOT/offline-root"
CACHE_DIR="$SRC_ROOT/offline-cache"

log() { echo "[make-offline] $*"; }
die() { echo "[make-offline] ERROR: $*" >&2; exit 1; }

[ -f "$MAIN_DEB" ] || die "main deb not found: $MAIN_DEB (run build-main.sh first)"

# ---------------------------------------------------------------- 黑名单
# 指南红线:glibc 永不打包;systemd/dbus/PAM/udev/login/passwd 一旦被离线闭包
# 升级,用户系统直接崩(deepin-screenshot 事故实证)。
BLACKLIST_RE='^(libc6|libc-bin|locales|libnss-[a-z]+|libselinux1?)$|^(systemd|systemd-.*)$|^libsystemd.*$|^(udev|libudev.*)$|^(dbus|dbus-.*)$|^libdbus.*$|^libpam.*$|^login$|^passwd$|^shadow$'

is_blacklisted() {
    local p="$1"
    echo "$p" | grep -Eq "$BLACKLIST_RE" && return 0
    # Essential=yes 的包(含 libc6、dpkg、coreutils、bash 等)一律剔除
    apt-cache show "$p" 2>/dev/null | grep -m1 '^Essential: *yes' >/dev/null && return 0
    return 1
}

# ---------------------------------------------------------------- 种子集合
seed_packages() {
    local depends_field p
    # 主包 ELF 依赖
    depends_field="$(dpkg-deb -f "$MAIN_DEB" Depends)"
    echo "$depends_field" | tr ',' '\n' | sed -E 's/\(.*//; s/^\s+|\s+$//g' | grep -v '^$'
    # 外部工具(required 必须齐;optional 缺了仅告警跳过)
    local all_ok=1
    while IFS='|' read -r pkg level note; do
        case "$pkg" in ''|'#'*) continue ;; esac
        pkg="$(echo "$pkg" | xargs)"
        if apt-cache policy "$pkg" 2>/dev/null | grep -q 'Candidate:'; then
            echo "$pkg"
        else
            if [ "$level" = "required" ]; then
                log "ERROR: REQUIRED tool package not in archive: $pkg ($note)"
                all_ok=0
            else
                log "WARNING: optional tool package not in archive, skipped: $pkg ($note)"
            fi
        fi
    done < "$SCRIPT_DIR/external-tools.list"
    [ "$all_ok" -eq 1 ] || die "required tool packages missing from apt archive"
}

# --------------------------------------------------------- 闭包展开与下载
download_closure() {
    log "expanding recursive dependency closure"
    local seeds
    seeds="$(seed_packages | sort -u)"
    [ -n "$seeds" ] || die "empty seed set"

    # apt-cache depends --recurse:含 Pre-Depends/Depends 全传递闭包。
    # 输出格式: 关系行("  Depends: foo"/"|Depends: foo")与包名行(缩进的纯名字,
    # 递归层越深缩进越多)交替 —— 早期版本只 grep 列首会把闭包退化成种子集合。
    # 剥掉缩进后过滤关系标签行与 <circular> 等标记,剩下的即包名(含备选,备选
    # 会被后续 policy 检查自然过滤)。
    local names
    names="$(apt-cache depends --recurse \
                --no-recommends --no-suggests --no-conflicts \
                --no-breaks --no-replaces --no-enhances \
                $seeds \
             | sed 's/^[[:space:]]*//' \
             | grep -vE '^(Depends|PreDepends|Conflicts|Breaks|Replaces|Enhances|Suggests|Recommends):' \
             | grep -vE '^(\||<|>|#|$)' \
             | sort -u)"

    rm -rf "$CACHE_DIR"; mkdir -p "$CACHE_DIR"
    local kept=0 skipped_essential=0 p
    local final_list_tmp="$CACHE_DIR/.final"
    : > "$final_list_tmp"
    for p in $names; do
        # 有候选版本的才是真实包(排除虚拟包名)
        apt-cache policy "$p" 2>/dev/null | grep -q 'Candidate:' || continue
        if is_blacklisted "$p"; then
            skipped_essential=$((skipped_essential+1))
            continue
        fi
        echo "$p" >> "$final_list_tmp"
        kept=$((kept+1))
    done
    log "closure: $kept packages kept, $skipped_essential blacklisted (essential/system)"

    [ "$kept" -gt 0 ] || die "closure resolved to empty set"

    log "downloading closure (apt-get download)"
    ( cd "$CACHE_DIR" && xargs -a "$final_list_tmp" -r -n 16 -P 4 \
        apt-get download -q ) >>"$CACHE_DIR/download.log" 2>&1 \
        || { tail -20 "$CACHE_DIR/download.log"; die "apt-get download failed"; }

    # required 工具必须确实下载到位
    local got p2
    got="$(ls "$CACHE_DIR" | sed -E 's/_.*//' | sort -u)"
    while IFS='|' read -r pkg level note; do
        case "$pkg" in ''|'#'*) continue ;; esac
        pkg="$(echo "$pkg" | xargs)"
        if [ "$level" = "required" ]; then
            echo "$got" | grep -qx "$pkg" \
                || die "required package $pkg NOT downloaded"
        fi
    done < "$SCRIPT_DIR/external-tools.list"
    log "required tool packages verified in cache"
}

# ---------------------------------------------------------------- 组包
assemble() {
    log "assembling offline deb root"
    rm -rf "$OFFLINE_ROOT"
    install -d "$OFFLINE_ROOT/usr/lib/engrampa-offline/debs"
    install -d "$OFFLINE_ROOT/usr/lib/engrampa-offline/pkgs"
    install -d "$OFFLINE_ROOT/usr/share/doc/engrampa-offline"
    install -d "$OFFLINE_ROOT/DEBIAN"

    install -m 644 "$CACHE_DIR"/*.deb "$OFFLINE_ROOT/usr/lib/engrampa-offline/debs/"
    install -m 644 "$MAIN_DEB" "$OFFLINE_ROOT/usr/lib/engrampa-offline/pkgs/"
    install -m 755 "$SCRIPT_DIR/install-offline.sh" \
        "$OFFLINE_ROOT/usr/lib/engrampa-offline/install-offline.sh"
    install -m 644 "$SRC_ROOT/COPYING" \
        "$OFFLINE_ROOT/usr/share/doc/engrampa-offline/copyright"

    # manifest:包名/版本/校验和,供目标机审计
    {
        echo "# engrampa-offline $VERSION ($ARCH) dependency closure"
        ( cd "$OFFLINE_ROOT/usr/lib/engrampa-offline" && sha256sum debs/*.deb pkgs/*.deb )
    } > "$OFFLINE_ROOT/usr/lib/engrampa-offline/manifest.txt"

    sed -e "s/@@VERSION@@/$VERSION/g" -e "s/@@ARCH@@/$ARCH/g" \
        "$SCRIPT_DIR/control/offline/control.in" > "$OFFLINE_ROOT/DEBIAN/control"
    install -m 755 "$SCRIPT_DIR/control/offline/postinst" "$OFFLINE_ROOT/DEBIAN/postinst"

    dpkg-deb --build --root-owner-group "$OFFLINE_ROOT" \
        "$DIST_OUT/engrampa-offline_${VERSION}_${ARCH}.deb" || die "dpkg-deb failed"
}

# ------------------------------------------------------- 载荷自检
selfcheck() {
    local deb="$DIST_OUT/engrampa-offline_${VERSION}_${ARCH}.deb"
    log "payload self-check on $(basename "$deb")"
    local listing
    listing="$(dpkg-deb -c "$deb")"

    # dpkg-deb -c 的路径带 ./ 前缀,按路径后缀+行尾锚定;不用 grep -q(SIGPIPE 红线)
    printf '%s\n' "$listing" | grep "usr/lib/engrampa-offline/install-offline.sh\$" >/dev/null \
        || die "self-check: install-offline.sh NOT in deb"
    printf '%s\n' "$listing" | grep "usr/lib/engrampa-offline/manifest.txt\$" >/dev/null \
        || die "self-check: manifest NOT in deb"
    printf '%s\n' "$listing" | grep "usr/lib/engrampa-offline/pkgs/engrampa_${VERSION}_${ARCH}.deb\$" >/dev/null \
        || die "self-check: engrampa main deb NOT in offline bundle"

    local n
    n="$(printf '%s\n' "$listing" | grep -c 'usr/lib/engrampa-offline/debs/.*\.deb$')"
    [ "$n" -gt 0 ] || die "self-check: dependency closure empty"
    log "closure debs in bundle: $n"

    # required 工具逐个断言(指南:曾发生离线包漏拷本体,靠自检兜底)
    local p level
    while IFS='|' read -r p level note; do
        case "$p" in ''|'#'*) continue ;; esac
        p="$(echo "$p" | xargs)"
        [ "$level" = "required" ] || continue
        printf '%s\n' "$listing" | grep "usr/lib/engrampa-offline/debs/${p}_" >/dev/null \
            || die "self-check: required tool '$p' NOT in closure"
    done < "$SCRIPT_DIR/external-tools.list"
    log "payload self-check passed"
}

main() {
    download_closure
    assemble
    selfcheck
    log "DONE: $DIST_OUT/engrampa-offline_${VERSION}_${ARCH}.deb"
    log "cleaning intermediates"
    rm -rf "$CACHE_DIR" "$OFFLINE_ROOT"
}

main "$@"
