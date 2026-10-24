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
# objc 家族(unar/gnustep 链)依赖 libobjc4;libobjc4 与 gcc-10-base 之间是
# "严格等于"钉版本,只能取自麒麟自家归档(debs-kylin/)。因此安装分两批:
#   主批   = 与目标版本无关的闭包(失败即致命);
#   目标批 = objc 家族 + 麒麟 libobjc4(在非麒麟系统上可能因版本钉死装不上,
#            失败降级为醒目告警 —— unar(含 rar 支撑)在该机不可用)。
OBJC_FAMILY="unar gnustep-base-common gnustep-base-runtime gnustep-common libgnustep-base1.26"

is_objc_family() {
    case " $OBJC_FAMILY " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

TO_INSTALL=()
TO_INSTALL_OBJC=()
for deb in "$DEBS_DIR"/*.deb; do
    [ -e "$deb" ] || continue
    pkg="$(dpkg-deb -f "$deb" Package)"
    state="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)"
    if [ "$state" = "install ok installed" ]; then
        log "skip (already installed): $pkg"
    elif is_objc_family "$pkg"; then
        TO_INSTALL_OBJC+=("$deb")
        log "to install (missing):      $pkg [target-specific]"
    else
        TO_INSTALL+=("$deb")
        log "to install (missing):      $pkg"
    fi
done

if [ "${#TO_INSTALL[@]}" -gt 0 ]; then
    log "installing ${#TO_INSTALL[@]} missing dependency package(s) ..."
    if ! dpkg -i -- "${TO_INSTALL[@]}" >>"$LOG" 2>&1; then
        # 失败时把错误上下文回显到控制台,避免细节只存在于易失的日志文件里
        echo "[engrampa-offline] dpkg -i FAILED. Error context from $LOG:" >&2
        grep -inE -B2 -A8 'error|fail' "$LOG" | tail -80 >&2 || true
        echo "[engrampa-offline] dpkg --audit:" >&2
        dpkg --audit >&2 || true
        die "dpkg -i failed for dependency closure - see $LOG"
    fi
else
    log "all main-batch dependency packages already satisfied"
fi

# ---- 目标敏感批: objc 家族 + 麒麟 libobjc4(尽力而为) ----
KYLIN_DEBS=()
for deb in "$DIR"/debs-kylin/*.deb; do
    [ -e "$deb" ] && KYLIN_DEBS+=("$deb")
done
if [ "${#TO_INSTALL_OBJC[@]}" -gt 0 ] || [ "${#KYLIN_DEBS[@]}" -gt 0 ]; then
    log "installing target-specific batch (${#TO_INSTALL_OBJC[@]} objc-family + ${#KYLIN_DEBS[@]} Kylin debs) ..."
    set -- "${TO_INSTALL_OBJC[@]}" "${KYLIN_DEBS[@]}"
    if dpkg -i -- "$@" >>"$LOG" 2>&1; then
        log "target-specific batch installed (unar/RAR support active)"
    else
        echo "[engrampa-offline] WARNING: target-specific batch failed on this machine." >&2
        echo "  unar (RAR 支撑) 及 gnustep 依赖未能配置,常见原因:本机 gcc-10-base" >&2
        echo "  版本与麒麟归档的 libobjc4 钉死版本不一致。其余功能不受影响。" >&2
        grep -inE -B2 -A8 'error|dependency problems' "$LOG" | tail -40 >&2 || true
        log "WARNING: unar/RAR support unavailable on this machine (see above)"
    fi
fi
dpkg --configure -a >>"$LOG" 2>&1 || true

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
for tool in 7z zip unzip cpio; do
    command -v "$tool" >/dev/null 2>&1 || MISSING_TOOLS="$MISSING_TOOLS $tool"
done
if [ -n "$MISSING_TOOLS" ]; then
    log "ERROR: core external tools still missing:$MISSING_TOOLS"
    exit 2
fi
log "core external tools present: 7z zip unzip cpio"

# unar/lsar(RAR 支撑)属目标敏感批,缺失仅告警(见上文 target-specific batch)
for tool in unar lsar; do
    command -v "$tool" >/dev/null 2>&1 || log "WARNING: $tool unavailable (RAR support off on this machine)"
done

# 收尾缓存刷新(与主包 postinst 幂等一致)
command -v glib-compile-schemas >/dev/null 2>&1 \
    && glib-compile-schemas /usr/share/glib-2.0/schemas >>"$LOG" 2>&1 || true

log "================================================================"
log "全部就绪: engrampa $MAIN_VER 及依赖、外部格式工具均已可用。"
log "================================================================"
exit 0
