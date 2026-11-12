# MoonTVPlus · 飞牛 fnOS 原生安装包

把 MoonTVPlus 打包成飞牛 fnOS 的原生 `.fpk`。**不使用 Docker**，除 glibc 外的依赖全部随包附带：

- Node.js 24（官方 glibc 构建），以及 Debian bookworm 的 `libstdc++.so.6` / `libgcc_s.so.1`（node 的 RUNPATH 指向自带的库目录）
- 应用本体：与上游 Dockerfile 运行镜像相同的布局（Next standalone + `pnpm deploy --prod` 的生产依赖）
- 原生模块按目标架构选取：`better-sqlite3` 换成与内置 Node ABI 一致的官方预编译包，`sharp` / `libsql` 用对应架构的平台包

x86 与 arm 各出一个包。这个目录只在 fork 的 `fnos-fpk` 分支上，应用代码一行没改，方便跟上游同步。

## 运行方式

| 项 | 说明 |
|---|---|
| 访问 | `http://<NAS 地址>:<端口>`，端口在安装向导里设，默认 3030。页面与接口都挂在根路径，不能放进飞牛统一网关的子路径，所以走局域网端口 |
| 账号 | 向导里设站长（owner）账号；之后在「应用设置」里改，保存后自动重启 |
| 存储 | SQLite（`NEXT_PUBLIC_STORAGE_TYPE=d1`），数据库在 `TRIM_PKGVAR/data/moontv.db` |
| 定时任务 | 安装时生成随机的 `CRON_PASSWORD`，不用上游默认的 `mtvpls` |
| 运行账号 | `moontvplus`（`config/privilege` 的 `run-as: package`） |
| 离线下载 | 默认关闭（上游默认也是关闭） |

目录：

| 位置 | 内容 |
|---|---|
| `TRIM_APPDEST`（`/vol1/@appcenter/moontvplus`） | `runtime/node`（node + 自带库）、`server/`（应用本体，直接在这里运行）。飞牛把它的属主设为应用账号，运行时写 `public/manifest.json` 和 `.next/cache` 没问题；不可写时启动会失败并说明原因 |
| `TRIM_PKGETC/settings.env` | 端口、站长账号、cron 密码（权限 600） |
| `TRIM_PKGVAR/data/` | SQLite 数据库 |
| `TRIM_PKGVAR/logs/` | `moontvplus.log`（超过 10 MB 截断）、pid |

飞牛的 ZFS（`trimacl` 挂载）新建文件不受 umask 约束，所以每次安装、升级、启动时都把 `data`、`logs`、`home` 收紧为目录 750、文件 640。

卸载时应用本体随安装目录一起删除；数据库与配置默认保留，卸载向导里关闭「保留」才删。227.0.1.1 曾把应用本体解压到 `TRIM_PKGVAR/server`，之后的版本在安装、升级、启动时会自动清掉这份旧拷贝。

## 构建

```bash
packaging/fnos/build.sh                # x86 + arm，产物在项目根目录的 dist/
packaging/fnos/build.sh --arch x86     # 只构建 x86
packaging/fnos/build.sh --reuse-app    # 复用上次的 next build，只重新组装打包
```

- 构建机：x86_64 Linux，需要 bash、git、curl、python3、tar、gzip、file、pnpm；patchelf、fnpack 自动下载（sha256 固定在 `build.sh` 里）
- 应用源码取 **git HEAD**（`git archive`），未提交的改动不会进包
- 版本：fpk 是 `<上游版本>.<N>`（如 `227.0.1.1`），对应 git tag `v<上游版本>-cob.<N>`；N 记录在项目根目录的 `dist/.build_rev`
- 项目根目录的 `dist/`（已加入 `.gitignore`）里每个架构只保留最新 2 个版本
- 升级 Node 或 better-sqlite3 时改 `build.sh` 顶部的版本和 sha256；脚本会核对 better-sqlite3 版本与 `pnpm-lock.yaml` 一致

## 测试

```bash
packaging/fnos/test/simulate.sh dist/moontvplus_<版本>_x86.fpk
```

在普通 x86 Linux 上用假的 `TRIM_*` 环境跑一遍全部生命周期脚本，包括失败路径：端口占用、进程启动即退出、应用目录不可写、改账号后重启、权限收紧、升级时清理旧拷贝且不动数据库、重装时保留 cron 密码、卸载时是否保留数据，以及删除路径的保护。arm 包在构建时只做静态检查（所有原生文件的架构），要在 arm 设备上实测。

## 同步上游后

1. `main` 快进到上游，推到自己的 fork
2. `fnos-fpk` rebase 到新的 `main`（打包只在 `packaging/fnos/` 里，一般不会冲突）
3. 在 `CHANGELOG.md` 加一节，运行 `build.sh`；小版本号会按新的上游版本从 1 重新计数
