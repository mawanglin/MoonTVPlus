# Redis/Kvrocks DNS Family 修复设计

- **日期**：2026-05-25
- **分支**：`fix/redis-dns-family-ipv4`
- **类型**：Bug fix（含一个新增可选环境变量）
- **影响范围**：使用 `redis` 或 `kvrocks` 存储后端的部署（特别是 NAS 上的 Docker 部署）

---

## 1. 背景与问题描述

### 现象

用户在飞牛 fnOS NAS 上使用以下 docker-compose 部署 MoonTVPlus（kvrocks 存储后端）：

```yaml
moontvplus-core:
  image: ghcr.io/mtvpls/moontvplus:latest
  environment:
    - KVROCKS_URL=redis://moontvplus-kvrocks:6666
  # ...
moontvplus-kvrocks:
  image: apache/kvrocks
  # ...
```

`core` 容器启动后日志反复打印：

```
Kvrocks reconnecting...
Kvrocks reconnection attempt N
Kvrocks client error: Error: getaddrinfo EAI_AGAIN moontvplus-kvrocks
    at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:122:26)
```

### 排查结论

经过逐层诊断：

| 检查 | 结果 |
|---|---|
| 两个容器在同一 Docker 网络 | ✅ 已确认 |
| kvrocks 容器健康、监听 6666 | ✅ 日志显示 `Ready to accept connections` |
| L3 连通性（直接用容器 IP 连 6666） | ✅ OK |
| 通过 service 名解析 DNS | ❌ 报 `EAI_AGAIN` |

**根因**：

1. `EAI_AGAIN` 表示 "DNS resolver 临时故障"（不是 "name not found"），通常是 DNS server 没响应。
2. Node.js 17+ 默认开启 `dns.setDefaultResultOrder('verbatim')`，对双栈 hostname 会优先尝试 IPv6 (AAAA) 解析。
3. 部分 NAS 系统（飞牛 fnOS、群晖 DSM 等）的 Docker 内嵌 DNS (`127.0.0.11`) 对 IPv6 (AAAA) 查询响应异常或超时。
4. 项目使用的 `node-redis` (`redis@^4.6.7`) 在 `socket` 配置里未显式指定 `family`，因此走 Node 默认 lookup 路径，踩 IPv6 坑。
5. 对比：`ioredis` 默认 `family: 4`，不踩此坑——这就是为什么很多老 redis 客户端在 NAS 上没问题。

### 为什么是"最近才出现"

- `package.json` 中 `"redis": "^4.6.7"` 用了 caret 范围，每次镜像 build 拉取的子版本可能不同。
- `Dockerfile` 用 `FROM node:24-alpine`，Node 主版本随上游浮动。
- 旧镜像可能基于 Node 18/20 + 较老 redis 版本，恰好不触发；新镜像组合下问题暴露。

---

## 2. 目标

修复后默认部署即可正常工作，**用户零配置改动**。同时提供 escape hatch 给极少数需要 IPv6 的部署。

### 非目标

- 不解决 Docker 内嵌 DNS 在 NAS 上的根本故障（不是本项目的范畴）。
- 不为 upstash/d1/sqlite/postgres 等其他存储后端做改动（不受影响）。
- 不升级 `redis` 包版本（避免引入其他变更）。
- 不改 Dockerfile 基础镜像（同上）。
- 不新增自动化测试（DNS / socket 行为难 mock，价值低；环境敏感的修复靠真实回归更可靠）。

---

## 3. 设计

### 3.1 代码改动

**文件**：`src/lib/redis-base.db.ts`

**位置**：`createRedisClient` 函数内（当前 82-149 行）的 `clientConfig.socket` 块。

**改动**：

```typescript
// 读取 IP family 配置（默认 4，强制 IPv4 解析）
// 解决某些 NAS 系统（如飞牛 fnOS）Docker 内嵌 DNS 对 IPv6 (AAAA)
// 查询响应异常导致 EAI_AGAIN 的问题
const family = parseInt(process.env.REDIS_FAMILY ?? '4', 10);

const clientConfig: any = {
  url: config.url,
  socket: {
    family,                                    // 👈 新增
    reconnectStrategy: (retries: number) => {
      console.log(`${config.clientName} reconnection attempt ${retries + 1}`);
      if (retries > 10) {
        console.error(`${config.clientName} max reconnection attempts exceeded`);
        return false;
      }
      return Math.min(1000 * Math.pow(2, retries), 30000);
    },
    connectTimeout: 10000,
    noDelay: true,
  },
  pingInterval: 30000,
};
```

### 3.2 设计决策

| 决策 | 理由 |
|---|---|
| 修改共用工厂 `createRedisClient`，不在 adapter 层 override | 1 处改动，kvrocks 和 redis 两个 adapter 同时受益；未来新增 Pika/Dragonfly 等同类 adapter 也自动继承 |
| 读取位置：在工厂内部读 env，不通过 `RedisConnectionConfig` 传入 | 这是网络层全局行为，不是连接特异的参数。放在工厂里，所有 caller 零改动 |
| 默认值：4（强制 IPv4） | 双栈环境也能正常解析 A 记录，无功能损失；纯 IPv6-only 部署在自托管影视站场景下极罕见 |
| 提供环境变量 `REDIS_FAMILY` | 给少数需要 IPv6 的部署一个 escape hatch（设 `6` 走 IPv6，`0` 走 Node 默认） |
| 类型解析：`parseInt(... ?? '4', 10)` | env 未设置或空 → 默认 4；env 设为无效值 → `NaN`，Node 的 `net` 模块会 fallback 默认行为，不会 crash |
| 注释 2-3 行解释 NAS + EAI_AGAIN 背景 | 这是一个非显然的修复，未来维护者看到 `family: 4` 会困惑"为什么写死"。注释必要 |

### 3.3 不做的事

- ❌ 不抽 helper 函数（1 行赋值，抽函数反而绕）。
- ❌ 不新增单元测试（理由见"非目标"）。
- ❌ 不动 `kvrocks.db.ts` / `redis.db.ts`（保持不变，自动继承修复）。
- ❌ 不动 `upstash.db.ts`（HTTP REST，不受影响）。
- ❌ 不动 `Dockerfile` / `package.json` 依赖版本。

---

## 4. 文档改动

### 4.1 README.md — 环境变量表新增一行

在现有 redis 相关环境变量后追加（约第 415 行 `REDIS_URL` 之后）：

```
| REDIS_FAMILY | redis/kvrocks 客户端的 IP 协议族（4=IPv4，6=IPv6，0=自动）。某些 NAS 系统 Docker 内嵌 DNS 对 IPv6 响应异常会报 EAI_AGAIN，保持默认 4 即可 | 0 / 4 / 6 | 4 |
```

### 4.2 README.md — 新增"故障排查"小节

在 README 末尾新增独立小节（具体位置在实现时定，紧邻现有部署/环境变量章节）：

```markdown
## 故障排查

### 容器内出现 `Kvrocks client error: ... EAI_AGAIN`（或 redis 同类错误）

**现象**：core 容器日志反复打印

​```
Kvrocks client error: Error: getaddrinfo EAI_AGAIN moontvplus-kvrocks
Kvrocks reconnection attempt N
​```

但 kvrocks/redis 容器本身正常监听端口。

**原因**：部分 NAS 系统（飞牛 fnOS、群晖 DSM 等）的 Docker 内嵌 DNS
(127.0.0.11) 对 IPv6 (AAAA) 查询响应异常。Node.js 17+ 默认 verbatim
解析顺序会优先尝试 IPv6，触发超时。

**默认已规避**：v220.0.1 起，redis 客户端默认强制 IPv4
（`REDIS_FAMILY=4`）。如仍出问题，请确认未覆盖此变量。

**进一步排查**：
1. 确认两个容器在同一 Docker 网络：
   `docker inspect <core> -f '{{json .NetworkSettings.Networks}}'`
2. 直接用 IP 测连通性：
   ​```bash
   KVIP=$(docker inspect <kvrocks容器> -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
   docker exec <core> node -e "require('net').createConnection(6666,'$KVIP').on('connect',()=>console.log('OK'))"
   ​```
3. 终极绕开 DNS：在 compose 的 core 服务里加 `extra_hosts`
   将服务名映射到容器 IP。
```

### 4.3 README.md — 现有 compose 示例不动

第 215/269/328 行的 compose 示例**保持原样**。默认 `REDIS_FAMILY=4` 已修复问题，示例无需引入额外环境变量。

---

## 5. CHANGELOG 改动

**文件**：`CHANGELOG`

在文件最顶部新增 patch 版本块：

```markdown
## [220.0.1] - 2026-05-25
### Fixed
- 修复部分 NAS 系统（飞牛 fnOS、群晖等）Docker 内嵌 DNS 对 IPv6 响应异常导致 redis/kvrocks 客户端持续报 `EAI_AGAIN` 无法连接的问题。redis 客户端 socket 现在默认强制 IPv4，可通过 `REDIS_FAMILY` 环境变量覆盖（0/4/6）。
```

### CHANGELOG 决策

| 项 | 值 | 理由 |
|---|---|---|
| 版本号 | `220.0.1`（patch） | 纯 bug 修复 + 1 个可选环境变量，无破坏性变更，符合 semver patch |
| 日期 | `2026-05-25` | 设计日期；如合并日期延后再调整 |
| 条目数 | 1 条 Fixed | 单一修复，无需拆 Added + Fixed |
| `package.json` version 字段 | **不动** | 留给发版流程（参照最近 commit `ac765ef v220` 是独立操作） |

---

## 6. 文件改动清单

| 文件 | 改动类型 | 行数估计 |
|---|---|---|
| `src/lib/redis-base.db.ts` | 修改 `createRedisClient`：新增 `family` 配置，读 `REDIS_FAMILY` 默认 4 | +6 / −0 |
| `README.md` | 环境变量表新增 1 行 + 新增"故障排查"小节 | +25 左右 |
| `CHANGELOG` | 顶部新增 `[220.0.1]` 块 | +5 左右 |
| `docs/superpowers/specs/2026-05-25-redis-dns-family-fix-design.md` | 本设计文档 | 新文件 |

**不修改**：`kvrocks.db.ts`、`redis.db.ts`、`upstash.db.ts`、`Dockerfile`、`package.json`、`pnpm-lock.yaml`。

---

## 7. 验收与回归

### 7.1 主验收路径（在飞牛 NAS 上）

```bash
# PR 分支上本地 build 镜像
docker build -t moontvplus:fix-dns-test .

# 临时把 compose 的 image 行改为 moontvplus:fix-dns-test
docker compose down
docker compose up -d
sleep 10
```

### 7.2 通过标准

| # | 检查项 | 命令 / 操作 | 期望结果 |
|---|---|---|---|
| 1 | 容器状态 | `docker compose ps` | core 和 kvrocks 都 `Up`，kvrocks 是 `(healthy)` |
| 2 | core 日志无错误 | `docker logs <core> --tail 50` | 看不到 `EAI_AGAIN` 或 `reconnection attempt`；看到 `Kvrocks connected` / `Kvrocks ready` |
| 3 | 浏览器可访问 | 打开 `http://<NAS IP>:31400/login` | 进入登录页，不卡死 |
| 4 | 基本功能 | 登录后搜索、播放、收藏 | 正常工作（kvrocks 读写无报错） |

> 注：`docker exec <core> getent hosts moontvplus-kvrocks` 即使修复后仍可能为空——`getent` 不走 redis 客户端的 lookup 路径。**真正的判据是 core 日志和功能可用性**。

### 7.3 回归矩阵

| 场景 | 是否受影响 | 验证方式 |
|---|---|---|
| 飞牛 NAS + kvrocks（修复目标） | ✅ | 见 7.2 |
| 普通 Linux + redis | 不受影响 | `family=4` 在双栈环境照样解析 A 记录 |
| Cloudflare + upstash | 不受影响 | upstash 走 HTTP REST |
| Vercel + d1/sqlite/postgres | 不受影响 | 不走 redis-base.db.ts |
| 用户显式设 `REDIS_FAMILY=6` | 走 IPv6 | 留给少数需求用户自验 |
| 用户显式设 `REDIS_FAMILY=0` | Node 默认 verbatim | 应急回退选项 |

### 7.4 失败回滚

若 PR 合入后用户报告新问题：

1. revert 这次 commit。
2. 临时缓解：用户设 `REDIS_FAMILY=0` 恢复 Node 默认行为。

---

## 8. 实施步骤（高层概览）

详细步骤交给 `writing-plans` 技能生成的实现计划。这里只列里程碑：

1. ✅ 切到分支 `fix/redis-dns-family-ipv4`
2. ✅ 写 spec 并提交（本文档）
3. ⏳ 实施代码改动（`redis-base.db.ts`）
4. ⏳ 更新 `README.md`（环境变量表 + 故障排查）
5. ⏳ 更新 `CHANGELOG`
6. ⏳ 本地 build 镜像并在飞牛上跑通验收
7. ⏳ 提交 commit（或多个 commit），推送分支
8. ⏳ （可选）向上游 `mtvpls/moontvplus` 提 PR
