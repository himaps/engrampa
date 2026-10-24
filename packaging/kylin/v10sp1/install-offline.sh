#!/bin/bash
# engrampa-offline 目标机安装脚本 —— 麒麟 V10 SP1 (arm64)
#
# 铁律(与项目麒麟适配指南一致):
#   1. 依赖闭包只装"目标机缺失"的包,绝不升级/替换任何已安装包
#      (没有任何版本比较后的"升级"分支);
#   2. 唯一例外是应用本体 engrampa:安装它正是运行本脚本的目的,
#      属用户显式升级意图;
#   3. 装完 ldd 复验,报告"全部就绪"或"仍缺清单",不静默失败。
#
# 用法: sudo /usr/lib/engrampa-offline/install-offline.sh
#   ENGRAMPA_OFFLINE_YES=1 跳过交互确认(CI 用)
set -u

DIR=/usr/lib/engrampa-offline
LOG=/var/log/engrampa-offline-install.log

log()  { echo "[engrampa-offline] $*" | tee -a "$LOG"; }
die()  { echo "[engrampa-offline] ERROR: $*" | tee -a "$LOG" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (sudo)"

DEBS_DIR="$DIR/debs"
PKGS_DIR="$DIR/pkgs"
[ -d "$DEBS_DIR" ] || die "$DEBS_DIR missing"
[ -d "$PKGS_DIR" ] || die "$PKGS_DIR missing"

# ---------------------------------------------------------------- 提醒与确认
INSTALLED_VER="$(dpkg-query -W -f='${Version}' engrampa 2>/dev/null || true)"
MAIN_DEB="$(ls "$PKGS_DIR"/engrampa_*.deb 2>/dev/null | head -1)"
[ -n "$MAIN_DEB" ] || die "engrampa main deb not found in $PKGS_DIR"
MAIN_VER="$(dpkg-deb -f "$MAIN_DEB" Version)"
ARCH_DEB="$(dpkg-deb -f "$MAIN_DEB" Architecture)"
[ "$ARCH_DEB" = "$(dpkg --print-architecture)" ] \
    || die "architecture mismatch: bundle is $ARCH_DEB, host is $(dpkg --print-architecture)"

if [ -n "$INSTALLED_VER" ] && [ "$INSTALLED_VER" != "$MAIN_VER" ]; then
    log "================================================================"
    log "检测到本机已安装 engrampa $INSTALLED_VER,即将替换为 $MAIN_VER。"
    log "如需回滚能力,现在终止并先执行备份:"
    log "  sudo apt install dpkg-repack && dpkg-repack engrampa"
    log "================================================================"
    if [ "${ENGRAMPA_OFFLINE_YES:-0}" != "1" ]; then
        if [ -t 0 ]; then
            read -r -p "继续安装并覆盖? [y/N] " ans
            case "$ans" in
                y|Y|yes|YES) ;;
                *) die "aborted by user" ;;
            esac
        else
            die "非交互环境(systemd-run)检测到预装 engrampa $INSTALLED_VER 将被覆盖。
  为防误替换,自动安装已中止。请确认后手动执行:
      sudo ENGRAMPA_OFFLINE_YES=1 $0
  (建议先 dpkg-repack engrampa 备份以便回滚)"
        fi
    fi
fi

# ------------------------------------------------ 只装缺失(零升级,无版本比较)
TO_INSTALL=()
for deb in "$DEBS_DIR"/*.deb; do
    [ -e "$deb" ] || continue
    pkg="$(dpkg-deb -f "$deb" Package)"
    state="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)"
    if [ "$state" = "install ok installed" ]; then
        log "skip (already installed): $pkg"
    else
        TO_INSTALL+=("$deb")
        log "to install (missing):      $pkg"
    fi
done

if [ "${#TO_INSTALL[@]}" -gt 0 ]; then
    log "installing ${#TO_INSTALL[@]} missing dependency package(s) ..."
    if ! dpkg -i -- "${TO_INSTALL[@]}" >>"$LOG" 2>&1; then
        # 失败时把日志尾部回显到控制台,避免细节只存在于易失的日志文件里
        echo "[engrampa-offline] dpkg -i FAILED, tail of $LOG:" >&2
        tail -60 "$LOG" >&2 || true
        die "dpkg -i failed for dependency closure - see $LOG"
    fi
else
    log "all dependency packages already satisfied, nothing to install"
fi

# ------------------------------------------------ 应用本体(显式升级意图)
log "installing engrampa $MAIN_VER (this is the point of this bundle)"
dpkg -i -- "$MAIN_DEB" >>"$LOG" 2>&1 \
    || die "dpkg -i failed for engrampa main deb - see $LOG"
dpkg --configure -a >>"$LOG" 2>&1 || true

# ---------------------------------------------------------------- 复验
log "verifying ..."

MISSING_LIBS="$(ldd /usr/bin/engrampa 2>/dev/null | grep 'not found' || true)"
if [ -n "$MISSING_LIBS" ]; then
    log "ldd check FAILED - unresolved libraries:"
    echo "$MISSING_LIBS" | tee -a "$LOG"
    die "see $LOG"
fi
log "ldd check: OK (no 'not found')"

VER_OUT="$(/usr/bin/engrampa --version 2>/dev/null || true)"
APP_VER="${MAIN_VER%%-*}"   # deb 版本取上游部分(1.28.5-1kylin1 -> 1.28.5)
case "$VER_OUT" in
    *"$APP_VER"*) log "engrampa --version: $VER_OUT" ;;
    *) die "engrampa --version unexpected: '$VER_OUT' (expected $APP_VER)" ;;
esac

MISSING_TOOLS=""
for tool in 7z zip unzip unar lsar cpio; do
    command -v "$tool" >/dev/null 2>&1 || MISSING_TOOLS="$MISSING_TOOLS $tool"
done
if [ -n "$MISSING_TOOLS" ]; then
    log "WARNING: external tools still missing:$MISSING_TOOLS"
    log "         (bundle incomplete or installation failed - see $LOG)"
    exit 2
fi
log "external tools present: 7z zip unzip unar lsar cpio"

# 收尾缓存刷新(与主包 postinst 幂等一致)
command -v glib-compile-schemas >/dev/null 2>&1 \
    && glib-compile-schemas /usr/share/glib-2.0/schemas >>"$LOG" 2>&1 || true

log "================================================================"
log "全部就绪: engrampa $MAIN_VER 及依赖、外部格式工具均已可用。"
log "================================================================"
exit 0
