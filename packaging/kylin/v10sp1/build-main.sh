#!/usr/bin/env bash
# 构建 engrampa 主 deb(面向银河麒麟 V10 SP1 arm64)
#
# 运行环境: ubuntu:20.04 (focal) 容器, root, 能访问 apt 归档。
# focal 与麒麟 V10 SP1 同源(同 glibc 2.31 / GCC 9.3 / 包名),
# 构建产物在目标机无版本升级需求 —— 见项目 memory 的麒麟适配指南。
#
# 用法: packaging/kylin/v10sp1/build-main.sh [源码根目录] (默认: 脚本上上级上上级)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="${1:-$SCRIPT_DIR/../../..}"
SRC_ROOT="$(cd "$SRC_ROOT" && pwd)"

VERSION="${ENGRAMPA_PKG_VERSION:-1.28.5-1kylin1}"
ARCH="$(dpkg --print-architecture)"
GLIBC_BASELINE=2.31            # 麒麟 V10 SP1 / focal
MESON_PIN=0.63.3               # focal apt 的 meson 0.53 偏旧,钉 pip 版保证语法兼容
SUBMODULES_SHA=4074560e3642a53ace07b31baaf3f04c060dcd0b  # mate-submodules master 2023-08-30, 带 meson.build
MIRROR="${APT_MIRROR:-http://azure.archive.ubuntu.com/ubuntu}"
DIST_OUT="$SRC_ROOT/dist"

log()  { echo "[build-main] $*"; }
die()  { echo "[build-main] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------- apt 环境
configure_apt() {
    log "configuring apt (mirror=$MIRROR, timeouts, Check-Valid-Until=false)"
    sed -i "s|http://archive.ubuntu.com/ubuntu|$MIRROR|g; s|http://security.ubuntu.com/ubuntu|$MIRROR|g" \
        /etc/apt/sources.list || true
    cat > /etc/apt/apt.conf.d/99-ci <<'EOF'
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::Check-Valid-Until "false";
APT::Get::AllowUnauthenticated "false";
EOF
    export DEBIAN_FRONTEND=noninteractive
    timeout 1200 apt-get update -y || die "apt-get update failed"
}

install_build_deps() {
    log "installing build dependencies"
    timeout 1800 apt-get install -y --no-install-recommends \
        build-essential ninja-build pkg-config git file dpkg-dev \
        curl xz-utils \
        python3-pip \
        libglib2.0-dev libgtk-3-dev libjson-glib-dev \
        libsm-dev libice-dev libmagic-dev \
        gettext itstool yelp-tools libxml2-utils \
        || die "failed to install build dependencies"
    # 钉版本的 meson(focal 自带 0.53 与 1.28.5 的 meson 语法存在兼容风险)
    if ! meson --version >/dev/null 2>&1 || [ "$(meson --version 2>/dev/null)" != "$MESON_PIN" ]; then
        pip3 install --no-cache-dir "meson==$MESON_PIN" || die "pip install meson failed"
    fi
    log "meson $(meson --version), ninja $(ninja --version)"
}

# ------------------------------------------------------- mate-submodules
# 仓库内 submodule 检出(54fff1b, 2020)无 meson.build;wrap 文件指向未固定的
# master。这里钉住已知含 meson.build 的提交,克隆到 subprojects/ 复用,
# 使构建不依赖 wrap 的网络解析且可复现。
prepare_submodules() {
    local sub="$SRC_ROOT/subprojects/mate-submodules"
    if [ -f "$sub/meson.build" ]; then
        log "subprojects/mate-submodules already present"
        return
    fi
    log "fetching mate-submodules @ $SUBMODULES_SHA"
    git init -q "$sub"
    git -C "$sub" remote add origin https://github.com/mate-desktop/mate-submodules.git
    timeout 300 git -C "$sub" fetch -q --depth 1 origin "$SUBMODULES_SHA" \
        || die "failed to fetch mate-submodules"
    git -C "$sub" checkout -q FETCH_HEAD
}

# ---------------------------------------------------------------- meson 构建
run_build() {
    log "meson setup + ninja"
    rm -rf "$SRC_ROOT/build"
    # -Dcaja-actions=false: 麒麟 V10 文件管理器是 peony(右键仍调 engrampa CLI),
    #   构建 caja 扩展会无谓引入 libcaja-extension 依赖
    # -Dpackagekit=false:   麒麟走自己的软件商店体系
    # 注意: focal 的 python3.8 argparse 对"选项之后跟 sourcedir 位置参数"会报
    # unrecognized arguments(CI 实证),故用规范形式: cwd=源码目录,只传 builddir
    ( cd "$SRC_ROOT" && \
      meson setup "$SRC_ROOT/build" --prefix=/usr --buildtype=release \
        -Dcaja-actions=false -Dpackagekit=false \
    ) || die "meson setup failed"
    ninja -C "$SRC_ROOT/build" || die "ninja failed"

    rm -rf "$SRC_ROOT/pkg-root"
    DESTDIR="$SRC_ROOT/pkg-root" ninja -C "$SRC_ROOT/build" install || die "DESTDIR install failed"
}

# ------------------------------------------------------- ELF Depends 生成
# 依赖集合由 ldd/objdump 反查 NEEDED 库 → 所属包得出。
# 版本下限策略(目标机 glibc 2.31 同源):
#   只对"下限有真实意义"的少数包写版本 —— glibc 基线(指南) + 上游
#   meson.build 声明的最低库版本;其余一律不带版本。
#   禁止用构建机版本当下限:focal 的 libgcc-s1 是 10.5(GCC10 家族),
#   麒麟 V10 SP1 可能随 GCC 9.x 家族的 libgcc-s1,dpkg 会拒绝 configure,
#   而 C 程序实际只用 GCC_3.0 级古老符号 —— 下限过狠反而装不上。
MIN_VERSIONS='libc6:2.31 libglib2.0-0:2.50 libgtk-3-0:3.22 libjson-glib-1.0-0:0.14'

gen_depends() {
    local elf
    for elf in "$SRC_ROOT"/pkg-root/usr/bin/engrampa "$SRC_ROOT"/pkg-root/usr/libexec/engrampa/*; do
        [ -f "$elf" ] || continue
        objdump -p "$elf" 2>/dev/null | sed -n 's/^ *NEEDED *\([^ ]*\)$/\1/p'
    done | sort -u | while read -r lib; do
        # 经 ldconfig 缓存把 soname 解析为真实库路径再查属主:
        # 直接 dpkg -S 按名字匹配会把 -dev 包的文件抢先命中(CI 实证混入
        # libglib2.0-dev)。NEEDED 均带版本后缀,与 dev 的无版本符号链接不冲突。
        # awk 不提前 exit、head 换全量读取的 sed —— SIGPIPE 红线(指南)。
        path="$(ldconfig -p | awk -v lib="$lib" '$1 == lib {print $NF}' | sed -n 1p || true)"
        [ -n "$path" ] && dpkg -S "$path" 2>/dev/null | sed -n 1p | cut -d: -f1 || true
    done | sed 's/:arm64$//' | sort -u | grep -vE -- '-(dev|doc|dbg)$' || true
}

gen_depends_field() {
    local deps=() p floor
    while read -r p; do
        [ -n "$p" ] || continue
        floor="$(printf '%s\n' $MIN_VERSIONS | awk -F: -v pkg="$p" '$1==pkg{print $2}')"
        if [ -n "$floor" ]; then
            deps+=("$p (>= $floor)")
        else
            deps+=("$p")
        fi
    done < <(gen_depends)
    local IFS=', '
    echo "${deps[*]}"
}

# ---------------------------------------------------------------- 组包
assemble_deb() {
    log "assembling control"
    local pkg_root="$SRC_ROOT/pkg-root"
    mkdir -p "$pkg_root/DEBIAN" "$DIST_OUT"

    local depends recommends
    depends="$(gen_depends_field)"
    # dpkg 控制字段语法: 多包必须逗号+空格分隔(空格分隔会 parse error,CI 实证)
    recommends="$(cut -d'|' -f1 "$SCRIPT_DIR/external-tools.list" | grep -v '^#' | grep -v '^$' | paste -sd, - | sed 's/,/, /g')"
    [ -n "$depends" ] || die "empty Depends - ELF scan failed"

    sed -e "s/@@VERSION@@/$VERSION/g" \
        -e "s/@@ARCH@@/$ARCH/g" \
        -e "s|@@DEPENDS@@|$depends|g" \
        -e "s|@@RECOMMENDS@@|$recommends|g" \
        "$SCRIPT_DIR/control/main/control.in" > "$pkg_root/DEBIAN/control"

    install -m 755 "$SCRIPT_DIR/control/main/postinst" "$pkg_root/DEBIAN/postinst"
    install -m 755 "$SCRIPT_DIR/control/main/postrm"   "$pkg_root/DEBIAN/postrm"

    # doc 目录与许可(dpkg 警告清理)
    install -d "$pkg_root/usr/share/doc/engrampa"
    install -m 644 "$SRC_ROOT/COPYING" "$pkg_root/usr/share/doc/engrampa/copyright"

    log "Depends: $depends"
    log "Recommends: $recommends"

    log "dpkg-deb build"
    dpkg-deb --build --root-owner-group "$pkg_root" \
        "$DIST_OUT/engrampa_${VERSION}_${ARCH}.deb" || die "dpkg-deb failed"
}

# ------------------------------------------------------- 载荷自检 + glibc 门禁
selfcheck() {
    local deb="$DIST_OUT/engrampa_${VERSION}_${ARCH}.deb"
    log "payload self-check on $(basename "$deb")"
    local listing
    listing="$(dpkg-deb -c "$deb")"
    for path in \
        /usr/bin/engrampa \
        /usr/share/applications/engrampa.desktop \
        /usr/share/glib-2.0/schemas/org.mate.engrampa.gschema.xml \
        /usr/share/engrampa/packages.match \
        /usr/share/man/man1/engrampa.1 \
    ; do
        # dpkg-deb -c 的路径带 ./ 前缀,按路径后缀+行尾锚定匹配
        printf '%s\n' "$listing" | grep -- "$path\$" >/dev/null || die "payload self-check: $path NOT in deb"
    done
    log "payload self-check passed"

    log "glibc gate (baseline $GLIBC_BASELINE)"
    local max_sym sym elf bad=0
    for elf in "$SRC_ROOT"/pkg-root/usr/bin/engrampa "$SRC_ROOT"/pkg-root/usr/libexec/engrampa/*; do
        [ -f "$elf" ] || continue
        max_sym="$(objdump -T "$elf" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -uV | tail -1 || true)"
        if [ -n "$max_sym" ]; then
            sym="${max_sym#GLIBC_}"
            if [ "$(printf '%s\n' "$GLIBC_BASELINE" "$sym" | sort -V | tail -1)" != "$GLIBC_BASELINE" ]; then
                echo "  FAIL: $(basename "$elf") requires $max_sym" >&2
                bad=1
            else
                echo "  ok: $(basename "$elf") max $max_sym"
            fi
        fi
    done
    [ "$bad" -eq 0 ] || die "glibc gate failed - binary requires newer glibc than $GLIBC_BASELINE"
    log "glibc gate passed"
}

main() {
    configure_apt
    install_build_deps
    prepare_submodules
    run_build
    assemble_deb
    selfcheck
    log "DONE: $DIST_OUT/engrampa_${VERSION}_${ARCH}.deb"
}

main "$@"
