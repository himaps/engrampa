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
# 追加:GCC 运行时家族(libgcc-s1/libstdc++6/libobjc4/... 与 gcc-10-base 之间
# 互相"严格等于"钉版本)——麒麟的 gcc-10-base 是 10.3.0-1kylin1~20.04,
# focal 的任何一份都钉不上,跨源携带必然 configure 失败(CI 实证)。
# 这些包属系统基件,真机必装;其中 libobjc4 是唯一非普装的,单独走
# 麒麟归档拉取(见 download_kylin_specific)。
BLACKLIST_RE='^(libc6|libc-bin|locales|libnss-[a-z]+|libselinux1?)$|^(systemd|systemd-.*)$|^libsystemd.*$|^(udev|libudev.*)$|^(dbus|dbus-.*)$|^libdbus.*$|^libpam.*$|^login$|^passwd$|^shadow$|^(gcc-10-base|libgcc-s1|libstdc\+\+6|libobjc4|libatomic1|libgomp1|libitm1|liblsan0|libtsan0|libubsan1|libquadmath0)$'

is_blacklisted() {
    local p="$1"
    echo "$p" | grep -Eq "$BLACKLIST_RE" && return 0
    # Essential=yes 的包(含 libc6、dpkg、coreutils、bash 等)一律剔除
    apt-cache show "$p" 2>/dev/null | grep -m1 '^Essential: *yes' >/dev/null && return 0
    return 1
}

# ---------------------------------------------------------------- 种子集合
# 注意: 本函数在命令替换 $(...) 中执行,一切诊断必须走 stderr,
# 否则会被吞进变量(CI 实证: 只见汇总 die 不见具体包名)。
# 判定不用 "grep -q 于管道"(指南红线),捕获后整串匹配;
# "Candidate: (none)"(已知但无候选)同样视为缺失。
apt_has_candidate() {
    local out
    out="$(apt-cache policy "$1" 2>/dev/null || true)"
    case "$out" in
        *Candidate:*)
            case "$out" in *Candidate:\ *none*) return 1 ;; esac
            return 0
            ;;
    esac
    return 1
}

seed_packages() {
    local depends_field
    # 主包 ELF 依赖
    depends_field="$(dpkg-deb -f "$MAIN_DEB" Depends)"
    echo "$depends_field" | tr ',' '\n' | sed -E 's/\(.*//; s/^[[:space:]]+|[[:space:]]+$//g' | grep -v '^$'
    # 外部工具(required 必须齐;optional 缺了仅告警跳过)
    local all_ok=1 pkg level note missing=""
    while IFS='|' read -r pkg level note; do
        case "$pkg" in ''|'#'*) continue ;; esac
        pkg="$(printf '%s' "$pkg" | tr -d '[:space:]')"
        if apt_has_candidate "$pkg"; then
            echo "$pkg"
        else
            if [ "$level" = "required" ]; then
                missing="$missing $pkg"
                all_ok=0
                echo "[make-offline] DEBUG: apt-cache policy '$pkg' output:" >&2
                apt-cache policy "$pkg" 2>&1 | sed 's/^/  | /' >&2
            else
                echo "[make-offline] WARNING: optional tool package not in archive, skipped: $pkg" >&2
            fi
        fi
    done < "$SCRIPT_DIR/external-tools.list"
    [ "$all_ok" -eq 1 ] || die "required tool packages missing from apt archive:$missing"
}

# --------------------------------------------------------- 闭包展开与下载
expand_closure() {
    local seeds="$1"
    local -A seen=()
    local -a queue=()
    local p d deps
    local out=""
    for p in $seeds; do
        [ -n "${seen[$p]:-}" ] && continue
        seen[$p]=1
        queue+=("$p")
    done
    while [ "${#queue[@]}" -gt 0 ]; do
        local -a next=()
        for p in "${queue[@]}"; do
            apt_has_candidate "$p" || continue
            is_blacklisted "$p" && continue
            out="$out $p"
            # 注意: 非 --recurse 模式的输出没有独立包名行,依赖名就在
            # "Depends: foo" 关系行上(递归格式过滤器在这里会收集到 0 个
            # 依赖,闭包退化为种子集合,CI 实证)。从关系行提取名字,
            # 剥掉版本括号;<virtual> 形态在入队处跳过。
            deps="$(apt-cache depends --no-recommends --no-suggests --no-conflicts \
                       --no-breaks --no-replaces --no-enhances "$p" 2>/dev/null \
                    | sed -n -E 's/^[[:space:]]*[|]?(Pre-)?Depends:[[:space:]]+([^[:space:]()]+).*/\2/p' \
                    || true)"
            for d in $deps; do
                case "$d" in ""|\<*) continue ;; esac
                if [ -z "${seen[$d]:-}" ]; then
                    seen[$d]=1
                    next+=("$d")
                fi
            done
        done
        queue=("${next[@]}")
    done
    printf '%s\n' $out | sort -u
}

download_closure() {
    log "expanding recursive dependency closure"
    local seeds
    seeds="$(seed_packages | sort -u)"
    [ -n "$seeds" ] || die "empty seed set"
    log "seeds ($(printf '%s\n' $seeds | wc -l)): $(echo $seeds)"

    # BFS 展开(黑名单感知): apt-cache depends --recurse 不认识黑名单,会把
    # 黑名单节点(如 systemd)的整棵子树(ntpsec→python3-ntp、adduser...)
    # 展开后只删节点名本身,垃圾子树留在闭包里(CI 实证: python3-ntp 入包)。
    # 逐节点 BFS: 无候选(虚拟名)或黑名单的节点不入闭包、其子树也不再展开;
    # 关系行/缩进处理与 apt-cache depends 输出格式一一对应。
    local names
    names="$(expand_closure "$seeds")"

    rm -rf "$CACHE_DIR"; mkdir -p "$CACHE_DIR"
    local kept=0 skipped_essential=0 p
    local final_list_tmp="$CACHE_DIR/.final"
    : > "$final_list_tmp"
    for p in $names; do
        # 有候选版本的才是真实包(排除虚拟包名)
        apt_has_candidate "$p" || continue
        if is_blacklisted "$p"; then
            skipped_essential=$((skipped_essential+1))
            continue
        fi
        echo "$p" >> "$final_list_tmp"
        kept=$((kept+1))
    done
    log "closure: $kept packages kept, $skipped_essential blacklisted (essential/system)"

    [ "$kept" -gt 0 ] || die "closure resolved to empty set"

    # 断言: 主包的 ELF 依赖必须在闭包里(CI 实证曾整链丢失导致 verify ldd 全红)。
    # 三态定位: 不在最终清单 → 在 apt-cache 名单里吗(在=被 policy/黑名单过滤,
    # 不在=递归展开就没带出来)。
    local dep in_names
    for dep in $(dpkg-deb -f "$MAIN_DEB" Depends \
                 | tr ',' '\n' | sed -E 's/\(.*//; s/^[[:space:]]+|[[:space:]]+$//g' | grep -v '^$'); do
        case "$dep" in
            libc6) continue ;;   # glibc 黑名单,目标机必装,豁免
        esac
        in_names=no
        case " $names " in *" $dep "*) in_names=yes ;; esac
        grep -qx "$dep" "$final_list_tmp" \
            || die "closure lost app dependency '$dep' (in apt-cache recurse output: $in_names)"
    done
    log "app ELF dependencies verified in closure"

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

# ------------------------------------------------ 麒麟归档夹具(dbus-x11)
# dconf-service 需要 dbus-session-bus 虚拟名(仅 dbus-x11/dbus-user-session
# 提供)。麒麟容器自带 dbus@麒麟版本,而 dbus-x11 对 dbus 是"严格等于"钉版本
# ——focal 的 dbus-x11 在麒麟容器上永远配不上(CI 实证),必须取麒麟自家归档,
# 与容器自带 dbus 同源自洽(与 libobjc4 同理)。解析闭包用构建容器里的
# python3,下载仍走 curl。仅验证夹具,不进离线包。
download_kylin_fixtures() {
    log "resolving dbus-x11 fixture closure from the Kylin archive (merged indexes)"
    mkdir -p "$CACHE_DIR" "$DIST_OUT/verify-baseline-kylin"
    # 注意: updates 套件(2403/2203)的 Packages 索引是**增量索引**,只含有
    # 更新的包;且麒麟把系统/安全栈(libpam/libapparmor/libkysec/policycoreutils)
    # 放在 universe 组件。必须合并 3 套件 × main/universe 共 6 份索引:
    # base 先载,updates 按新旧覆盖(同包取最新),再解析闭包。
    local suite comp
    local -a idxs=()
    for suite in 10.1 10.1-2203-updates 10.1-2403-updates; do
        for comp in main universe; do
            if curl -sf --retry 4 --retry-delay 15 --max-time 240 \
                  -o "$CACHE_DIR/kylin-idx-$suite-$comp.gz" \
                  "$KYLIN_MIRROR/dists/$suite/$comp/binary-arm64/Packages.gz"; then
                idxs+=("$CACHE_DIR/kylin-idx-$suite-$comp.gz")
            else
                log "WARNING: Kylin $suite/$comp index unavailable, continuing without it"
            fi
        done
    done
    [ "${#idxs[@]}" -gt 0 ] || die "no Kylin suite index could be fetched"
    local fnames fn
    fnames="$(python3 - "${idxs[@]}" <<'PYEOF' || true
import gzip, re, sys

pkgs = {}
# 后载覆盖先载: base → 2203 → 2403,同包取最新套件的版本
for path in sys.argv[1:]:
    for stanza in gzip.open(path, 'rt', encoding='utf-8', errors='replace').read().split('\n\n'):
        f = {}
        for line in stanza.splitlines():
            if ':' in line and not line.startswith(' '):
                k, v = line.split(':', 1)
                f[k.strip()] = v.strip()
        if 'Package' in f and 'Filename' in f:
            pkgs[f['Package']] = f

def dep_names(depends):
    out = []
    for clause in (depends or '').split(','):
        clause = clause.strip()
        if not clause:
            continue
        for alt in clause.split('|'):
            name = re.sub(r'\s*\(.*', '', alt).strip().split(':')[0]
            if name:
                out.append(name)
    return out

if 'dbus-x11' not in pkgs:
    sys.exit(1)
seen, queue, out = {'dbus-x11'}, ['dbus-x11'], []
while queue:
    nxt = []
    for p in queue:
        if p not in pkgs:
            continue
        out.append(pkgs[p]['Filename'])
        for d in dep_names(pkgs[p].get('Depends')):
            if d not in seen:
                seen.add(d)
                nxt.append(d)
    queue = nxt
print('\n'.join(out))
PYEOF
)" || true
    if [ -n "$fnames" ]; then
        log "Kylin fixture closure (merged): $(printf '%s\n' "$fnames" | wc -l) packages"
        # 注意: 子壳状态必须 0=成功;ok 语义写反会让 set -e 在子壳语句处直接
        # 杀脚本(下一行的 || die 救不了独立语句),CI 表现为无报错静默死亡。
        # Azure→中国镜像间歇抽风(单文件 retry 3 不够覆盖窗口),按失败清单
        # 多轮重试,已下载的跳过,轮间退避。
        if ( cd "$DIST_OUT/verify-baseline-kylin"
             round=0
             pending="$fnames"
             while [ -n "$pending" ] && [ "$round" -lt 4 ]; do
                 failed=""
                 while read -r fn; do
                     [ -n "$fn" ] || continue
                     base="$(basename "$fn")"
                     [ -f "$base" ] && continue
                     curl -sf --retry 5 --retry-delay 10 --max-time 240 -O "$KYLIN_MIRROR/$fn" \
                         || failed="$failed
$fn"
                 done <<< "$pending"
                 pending="${failed#
}"
                 round=$((round+1))
                 if [ -n "$pending" ]; then
                     echo "download round $round left $(printf '%s' "$pending" | wc -l) file(s), backing off" >&2
                     sleep 30
                 fi
             done
             [ -z "$pending" ]
             exit $? ); then
            return 0
        else
            die "failed to download Kylin fixture debs"
        fi
    fi
    die "dbus-x11 not found in any Kylin suite (main/arm64)"
}

# ------------------------------------------------ 麒麟专属包(libobjc4)
# libobjc4(unar/gnustep 链需要)被 GCC-runtime 黑名单排除后,必须从麒麟自家
# 归档取:麒麟的 libobjc4 钉麒麟的 gcc-10-base,天然自洽;focal 的在麒麟上
# 因严格等号钉永远装不上。归档/suite/组件来自 distrotwin/kylin 的 v10sp1.conf。
KYLIN_MIRROR="http://archive.kylinos.cn/kylin/KYLIN-ALL"
KYLIN_SUITES="10.1-2403-updates 10.1-2203-updates 10.1"

download_kylin_specific() {
    log "fetching libobjc4 from the Kylin archive"
    mkdir -p "$CACHE_DIR"
    local suite idx url ver fn
    for suite in $KYLIN_SUITES; do
        url="$KYLIN_MIRROR/dists/$suite/main/binary-arm64/Packages.gz"
        if curl -sf --retry 4 --retry-delay 15 --max-time 240 -o "$CACHE_DIR/kylin-Packages.gz" "$url"; then
            # 注意: 索引解压 ~30MB,awk 不得提前 exit(指南红线: SIGPIPE 杀生产端,
            # pipefail 下整脚本 141 退出,CI 实证)。全量扫描,命中后关标志防重复。
            ver="$(zcat "$CACHE_DIR/kylin-Packages.gz" \
                | awk '/^Package: libobjc4$/{f=1;next} f&&/^Version:/{print $2; f=0}' || true)"
            if [ -n "$ver" ]; then
                fn="$(zcat "$CACHE_DIR/kylin-Packages.gz" \
                    | awk '/^Package: libobjc4$/{f=1;next} f&&/^Filename:/{print $2; f=0}' || true)"
                log "Kylin libobjc4: $ver (suite $suite)"
                mkdir -p "$DIST_OUT/kylin-debs"
                ( cd "$DIST_OUT/kylin-debs" && \
                  curl -sf --retry 3 --max-time 300 -O \
                    "$KYLIN_MIRROR/$fn" ) \
                    || die "failed to download Kylin libobjc4"
                return 0
            fi
        fi
    done
    die "libobjc4 not found in any Kylin suite (main/arm64)"
}

# ------------------------------------------------ 验证环境基线夹具
# libdbus-1-3 / libselinux1 在黑名单(指南红线,不进离线包),真实麒麟桌面必装;
# 但极简验证容器(ubuntu:20.04 与 distrotwin base)没有它们,而闭包中
# libavahi-client3/rpm-common/cdebconf 依赖之。作为验证夹具单独放行:
# 随产物分发、仅供 verify-offline 预装模拟桌面基线,绝不进入离线 deb。
download_verify_baseline() {
    log "downloading verify-baseline fixtures (dbus stack, libselinux1, bash)"
    mkdir -p "$DIST_OUT/verify-baseline"
    # 极简容器缺口(真实麒麟桌面必有,夹具不进离线包,仅验证环境预置):
    #   libdbus-1-3/libselinux1 - 黑名单库,被 libavahi-client3/rpm-common/cdebconf 依赖
    #   bash                     - distrotwin kylin base 未装,lrzip 依赖
    # 注意: dbus-x11(session-bus 虚拟名的提供者)不在此列 —— focal 的 dbus-x11
    # "dbus (= 精确版本)"钉死麒麟自带的 dbus,必须取自麒麟归档(见
    # download_kylin_fixtures)。这里对夹具集做无黑名单的完整递归闭包;
    # 夹具安装侧"只装缺失",不覆盖容器已有版本。
    local fnames fd fdl
    fnames="$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
                  --no-breaks --no-replaces --no-enhances \
                  libdbus-1-3 libselinux1 bash adduser libaudit1 \
              | sed 's/^[[:space:]]*//' \
              | grep -vE '^(Depends|PreDepends|Conflicts|Breaks|Replaces|Enhances|Suggests|Recommends):' \
              | grep -vE '^(\||<|>|#|$)' \
              | sort -u)"
    fdl=""
    for fd in $fnames; do
        apt_has_candidate "$fd" && fdl="$fdl $fd"
    done
    [ -n "$fdl" ] || die "verify-baseline fixture set resolved to empty"
    log "fixture closure:$(printf '%s' "$fdl" | tr ' ' '\n' | wc -l) packages"
    ( cd "$DIST_OUT/verify-baseline" && apt-get download -q $fdl ) \
        || die "failed to download verify-baseline fixtures"
}

# ---------------------------------------------------------------- 组包
assemble() {
    log "assembling offline deb root"
    rm -rf "$OFFLINE_ROOT"
    install -d "$OFFLINE_ROOT/usr/lib/engrampa-offline/debs"
    install -d "$OFFLINE_ROOT/usr/lib/engrampa-offline/debs-kylin"
    install -d "$OFFLINE_ROOT/usr/lib/engrampa-offline/pkgs"
    install -d "$OFFLINE_ROOT/usr/share/doc/engrampa-offline"
    install -d "$OFFLINE_ROOT/DEBIAN"

    install -m 644 "$CACHE_DIR"/*.deb "$OFFLINE_ROOT/usr/lib/engrampa-offline/debs/"
    install -m 644 "$DIST_OUT"/kylin-debs/*.deb "$OFFLINE_ROOT/usr/lib/engrampa-offline/debs-kylin/"
    install -m 644 "$MAIN_DEB" "$OFFLINE_ROOT/usr/lib/engrampa-offline/pkgs/"
    install -m 755 "$SCRIPT_DIR/install-offline.sh" \
        "$OFFLINE_ROOT/usr/lib/engrampa-offline/install-offline.sh"
    install -m 644 "$SRC_ROOT/COPYING" \
        "$OFFLINE_ROOT/usr/share/doc/engrampa-offline/copyright"

    # manifest:包名/版本/校验和,供目标机审计
    {
        echo "# engrampa-offline $VERSION ($ARCH) dependency closure"
        ( cd "$OFFLINE_ROOT/usr/lib/engrampa-offline" && \
          sha256sum debs/*.deb debs-kylin/*.deb pkgs/*.deb )
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

    printf '%s\n' "$listing" | grep "usr/lib/engrampa-offline/debs-kylin/libobjc4_" >/dev/null \
        || die "self-check: Kylin libobjc4 NOT in debs-kylin/"

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
    download_kylin_specific
    download_kylin_fixtures
    download_verify_baseline
    assemble
    selfcheck
    # 夹具完整性:验证 job 依赖这两个目录,缺失要在此刻大声报错
    ls "$DIST_OUT"/verify-baseline/*.deb >/dev/null 2>&1 \
        || die "verify-baseline fixtures empty"
    ls "$DIST_OUT"/verify-baseline-kylin/*.deb >/dev/null 2>&1 \
        || die "verify-baseline-kylin fixtures empty"
    log "DONE: $DIST_OUT/engrampa-offline_${VERSION}_${ARCH}.deb"
    log "cleaning intermediates"
    rm -rf "$CACHE_DIR" "$OFFLINE_ROOT"
}

main "$@"
