# Engrampa · 银河麒麟 V10 SP1 (arm64) 打包

面向银河麒麟桌面操作系统 V10 SP1（aarch64）的 engrampa 1.28.5 构建与离线交付。
遵循项目沉淀的麒麟适配指南（focal 同源基线、离线闭包、只装缺失零升级）。

## 产物

| 文件 | 内容 |
|---|---|
| `engrampa_1.28.5-1kylin1_arm64.deb` | 主包。Depends 仅声明真实 ELF 依赖；Recommends 声明外部格式工具（p7zip-full、zip、unzip、unar、cpio…），在线机 `apt install` 时按需带入 |
| `engrampa-offline_1.28.5-1kylin1_arm64.deb` | 离线套件 = 主包 + 依赖闭包 `debs/` + 只装缺失的 `install-offline.sh` + `manifest.txt`（sha256 清单） |

基线：`ubuntu:20.04`（focal）容器构建 —— 与麒麟 V10 SP1 同源（glibc 2.31 / GCC 9.3 / 包名一致），
产物在目标机无任何系统组件升级需求。构建后自动做 glibc 符号门禁（≤ 2.31）与载荷自检。

## 构建可行性评估（目标机 glibc 2.31）

glibc 符号版本在**链接期**由构建机 libc 固化进二进制，运行时由宿主提供，向下不兼容。
本方案对 glibc 2.31 目标可行，依据三层：

1. **链接期封顶**：构建容器 `ubuntu:20.04` 自身就是 glibc 2.31 —— 产物 GLIBC 需求
   必然 ≤ 2.31（硬天花板），CI 另有 `objdump -T` 扫描门禁独立断言；
2. **API 水位**：engrampa 1.28.5 上游声明的最低库版本（glib ≥2.50 / gtk ≥3.22 /
   json-glib ≥0.14）远低于 focal 提供的 2.64 / 3.24 / 1.4.4，麒麟 V10 SP1 与 focal
   同源同版本，源码层面不存在更高 API 需求；
3. **闭包一致**：离线闭包全部取自 focal 归档，同样按 2.31 基线编译。

配套约束：**Depends 版本下限只写在有真实意义的少数包上**（`libc6 (>= 2.31)` 与上游
声明的最低项），其余不带版本——若拿构建机版本当下限（如 focal 的
`libgcc-s1 (>= 10.5.0)`），麒麟若随 GCC 9.x 家族的 libgcc-s1，dpkg 会因依赖不满足
拒绝 configure，而纯 C 的 engrampa 实际只用 GCC_3.0 级古老符号。

## CI

`.github/workflows/packaging-kylin-v10sp1.yml`（公开仓库，`ubuntu-24.04-arm` 原生 arm64 runner 免费可用）：

1. **build** — `ubuntu:20.04` 容器：
   主包构建 → 离线闭包下载（Essential/系统核心黑名单剔除）→ 双 deb 载荷自检 → glibc 门禁。
2. **verify** — 干净 focal 容器模拟目标机：`dpkg -i` 离线包 → 跑 `install-offline.sh` →
   断言 `engrampa --version`、ldd 零 `not found`、required 工具齐备、
   **零升级断言**（装前装后 dpkg 快照比对：任何已装包版本变化/移除即失败）。
3. **verify-kylin** — 真实麒麟包环境容器 `ghcr.io/distrotwin/kylin:v10sp1-base-arm64-20260903`
   （麒麟公开 apt 归档自举，钉带日期 tag），同一套验证脚本再过一遍——
   验证"闭包包名/版本在真实麒麟上成立"（指南第 5 节要求）。
4. **release** — 推 `v*` tag 时上传双 deb + SHA256SUMS。

若将来仓库转私有（无 arm64 runner）：把 `runs-on` 换成 `ubuntu-latest`，在 job 里加
`docker run --platform linux/arm64`（QEMU binfmt）执行同样脚本，速度慢一个量级。

## 目标机安装

### 在线机

```bash
sudo apt install ./engrampa_1.28.5-1kylin1_arm64.deb
# Recommends 里的 p7zip-full/zip/unzip/unar/cpio 由 apt 自动拉齐
```

### 离线机

```bash
# 1.(强烈建议,见下节"回滚")先备份预装版本
sudo dpkg -i engrampa-offline_1.28.5-1kylin1_arm64.deb
# postinst 经 systemd-run 延迟 10 秒自动执行安装脚本(锁释放后);
# 无 systemd 环境按提示手动执行:
sudo /usr/lib/engrampa-offline/install-offline.sh
```

安装脚本铁律（对应指南红线）：

- 依赖闭包**只装目标机缺失的包**（`dpkg-query` 状态非 `install ok installed` 才装），
  没有任何版本比较分支，**绝不升级/替换已装系统组件**；
- 应用本体 `engrampa` 的替换是用户运行本套件的显式意图，是唯一例外；
- 闭包构建期已剔除 Essential=yes 与黑名单（glibc、`systemd*`、`dbus*`、`libpam*`、
  `udev`、`login`、`passwd`）——deepin-screenshot 事故的教训，这些包目标机必已同源安装；
- 装完 ldd 复验 + `engrampa --version` + required 工具检查，
  全部就绪或仍缺清单都会明确报告，日志在 `/var/log/engrampa-offline-install.log`。

## 回滚（覆盖预装的"归档管理器"前必读）

麒麟 V10 SP1 预装的归档管理器就是 engrampa（麒麟改包旧版），本包与其同包名同路径，
安装即替换。**没有原厂安装包也能回滚**——装之前从当前系统重建一份：

```bash
sudo apt install dpkg-repack
dpkg-repack engrampa        # 生成 engrampa_<预装版本>_arm64.deb, 妥善保存
# 顺手翻 apt 缓存(很多机器上旧包还在):
ls /var/cache/apt/archives/engrampa*
```

回滚：

```bash
sudo dpkg -i engrampa_<预装版本>_arm64.deb --force-downgrade
sudo glib-compile-schemas /usr/share/glib-2.0/schemas/
```

注意：不要绕过 dpkg 直接 `meson install`/`make install` 到 `/usr`（包数据库会与文件系统脱钩）。

## 外部工具清单

`external-tools.list` 定义 engrampa 以**子进程方式**调用的格式后端（ldd 闭包带不上，
必须显式列清单）。`required` 五件套：`p7zip-full`、`zip`、`unzip`、`unar`、`cpio`；
其余为 optional（ar/isoinfo/rpm2cpio/xz/zstd/bzip2/lha/arj/arc/ace/alz/lrz/lzo…），
focal 归档缺哪个就告警跳过。RAR/RAR5 由 `unar` 支撑（focal 无非自由 rar 包）。
增删工具只改这一个文件，Recommends 与离线闭包同时生效。

## 构建细节备忘

- **mate-submodules**：仓库内 submodule 检出（54fff1b，2020）无 `meson.build`，
  meson 的 wrap 文件又指向未固定的 master。构建脚本钉住已知含 `meson.build` 的提交
  `4074560`（2023-08-30）克隆到 `subprojects/`，可复现且不随上游漂移。
- **meson 0.63.3**（pip）：focal apt 的 meson 0.53 与 1.28.5 的构建脚本有兼容风险。
- **`-Dcaja-actions=false`**：麒麟 V10 文件管理器是 peony（右键"压缩"仍调 `engrampa --add`
  CLI），构建 caja 扩展只会平添 `libcaja-extension` 依赖。
- **`-Dpackagekit=false`**：麒麟走自己的软件商店体系。
- **Depends 版本下限克制策略**：仅 `libc6 (>= 2.31)` 与上游声明的最低项带版本，
  其余裸包名 —— 避免构建机版本（focal 后缀/GCC 世代）与麒麟实机差异导致 dpkg 拒绝
  configure，详见上文"构建可行性评估"。
- `ubuntu:20.04` 镜像随 ESM 冻结基本不变，但发布重要版本时仍建议在 release notes
  记录构建所用镜像 digest。

## 已验证的功能基线（对 1.28.5 源码的核查结论）

- ✅ 打开压缩包后选中文件**拖拽到桌面/文件夹**（XDS 协议，`fr-window.c`）；
- ✅ **双击打开**包内文件（解压到临时目录 + 默认程序 + 修改回写询问，`dlg-update.c`）；
- ✅ 大小列**自动单位**显示（`g_format_size`）；
- ⚠️ 压缩密码：新建/批量压缩对话框已可手动输入，"默认密码/记住密码"需另行开发；
- ❌ BandiZip 式命名模板（`xxx【YYYYMMDDHHMMSS】.zip`）需另行开发。
