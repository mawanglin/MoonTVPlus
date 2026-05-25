# Redis/Kvrocks DNS Family 修复实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在共享的 `createRedisClient` 工厂内默认强制 `socket.family = 4`，修复部分 NAS 系统（飞牛 fnOS、群晖等）Docker 内嵌 DNS 对 IPv6 响应异常导致 redis/kvrocks 客户端报 `EAI_AGAIN` 的问题；提供 `REDIS_FAMILY` 环境变量作为 escape hatch；更新 README 和 CHANGELOG。

**Architecture:** 单点修改 `src/lib/redis-base.db.ts` 中的 `createRedisClient`，在 `clientConfig.socket` 块加入 `family` 字段，值从 `process.env.REDIS_FAMILY` 解析（默认 4）。`kvrocks.db.ts` / `redis.db.ts` 共用此工厂，无需改动，自动继承修复。

**Tech Stack:** TypeScript、Next.js、`redis@^4.6.7` (node-redis)、Node.js 24-alpine、pnpm。

**Spec 参考:** `docs/superpowers/specs/2026-05-25-redis-dns-family-fix-design.md`

**Branch:** `fix/redis-dns-family-ipv4`（已创建并切换）

**Note on testing:** 按 spec 第 2 节"非目标"明确不新增自动化测试——DNS / socket 行为难 mock、价值低；环境敏感的修复靠真实回归更可靠。最终验收通过 Task 5（NAS 实地部署）完成。

---

## File Structure

| 文件 | 改动 | 责任 |
|---|---|---|
| `src/lib/redis-base.db.ts` | 修改第 92-110 行附近的 `clientConfig.socket` 块 | 共享的 redis 客户端工厂，承载本次修复 |
| `README.md` | 修改环境变量表（约 415 行后插入）+ 末尾追加"故障排查"小节（约 561 行后） | 用户文档：新增环境变量说明 + 排错指引 |
| `CHANGELOG` | 顶部新增 `[220.0.1]` 块 | 变更记录 |

**不修改**：`kvrocks.db.ts`、`redis.db.ts`、`upstash.db.ts`、`Dockerfile`、`package.json`、`pnpm-lock.yaml`。

---

## Task 1：修改 createRedisClient 工厂

**Files:**
- Modify: `src/lib/redis-base.db.ts:82-110`

- [ ] **Step 1：读取当前文件以确认上下文**

读取 `src/lib/redis-base.db.ts` 的第 80-115 行，确认 `createRedisClient` 函数和 `clientConfig.socket` 块的当前形态与下面 Step 2 的"现状"片段完全一致。如果不一致（例如别人已经改过），停下来通知用户。

预期当前状态（Step 2 中的 `old_string` 必须严格匹配此片段）：

```typescript
    // 创建客户端配置
    const clientConfig: any = {
      url: config.url,
      socket: {
        // 重连策略：指数退避，最大30秒
        reconnectStrategy: (retries: number) => {
          console.log(`${config.clientName} reconnection attempt ${retries + 1}`);
          if (retries > 10) {
            console.error(`${config.clientName} max reconnection attempts exceeded`);
            return false; // 停止重连
          }
          return Math.min(1000 * Math.pow(2, retries), 30000); // 指数退避，最大30秒
        },
        connectTimeout: 10000, // 10秒连接超时
        // 设置no delay，减少延迟
        noDelay: true,
      },
      // 添加其他配置
      pingInterval: 30000, // 30秒ping一次，保持连接活跃
    };
```

- [ ] **Step 2：应用 Edit**

使用 Edit 工具对 `src/lib/redis-base.db.ts` 做如下替换：

**old_string**（完全照抄上面 Step 1 的预期当前状态）：

```typescript
    // 创建客户端配置
    const clientConfig: any = {
      url: config.url,
      socket: {
        // 重连策略：指数退避，最大30秒
        reconnectStrategy: (retries: number) => {
          console.log(`${config.clientName} reconnection attempt ${retries + 1}`);
          if (retries > 10) {
            console.error(`${config.clientName} max reconnection attempts exceeded`);
            return false; // 停止重连
          }
          return Math.min(1000 * Math.pow(2, retries), 30000); // 指数退避，最大30秒
        },
        connectTimeout: 10000, // 10秒连接超时
        // 设置no delay，减少延迟
        noDelay: true,
      },
      // 添加其他配置
      pingInterval: 30000, // 30秒ping一次，保持连接活跃
    };
```

**new_string**：

```typescript
    // IP 协议族（默认 4，强制 IPv4 解析）
    // 解决部分 NAS（飞牛 fnOS、群晖等）Docker 内嵌 DNS 对 IPv6 (AAAA)
    // 查询响应异常导致 EAI_AGAIN 的问题，可通过 REDIS_FAMILY 覆盖
    const family = parseInt(process.env.REDIS_FAMILY ?? '4', 10);

    // 创建客户端配置
    const clientConfig: any = {
      url: config.url,
      socket: {
        family,
        // 重连策略：指数退避，最大30秒
        reconnectStrategy: (retries: number) => {
          console.log(`${config.clientName} reconnection attempt ${retries + 1}`);
          if (retries > 10) {
            console.error(`${config.clientName} max reconnection attempts exceeded`);
            return false; // 停止重连
          }
          return Math.min(1000 * Math.pow(2, retries), 30000); // 指数退避，最大30秒
        },
        connectTimeout: 10000, // 10秒连接超时
        // 设置no delay，减少延迟
        noDelay: true,
      },
      // 添加其他配置
      pingInterval: 30000, // 30秒ping一次，保持连接活跃
    };
```

- [ ] **Step 3：lint 检查不引入新错误**

Run: `pnpm lint -- src/lib/redis-base.db.ts`

预期：通过（无新错误）。如果项目根目录下没有顶层 lint 脚本，或者它只跑全量，改用：
`npx eslint src/lib/redis-base.db.ts`

如果 ESLint 没有安装/没有配置，跳过此步骤（不阻塞），在 commit message 里注明。

- [ ] **Step 4：TypeScript 编译检查**

Run: `pnpm tsc --noEmit`

预期：通过（无新类型错误）。`redis@4` 的 socket 配置类型 `RedisSocketOptions` 接受 `family?: 0 | 4 | 6`；`parseInt('4')` 类型推断为 `number`，赋给 `socket: { family }` 时 TS 走结构化推断，应能通过。如果报类型错（要求字面量类型），降级方案：把赋值改成

```typescript
const family = (parseInt(process.env.REDIS_FAMILY ?? '4', 10) as 0 | 4 | 6);
```

- [ ] **Step 5：commit**

```bash
git add src/lib/redis-base.db.ts
git commit -m "$(cat <<'EOF'
fix(redis): default socket.family to 4 to avoid EAI_AGAIN on NAS

部分 NAS 系统（飞牛 fnOS、群晖等）Docker 内嵌 DNS 对 IPv6 (AAAA)
查询响应异常，Node.js 17+ 默认 verbatim 解析顺序优先尝试 IPv6 导
致 redis/kvrocks 客户端持续报 EAI_AGAIN。在共享的 createRedisClient
工厂内默认强制 socket.family=4，可通过 REDIS_FAMILY 环境变量覆盖
（0/4/6）。

kvrocks.db.ts 与 redis.db.ts 共用此工厂，自动继承修复。
EOF
)"
```

预期：commit 成功。如果项目有 pre-commit hook（如 husky）失败，依照 hook 错误排查并修复后**新建** commit（不要 amend）。

---

## Task 2：更新 README — 环境变量表

**Files:**
- Modify: `README.md:415`（在 `REDIS_URL` 行之后插入新行）

- [ ] **Step 1：读取当前 README 第 414-417 行验证状态**

读取 `README.md` 第 413-417 行，确认 `REDIS_URL` 行在 415 行、`UPSTASH_URL` 行在 416 行。如果行号已飘移，找到 `REDIS_URL` 实际所在行，把下面 Step 2 中的 `old_string` 调整为以"REDIS_URL"那一行作为唯一锚点的最小匹配。

- [ ] **Step 2：在 REDIS_URL 行后插入 REDIS_FAMILY 行**

使用 Edit 工具：

**old_string**（精确匹配 `REDIS_URL` 那一行 + 紧随的 `UPSTASH_URL` 行作为唯一锚点）：

```
| REDIS_URL                                | redis 连接 url                                               | 连接 url                    | 空                                                           |
| UPSTASH_URL                              | upstash redis 连接 url                                       | 连接 url                    | 空                                                           |
```

**new_string**：

```
| REDIS_URL                                | redis 连接 url                                               | 连接 url                    | 空                                                           |
| REDIS_FAMILY                             | redis/kvrocks 客户端的 IP 协议族（4=IPv4，6=IPv6，0=自动）。某些 NAS 系统 Docker 内嵌 DNS 对 IPv6 响应异常会报 EAI_AGAIN，保持默认 4 即可 | 0 / 4 / 6                   | 4                                                            |
| UPSTASH_URL                              | upstash redis 连接 url                                       | 连接 url                    | 空                                                           |
```

> 说明：本表格用对齐空格保持视觉对齐。新行的填充按现有列宽近似对齐即可——markdown 表格的渲染**不依赖空格数量**，只看 `|` 分隔符。所以哪怕空格数没对齐也不影响显示。

- [ ] **Step 3：commit**

```bash
git add README.md
git commit -m "docs(readme): 新增 REDIS_FAMILY 环境变量说明"
```

---

## Task 3：更新 README — 新增故障排查小节

**Files:**
- Modify: `README.md:561-562`（在"安全与隐私提醒"小节之后、"License"之前插入新小节）

- [ ] **Step 1：读取当前 README 第 558-566 行确认上下文**

读取 `README.md` 第 558-566 行，确认"License"小节标题（`## License`）所在的行号，并取该行前 1-2 行的内容作为 anchor。如果行号飘移过大，使用 grep 重新定位：`grep -n "^## License" README.md`。

- [ ] **Step 2：在 ## License 之前插入故障排查小节**

使用 Edit 工具：

**old_string**（精确匹配 `## License` 标题及其前后一定上下文，保证唯一）：

```
## License

[MIT](LICENSE) © 2025 MoonTV & Contributors
```

**new_string**：

```
## 故障排查

### 容器内出现 `Kvrocks client error: ... EAI_AGAIN`（或 redis 同类错误）

**现象**：core 容器日志反复打印

    Kvrocks client error: Error: getaddrinfo EAI_AGAIN moontvplus-kvrocks
    Kvrocks reconnection attempt N

但 kvrocks/redis 容器本身正常监听端口。

**原因**：部分 NAS 系统（飞牛 fnOS、群晖 DSM 等）的 Docker 内嵌 DNS (`127.0.0.11`) 对 IPv6 (AAAA) 查询响应异常。Node.js 17+ 默认 verbatim 解析顺序会优先尝试 IPv6，触发超时。

**默认已规避**：v220.0.1 起，redis 客户端默认强制 IPv4（`REDIS_FAMILY=4`）。如仍出问题，请确认未覆盖此变量。

**进一步排查**：

1. 确认两个容器在同一 Docker 网络：

       docker inspect <core容器> -f '{{json .NetworkSettings.Networks}}'

2. 用 IP 直连绕过 DNS 验证 L3 连通性：

       KVIP=$(docker inspect <kvrocks容器> -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
       docker exec <core容器> node -e "require('net').createConnection(6666,'$KVIP').on('connect',()=>console.log('OK'))"

   输出 `OK` 表示网络层通，问题就是 DNS。

3. 终极绕开 DNS：在 compose 的 core 服务里加 `extra_hosts`，把服务名映射到容器 IP。

## License

[MIT](LICENSE) © 2025 MoonTV & Contributors
```

> **关于嵌套代码块的处理**：为避免在 markdown fenced code block 中再嵌套 fenced code block 产生渲染问题，本节示例代码统一使用 **4 空格缩进** 表示代码块（CommonMark indented code block 语法），不用 ``` 围栏。

- [ ] **Step 3：肉眼检查**

读取修改后的 `README.md` 第 555-580 行，确认：
1. "故障排查"小节正确插入在"安全与隐私提醒"之后、"License"之前
2. 缩进代码块的缩进是 4 空格（不是 tab，不是 2 空格）
3. 与上下小节之间各有一行空行

- [ ] **Step 4：commit**

```bash
git add README.md
git commit -m "docs(readme): 新增故障排查小节，介绍 EAI_AGAIN 排错路径"
```

---

## Task 4：更新 CHANGELOG

**Files:**
- Modify: `CHANGELOG:1`（在文件最顶部插入新版本块）

- [ ] **Step 1：读取 CHANGELOG 前 5 行确认顶部格式**

读取 `CHANGELOG` 第 1-5 行，确认最新版本块当前是 `## [220.0.0] - 2026-05-14`。如果已经有更新的版本号在顶部，停下来通知用户（说明发版周期已经动过，需要重新对齐版本号）。

- [ ] **Step 2：在文件最顶部插入新版本块**

使用 Edit 工具：

**old_string**：

```
## [220.0.0] - 2026-05-14
```

**new_string**：

```
## [220.0.1] - 2026-05-25
### Fixed
- 修复部分 NAS 系统（飞牛 fnOS、群晖等）Docker 内嵌 DNS 对 IPv6 响应异常导致 redis/kvrocks 客户端持续报 `EAI_AGAIN` 无法连接的问题。redis 客户端 socket 现在默认强制 IPv4，可通过 `REDIS_FAMILY` 环境变量覆盖（0/4/6）。

## [220.0.0] - 2026-05-14
```

- [ ] **Step 3：commit**

```bash
git add CHANGELOG
git commit -m "docs(changelog): 新增 220.0.1 修复 NAS DNS EAI_AGAIN 问题"
```

---

## Task 5：本地构建镜像 + NAS 实地验收

> 这是手动验收步骤，不是自动化测试。按 spec 第 2 节"非目标"明确不写自动化测试。

**Files:** 无源码改动。

**前置条件**：用户拥有飞牛 NAS 访问权限，且 NAS 上当前有 kvrocks 容器在跑（之前会话中已配置好）。

- [ ] **Step 1：本地（开发机）构建镜像**

在仓库根目录执行：

```bash
docker build -t moontvplus:fix-dns-test .
```

预期：构建成功，输出最后一行类似 `Successfully tagged moontvplus:fix-dns-test`。
预计耗时：3-8 分钟（取决于网络和缓存）。
如果构建失败，看错误信息——常见原因：磁盘空间不足、pnpm 安装超时、Next.js 构建报错。后两者可能与本次改动无关，是 main 分支的已有问题；与本次改动无关的失败，停下来告知用户。

- [ ] **Step 2：把镜像传到 NAS**

两种方式选一种：

**方式 A：直接在 NAS 上 build**（推荐，如果 NAS 装了 Docker 且有 git）：

```bash
# 在 NAS 上
git clone <仓库 URL> -b fix/redis-dns-family-ipv4 /tmp/moontvplus-fix
cd /tmp/moontvplus-fix
docker build -t moontvplus:fix-dns-test .
```

**方式 B：开发机 build → 导出 → NAS 导入**：

```bash
# 开发机
docker save moontvplus:fix-dns-test | gzip > /tmp/moontvplus-fix.tar.gz
scp /tmp/moontvplus-fix.tar.gz <nas-user>@<nas-ip>:/tmp/

# NAS 上
gunzip -c /tmp/moontvplus-fix.tar.gz | docker load
```

- [ ] **Step 3：修改 NAS 上的 compose 临时指向测试镜像**

在 NAS 上编辑 docker-compose 文件，把
```yaml
image: ghcr.io/mtvpls/moontvplus:latest
```
临时改为
```yaml
image: moontvplus:fix-dns-test
```

- [ ] **Step 4：拉起服务并观察**

在 NAS 上执行：

```bash
docker compose down
docker compose up -d
sleep 15
docker compose ps
docker logs moontvplus-core-1 --tail 50
```

**通过标准**：

1. `docker compose ps` 输出中 `moontvplus-kvrocks-1` 状态为 `Up (healthy)`，`moontvplus-core-1` 状态为 `Up`。
2. `docker logs moontvplus-core-1 --tail 50` 中：
   - **看不到**：`Kvrocks reconnection attempt`、`EAI_AGAIN`、`Kvrocks reconnecting...`
   - **看得到**：`Kvrocks connected` 或 `Kvrocks ready` 或正常的 Next.js 启动日志（如 `Fetching ...` 不再循环 retry）

如果还看到 `EAI_AGAIN`：

- 确认镜像确实是新 build 的：`docker inspect moontvplus-core-1 -f '{{.Image}}'` 应该是 `moontvplus:fix-dns-test` 的 image ID
- 在 core 容器里验证环境变量没被覆盖成奇怪值：`docker exec moontvplus-core-1 sh -c 'echo "REDIS_FAMILY=$REDIS_FAMILY"'`（空 = 走默认 4）
- 进 core 容器跑 node REPL 检查 socket family 实际取到的值：
  ```bash
  docker exec moontvplus-core-1 node -e "console.log(parseInt(process.env.REDIS_FAMILY ?? '4', 10))"
  ```
  期望输出 `4`

- [ ] **Step 5：浏览器烟雾测试**

打开 `http://<NAS_IP>:31400/login`：
- 登录页能打开（不是空白、不是 502）
- 用 `admin` / 配置的密码登录成功
- 搜索任意影片，能出结果
- 进入播放页能播放
- 收藏一个，刷新页面后收藏还在（验证 kvrocks 写入持久化）

5 项都通过 = 验收 OK。

- [ ] **Step 6：还原 NAS compose 的 image**

把 compose 里的 `image: moontvplus:fix-dns-test` 改回 `image: ghcr.io/mtvpls/moontvplus:latest`，但**先不要重启**——上游镜像还没有此修复，重启会回到坏状态。

正确做法：保留测试镜像运行直到上游合并并发布。或者写一个临时的 docker-compose.override.yml 锁定测试镜像。

> 这一步是清理性质，不影响 PR 是否能合并。

---

## Task 6：推送分支（PR 准备）

**Files:** 无文件改动，纯 git 操作。

- [ ] **Step 1：检查分支状态**

```bash
git status
git log --oneline main..HEAD
```

预期：工作区干净；`main..HEAD` 列出 5 个 commit（spec + Task 1 + Task 2 + Task 3 + Task 4）。

- [ ] **Step 2：推送分支到 origin**

```bash
git push -u origin fix/redis-dns-family-ipv4
```

如果远程是 fork 而不是 upstream，根据用户实际仓库情况调整。如果用户希望先在本地保留不推送，跳过此步。

- [ ] **Step 3：（可选）开 PR**

按用户意愿决定。如果要开 PR，用以下模板：

**标题**：`fix(redis): default socket.family to 4 to avoid EAI_AGAIN on NAS`

**描述**：

```markdown
## Summary

- 修复 NAS 系统（飞牛 fnOS、群晖等）Docker 内嵌 DNS 对 IPv6 响应异常导致 redis/kvrocks 客户端持续报 `EAI_AGAIN` 无法连接的问题
- 在共享的 `createRedisClient` 工厂内默认强制 `socket.family=4`
- 新增 `REDIS_FAMILY` 环境变量（默认 4，可设 0/6）作为 escape hatch
- 更新 README 环境变量表 + 故障排查小节
- 更新 CHANGELOG（新增 220.0.1）

## Background

详见 `docs/superpowers/specs/2026-05-25-redis-dns-family-fix-design.md`。

## Test Plan

- [x] 本地 `pnpm tsc --noEmit` 通过
- [x] 飞牛 NAS 实地验收：core 日志不再出现 `EAI_AGAIN`，登录/搜索/播放/收藏全部正常

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

> **注意**：本步骤涉及推送到远程和创建 PR，属于"shared state 改动"。执行前必须先和用户确认。

---

## Self-Review

我把这份计划对照 spec 检查了一遍：

**Spec 覆盖检查**：

| Spec 章节 | 对应 Task |
|---|---|
| 3.1 代码改动（redis-base.db.ts） | Task 1 |
| 4.1 README 环境变量表 | Task 2 |
| 4.2 README 故障排查小节 | Task 3 |
| 4.3 README 现有 compose 示例不动 | （隐含——计划未提及修改示例，即不动）|
| 5 CHANGELOG 改动 | Task 4 |
| 7.1-7.2 主验收路径与通过标准 | Task 5 |
| 8 实施步骤 | 整个计划即对应 |

**Placeholder 扫描**：无 TBD / TODO / 含糊措辞。Task 5 Step 6 的"清理性质"步骤说明清楚是可选的"还原"动作。

**类型一致性**：环境变量名全文统一为 `REDIS_FAMILY`，函数名统一为 `createRedisClient`，文件路径统一为 `src/lib/redis-base.db.ts`。版本号统一为 `220.0.1`，日期统一为 `2026-05-25`。

**潜在风险点已说明**：
- Task 1 Step 4：TS 类型可能要求字面量类型，已给降级方案
- Task 1 Step 3：lint 工具未必存在，已给跳过条件
- Task 5 Step 4：如果还报 `EAI_AGAIN` 有具体排查清单
- Task 6 Step 3：推送/开 PR 是 shared state 改动，明确标注需用户确认

计划自检通过。
