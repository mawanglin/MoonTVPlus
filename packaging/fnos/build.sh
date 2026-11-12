#!/bin/bash
# 构建 MoonTVPlus 的飞牛 fnOS 原生 fpk（x86 与 arm 各一个）。
# 做法与 fnos.fpk.incus 一致：除 glibc 外全部依赖随包附带（Node.js、libstdc++、libgcc_s、
# 全部 npm 生产依赖及其原生模块），不依赖 Docker、系统或应用中心的运行时。
#
# 用法（在仓库任意位置执行）:
#   packaging/fnos/build.sh                 两个架构都构建，共用同一个小版本号
#   packaging/fnos/build.sh --arch x86      只构建 x86（沿用当前小版本号；加 --bump 自增）
#   packaging/fnos/build.sh --rev 3         手动指定小版本号
#   packaging/fnos/build.sh --reuse-app     复用上次的 next build 结果（只重新组装与打包）
#
# 依赖：bash git curl python3 tar gzip file，pnpm（与 package.json 的 packageManager 一致）。
#       patchelf、fnpack 自动下载到 packaging/fnos/.cache/tools。构建机须为 x86_64（fnpack 只有 amd64 版）。
# 应用源码取自 git HEAD（git archive），未提交的改动不会进包。
# 产物：<项目根目录>/dist/moontvplus_<版本>_<x86|arm>.fpk，每个架构只保留最新 2 个版本。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(git -C "$ROOT" rev-parse --show-toplevel)"
CACHE="${ROOT}/.cache"
TOOLS="${CACHE}/tools"
BUILD="${ROOT}/build"
DIST="${REPO}/dist"        # 产物放在项目根目录的 dist/，方便找
TEMPLATE="${ROOT}/template"

# ---- 版本固定（升级时改这里，并更新 sha256）----
NODE_VERSION="24.22.2"            # Node.js 24 LTS 官方 glibc 构建（需 glibc ≥ 2.28，飞牛是 Debian 12 / 2.36）
NODE_ABI="137"                    # Node 24 的 NODE_MODULE_VERSION，决定 better-sqlite3 预编译包
BSQL_VERSION="12.6.2"             # better-sqlite3，须与 pnpm-lock.yaml 一致（脚本会核对）
declare -A BSQL_SHA256=(
  [x64]="3138ba6a9268b70a194b212809c12967b77ac286d65645f8fb01472464b9865b"
  [arm64]="4e66c2c0cbe200206008a35fbcfb8a893aa475df223a1100ccc50d6dd2dce844"
)
PATCHELF_VERSION="0.18.0"
PATCHELF_SHA256="ce84f2447fb7a8679e58bc54a20dc2b01b37b5802e12c57eece772a6f14bf3f0"   # x86_64
FNPACK_VERSION="1.2.3"
FNPACK_SHA256="54b97fa7b70968c4d05c79840f5daeff508957d0bb2062fdb0376d00d9615c93"     # linux-amd64

ARCHES="x86 arm"
REV=""
BUMP=0
REUSE_APP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCHES="$2"; shift 2 ;;
    --rev) REV="$2"; shift 2 ;;
    --bump) BUMP=1; shift ;;
    --reuse-app) REUSE_APP=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

info() { printf '\033[0;32m[build]\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[build]\033[0m %s\n' "$*" >&2; exit 1; }

node_arch() { case "$1" in x86) echo x64 ;; arm) echo arm64 ;; *) die "未知架构 $1" ;; esac; }
deb_arch()  { case "$1" in x86) echo amd64 ;; arm) echo arm64 ;; esac; }
file_arch() { case "$1" in x86) echo x86-64 ;; arm) echo aarch64 ;; esac; }

[ "$(uname -m)" = x86_64 ] || die "构建机须为 x86_64（fnpack 只有 linux-amd64 版）"
for t in git curl python3 tar gzip file pnpm sha256sum; do command -v "$t" >/dev/null || die "缺少命令 $t"; done

# 下载并按 sha256 校验；校验失败删除文件
fetch_verified() {  # url dest sha256
  local url="$1" dest="$2" sum="$3"
  if [ ! -f "$dest" ]; then
    info "下载 $(basename "$dest")"
    curl -fsSL -o "${dest}.part" "$url"
    mv "${dest}.part" "$dest"
  fi
  echo "${sum}  ${dest}" | sha256sum -c - >/dev/null 2>&1 || { rm -f "$dest"; die "$(basename "$dest") sha256 校验失败，已删除，请重试"; }
}

# ---------------------------------------------------------------- 工具

mkdir -p "$TOOLS" "$DIST" "${CACHE}/dl"
fetch_verified "https://static2.fnnas.com/fnpack/fnpack-${FNPACK_VERSION}-linux-amd64" "${CACHE}/dl/fnpack-${FNPACK_VERSION}" "$FNPACK_SHA256"
install -m 0755 "${CACHE}/dl/fnpack-${FNPACK_VERSION}" "${TOOLS}/fnpack"
fetch_verified "https://github.com/NixOS/patchelf/releases/download/${PATCHELF_VERSION}/patchelf-${PATCHELF_VERSION}-x86_64.tar.gz" \
  "${CACHE}/dl/patchelf-${PATCHELF_VERSION}.tar.gz" "$PATCHELF_SHA256"
[ -x "${TOOLS}/bin/patchelf" ] || tar -xzf "${CACHE}/dl/patchelf-${PATCHELF_VERSION}.tar.gz" -C "$TOOLS" ./bin/patchelf
PATCHELF="${TOOLS}/bin/patchelf"

# ---------------------------------------------------------------- 版本号
# fpk 版本：<上游版本>.<N>（飞牛 manifest 用纯数字点号）；对应 git tag：v<上游版本>-cob.<N>。
# N 按上游版本各自从 1 计数，同一次构建的 x86/arm 共用，记录在 dist/.build_rev。

UPSTREAM_VERSION="$(git -C "$REPO" show HEAD:VERSION.txt | tr -d '[:space:]')"
[[ "$UPSTREAM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION.txt 格式不符：${UPSTREAM_VERSION}"
REV_FILE="${DIST}/.build_rev"
cur_rev="$( (sed -n "s/^${UPSTREAM_VERSION//./\\.}=//p" "$REV_FILE" 2>/dev/null || true) | tail -n1)"
if [ -z "$REV" ]; then
  if [ "$ARCHES" = "x86 arm" ] || [ "$BUMP" = 1 ] || [ -z "$cur_rev" ]; then REV=$(( ${cur_rev:-0} + 1 )); else REV="$cur_rev"; fi
fi
{ grep -v "^${UPSTREAM_VERSION//./\\.}=" "$REV_FILE" 2>/dev/null || true; echo "${UPSTREAM_VERSION}=${REV}"; } > "${REV_FILE}.tmp"
mv "${REV_FILE}.tmp" "$REV_FILE"
VERSION="${UPSTREAM_VERSION}.${REV}"
COMMIT="$(git -C "$REPO" rev-parse --short HEAD)"
# 应用代码的版本键：最后一次改动应用代码（打包目录与 .gitignore 除外）的提交；只改打包时可以复用 next build
APP_KEY="$(git -C "$REPO" log -1 --format=%h HEAD -- . ':!packaging' ':!.gitignore')"
info "包版本 ${VERSION}（上游 ${UPSTREAM_VERSION}，对应 tag v${UPSTREAM_VERSION}-cob.${REV}，提交 ${COMMIT}）"
git -C "$REPO" diff --quiet HEAD -- . ':!packaging/fnos' 2>/dev/null \
  || info "注意：工作区有未提交的应用代码改动，它们不会进包（只打包 HEAD）"

# ---------------------------------------------------------------- 应用构建（两个架构共用）

SRC="${BUILD}/src"
if [ "$REUSE_APP" = 1 ] && [ -f "${SRC}/.next/standalone/server.js" ] && [ "$(cat "${SRC}/.fpk-commit" 2>/dev/null)" = "$APP_KEY" ]; then
  info "复用已构建的应用（应用代码 ${APP_KEY}）"
else
  info "导出源码 ${COMMIT}"
  rm -rf "$SRC"
  mkdir -p "$SRC"
  git -C "$REPO" archive --format=tar HEAD | tar -x -C "$SRC"
  lock_bsql="$(grep -oE "^  better-sqlite3@[0-9.]+:" "${SRC}/pnpm-lock.yaml" | head -n1 | grep -oE "[0-9.]+[0-9]")"
  [ "$lock_bsql" = "$BSQL_VERSION" ] || die "pnpm-lock 里的 better-sqlite3 是 ${lock_bsql}，与 BSQL_VERSION=${BSQL_VERSION} 不一致，请更新 build.sh"
  info "pnpm install"
  (cd "$SRC" && pnpm install --frozen-lockfile) > "${BUILD}/install.log" 2>&1 || { tail -n 30 "${BUILD}/install.log"; die "pnpm install 失败"; }
  info "next build（约 3–5 分钟）"
  (cd "$SRC" && DOCKER_ENV=true NEXT_TELEMETRY_DISABLED=1 pnpm run build) > "${BUILD}/next-build.log" 2>&1 \
    || { tail -n 40 "${BUILD}/next-build.log"; die "next build 失败"; }
  echo "$APP_KEY" > "${SRC}/.fpk-commit"
fi

changelog="$(awk '/^## /{n++; next} n==1 && /^- /{sub(/^- /, ""); printf "%s ", $0}' "${ROOT}/CHANGELOG.md" 2>/dev/null | sed 's/ *$//')"
changelog="${changelog:-基于上游 MoonTVPlus ${UPSTREAM_VERSION}}"

# ---------------------------------------------------------------- 按架构组装

for arch in $ARCHES; do
  na="$(node_arch "$arch")"; da="$(deb_arch "$arch")"; fa="$(file_arch "$arch")"
  work="${BUILD}/${arch}"
  pkg="${work}/pkg"
  srv="${pkg}/app/server"   # 应用本体直接放进包里，安装后在 TRIM_APPDEST/server 运行
  info "==== ${arch}"
  rm -rf "$work"
  mkdir -p "$pkg/app/runtime/node/bin" "$pkg/app/runtime/node/lib" "$srv" "${work}/x"

  # ---- 生产依赖：按目标架构选取可选的平台包（sharp、libsql 等）
  info "pnpm deploy（${na}）"
  cp "${SRC}/pnpm-workspace.yaml" "${work}/pnpm-workspace.yaml.orig"
  printf '\nsupportedArchitectures:\n  os: [linux]\n  cpu: [%s]\n  libc: [glibc]\n' "$na" >> "${SRC}/pnpm-workspace.yaml"
  deploy_rc=0
  (cd "$SRC" && npm_config_arch="$na" npm_config_platform=linux pnpm deploy --filter=. --prod --legacy "${work}/deps") \
    > "${work}/deploy.log" 2>&1 || deploy_rc=$?
  cp "${work}/pnpm-workspace.yaml.orig" "${SRC}/pnpm-workspace.yaml"
  [ "$deploy_rc" = 0 ] || { tail -n 30 "${work}/deploy.log"; die "pnpm deploy 失败"; }

  # ---- 应用本体：布局与上游 Dockerfile 的运行镜像一致
  cp -a "${SRC}/.next/standalone/." "$srv/"
  rm -rf "${srv}/node_modules"
  cp -a "${work}/deps/node_modules" "${srv}/node_modules"
  cp -a "${SRC}/scripts" "${SRC}/migrations" "${SRC}/start.js" "${SRC}/server.js" "${SRC}/public" "$srv/"
  mkdir -p "${srv}/src/lib" "${srv}/.next"
  cp -a "${SRC}/src/lib/tv-remote-hub.js" "${srv}/src/lib/"
  cp -a "${SRC}/.next/static" "${srv}/.next/static"
  rm -f "${srv}/public/manifest.json"   # 启动时按站点名重新生成

  # ---- 裁剪：运行时用不到的编译器，以及其他平台 / musl 的原生包
  nm="${srv}/node_modules/.pnpm"
  find "$nm" -mindepth 1 -maxdepth 1 -type d | while read -r d; do
    b="$(basename "$d")"
    if [[ "$b" =~ ^@next\+swc- ]] \
      || [[ "$b" =~ (darwin|win32|freebsd|android|openbsd|sunos|aix)[-_] ]] \
      || [[ "$b" =~ linux-.*musl ]] \
      || { [[ "$b" =~ linux-(x64|arm64|arm|ia32|ppc64|s390x|riscv64|loong64|mips) ]] && ! [[ "$b" =~ linux-${na}(-|@|_|$) ]]; }; then
      rm -rf "$d"
    fi
  done
  # 自带多平台 prebuilds 的包（如 bufferutil）只留 linux-<arch>
  find "${srv}/node_modules" -type d -name prebuilds -prune | while read -r p; do
    find "$p" -mindepth 1 -maxdepth 1 -type d ! -name "linux-${na}*" -exec rm -rf {} +
  done
  find "${srv}/node_modules" -xtype l -delete   # 删除被裁掉的包留下的悬空链接

  # ---- better-sqlite3：换成与内置 Node ABI、目标架构一致的官方预编译包
  bsql_tgz="${CACHE}/dl/better-sqlite3-v${BSQL_VERSION}-node-v${NODE_ABI}-linux-${na}.tar.gz"
  fetch_verified "https://github.com/WiseLibs/better-sqlite3/releases/download/v${BSQL_VERSION}/$(basename "$bsql_tgz")" "$bsql_tgz" "${BSQL_SHA256[$na]}"
  bsql_dirs="$(find "$nm" -maxdepth 4 -type d -path "*/better-sqlite3@${BSQL_VERSION}/node_modules/better-sqlite3")"
  [ -n "$bsql_dirs" ] || die "生产依赖里找不到 better-sqlite3@${BSQL_VERSION}"
  for d in $bsql_dirs; do
    rm -rf "${d}/build"
    tar -xzf "$bsql_tgz" -C "$d" build/Release/better_sqlite3.node
  done

  # ---- 自检：所有原生文件都必须是目标架构；不能有指向包外的符号链接
  bad=0
  while IFS= read -r -d '' f; do
    desc="$(file -b "$f")"
    case "$desc" in ELF*) [[ "$desc" == *"$fa"* ]] || { echo "  ${f#"$srv"/}: ${desc%%,*}"; bad=1; } ;; esac
  done < <(find "$srv" -type f \( -name '*.node' -o -name '*.so' -o -name '*.so.*' \) -print0)
  [ "$bad" = 0 ] || die "上面这些原生文件不是 ${fa} 架构"
  [ -z "$(find "$srv" -type l -lname '/*' | head -n1)" ] || die "server 里有绝对路径符号链接"
  while IFS= read -r l; do
    case "$(realpath -m "$l")" in "$srv"/*) ;; *) die "符号链接指向包外：$l" ;; esac
  done < <(find "$srv" -type l)
  for f in start.js server.js scripts/init-sqlite.js scripts/generate-manifest.js migrations/001_initial_schema.sql \
           src/lib/tv-remote-hub.js .next/BUILD_ID .next/static public/icons/icon-512x512.png \
           node_modules/next node_modules/socket.io node_modules/better-sqlite3/build/Release/better_sqlite3.node; do
    [ -e "${srv}/${f}" ] || die "server 缺少 ${f}"
  done

  info "应用本体 $(du -sh --apparent-size "$srv" | cut -f1)，$(find "$srv" -type f | wc -l) 个文件"

  # ---- Node.js 运行时 + libstdc++ / libgcc_s（Debian bookworm，与飞牛系统同源）
  node_txz="${CACHE}/dl/node-v${NODE_VERSION}-linux-${na}.tar.xz"
  [ -f "${CACHE}/dl/node-SHASUMS256-${NODE_VERSION}.txt" ] \
    || curl -fsSL -o "${CACHE}/dl/node-SHASUMS256-${NODE_VERSION}.txt" "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"
  node_sum="$(grep " node-v${NODE_VERSION}-linux-${na}.tar.xz\$" "${CACHE}/dl/node-SHASUMS256-${NODE_VERSION}.txt" | cut -d' ' -f1)"
  [ -n "$node_sum" ] || die "SHASUMS 里没有 node-v${NODE_VERSION}-linux-${na}.tar.xz"
  fetch_verified "https://nodejs.org/dist/v${NODE_VERSION}/$(basename "$node_txz")" "$node_txz" "$node_sum"
  tar -xJf "$node_txz" -C "${work}/x" "node-v${NODE_VERSION}-linux-${na}/bin/node" "node-v${NODE_VERSION}-linux-${na}/LICENSE"
  install -m 0755 "${work}/x/node-v${NODE_VERSION}-linux-${na}/bin/node" "${pkg}/app/runtime/node/bin/node"
  cp "${work}/x/node-v${NODE_VERSION}-linux-${na}/LICENSE" "${pkg}/app/runtime/node/LICENSE"
  python3 -I "${ROOT}/lib/fetch_debs.py" --arch "$da" --cache "${CACHE}/debian" --out "${pkg}/app/runtime/node/lib" \
    libstdc++6:libstdc++.so.6 libgcc-s1:libgcc_s.so.1 > "${work}/debs.txt" || die "取 libstdc++ / libgcc_s 失败"
  # RUNPATH 指向自带的库目录；原生模块（better-sqlite3、sharp）通过 soname 复用进程里已加载的这两个库
  "$PATCHELF" --set-rpath '$ORIGIN/../lib' "${pkg}/app/runtime/node/bin/node"

  # ---- 壳：脚本、配置、向导、图标、桌面入口
  cp -r "${TEMPLATE}/cmd" "${TEMPLATE}/config" "${TEMPLATE}/wizard" "$pkg/"
  cp "${TEMPLATE}/ICON.PNG" "${TEMPLATE}/ICON_256.PNG" "$pkg/"
  cp -r "${TEMPLATE}/app/ui" "${pkg}/app/"
  sed -e "s|@VERSION@|${VERSION}|" -e "s|@PLATFORM@|${arch}|" -e "s|@CHANGELOG@|${changelog//|/\\|}|" \
    "${TEMPLATE}/manifest" > "${pkg}/manifest"
  {
    echo "MoonTVPlus ${UPSTREAM_VERSION}（提交 ${COMMIT}，应用代码 ${APP_KEY}），fpk ${VERSION}，${arch}"
    echo "Node.js ${NODE_VERSION}，better-sqlite3 ${BSQL_VERSION}（node-v${NODE_ABI}-linux-${na}）"
    cat "${work}/debs.txt"
  } > "${pkg}/app/BUILD-INFO.txt"

  find "$pkg" -type d -exec chmod 0755 {} +
  find "$pkg" -type f -exec chmod 0644 {} +
  chmod 0755 "${pkg}"/cmd/* "${pkg}/app/runtime/node/bin/node" "${pkg}"/app/runtime/node/lib/*

  # ---- 打包前自检
  for f in manifest config/privilege config/resource ICON.PNG ICON_256.PNG wizard/install wizard/config wizard/uninstall \
           app/ui/config app/ui/images/icon_64.png app/ui/images/icon_256.png app/server/start.js app/server/public app/server/.next \
           app/runtime/node/bin/node app/runtime/node/lib/libstdc++.so.6 app/runtime/node/lib/libgcc_s.so.1; do
    [ -e "${pkg}/${f}" ] || die "缺少 ${f}"
  done
  for s in functions main install_init install_callback upgrade_init upgrade_callback uninstall_init uninstall_callback \
           config_init config_callback; do
    [ -f "${pkg}/cmd/${s}" ] || die "缺少 cmd/${s}"
    bash -n "${pkg}/cmd/${s}" || die "cmd/${s} 语法错误"
  done
  python3 -I -c "
import json, sys
for p in ['config/privilege', 'config/resource', 'wizard/install', 'wizard/config', 'wizard/uninstall', 'app/ui/config']:
    json.load(open(sys.argv[1] + '/' + p))
" "$pkg" || die "JSON 配置无效"
  for b in app/runtime/node/bin/node app/runtime/node/lib/libstdc++.so.6 app/runtime/node/lib/libgcc_s.so.1; do
    file -bL "${pkg}/${b}" | grep -q "$fa" || die "${b} 架构不符"
  done
  [ "$("$PATCHELF" --print-rpath "${pkg}/app/runtime/node/bin/node")" = '$ORIGIN/../lib' ] || die "node 的 RUNPATH 未设置"
  if [ "$arch" = x86 ]; then
    # 本机能跑 x86：确认内置 Node 用的是自带的 libstdc++，并能加载两个原生模块
    for lib in libstdc++.so.6 libgcc_s.so.1; do
      got="$(ldd "${pkg}/app/runtime/node/bin/node" | awk -v l="$lib" '$1 == l {print $3}')"
      [ -n "$got" ] && [ "$(realpath "$got")" = "$(realpath "${pkg}/app/runtime/node/lib/${lib}")" ] \
        || die "node 没有使用自带的 ${lib}（实际：${got:-未找到}）"
    done
    "${pkg}/app/runtime/node/bin/node" -e "
      const D = process.argv[1] + '/node_modules/';
      const db = new (require(D + 'better-sqlite3'))(':memory:');
      db.exec('create table t(x)'); db.prepare('insert into t values (?)').run(1);
      if (db.prepare('select count(*) c from t').get().c !== 1) throw new Error('sqlite');
      require(D + 'sharp');
      console.log('native ok');" "$srv" > /dev/null || die "内置 Node 加载 better-sqlite3 / sharp 失败"
  fi

  info "fnpack build"
  rm -f "${work}"/*.fpk
  (cd "$work" && "${TOOLS}/fnpack" build --directory pkg) > "${work}/fnpack.log" 2>&1 \
    || { cat "${work}/fnpack.log"; die "fnpack 失败"; }
  out="$(find "$work" -maxdepth 1 -name '*.fpk' | head -n1)"
  [ -n "$out" ] || { cat "${work}/fnpack.log"; die "未找到 fnpack 输出"; }
  mv -f "$out" "${DIST}/moontvplus_${VERSION}_${arch}.fpk"
  info "产物 ${DIST}/moontvplus_${VERSION}_${arch}.fpk（$(( $(stat -c %s "${DIST}/moontvplus_${VERSION}_${arch}.fpk") / 1048576 ))MB）"

  # 每个架构只保留最新 2 个版本
  find "$DIST" -maxdepth 1 -name "moontvplus_*_${arch}.fpk" -printf '%f\n' | sort -V | head -n -2 | while read -r old; do
    rm -f "${DIST}/${old}"
    info "已删除旧包 ${old}"
  done
done

(cd "$DIST" && sha256sum moontvplus_"${VERSION}"_*.fpk)
