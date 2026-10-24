#!/usr/bin/env bash
# 离线包真实验证(在 ubuntu:20.04 容器中模拟目标机)
#
# 断言清单:
#   1. dpkg -i 离线 deb 本身成功(载荷自检通过)
#   2. install-offline.sh 全流程成功(只装缺失 → ldd 门禁 → --version)
#   3. required 外部工具就位
#   4. 零升级断言: 装前装后 dpkg 快照比对,任何已装包版本变化/替换均为失败
#      (干净容器里所有闭包包都应是"新增";真实麒麟上预装 engrampa 被替换是
#       用户显式意图,不在本断言的模拟范围内)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${1:-$SCRIPT_DIR/../../../dist}"

log()  { echo "[verify-offline] $*"; }
die()  { echo "[verify-offline] ERROR: $*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
OFFLINE_DEB="$(ls "$DIST_DIR"/engrampa-offline_*.deb 2>/dev/null | head -1)"
[ -n "$OFFLINE_DEB" ] || die "engrampa-offline deb not found in $DIST_DIR"
VERSION="$(dpkg-deb -f "$OFFLINE_DEB" Version)"
APP_VER="${VERSION%%-*}"
log "verifying $(basename "$OFFLINE_DEB") (version $VERSION)"

# xvfb 兜底(--version 理论上无显示环境可用,双保险)。
# ENGRAMPA_SKIP_XVFB=1: 真实麒麟容器(distrotwin)验证时置位 —— 不进麒麟 apt 源装 xvfb。
if [ "${ENGRAMPA_SKIP_XVFB:-0}" != "1" ] && ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 600 apt-get update -qq || true
    timeout 600 apt-get install -y -qq --no-install-recommends xvfb \
        || log "WARNING: xvfb unavailable, will run without it"
fi
run_app() {
    if command -v xvfb-run >/dev/null 2>&1; then
        xvfb-run -a "$@"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------- 安装前快照
SNAP_BEFORE=/tmp/dpkg-before.txt
dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null | sort > "$SNAP_BEFORE" || true
log "snapshot before: $(wc -l < "$SNAP_BEFORE") packages"

# ---------------------------------------------------------------- 桌面基线夹具
# 极简容器缺 libdbus-1-3/libselinux1(闭包黑名单项,真实麒麟桌面必装,
# 且 libavahi-client3/rpm-common/cdebconf 依赖之)。先装夹具模拟桌面基线。
if [ -d "$DIST_DIR/verify-baseline" ] && ls "$DIST_DIR"/verify-baseline/*.deb >/dev/null 2>&1; then
    log "provisioning desktop-baseline fixtures (libdbus-1-3, libselinux1)"
    dpkg -i "$DIST_DIR"/verify-baseline/*.deb || die "baseline fixture install failed"
else
    log "WARNING: no verify-baseline fixtures found in $DIST_DIR"
fi

# ---------------------------------------------------------------- 安装离线包
log "dpkg -i offline bundle (postinst will print the manual command - no systemd in container)"
dpkg -i "$OFFLINE_DEB" || die "dpkg -i offline deb failed"

[ -x /usr/lib/engrampa-offline/install-offline.sh ] \
    || die "install-offline.sh not deployed by the deb"

log "running install-offline.sh (non-interactive mode)"
ENGRAMPA_OFFLINE_YES=1 /usr/lib/engrampa-offline/install-offline.sh \
    || die "install-offline.sh failed"

# ---------------------------------------------------------------- 断言
log "assert: engrampa package state"
dpkg-query -W -f='${db:Status-Abbrev}' engrampa | grep -q 'ii ' \
    || die "engrampa not in 'ii' state"
INST_VER="$(dpkg-query -W -f='${Version}' engrampa)"
[ "$INST_VER" = "$VERSION" ] || die "engrampa version mismatch: $INST_VER != $VERSION"

log "assert: engrampa --version"
VER_OUT="$(run_app /usr/bin/engrampa --version 2>/dev/null || true)"
printf '%s\n' "$VER_OUT" | grep " $APP_VER" >/dev/null \
    || die "engrampa --version did not report $APP_VER: '$VER_OUT'"
log "  $VER_OUT"

log "assert: ldd gate"
LDD_OUT="$(ldd /usr/bin/engrampa 2>/dev/null || true)"
printf '%s\n' "$LDD_OUT" | grep "not found" >/dev/null \
    && { printf '%s\n' "$LDD_OUT"; die "ldd reports unresolved libraries"; }
log "  no 'not found'"

log "assert: required external tools"
for tool in 7z zip unzip unar lsar cpio; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool missing: $tool"
done
log "  7z zip unzip unar lsar cpio all present"

log "assert: zero upgrade / zero replace"
dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null | sort > /tmp/dpkg-after.txt || true
python3 - "$SNAP_BEFORE" /tmp/dpkg-after.txt <<'PYEOF' || die "zero-upgrade assertion FAILED"
import sys
def load(p):
    d = {}
    for line in open(p, encoding="utf-8"):
        line = line.rstrip("\n")
        if "\t" in line:
            pkg, ver = line.split("\t", 1)
            d[pkg] = ver
    return d
before, after = load(sys.argv[1]), load(sys.argv[2])
changed = [p for p in before if p in after and before[p] != after[p]]
removed  = [p for p in before if p not in after]
new      = [p for p in after if p not in before]
if changed or removed:
    print("CHANGED: %s" % ", ".join(changed[:20]))
    print("REMOVED: %s" % ", ".join(removed[:20]))
    sys.exit(1)
print("  new packages: %d, changed: 0, removed: 0" % len(new))
PYEOF

log "assert: schema compiled"
[ -f /usr/share/glib-2.0/schemas/org.mate.engrampa.gschema.xml ] \
    || die "gschema not installed"

log "ALL CHECKS PASSED"
