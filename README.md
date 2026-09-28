# WorkBuddy 反代（WorkBuddy-Proxy）

把 **WorkBuddy / CodeBuddy 账号池** 变成一个你自己拥有的 **OpenAI 兼容 API 网关**，配一个网页管理面板，并且**支持逐账号出站代理** —— 每个账号可以从独立的出口 IP 出去。

> 这是 [`HanawaBanana/workbuddy2api`](https://github.com/HanawaBanana/workbuddy2api)（网关）
> 与 [`yys9253462-gif/workbuddy-manager`](https://github.com/yys9253462-gif/workbuddy-manager)（面板）
> 的**整合 + 出站代理补丁**版本。两个上游都是 MIT 许可。

---

## 目录

- [它做了什么](#它做了什么)
- [快速开始](#快速开始)
- [终端菜单](#终端菜单)
- [命令行用法](#命令行用法)
- [逐账号出站代理（核心功能）](#逐账号出站代理核心功能)
  - [面板里配置](#面板里配置)
  - [终端里配置](#终端里配置)
  - [直接改文件](#直接改文件)
  - [怎么验证生效](#怎么验证生效)
  - [代理格式与常见坑](#代理格式与常见坑)
- [客户端接入](#客户端接入)
- [域名与 HTTPS](#域名与-https)
- [目录结构](#目录结构)
- [Docker 手动部署](#docker-手动部署)
- [架构](#架构)
- [本次相对上游改了什么](#本次相对上游改了什么)
- [更新](#更新)
- [卸载](#卸载)
- [故障排查](#故障排查)
- [安全须知](#安全须知)
- [许可与致谢](#许可与致谢)

---

## 它做了什么

```
你的客户端（Cherry Studio / NextChat / Cursor / 任何 OpenAI 兼容工具）
        │  Bearer: wbk_xxx  （你在面板里建的密钥）
        ▼
┌──────────────────────────────┐
│  workbuddy-manager   :7864   │  网页面板
│  · 扫码纳管账号（CN / 国际版分区）│  · 建/删 API 密钥
│  · 查看额度、任务日志            │  · 逐账号配出站代理  ← 本仓库新增
└──────────────┬───────────────┘
               │  http://workbuddy2api:7863
               ▼
┌──────────────────────────────┐
│  workbuddy2api       :7863   │  OpenAI 兼容网关
│  · 账号池调度 / 健康检查 / 熔断  │
│  · 六大定时积分任务             │
│  · 逐账号 HTTP/SOCKS5 出站  ← 本仓库新增
└──────────────┬───────────────┘
               │  按账号身份 + 该账号配置的代理
               ▼
         WorkBuddy 上游
```

两个容器都只绑 `127.0.0.1`。要外网访问就绑域名（脚本自动配反代 + 签证书）。

---

## 快速开始

在一台 Debian 12 / Ubuntu 22+ 的服务器上，以 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/firstwxx1/WorkBuddy-Proxy/main/workbuddy-deploy.sh | sudo bash
```

交互终端里会直接进**菜单**。想直接装：

```bash
# 仅本机访问
curl -fsSL https://raw.githubusercontent.com/firstwxx1/WorkBuddy-Proxy/main/workbuddy-deploy.sh \
  | sudo bash -s -- install --auto

# 装完直接绑域名（DNS 需已指向本机）
curl -fsSL https://raw.githubusercontent.com/firstwxx1/WorkBuddy-Proxy/main/workbuddy-deploy.sh \
  | sudo bash -s -- install --domain wb.example.com --auto
```

不想管道执行（推荐，能看清脚本）：先下载再跑。

```bash
wget -O workbuddy-deploy.sh https://raw.githubusercontent.com/firstwxx1/WorkBuddy-Proxy/main/workbuddy-deploy.sh
chmod +x workbuddy-deploy.sh
sudo ./workbuddy-deploy.sh
```

**前置条件**

| 项 | 要求 |
|---|---|
| 系统 | Debian 12 / Ubuntu 22.04+（脚本用 apt 装依赖） |
| 权限 | root |
| Docker | 无需预装，脚本自动装 |
| 内存 | ≥ 1 GB（跑起来占 150–250 MB，构建时更高） |
| 磁盘 | 根分区可用 ≥ 4 GB（源码构建 + 镜像 + 数据） |
| 网络 | 能访问 `github.com`（拉源码）与 `get.docker.com`（首次装 Docker） |

**首次部署完成后**

1. 加账号：SSH 隧道进去，浏览器打开面板，扫码。
   ```bash
   ssh -L 7864:127.0.0.1:7864 root@你的服务器IP
   # 本机浏览器打开 http://localhost:7864
   ```
2. 建密钥：面板「密钥」页 → 新建 → 拿到 `wbk_...`
3. 配代理（可选）：面板「账号」页每行的地球按钮，或终端菜单 `7`
4. 绑域名（可选）：终端菜单 `4`

凭据文件在 `/opt/wb2api/.credentials`（`0600`），里面有上游 `api_key`、面板管理员密码、对外 `MANAGER_API_KEY`。

---

## 终端菜单

不带参数、且是交互终端时，脚本进菜单：

```
  WorkBuddy 反代 · 一键部署面板
  仓库 https://github.com/firstwxx1/WorkBuddy-Proxy.git

    1) 安装              首次部署 / 补装（源码构建 + 起容器）
    2) 更新              拉最新源码 + 重建镜像 + 重启
    3) 卸载              停容器 + 删镜像 + 删目录
    4) 绑定域名          写反代配置（Nginx 优先，无则 Caddy + 签证书）
    5) 删除域名          移除反代配置并重载
    6) 状态              容器 / 端口 / 健康 / 代理总览
    7) 代理              逐账号配置出站 SOCKS5 / HTTP 出口
    8) 凭据              显示 api_key / 面板密码 / 对外密钥
    0) 退出
```

也可以让脚本菜单**开机就带**（放进 `~/.bashrc` 或挂成 `wb` 命令）：

```bash
cat >> /root/.bashrc <<'EOF'
alias wb='/opt/wb2api/../workbuddy-deploy.sh 2>/dev/null || bash <(curl -fsSL https://raw.githubusercontent.com/firstwxx1/WorkBuddy-Proxy/main/workbuddy-deploy.sh)'
EOF
```

> 更规范的做法：把脚本拷到 `/root/workbuddy-deploy.sh`，然后 `ln -s /root/workbuddy-deploy.sh /usr/local/bin/wb`。

---

## 命令行用法

```
bash workbuddy-deploy.sh [选项 | 子命令]

子命令:
  install                安装（首次部署 / 补装）
  update                 更新（拉最新源码 + 重建镜像 + 重启）
  uninstall              卸载（交互询问是否保留数据）
  bind-domain <域名>     绑定域名
  unbind-domain <域名>   删除域名反代配置
  status                 查看容器 / 端口 / 健康 / 代理
  credentials            显示凭据文件
  menu                   强制显示菜单

选项:
  -d, --domain <域名>       面板 / 对外域名
      --api-domain <域名>   独立 API 域名（只暴露 /v1）
  -p, --password <密码>     面板管理员密码（≥8 位）
  -a, --auto                全自动，跳过交互
      --base-dir <目录>     安装根目录（默认 /opt/wb2api）
  -h, --help                帮助
```

常用例子：

```bash
sudo ./workbuddy-deploy.sh                                # 菜单
sudo ./workbuddy-deploy.sh status                         # 看状态
sudo ./workbuddy-deploy.sh bind-domain wb.example.com     # 绑域名
sudo ./workbuddy-deploy.sh unbind-domain wb.example.com   # 删域名
sudo ./workbuddy-deploy.sh update                         # 更新
sudo ./workbuddy-deploy.sh uninstall                      # 卸载
```

可用环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `REPO_URL` | `https://github.com/firstwxx1/WorkBuddy-Proxy.git` | 源码仓库 |
| `REPO_REF` | `main` | 分支 / tag |
| `BASE_DIR` | `/opt/wb2api` | 安装根目录 |
| `WB2API_IMAGE` | `workbuddy2api:proxy-patched` | 网关镜像名（源码构建） |
| `MANAGER_IMAGE` | `workbuddy-manager:proxy-patched` | 面板镜像名（源码构建） |
| `WB2API_PORT` | `7863` | 网关宿主侧端口 |
| `MANAGER_PORT` | `7864` | 面板宿主侧端口 |
| `API_KEY` | 随机 | 上游 `api_key` |
| `ADMIN_PASSWORD` | 随机 | 面板初始密码 |
| `DOMAIN` / `API_DOMAIN` | 空 | 域名 |
| `SYNC_CODE` | `1` | `0` = 跳过代码同步，保留本地改动 |
| `NONINTERACTIVE` | `0` | `1` = 跳过交互向导 |

---

## 逐账号出站代理（核心功能）

这是本仓库相对上游的主要增强。**每个账号可以从不同的出口 IP 出去。**

网关侧：`internal/auth/auth.go` 的 `Auth` 结构体新增 `ProxyURL`；`internal/upstream/transport.go`
按代理串缓存 `*http.Transport`（`tr.Proxy = http.ProxyURL(...)`，**不走** `ProxyFromEnvironment`）；
`internal/upstream/client.go` 每次请求按账号取对应 transport。

面板侧：`accounts.py` 新增 `PUT /api/accounts/{filename}/proxy`；`wb2api.py` 新增
`set_account_proxy()`，写入 `auths/*.json` 的顶层 `proxy` 键。

**热加载**：网关的 `internal/pool/watch.go` 每 5 秒轮询 `auths/`，检测到变化就整体替换
`*auth.Auth`（`e.a = a`），所以 `ProxyURL` **无需重启容器**即生效。日志会打：

```
[watch] auths 目录变化：账号数保持 N（已热加载凭证更新）
```

### 面板里配置

**账号** 页 → 目标账号那一行的 **地球按钮**（🌐）→ 填代理地址 → 保存。

- 输入框留空 = **清除代理**，改回直连
- 保存后提示「已触发重载」或「上游每 5 秒自动热加载，稍后生效」
- 格式化建议见弹窗里的提示，以及下方的[常见坑](#代理格式与常见坑)

### 终端里配置

```bash
sudo ./workbuddy-deploy.sh          # 菜单 → 7) 代理
```

或者：

```
  1) 查看账号与代理总览
  2) 设置 / 清除某账号的代理
  3) 返回主菜单
```

第 2 项会先列出所有账号的 UID / 当前代理 / 昵称，然后让你输入账号（支持 uid 前缀或文件名），
再输入代理地址。留空即清除。

总览长这样：

```
  26d714e4      socks5://proxy:***@172.82.74.159:1080   Nick
  3614c6c7      直连
  ...
  共 9 个账号；配了 proxy 的走该出口，未配的直连。
```

### 直接改文件

`auths/` 下每个账号一个 JSON，顶层加 `proxy` 键即可：

```bash
ls /opt/wb2api/workbuddy2api/auths/
# 26d714e4-....json  ...

python3 - <<'PY'
import json
p = "/opt/wb2api/workbuddy2api/auths/26d714e4-....json"
d = json.load(open(p, encoding="utf-8"))
d["proxy"] = "socks5://proxy:Sx2026%23QzWmR8tL4pN@172.82.74.159:1080"
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
```

> 改完记得 `chown 10001:10001` 那个文件（容器内 app 用户是 uid 10001）：
> ```bash
> chown 10001:10001 /opt/wb2api/workbuddy2api/auths/*.json
> ```

更省事的办法：`/opt/wb2api/workbuddy2api/` 下有个 `acct.sh` 可用来查看/补跑任务，
但代理这块以面板或本脚本菜单为准（`acct.sh` 是上游工具，不含代理子命令）。

### 怎么验证生效

**方法 1：看网关日志**

```bash
docker logs --tail 50 workbuddy2api
# 期望能看到：
#   [watch] auths 目录变化：账号数保持 9（已热加载凭证更新）
```

**方法 2：从配置的代理出口探一次自己的 IP**

用系统 `curl` 直接走那条代理，确认出口 IP 就是你配的那台：

```bash
curl -sS --max-time 10 --socks5-hostname proxy:Sx2026%23QzWmR8tL4pN@172.82.74.159:1080 \
  http://ip-api.com/json/?fields=query,country,regionName,city,isp
```

```json
{"query":"172.82.74.159","country":"United States","regionName":"New York","city":"Jamestown","isp":"HostRush"}
```

出口 `query` 字段等于你代理的 IP，就说明这条代理通。再用**错误的密码**试一次，
应当被拒绝（403 / 认证失败），用来确认「确实是走代理、不是悄悄直连」：

```bash
curl -sS --max-time 10 --socks5-hostname proxy:WRONGPASS@172.82.74.159:1080 \
  http://ip-api.com/json/ ; echo "exit=$?"
```

**方法 3：看上游识别到的客户端 IP**

网关把该账号的请求经代理发出，上游看到的就是代理出口 IP。多账号配置不同代理时，
在面板的账号详情里能看到每个账号最近一次调用，或者直接对着两个账号压并发，
看上游侧的地域是否分散。

**方法 4：确认容器没有绕过代理**

如果代理不生效，最常见原因是认证失败（密码里 `#` 没转义）而被静默直连。
对照方法 2 的错误密码测试——如果错密码也通，说明代理串没被正确使用，检查 JSON 里
`proxy` 键是否在**顶层**（不是嵌套在 `credentials` 之类里面）。

### 代理格式与常见坑

```
scheme://[user[:password]@]host:port
```

支持的 scheme：

| scheme | 说明 |
|---|---|
| `socks5` | SOCKS5，DNS 在本地解析 |
| `socks5h` | SOCKS5，DNS 交给代理解析（**推荐**，避免本地 DNS 泄漏） |
| `http` | HTTP CONNECT 代理 |
| `https` | HTTPS 代理 |

**坑 1 — 密码里的 `#` 必须写成 `%23`。**
`#` 是 URL 的 fragment 分隔符，不转义的话后面全部被丢掉，代理认证必然失败。

```
密码 Sx2026#QzWmR8tL4pN
✗ socks5://proxy:Sx2026#QzWmR8tL4pN@1.2.3.4:1080
✓ socks5://proxy:Sx2026%23QzWmR8tL4pN@1.2.3.4:1080
```

**坑 2 — 别双重编码。**
`%2523` 会被解码成字面量 `%`，密码就错了。**只编码一次。**

**坑 3 — 密码里的 `@`、`:`、`/`、`?` 也要编码。**

| 字符 | 编码 |
|---|---|
| `#` | `%23` |
| `@` | `%40` |
| `:` | `%3A` |
| `/` | `%2F` |
| `?` | `%3F` |

**坑 4 — 认证失败是静默的。**
SOCKS5 握手失败时上游只会报「无可用账号」或超时，不会明说「代理密码错」。
所以**每次配完一定用方法 2 验证一遍**。

---

## 客户端接入

面板「密钥」页建一把 `wbk_...`，然后在任何 OpenAI 兼容客户端里填：

| 字段 | 值 |
|---|---|
| 接口地址 / Base URL | `https://你的域名/v1` |
| API Key | `wbk_...` |
| 模型名称 | 见下方 |

**模型名必须带分区前缀，且全小写。**

- 国内版：`cn:` 前缀 → `cn:kimi-k3`、`cn:deepseek-v4.1-flash`、`cn:auto`
- 国际版：`global:` 前缀 → `global:...`

```
✓ cn:kimi-k3
✗ cn:Kimi-K3        ← 大写会失败
✗ kimi-k3           ← 缺前缀会失败
```

看当前密钥能调哪些模型：

```bash
curl -sS https://你的域名/v1/models -H "Authorization: Bearer wbk_..." | python3 -m json.tool
```

**密钥有分区（realm）。** 面板里建密钥时会绑定 `cn` 或 `global`：

- `cn` 密钥调 `global:` 模型 → `400 realm_mismatch`
- `global` 密钥调 `cn:` 模型 → `400 realm_mismatch`

两种模型都要就建两把密钥。用 `cn:auto` / `global:auto` 可以在各自分区内自动挑可用模型。

> 客户端报「连接失败 / 模型服务拒绝了测试请求」时，先查两件事：
> ① 模型名有没有前缀、是不是全小写；② 密钥分区与模型前缀是否一致。
> 网关在上游拿不到账号时返回 503 `no_healthy_account`，**这个错误也会被
> 模型名写错触发**，容易误导——别只看这一句。

---

## 域名与 HTTPS

```bash
sudo ./workbuddy-deploy.sh bind-domain wb.example.com
```

脚本会：

1. 检测域名 A 记录是否指向本机公网 IP（不一致会提示该加哪条记录，并等你复检）
2. **已有 Nginx**（含科技Lion环境）→ 写 `/etc/nginx/conf.d/<域名>.conf`，热重载
3. **没有 Nginx** → 自动装 Caddy（官方 apt 源），写 `/etc/caddy/conf.d/<域名>.caddy`，
   自动签 Let's Encrypt 证书
4. 反代配置已针对 AI 流式输出强化：`proxy_buffering off` + `X-Accel-Buffering no`
   + `proxy_read_timeout 600s`，SSE 不会被缓冲掉

绑定独立 API 域名（只暴露 `/v1`，不暴露面板）：

```bash
sudo ./workbuddy-deploy.sh bind-domain wb.example.com --api-domain api.example.com
```

删除：

```bash
sudo ./workbuddy-deploy.sh unbind-domain wb.example.com
```

> **Cloudflare 用户注意**：绑域名前先把橙云关掉（DNS only），否则证书签不下来。

---

## 目录结构

```
WorkBuddy-Proxy/
├── README.md                  本文档
├── workbuddy-deploy.sh        一键部署脚本（带终端菜单）
├── kejilion/
│   └── workbuddy2api.conf     科技Lion（kejilion.sh）应用配置
├── workbuddy2api/             网关源码（Go，含出站代理补丁）
│   ├── internal/auth/         Auth.ProxyURL + 读写 auths/*.json
│   ├── internal/upstream/     transport 池 + 按账号取 client
│   ├── internal/pool/         watch.go：5 秒热加载 auths/
│   ├── cmd/                   wb2api 主程序 + acct 运维工具
│   ├── Dockerfile
│   └── config.example.json
└── workbuddy-manager/         面板源码（Python FastAPI + Next.js）
    ├── server/                后端
    │   ├── routers/accounts.py    PUT /api/accounts/{f}/proxy
    │   └── services/wb2api.py     set_account_proxy()
    ├── web/                   前端（Next.js，静态导出到 web/out）
    │   ├── components/common/accounts/AccountProxyDialog.tsx
    │   └── lib/i18n/locales/    zh-CN/zh-TW/en/ja/ko
    └── Dockerfile
```

运行时目录（**不在仓库里**，脚本创建）：

```
/opt/wb2api/
├── .credentials               api_key / 面板密码 / 对外密钥（0600）
├── src/                       本仓库的 git clone
├── workbuddy2api/
│   ├── config.json            api_key、定时任务、admin 端点
│   ├── auths/<uid>.json       账号凭证 + proxy  ← 逐账号代理存这里
│   ├── data/                  状态、审计日志
│   ├── docker-compose.yml
│   └── acct.sh                运维工具
└── workbuddy-manager/
    ├── data/                  SQLite、users.json
    └── docker-compose.yml
```

---

## Docker 手动部署

不用脚本，手动来。

**1. 网关**

```bash
mkdir -p /opt/wb2api/workbuddy2api/auths /opt/wb2api/workbuddy2api/data
cd /opt/wb2api/workbuddy2api
cp /path/to/WorkBuddy-Proxy/workbuddy2api/config.example.json config.json
# 编辑 config.json：至少改 api_key
```

同目录放 `docker-compose.yml`：

```yaml
name: wb2api-up
services:
  wb2api:
    build: { context: ., dockerfile: Dockerfile }
    image: workbuddy2api:proxy-patched
    container_name: workbuddy2api
    restart: unless-stopped
    mem_limit: 256m
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
    environment: [ "TZ=Asia/Shanghai" ]
    ports: [ "127.0.0.1:7863:7863" ]
    volumes:
      - ./auths:/app/auths
      - ./data:/app/data
      - ./config.json:/app/config.json:ro
networks:
  default: { name: wbnet, external: true }
```

**2. 面板**

```bash
mkdir -p /opt/wb2api/workbuddy-manager/data
cd /opt/wb2api/workbuddy-manager
```

```yaml
name: wb2api-mgr
services:
  workbuddy-manager:
    build: { context: ., dockerfile: Dockerfile }
    image: workbuddy-manager:proxy-patched
    container_name: workbuddy-manager
    restart: unless-stopped
    mem_limit: 320m
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
    environment:
      TZ: Asia/Shanghai
      WB_ADMIN_PASSWORD: "换成你的强密码"
      WB2API_BASE: http://workbuddy2api:7863
      WB2API_KEY: "与网关 config.json 的 api_key 一致"
      WB2API_MODE: docker
      WB2API_CONTAINER: workbuddy2api
      WB_AUTH_DIR: /opt/workbuddy2api/auths
      WB_UPSTREAM_CONFIG: /opt/workbuddy2api/config.json
      WB_DATA_DIR: /app/data
      WB_SECURE_COOKIE: auto
      WB_TRUST_PROXY: "1"
      WB_ENABLE_DOCS: "0"
    ports: [ "127.0.0.1:7864:7864" ]
    volumes:
      - ./data:/app/data
      - ../workbuddy2api:/opt/workbuddy2api
      - /var/run/docker.sock:/var/run/docker.sock
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:7864/api/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
networks:
  default: { name: wbnet, external: true }
```

**3. 起**

```bash
docker network create wbnet
chown -R 10001:10001 /opt/wb2api/workbuddy2api/auths /opt/wb2api/workbuddy2api/data \
                      /opt/wb2api/workbuddy-manager/data
docker compose -f /opt/wb2api/workbuddy2api/docker-compose.yml build && \
docker compose -f /opt/wb2api/workbuddy2api/docker-compose.yml up -d
docker compose -f /opt/wb2api/workbuddy-manager/docker-compose.yml build && \
docker compose -f /opt/wb2api/workbuddy-manager/docker-compose.yml up -d

curl -sS http://127.0.0.1:7863/healthz
curl -sS http://127.0.0.1:7864/api/healthz
```

---

## 架构

| 组件 | 容器 | 宿主端口 | 说明 |
|---|---|---|---|
| 网关 | `workbuddy2api` | `127.0.0.1:7863` | Go，OpenAI 兼容，账号池调度 |
| 面板 | `workbuddy-manager` | `127.0.0.1:7864` | Python FastAPI + Next.js 静态导出 |
| 共享网络 | `wbnet` | — | 面板通过 `http://workbuddy2api:7863` 访问网关 |

关键端点：

| 端点 | 容器 | 说明 |
|---|---|---|
| `GET /healthz` | 网关 | `{"healthy":N,...,"total":N}`；无账号时 503 |
| `GET /v1/models` | 网关 | 需要 `Bearer`，按密钥分区过滤 |
| `POST /v1/chat/completions` | 网关 | 同上，支持 SSE 流式 |
| `POST /admin/tasks/{name}/run` | 网关 | 手动补跑定时任务 |
| `GET /api/healthz` | 面板 | `{"ok":true}` |
| `POST /api/login` | 面板 | **返回 cookie session，不是 Bearer token** |
| `PUT /api/accounts/{filename}/proxy` | 面板 | 设置/清除该账号出站代理 ← 本仓库新增 |

---

## 本次相对上游改了什么

**网关（workbuddy2api）**

| 文件 | 改动 |
|---|---|
| `internal/auth/auth.go` | `Auth` 新增 `ProxyURL string`；`Parse()` 读顶层 `proxy`；`SaveAtomic()` 仅在非空时写回 |
| `internal/upstream/transport.go` | 新增 `newTransportWithProxy(*url.URL)`，显式 `tr.Proxy = http.ProxyURL(...)`；新增按代理串缓存的 `transportPool` |
| `internal/upstream/client.go` | `Client.proxies`；`transportFor(a)` / `httpClientFor(a)` / `chatClientFor(a)` 按账号取 transport；`doJSON(req, a)` 与 `ChatStreamContext` 全程按账号走代理 |

**面板（workbuddy-manager）**

| 文件 | 改动 |
|---|---|
| `server/services/wb2api.py` | 新增 `set_account_proxy()`；`list_auth_accounts()` 回传顶层 `proxy`；代理串校验（scheme ∈ http/https/socks5/socks5h + host 非空） |
| `server/routers/accounts.py` | 新增 `PUT /accounts/{filename}/proxy`；写审计日志（`account_set_proxy`），提示是否已触发重载 |
| `web/lib/types.ts` | `Account.proxy?: string` |
| `web/lib/api.ts` | `accountApi.setProxy(file, proxy, reload = true)` |
| `web/components/common/accounts/AccountProxyDialog.tsx` | 新增对话框（含 `%23` 提示） |
| `web/app/(main)/accounts/page.tsx` | 行内地球按钮 + 对话框挂载 |
| `web/lib/i18n/locales/{zh-CN,zh-TW,en,ja,ko}.json` | 11 个 `accounts.proxy*` 键 |

**部署**

- `workbuddy-deploy.sh` 全新编写：加菜单（安装/更新/卸载/绑定域名/删除域名/状态/代理/凭据），
  源码从**本仓库**克隆并**本地构建镜像**（不再依赖上游预构建镜像），
  新增代理管理菜单与 `status` 里的代理总览。
- `kejilion/workbuddy2api.conf`：可直接放进 `/root/apps/` 由 `kejilion.sh` 调用。

---

## 更新

```bash
sudo ./workbuddy-deploy.sh update
```

行为：`git fetch + reset --hard` 到 `REPO_REF` → 重新构建两个镜像 → `up -d`。

`config.json` / `auths/` / `data/` 都是非跟踪文件，**不会被覆盖**（账号和代理配置安全）。

如果你改过源码想保留，用 `SYNC_CODE=0`：

```bash
SYNC_CODE=0 sudo ./workbuddy-deploy.sh update
```

---

## 卸载

```bash
sudo ./workbuddy-deploy.sh uninstall
```

会：停容器 → 删镜像 → 删共享网络（无成员时）→
清理指向本服务端口的悬空反代配置并重载 → 删 `/opt/wb2api`。

**交互时会问是否保留数据**：

```
  是否保留数据目录 auths/ data/（y = 保留并备份到 /opt/wb2api.data-backup）
```

选 `y` 会把账号凭证和面板数据库拷到 `/opt/wb2api.data-backup/`，重装后可以搬回去。

---

## 故障排查

**面板打不开**

面板只绑 `127.0.0.1`，这是设计如此。

```bash
ssh -L 7864:127.0.0.1:7864 root@你的服务器IP
# 本机浏览器 http://localhost:7864
```

想正经外网访问就绑域名（菜单 `4`）。

**`docker ps` 里网关显示 `(unhealthy)`**

没账号时 `/healthz` 如实返回 503，Docker 就标 unhealthy。扫码加上账号后自动转 healthy。**不是故障。**

**客户端报「模型服务拒绝了测试请求」**

按顺序查：

```bash
# 1. 密钥是否有效、能看到哪些模型
curl -sS https://你的域名/v1/models -H "Authorization: Bearer wbk_..."
```

2. 模型名有没有 `cn:` / `global:` 前缀，是不是**全小写**
3. 密钥分区与模型前缀是否一致（`cn` 密钥不能调 `global:` 模型）
4. 网关有没有可用账号：
   ```bash
   curl -sS http://127.0.0.1:7863/healthz
   # healthy 为 0 时先加账号
   ```

**代理配了但不生效**

九成是密码没转义。见[代理格式与常见坑](#代理格式与常见坑)，然后用
[方法 2](#怎么验证生效) 验证。

**端口被占**

```bash
ss -tlnp | grep -E ':(7863|7864)'
```

换端口重跑：

```bash
WB2API_PORT=8863 MANAGER_PORT=8864 sudo ./workbuddy-deploy.sh install
```

**证书签不下来**

1. 域名 A 记录是否指向本机公网 IP
2. 安全组 / 防火墙是否放行 80、443
3. Cloudflare 橙云是否关掉
4. 补齐后重新 `bind-domain`，已装的部分不会重装

**容器被 OOM kill**

两个容器已限 256m / 320m。升级用 `update`（本机构建需要更多内存），
**不要在面板里触发本机构建**。1GB 机器构建时先停掉无关服务。

**看日志**

```bash
docker logs -f workbuddy2api
docker logs -f workbuddy-manager
```

---

## 安全须知

- **面板容器挂载了 `/var/run/docker.sock`**，并且持有账号明文凭证——等于这台机器的高权限入口。
  只绑 `127.0.0.1`、走 HTTPS、用强密码，**不要把 7864 直接暴露到公网**。
- 凭据文件 `/opt/wb2api/.credentials` 权限 `0600`，root 可读，请自行妥善保管。
- 本仓库不含任何预置密钥、账号凭证或域名。`config.json` 里的 `api_key` 是占位符，
  面板 compose 从环境变量读密码，安装时才生成。
- 请遵守你所使用的对应服务的条款，仅用于纳管**你自己的**账号。

---

## 许可与致谢

| 项目 | 许可 |
|---|---|
| [HanawaBanana/workbuddy2api](https://github.com/HanawaBanana/workbuddy2api) | MIT |
| [yys9253462-gif/workbuddy-manager](https://github.com/yys9253462-gif/workbuddy-manager) | MIT |
| 本仓库（整合 + 出站代理补丁 + 部署脚本） | MIT |

特别致谢 **[科技Lion Linux 工具箱](https://kejilion.sh)** —— 优秀的建站反代与运维生态，
本脚本的 Nginx / Caddy 双路反代与域名状态文件约定均沿用其思路。
