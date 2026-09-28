#!/usr/bin/env bash
# =============================================================================
#  WorkBuddy 反代 · 一键部署面板（WorkBuddy-Proxy）
#
#  做什么：在自有服务器上跑起「WorkBuddy 账号池反向代理 + 管理面板」，
#          支持**逐账号出站代理**（每个账号走独立 SOCKS5/HTTP 出口 IP），
#          让各种 OpenAI 兼容客户端用一个自己的 API Key 调用。
#
#  一键启动终端面板：
#      curl -fsSL https://raw.githubusercontent.com/firstwxx1/WorkBuddy-Proxy/main/workbuddy-deploy.sh | sudo bash
#    （或先下载再执行：bash workbuddy-deploy.sh）
#
#  菜单功能（与科技Lion原版对齐，全部在本脚本内完成）：
#      1) 安装           首次部署 / 补装
#      2) 更新           重跑部署，拉最新源码 + 重建镜像
#      3) 卸载           停容器 + 删镜像 + 删目录（可选保留数据）
#      4) 绑定域名       写反代配置（Nginx 优先，无则装 Caddy + 自动签证书）
#      5) 删除域名       移除反代配置并重载（不影响容器与数据）
#      6) 状态           容器 / 端口 / 健康检查 / 代理总览
#      7) 代理           逐账号配置出站代理
#      8) 凭据           显示 .credentials（密钥 / 面板密码）
#      0) 退出
#
#  命令行参数（供 CI / 自动化；等价于同名环境变量）：
#      -d, --domain <域名>       面板 / 对外域名（DNS 需先指向本机）
#          --api-domain <域名>   独立 API 域名（只暴露 /v1，不含面板）
#      -p, --password <密码>     面板管理员密码（≥8 位）
#      -a, --auto                跳过交互向导，用参数 / 默认值直接开跑
#          --base-dir <目录>     安装根目录（默认 /opt/wb2api）
#      -h, --help                显示本帮助并退出
#      子命令：install / update / uninstall / bind-domain <域名> / unbind-domain <域名>
#              status / credentials / menu
#
#  可用环境变量覆盖默认值：
#      REPO_URL        源码仓库        默认 https://github.com/firstwxx1/WorkBuddy-Proxy.git
#      REPO_REF        分支 / tag      默认 main
#      BASE_DIR        安装根目录      **无默认值**。install 未指定时用 /opt/wb2api；
#                                      uninstall / update 未指定时会去读 /etc/wb-proxy-install.conf
#                                      或探测本机实例，绝不复用某个硬编码默认路径。
#      WB2API_IMAGE    网关镜像名      默认 workbuddy2api:proxy-patched
#      MANAGER_IMAGE   面板镜像名      默认 workbuddy-manager:proxy-patched
#      API_KEY         上游 api_key    默认随机生成
#      ADMIN_PASSWORD  面板初始密码    默认随机生成
#      DOMAIN          面板 / 对外域名（DNS 需已解析到本机）
#      API_DOMAIN      可选：独立 API 域名，只暴露 /v1（不暴露面板）
#      SYNC_CODE=0     跳过代码同步（保留你在代码目录里的本地改动）
#      NONINTERACTIVE=1 跳过交互向导
#
#  前置要求：
#      · Linux 服务器（Debian 12 / Ubuntu 22+ 验证通过），root 执行
#      · 已装 Docker + compose 插件（没装脚本会自动装）
#      · 内存 ≥ 1GB、根分区可用 ≥ 4GB（构建镜像需要）
#
#  安全须知：
#      · 面板容器挂载 docker.sock 且持有账号明文凭证，等于本机高权限入口。
#        请只绑 127.0.0.1 + 走 HTTPS + 用强密码，不要把面板端口暴露到公网。
#      · 凭据文件 <BASE_DIR>/.credentials 权限 0600、root 可读，请妥善保管。
#
#  上游与许可（本仓库是以下两个开源项目的**反代整合 + 出站代理补丁**版本）：
#      · 网关 workbuddy2api     https://github.com/HanawaBanana/workbuddy2api (MIT)
#      · 面板 workbuddy-manager https://github.com/yys9253462-gif/workbuddy-manager (MIT)
#      · 致敬 科技Lion Linux 工具箱 (https://kejilion.sh) 优秀的建站反代与运维生态
#      本仓库可按 MIT 许可自由使用 / 修改 / 再分发。
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------- 默认值
REPO_URL="${REPO_URL:-https://github.com/firstwxx1/WorkBuddy-Proxy.git}"
REPO_REF="${REPO_REF:-main}"

# ---------------------------------------------------------------- BASE_DIR 解析
#
# ⚠️ 这里曾经是 `BASE_DIR="${BASE_DIR:-/opt/wb2api}"` —— 本次生产事故的根源。
#   uninstall 会 `rm -rf $BASE_DIR`，而带默认值的变量意味着：
#   只要环境变量没传到（例如 `NONINTERACTIVE=1 bash x.sh uninstall` 手滑漏了前缀），
#   BASE_DIR 就会静默回落到 /opt/wb2api，把**另一套实例**当成自己删掉。
#
# 新规则（顺序固定，不存在「静默回落」）：
#   1) --base-dir / 环境变量显式给了 → 用它（最高优先）
#   2) 否则读 /etc/wb-proxy-install.conf（安装时落下的全局注册表）
#   3) 否则探测本机已知实例；恰好一个 → 用它
#   4) 都没有 → 报错退出，让用户显式指定
# 注意：第 3 步只用于「已装实例」场景；全新安装本机无实例时会落入第 4 步，
# 那时由 install 分支在参数解析后自行回落默认目录。
WB_INSTALL_REGISTRY="${WB_INSTALL_REGISTRY:-/etc/wb-proxy-install.conf}"
DEFAULT_BASE_DIR="/opt/wb2api"     # 仅 install 使用，绝不参与卸载路径推导

# ⚠️ 这两行必须在**参数解析之前**执行。
#   解析器会写 BASE_DIR（--base-dir）和 ACTION（子命令），
#   这里要捕获的是「用户到底显式给了没」和「这次要干什么」这两个原始事实。
BASE_DIR_EXPLICIT=0
[ -n "${BASE_DIR:-}" ] && BASE_DIR_EXPLICIT=1
ACTION=""

discover_base_dir() {
  # 已显式指定 → 直接用
  [ "$BASE_DIR_EXPLICIT" = "1" ] && return 0

  # 全局注册表
  if [ -f "$WB_INSTALL_REGISTRY" ]; then
    local r
    r="$(sed -n 's/^BASE_DIR=//p' "$WB_INSTALL_REGISTRY" | head -1)"
    if [ -n "$r" ]; then BASE_DIR="$r"; return 0; fi
  fi

  # 探测本机已知实例：认「哨兵文件」，不认目录名。
  # 哨兵存在即视为本脚本装过的实例 —— 不再额外要求 compose 文件，
  # 因为装到一半失败的实例也需要能被 uninstall 收拾干净。
  local found=() parent d
  for parent in /opt /home /root /srv /data /mnt /usr/local; do
    [ -d "$parent" ] || continue
    for d in "$parent"/*; do
      [ -d "$d" ] || continue
      [ -L "$d" ] && continue
      if [ -f "$d/.wb-proxy-install" ]; then
        found+=("$d")
      fi
    done
  done
  if [ "${#found[@]}" -eq 1 ]; then
    BASE_DIR="${found[0]}"
    return 0
  fi
  if [ "${#found[@]}" -gt 1 ]; then
    printf '\n  \033[31m✗ 本机探测到多个已装实例，无法自动判断要操作哪一个：\033[0m\n' >&2
    local x; for x in "${found[@]}"; do printf '      %s\n' "$x" >&2; done
    printf '  请用 --base-dir 显式指定。\n\n' >&2
    exit 1
  fi

  # 无实例：仅 install（或裸跑进菜单）可回落默认目录
  case "${ACTION:-}" in
    install|"") BASE_DIR="$DEFAULT_BASE_DIR"; return 0 ;;
  esac
  printf '\n  \033[31m✗ 未指定安装目录，且本机没有已装实例。\033[0m\n' >&2
  printf '  请显式指定：--base-dir /你的/目录\n' >&2
  printf '  （查看帮助：bash %s --help）\n\n' "$(basename "$0")" >&2
  exit 1
}

# 下面这行只是占位；解析完参数后会按最终 BASE_DIR 重算。
BASE_DIR="${BASE_DIR:-}"
UP_DIR=""; MG_DIR=""; SRC_DIR=""

WB2API_IMAGE="${WB2API_IMAGE:-workbuddy2api:proxy-patched}"
MANAGER_IMAGE="${MANAGER_IMAGE:-workbuddy-manager:proxy-patched}"

# 前端构建参数（面板 Dockerfile 用）
NPM_REGISTRY="${NPM_REGISTRY:-}"                  # 留空 = 官方源，失败自动降级 npmmirror
NODE_MAX_OLD_SPACE="${NODE_MAX_OLD_SPACE:-3072}"  # next build 的 V8 堆上限（MB）

# 容器内 app 用户 uid，卷属主必须一致
UP_UID="${UP_UID:-10001}"

WB2API_PORT="${WB2API_PORT:-7863}"     # 宿主侧网关端口（容器内固定 7863）
MANAGER_PORT="${MANAGER_PORT:-7864}"   # 宿主侧面板端口（容器内固定 7864）
UP_NAME="${UP_NAME:-workbuddy2api}"
MG_NAME="${MG_NAME:-workbuddy-manager}"
NET_NAME="${NET_NAME:-wbnet}"
# compose 项目名必须显式唯一：compose 按目录名识别项目，
# 两个实例目录同名时对其中一个 down 会连另一个一起删。
# ⚠️ 不设默认值 —— 必须由 BASE_DIR 推导或在解析后由用户显式给出，
#    否则两个实例可能撞到同一个 compose 项目名，down 一个删两个。
PROJ_UP="${PROJ_UP:-}"
PROJ_MG="${PROJ_MG:-}"

SYNC_CODE="${SYNC_CODE:-1}"
DOMAIN="${DOMAIN:-}"
API_DOMAIN="${API_DOMAIN:-}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

CRED_FILE=""
# 安装标记（哨兵）。卸载时**必须**存在，否则一律拒绝 ——
# 这是为了防住「BASE_DIR 落到默认值，把别的实例删掉」这类事故。
# 文件里记录本实例的身份，卸载前会与当前参数逐项比对。
INSTALL_MARK=""
STATE_DIR="/home/docker"
ACCESS_CONF="$STATE_DIR/${MG_NAME}_access.conf"
PORT_CONF="$STATE_DIR/${MG_NAME}_port.conf"

# ---------------------------------------------------------------- 颜色
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_D=$'\033[2m'; C_BOLD=$'\033[1m'; C_0=$'\033[0m'
else
  C_G=""; C_Y=""; C_R=""; C_D=""; C_BOLD=""; C_0=""
fi
T0=$(date +%s)
STEP_NO=0
elapsed() { local s=$(( $(date +%s) - T0 )); printf '%dm%02ds' $(( s / 60 )) $(( s % 60 )); }
ok()   { printf "  ${C_G}✓${C_0} %s\n" "$*"; }
warn() { printf "  ${C_Y}!${C_0} %s\n" "$*" >&2; }
die()  { printf "  ${C_R}✗ %s${C_0}\n" "$*" >&2; exit 1; }
info() { printf "  ${C_D}·${C_0} %s\n" "$*"; }
step() { STEP_NO=$(( STEP_NO + 1 )); printf "\n${C_G}[%02d]${C_0} %s\n" "$STEP_NO" "$*"; }
hr()   { printf "\n  ${C_G}══════════════════════════════════════════════════${C_0}\n"; }

gen_password() {
  # 只在安全字符集里取（不含引号 / 反斜杠 / 反引号 / 美元符），长度 20
  LC_ALL=C tr -dc 'A-Za-z0-9@#%_+=:.,-' </dev/urandom 2>/dev/null | head -c 20
  printf '\n'
}
password_is_safe() {
  case "$1" in
    *'"'*|*'\'*|*'`'*|*'$'*|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
    *) return 0 ;;
  esac
}
ask() { # $1=提示 $2=默认值；结果写入全局变量 REPLY_ASK
  local p="$1" d="${2:-}" r=""
  printf "  %s" "$p"
  [ -n "$d" ] && printf " ${C_D}[%s]${C_0}" "$d"
  printf "："
  if ! read -r r; then r="$d"; fi
  r="${r%$'\r'}"
  REPLY_ASK="${r:-$d}"
}
pause_any() { printf "  ${C_D}按回车返回菜单…${C_0}"; read -r _ || true; }

usage() {
  cat <<'USAGE'
用法: bash workbuddy-deploy.sh [选项 | 子命令]

不带任何参数且为交互终端 → 进入菜单。

子命令:
  install                安装（首次部署 / 补装）
  update                 更新（拉最新源码 + 重建镜像 + 重启）
  uninstall              卸载（容器 / 镜像 / 目录，交互询问是否保留数据）
  bind-domain <域名>     绑定域名（Nginx 优先，无则 Caddy + 自动签证书）
  unbind-domain <域名>   删除域名反代配置
  status                 查看容器 / 端口 / 健康状态
  credentials            显示凭据文件
  menu                   强制显示菜单

选项（等价于同名环境变量）:
  -d, --domain <域名>       面板 / 对外域名（DNS 需已指向本机）
      --api-domain <域名>   独立 API 域名（只暴露 /v1，不含面板）
  -p, --password <密码>     面板管理员密码（≥8 位）
  -a, --auto                全自动：跳过交互向导
      --base-dir <目录>     安装根目录（install 未指定时默认 /opt/wb2api）
  -h, --help                显示本帮助并退出

安全机制:
  · 安装时会在 <目录> 下落一个哨兵文件 .wb-proxy-install，并写全局注册表
    /etc/wb-proxy-install.conf。uninstall / update 前必须读到哨兵，
    且其中的容器名 / 端口与本次参数一致，否则一律拒绝执行。
  · 卸载前还会校验路径本身：根目录、系统目录、层级过浅的路径直接拒绝。
  · 本机有多套实例时，不带 --base-dir 的卸载会被拒绝（无法判断删哪套）。

示例:
  bash workbuddy-deploy.sh                                   # 菜单
  bash workbuddy-deploy.sh install --domain wb.example.com -a
  bash workbuddy-deploy.sh install --base-dir /srv/wb-proxy -a
  bash workbuddy-deploy.sh bind-domain wb.example.com
  bash workbuddy-deploy.sh unbind-domain wb.example.com
  bash workbuddy-deploy.sh update --base-dir /srv/wb-proxy
  bash workbuddy-deploy.sh uninstall --base-dir /srv/wb-proxy
USAGE
}

# ---------------------------------------------------------------- 参数解析
# 注意：ACTION / BASE_DIR_EXPLICIT 已在上面（BASE_DIR 解析区）初始化。
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--domain)    DOMAIN="${2:-}";        [ -n "$DOMAIN" ]        || die "--domain 需要跟一个域名"; shift 2 ;;
    --api-domain)   API_DOMAIN="${2:-}";    [ -n "$API_DOMAIN" ]    || die "--api-domain 需要跟一个域名"; shift 2 ;;
    -p|--password)  ADMIN_PASSWORD="${2:-}";[ -n "$ADMIN_PASSWORD" ]|| die "--password 需要跟一个密码"; shift 2 ;;
    -a|--auto|-y|--yes) NONINTERACTIVE=1; shift ;;
    --base-dir)     BASE_DIR="${2:-}";      [ -n "$BASE_DIR" ]      || die "--base-dir 需要跟一个目录"
                    BASE_DIR_EXPLICIT=1;   shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    install|update|uninstall|status|credentials|menu) ACTION="$1"; shift ;;
    bind-domain)    ACTION="bind-domain";   ACTION_ARG="${2:-}"; shift $(( $# >= 2 ? 2 : 1 )) ;;
    unbind-domain)  ACTION="unbind-domain"; ACTION_ARG="${2:-}"; shift $(( $# >= 2 ? 2 : 1 )) ;;
    *) die "未知参数：$1（用 --help 查看支持的选项）" ;;
  esac
done

# ---------------------------------------------------------------- 解析 BASE_DIR
#
# 关键：这一步必须在**参数解析之后、任何可能删文件的动作之前**完成。
# 顺序是「先定目录，再干活」——不是「先干活，用默认目录兜底」。
discover_base_dir

case "$BASE_DIR" in
  /*) : ;;
  *)  die "BASE_DIR 必须是绝对路径（当前：$BASE_DIR）" ;;
esac
case "$BASE_DIR" in
  */../*|*/..|../*|..) die "BASE_DIR 不能含 .. 相对段（当前：$BASE_DIR）" ;;
esac
BASE_DIR="${BASE_DIR%/}"
[ -n "$BASE_DIR" ] || die "BASE_DIR 解析为空"

# 按最终值重算派生路径
UP_DIR="$BASE_DIR/workbuddy2api"
MG_DIR="$BASE_DIR/workbuddy-manager"
SRC_DIR="$BASE_DIR/src"
PROJ_UP="${PROJ_UP:-$(basename "$BASE_DIR")-up}"
PROJ_MG="${PROJ_MG:-$(basename "$BASE_DIR")-mgr}"
CRED_FILE="$BASE_DIR/.credentials"
INSTALL_MARK="$BASE_DIR/.wb-proxy-install"
ACCESS_CONF="$STATE_DIR/${MG_NAME}_access.conf"
PORT_CONF="$STATE_DIR/${MG_NAME}_port.conf"

# ---------------------------------------------------------------- 环境检测
require_root() {
  [ "$(id -u)" -eq 0 ] || die "请用 root 运行（需要 docker 与写 /opt 的权限）"
}

# 检测反向代理环境：优先复用已有 Nginx（科技Lion / 系统 nginx），否则用 Caddy
HAS_NGINX=0
NGINX_CONF_DIR=""
NGINX_TEST_CMD=""
NGINX_RELOAD_CMD=""

detect_proxy_env() {
  HAS_NGINX=0; NGINX_CONF_DIR=""; NGINX_TEST_CMD=""; NGINX_RELOAD_CMD=""
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '^nginx$'; then
    HAS_NGINX=1
    NGINX_CONF_DIR="/home/web/conf.d"
    [ -d "$NGINX_CONF_DIR" ] || NGINX_CONF_DIR="/etc/nginx/conf.d"
    NGINX_TEST_CMD="docker exec nginx nginx -t"
    NGINX_RELOAD_CMD="docker exec nginx nginx -s reload"
  elif command -v nginx >/dev/null 2>&1 && { systemctl is-active nginx >/dev/null 2>&1 || ss -tlnp 2>/dev/null | grep -qE ':(80|443) .*nginx'; }; then
    HAS_NGINX=1
    NGINX_CONF_DIR="/etc/nginx/conf.d"
    [ -d "$NGINX_CONF_DIR" ] || NGINX_CONF_DIR="/home/web/conf.d"
    NGINX_TEST_CMD="nginx -t"
    NGINX_RELOAD_CMD="systemctl reload nginx || nginx -s reload"
  elif ss -tlnp 2>/dev/null | grep -qE ':(80|443) '; then
    HAS_NGINX=1
    NGINX_CONF_DIR="/home/web/conf.d"
    [ -d "$NGINX_CONF_DIR" ] || NGINX_CONF_DIR="/etc/nginx/conf.d"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qE 'nginx'; then
      NGINX_TEST_CMD="docker exec nginx nginx -t"
      NGINX_RELOAD_CMD="docker exec nginx nginx -s reload"
    else
      NGINX_TEST_CMD="nginx -t"
      NGINX_RELOAD_CMD="systemctl reload nginx || nginx -s reload"
    fi
  fi
}

install_deps() {
  # 缺哪个补哪个，且只做一次 apt-get update（小机器上 update 很慢）
  local MISSING="" tool
  for tool in git python3 openssl curl; do
    command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
  done
  if [ -n "$MISSING" ]; then
    info "缺少依赖：$MISSING —— 正在 apt 安装（首次可能要 1-2 分钟）…"
    apt-get update -qq >/dev/null 2>&1 || warn "apt-get update 失败（软件源不可用？仍尝试直接安装）"
    # shellcheck disable=SC2086
    apt-get install -y -qq $MISSING ca-certificates >/dev/null 2>&1 || true
  fi
  for tool in git python3; do
    command -v "$tool" >/dev/null 2>&1 || die "缺少 $tool 且自动安装失败，请手动安装后重跑"
  done

  if ! command -v docker >/dev/null 2>&1; then
    info "未检测到 Docker —— 用官方脚本安装（get.docker.com，约 1~2 分钟）…"
    if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null && sh /tmp/get-docker.sh >/dev/null 2>&1; then
      rm -f /tmp/get-docker.sh
      ok "Docker 安装脚本执行完成"
    else
      rm -f /tmp/get-docker.sh
      warn "Docker 官方安装脚本执行失败（网络不通 get.docker.com？）"
    fi
    systemctl enable --now docker >/dev/null 2>&1 || true
    sleep 2
  fi
  command -v docker >/dev/null 2>&1 || die "Docker 未安装成功。可手动执行：curl -fsSL https://get.docker.com | sh"

  if ! docker compose version >/dev/null 2>&1; then
    info "缺少 docker compose 插件 —— 尝试 apt 安装 docker-compose-plugin…"
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 || true
  fi
  docker compose version >/dev/null 2>&1 || die "缺少 docker compose 插件。可手动执行：apt-get install -y docker-compose-plugin"

  ok "docker $(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) · compose $(docker compose version --short 2>/dev/null) · git $(git --version | awk '{print $3}') · $(python3 -V 2>&1)"
}

preflight() {
  step "环境预检"
  info "提示：构建镜像全程约 3~8 分钟；建议在 tmux/screen 里执行，避免 SSH 断线中断（断了可直接重跑）"
  [ "$NONINTERACTIVE" = "1" ] || info "apt 系统需为 Debian / Ubuntu 系（本脚本自动安装依赖基于 apt）"

  local AVAIL AVAIL_GB
  AVAIL=$(free -m 2>/dev/null | awk 'NR==2{print $7}')
  [ -n "$AVAIL" ] || AVAIL=0
  ok "可用内存 ${AVAIL}MB（网关+面板运行约 150-250MB）"

  # 前端 next build 是全程最吃内存的一步（大量图标/图表组件 + 5 套 i18n）。
  # 我们已把 V8 堆上限抬到 NODE_MAX_OLD_SPACE，但**宿主内存不足时会直接被内核 OOM kill**，
  # 报错会是莫名其妙的 "exit code: 137" / "Killed"。这里提前把话说清楚。
  # web/out 已存在则跳过构建，需求大幅下降。
  if [ -d "$SRC_DIR/workbuddy-manager/web/out" ] && [ -f "$SRC_DIR/workbuddy-manager/web/out/index.html" ]; then
    ok "面板前端已有构建产物（web/out）—— 构建期内存需求较低"
  else
    local NEED_MB=$(( NODE_MAX_OLD_SPACE + 700 ))
    if [ "$AVAIL" -lt "$NEED_MB" ]; then
      warn "面板前端需要在容器内构建（仓库未带 web/out）—— 建议可用内存 ≥ ${NEED_MB}MB，当前 ${AVAIL}MB"
      warn "  若构建被 OOM kill（docker 报 exit code 137 / Killed），三种解法任选："
      warn "    1) 先腾内存：停掉不用的服务，或加 swap（fallocate -l 2G /swapfile && mkswap /swapfile && swapon /swapfile）"
      warn "    2) 降堆上限：NODE_MAX_OLD_SPACE=2048 sudo ./workbuddy-deploy.sh install"
      warn "    3) 本机构建前端后重传：cd workbuddy-manager/web && npm ci && NEXT_OUTPUT_EXPORT=1 npx next build"
      warn "       （生成 web/out 后本步会被自动跳过）"
    else
      ok "面板前端构建内存充足（需约 ${NEED_MB}MB，可用 ${AVAIL}MB）"
    fi
  fi

  AVAIL_GB=$(df -Pk / 2>/dev/null | awk 'NR==2{printf "%d", $4/1048576}')
  [ -n "$AVAIL_GB" ] || AVAIL_GB=0
  if [ "$AVAIL_GB" -lt 4 ]; then
    die "根分区可用空间仅 ${AVAIL_GB}GB（构镜像+数据约需 4~6GB），请先清理磁盘再重试"
  fi
  ok "根分区可用 ${AVAIL_GB}GB（构镜像+数据约需 4~6GB）"

  # 面板与网关必须同网 —— 面板容器经 host.docker.internal 访问时走网桥 IP，
  # 而网关只绑 127.0.0.1，必然连接失败。
  docker network inspect "$NET_NAME" >/dev/null 2>&1 || docker network create "$NET_NAME" >/dev/null
  ok "共享网络 $NET_NAME 就绪"

  local p
  for p in "$WB2API_PORT" "$MANAGER_PORT"; do
    if ss -tlnp 2>/dev/null | grep -q ":$p "; then
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -qxE "${UP_NAME}|${MG_NAME}"; then
        ok "端口 $p 已由本脚本部署的服务占用（视为已部署，继续）"
      else
        die "端口 $p 已被其它进程占用"
      fi
    else
      ok "端口 $p 空闲"
    fi
  done

  detect_proxy_env
  if [ "$HAS_NGINX" = "1" ]; then
    ok "检测到已运行 Nginx（已占 80/443），域名反代将对接 Nginx，自动跳过 Caddy 避免端口冲突"
  fi
}

# ---------------------------------------------------------------- 安装标记（哨兵）
#
# 为什么需要它：卸载会 `rm -rf $BASE_DIR`。如果 BASE_DIR 因为漏传参数落到默认值，
# 就会把**另一个实例**（甚至别人的部署）当成自己删掉。哨兵文件是唯一的身份凭据：
#   · 安装/更新时写入，内容是本实例的关键参数
#   · 卸载/更新前必须读到，且与当前参数一致，否则拒绝执行
# 这与 kejilion.sh 用 $app_dir/.kejilion-app 做归属判定的思路一致。
write_install_mark() {
  mkdir -p "$BASE_DIR" || die "无法创建 $BASE_DIR"
  umask 077
  cat > "$INSTALL_MARK" <<MARK
# WorkBuddy-Proxy 安装标记 —— 由 workbuddy-deploy.sh 自动生成，请勿手工编辑。
# 卸载/更新前会与本机实际参数比对；不一致或缺失时脚本会拒绝执行。
WB_PROXY_MARK=1
BASE_DIR=$BASE_DIR
UP_NAME=$UP_NAME
MG_NAME=$MG_NAME
WB2API_PORT=$WB2API_PORT
MANAGER_PORT=$MANAGER_PORT
NET_NAME=$NET_NAME
MARK
  umask 022
}

# 全局注册表：告诉本机「这套实例装在哪」。
# 有了它，`bash workbuddy-deploy.sh uninstall`（不带任何环境变量）也能正确
# 定位到已装实例，而不会回落到某个默认目录。
# 多实例场景：注册表记录最近一次安装的目录；要操作别的实例请用 --base-dir。
write_global_registry() {
  local dir
  dir="$(dirname "$WB_INSTALL_REGISTRY")"
  mkdir -p "$dir" 2>/dev/null || { warn "无法写全局注册表（$WB_INSTALL_REGISTRY），跳过"; return 0; }
  umask 022
  cat > "$WB_INSTALL_REGISTRY" <<REG
# WorkBuddy-Proxy 全局安装注册表 —— 由 workbuddy-deploy.sh 自动生成，请勿手工编辑。
# 用途：让不带参数的 uninstall / update 能定位到已装实例。
# 多实例时这里只记录最近一次；操作其它实例请加 --base-dir <目录>。
BASE_DIR=$BASE_DIR
INSTALLED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
REG
}

# 校验标记。参数：$1 = 动作名（用于报错文案）
# 失败一律 `die` —— 卸载/更新是破坏性操作，宁可拒绝也不能猜。
require_install_mark() {
  local action="${1:-操作}"

  [ -e "$BASE_DIR" ] || die "$action 被拒绝：目录不存在（$BASE_DIR）"
  [ -L "$BASE_DIR" ] && die "$action 被拒绝：$BASE_DIR 是符号链接（防误删，请手工处理）"
  [ -f "$INSTALL_MARK" ] || die "$action 被拒绝：$BASE_DIR 下没有安装标记（$INSTALL_MARK）。
  这说明该目录不是本脚本安装的，或者参数指错了地方。
  如果你确实要清理它，请手工确认后再操作：
      ls -la '$BASE_DIR'
      rm -rf '$BASE_DIR'"

  # 读标记里的记录，与当前参数比对
  local m_base m_up m_mg
  m_base="$(sed -n 's/^BASE_DIR=//p' "$INSTALL_MARK" | head -1)"
  m_up="$(sed -n 's/^UP_NAME=//p' "$INSTALL_MARK" | head -1)"
  m_mg="$(sed -n 's/^MG_NAME=//p' "$INSTALL_MARK" | head -1)"

  if [ -n "$m_base" ] && [ "$m_base" != "$BASE_DIR" ]; then
    die "$action 被拒绝：安装标记记录的目录是 $m_base，当前参数是 $BASE_DIR —— 不匹配。
  如果你是想操作 $m_base，请显式指定：--base-dir '$m_base'"
  fi
  if [ -n "$m_up" ] && [ "$m_up" != "$UP_NAME" ]; then
    die "$action 被拒绝：安装标记记录的网关容器名是 $m_up，当前是 $UP_NAME —— 不匹配。
  如果你是想操作那套实例，请显式指定：UP_NAME='$m_up'"
  fi
  if [ -n "$m_mg" ] && [ "$m_mg" != "$MG_NAME" ]; then
    die "$action 被拒绝：安装标记记录的面板容器名是 $m_mg，当前是 $MG_NAME —— 不匹配。
  如果你是想操作那套实例，请显式指定：MG_NAME='$m_mg'"
  fi

  # 参数自洽性：端口必须是数字
  case "$WB2API_PORT" in ''|*[!0-9]*) die "$action 被拒绝：WB2API_PORT 不是数字（$WB2API_PORT）" ;; esac
  case "$MANAGER_PORT" in ''|*[!0-9]*) die "$action 被拒绝：MANAGER_PORT 不是数字（$MANAGER_PORT）" ;; esac
}

# 把哨兵里的身份（容器名 / 端口 / 网络）套用到当前变量。
# 用途：只读命令（status / proxy / credentials）在自动发现目录后，
#       也要用**那套实例真实的**端口去查，而不是脚本的默认端口。
# 与卸载闸门不同，这里失败不 die —— 只读命令不该因为没哨兵就退出。
apply_install_mark_identity() {
  [ -f "$INSTALL_MARK" ] || return 0
  local v
  v="$(sed -n 's/^UP_NAME=//p'      "$INSTALL_MARK" | head -1)"; [ -n "$v" ] && UP_NAME="$v"
  v="$(sed -n 's/^MG_NAME=//p'      "$INSTALL_MARK" | head -1)"; [ -n "$v" ] && MG_NAME="$v"
  v="$(sed -n 's/^WB2API_PORT=//p'  "$INSTALL_MARK" | head -1)"; [ -n "$v" ] && WB2API_PORT="$v"
  v="$(sed -n 's/^MANAGER_PORT=//p' "$INSTALL_MARK" | head -1)"; [ -n "$v" ] && MANAGER_PORT="$v"
  v="$(sed -n 's/^NET_NAME=//p'     "$INSTALL_MARK" | head -1)"; [ -n "$v" ] && NET_NAME="$v"
  ACCESS_CONF="$STATE_DIR/${MG_NAME}_access.conf"
  PORT_CONF="$STATE_DIR/${MG_NAME}_port.conf"
  PROJ_UP="$(basename "$BASE_DIR")-up"
  PROJ_MG="$(basename "$BASE_DIR")-mgr"
  return 0
}

# ---------------------------------------------------------------- 危险路径防护
#
# `rm -rf` 的最后一道闸：拒绝「明显不该被删」的路径。
# 这不是完备性校验（完备做不到），而是拦住最常见的误伤：
# 根目录、系统目录、以及各种「上层父目录」。
assert_safe_to_erase() {
  local d="${1:-}" real

  [ -n "$d" ] || die "拒绝删除：路径为空"
  [ "$d" = "/" ] && die "拒绝删除：路径是根目录"

  # 规范化（去掉尾部斜杠、解析相对段），但不要求目录存在
  real="$(printf '%s' "$d" | sed 's:/*$::')"
  [ -n "$real" ] || real="/"

  case "$real" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die "拒绝删除：$real 是系统目录，不可能由本脚本安装" ;;
    /opt/*|/home/*|/root/*|/srv/*|/var/*|/usr/local/*|/mnt/*|/data/*)
      : ;;   # 正常的安装位置，放行
    *)
      # 其它位置：先挡死系统子目录，再要求路径足够深。
      # 注意 /usr/* 除了 /usr/local/* 之外全在禁用之列（上面白名单已经排除了
      # /usr/local/*），所以这里统一按前缀拒绝，不留「够深就放行」的口子。
      case "$real" in
        /bin/*|/boot/*|/dev/*|/etc/*|/lib/*|/lib64/*|/proc/*|/run/*|/sbin/*|/sys/*|/usr/*|/tmp/*)
          die "拒绝删除：$real 位于系统目录之下，不可能由本脚本安装" ;;
      esac
      # 仍要求路径足够深（≥ 3 层），否则拒绝
      local depth
      depth="$(printf '%s' "$real" | awk -F/ '{print NF-1}')"
      if [ "$depth" -lt 3 ]; then
        die "拒绝删除：$real 层级过浅（$depth），出于安全考虑需要 ≥ 3 层。
  如确认要删，请手工执行：rm -rf '$real'"
      fi
      ;;
  esac

  # 路径里含通配符 / 变量残留 → 拒绝（防 'rm -rf $VAR' 展开出错）
  case "$real" in
    *'*'*|*'?'*|*'$'*|*'`'*) die "拒绝删除：$real 含通配符或未展开变量" ;;
  esac

  printf '%s' "$real"
}

# ---------------------------------------------------------------- 凭据
gen_credentials() {
  step "生成 / 读取凭据"
  mkdir -p "$BASE_DIR"

  # 先给「本次显式指定的密码」留底：下面 source $CRED_FILE 会把它覆盖成旧值
  local EXPLICIT_ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
  CRED_DIRTY=0
  CRED_LOST=0
  PASSWD_RESET=0
  FIRST_RUN_NOTE=""

  if [ -f "$CRED_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CRED_FILE"
    API_KEY="${API_KEY:-}"
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
    if [ -z "$API_KEY" ]; then
      API_KEY="$(openssl rand -hex 24 2>/dev/null || head -c48 /dev/urandom | od -An -tx1 | tr -d ' \n')"
      warn "凭据文件里缺少 api_key —— 已重新生成"
      CRED_DIRTY=1
    fi
    if [ -z "$ADMIN_PASSWORD" ]; then
      ADMIN_PASSWORD="$(gen_password)"
      PASSWD_RESET=1
      warn "凭据文件里缺少管理密码 —— 已重新生成，部署末尾重建面板后生效"
      CRED_DIRTY=1
    fi
    RUN_MODE="增量更新"
    ok "沿用已保存的 api_key / 管理密码（$CRED_FILE）"
    if [ -n "$EXPLICIT_ADMIN_PASSWORD" ] && [ "$EXPLICIT_ADMIN_PASSWORD" != "$ADMIN_PASSWORD" ]; then
      ADMIN_PASSWORD="$EXPLICIT_ADMIN_PASSWORD"
      PASSWD_RESET=1
      ok "已采用本次指定的新密码（部署末尾重建面板后生效）"
    fi
  else
    RUN_MODE="首次部署"
    API_KEY="${API_KEY:-$(openssl rand -hex 24 2>/dev/null || head -c48 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(gen_password)}"
    [ -n "$API_KEY" ] && [ -n "$ADMIN_PASSWORD" ] || die "随机数生成失败"

    if [ -f "$MG_DIR/data/users.json" ] || [ -f "$UP_DIR/config.json" ]; then
      CRED_LOST=1
      PASSWD_RESET=1
      RUN_MODE="凭据已重建"
      warn "检测到已有部署产物但凭据文件丢失：已重新生成 api_key 与管理员密码，"
      warn "  稍后会把它们同步进网关 config.json 与面板（原密钥/密码将失效）"
    fi
    umask 077
    { printf 'API_KEY=%q\n' "$API_KEY"; printf 'ADMIN_PASSWORD=%q\n' "$ADMIN_PASSWORD"; } > "$CRED_FILE"
    umask 022
    FIRST_RUN_NOTE="    · 这是首次部署：请立刻把上面的管理密码与 api_key 存进密码管理器。"
    ok "已生成并保存到 $CRED_FILE（0600，请妥善保管）"
  fi

  # 密码策略兜底：要安全地同时写进 compose 的 YAML 双引号串与 .credentials
  if [ "${#ADMIN_PASSWORD}" -lt 8 ] || ! password_is_safe "$ADMIN_PASSWORD"; then
    local PW_NOTE="含不安全字符（不能有双引号、反斜杠、反引号、美元符或不可见字符）"
    [ "${#ADMIN_PASSWORD}" -lt 8 ] && PW_NOTE="少于 8 位（当前 ${#ADMIN_PASSWORD} 位）"
    if [ -n "$EXPLICIT_ADMIN_PASSWORD" ]; then
      die "管理员密码${PW_NOTE}。面板容器挂载了 docker.sock，弱密码等于敞开高权限入口；且特殊字符会写坏 compose 的 YAML。请换一个密码后重试。"
    else
      warn "凭据文件里的管理密码${PW_NOTE} —— 继续使用，但建议尽快改掉："
      warn "  重跑时加 -p '新密码'（≥8 位、且不含双引号 / 反斜杠）即可重置。"
    fi
  fi

  if [ "$CRED_DIRTY" = "1" ]; then
    umask 077
    { printf 'API_KEY=%q\n' "$API_KEY"; printf 'ADMIN_PASSWORD=%q\n' "$ADMIN_PASSWORD"; } > "$CRED_FILE"
    [ -n "${MANAGER_API_KEY:-}" ] && printf 'MANAGER_API_KEY=%q\n' "$MANAGER_API_KEY" >> "$CRED_FILE"
    umask 022
    ok "凭据文件已补齐缺失项（$CRED_FILE）"
  fi
}

explain_clone_err() {
  local out="$1"
  case "$out" in
    *"could not read Username"*|*"Authentication failed"*|*"Repository not found"*|*"repository"*"not found"*)
      warn "  ↳ 上面这句通常表示【仓库不存在，或它是私有仓库、而本机没有访问凭据】；" ;;
    *"Could not resolve host"*|*"Connection timed out"*|*"Failed to connect"*|*"Network is unreachable"*|*"Could not resolve"*)
      warn "  ↳ 连不上 GitHub —— 检查本机 DNS / 出网 / 代理设置；" ;;
    *"already exists and is not an empty directory"*)
      warn "  ↳ 目标目录非空 —— 删掉它，或用 --base-dir 换一个安装位置；" ;;
    *)
      warn "  ↳ 以上为 git 原话，可据此搜索；" ;;
  esac
}

# ---------------------------------------------------------------- 源码同步
sync_source() {
  step "同步源码（$REPO_URL @ $REPO_REF）"
  mkdir -p "$SRC_DIR"

  if [ -d "$SRC_DIR/.git" ]; then
    if [ "$SYNC_CODE" = "1" ]; then
      git -C "$SRC_DIR" remote set-url origin "$REPO_URL" >/dev/null 2>&1 || true
      if git -C "$SRC_DIR" fetch --depth 1 origin "$REPO_REF" >/dev/null 2>&1 \
         && git -C "$SRC_DIR" reset --hard "origin/$REPO_REF" >/dev/null 2>&1; then
        ok "源码已同步到远端 $REPO_REF"
      else
        warn "源码同步失败（网络或仓库异常）—— 本次沿用本地既有代码继续部署"
      fi
    else
      ok "已存在，SYNC_CODE=0 —— 跳过代码同步，保留你的本地修改"
    fi
  else
    if [ -e "$SRC_DIR" ] && [ ! -d "$SRC_DIR/.git" ]; then
      warn "目标目录 $SRC_DIR 已存在但不是 git 仓库（多为上次中断残留）—— 已移除后重新克隆"
      rm -rf "$SRC_DIR"
    fi
    local CLONE_OUT
    CLONE_OUT="$(git clone --depth 1 -b "$REPO_REF" "$REPO_URL" "$SRC_DIR" 2>&1)" || {
      if [ -n "$CLONE_OUT" ]; then printf '%s\n' "$CLONE_OUT" | sed 's/^/     /'; fi
      explain_clone_err "$CLONE_OUT"
      die "克隆仓库失败：$REPO_URL"
    }
    ok "已克隆 $REPO_URL"
  fi

  [ -d "$SRC_DIR/workbuddy2api" ]     || die "源码缺少 workbuddy2api/ 目录，仓库结构异常"
  [ -d "$SRC_DIR/workbuddy-manager" ] || die "源码缺少 workbuddy-manager/ 目录，仓库结构异常"

  # 把源码镜像进运行时目录 —— 用 rsync 风格的整体同步，但**保护运行时文件**：
  #   · workbuddy2api/  : 保留 auths/ data/ config.json（账号、代理配置、密钥）
  #   · workbuddy-manager/ : 保留 data/（SQLite、users.json）
  # 传给 rsync 的 --exclude 就是这两处；没有 rsync 时退回 cp -a + 白名单保护。
  mkdir -p "$UP_DIR" "$MG_DIR"

  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete \
      --exclude 'auths/' --exclude 'data/' --exclude 'config.json' \
      --exclude 'docker-compose.yml' \
      "$SRC_DIR/workbuddy2api/" "$UP_DIR/" 2>/dev/null || \
      warn "网关源码同步失败（rsync），沿用既有代码"
    rsync -a --delete \
      --exclude 'data/' --exclude 'docker-compose.yml' \
      "$SRC_DIR/workbuddy-manager/" "$MG_DIR/" 2>/dev/null || \
      warn "面板源码同步失败（rsync），沿用既有代码"
    ok "源码已就位（rsync 同步，运行时文件已保留）"
  else
    # 无 rsync：cp -a 覆盖源码，运行时文件因为在 SRC 里不存在所以不会被覆盖，
    # 但 --delete 语义缺失 —— 上游删掉的文件会残留，一般无碍（只影响镜像体积）。
    local rel
    for rel in internal cmd scripts; do
      [ -d "$SRC_DIR/workbuddy2api/$rel" ] && \
        { rm -rf "$UP_DIR/$rel"; cp -a "$SRC_DIR/workbuddy2api/$rel" "$UP_DIR/"; }
    done
    for rel in go.mod go.sum Dockerfile README.md LICENSE config.example.json \
               acct.sh checkin.sh credit.sh dev.sh login.sh signin.sh trial.sh \
               .dockerignore .gitignore; do
      [ -e "$SRC_DIR/workbuddy2api/$rel" ] && cp -a "$SRC_DIR/workbuddy2api/$rel" "$UP_DIR/" 2>/dev/null || true
    done
    for rel in server deploy docs; do
      [ -d "$SRC_DIR/workbuddy-manager/$rel" ] && \
        { rm -rf "$MG_DIR/$rel"; cp -a "$SRC_DIR/workbuddy-manager/$rel" "$MG_DIR/"; }
    done
    for rel in web requirements.txt Dockerfile CHANGELOG.md .dockerignore .gitignore; do
      [ -e "$SRC_DIR/workbuddy-manager/$rel" ] && cp -a "$SRC_DIR/workbuddy-manager/$rel" "$MG_DIR/" 2>/dev/null || true
    done
    ok "源码已就位（无 rsync，白名单复制）"
  fi

  # 面板镜像里 web/out 是预构建产物；如果源码没带 out，允许 Dockerfile 自行构建
  [ -d "$MG_DIR/web" ] || die "面板源码缺少 web/ 目录，仓库结构异常"
}

# ---------------------------------------------------------------- 网关配置
write_gateway_config() {
  if [ ! -f "$UP_DIR/config.json" ]; then
    local src_cfg="$SRC_DIR/workbuddy2api/config.json"
    [ -f "$src_cfg" ] || src_cfg="$SRC_DIR/workbuddy2api/config.example.json"
    cp -f "$src_cfg" "$UP_DIR/config.json" 2>/dev/null || echo '{}' > "$UP_DIR/config.json"
    ok "已从示例复制 config.json"
  fi

  python3 - "$UP_DIR/config.json" "$API_KEY" "${CRED_LOST:-0}" <<'PY'
import json, sys
p, key, cred_lost = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    cfg = json.load(open(p, encoding='utf-8'))
except Exception:
    cfg = {}

# api_key：凭据丢失或占位符未替换时对齐
if cred_lost == "1" or not cfg.get("api_key") or cfg.get("api_key") == "CHANGE_ME_GENERATED_AT_INSTALL":
    cfg["api_key"] = key

cfg["listen"] = "0.0.0.0:7863"          # 容器内监听；宿主侧只绑 127.0.0.1

# admin 管理端点（支持 POST /admin/tasks/{name}/run 补跑与 acct.sh）
if not isinstance(cfg.get("admin"), dict):
    cfg["admin"] = {}
cfg["admin"]["enabled"] = True
cfg["admin"].setdefault("audit_enabled", True)
cfg["admin"].setdefault("audit_file", "./data/admin_audit.log")

# 六大定时积分任务
if not isinstance(cfg.get("schedule"), dict):
    cfg["schedule"] = {}
sch = cfg["schedule"]
sch.setdefault("checkin_hours", [9, 21])
sch.setdefault("travel_hours", [9, 21])
sch.setdefault("activity_hours", [10])
sch.setdefault("keepalive_hours", [22])
sch.setdefault("school_hours", [12])
sch.setdefault("cat_hours", [1])
for k in ("checkin_enabled", "travel_enabled", "activity_enabled",
          "keepalive_enabled", "school_enabled", "cat_enabled"):
    sch.setdefault(k, True)
sch.setdefault("jitter_minutes", 0)

with open(p, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  ok "config.json 已对齐（api_key / admin 端点 / 六大定时积分任务）"
}

# ---------------------------------------------------------------- compose 文件
write_compose_files() {
  mkdir -p "$UP_DIR/auths" "$UP_DIR/data"
  cat > "$UP_DIR/docker-compose.yml" <<YAML
# 由 workbuddy-deploy.sh 生成 —— 从本仓库源码构建（含逐账号出站代理补丁）
name: ${PROJ_UP}
services:
  wb2api:
    build:
      context: .
      dockerfile: Dockerfile
    image: ${WB2API_IMAGE}
    container_name: ${UP_NAME}
    restart: unless-stopped
    mem_limit: 256m
    # 日志上限：json-file 默认不轮转，长期跑会慢慢把根分区写满
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    environment:
      - TZ=Asia/Shanghai
    ports:
      - "127.0.0.1:${WB2API_PORT}:7863"   # 只绑本机，面板/反代经宿主机访问
    volumes:
      - ./auths:/app/auths
      - ./data:/app/data
      - ./config.json:/app/config.json:ro
networks:
  default:
    name: ${NET_NAME}
    external: true
YAML
  ok "生成网关 docker-compose.yml（源码构建 + mem_limit 256m）"

  mkdir -p "$MG_DIR/data"
  cat > "$MG_DIR/docker-compose.yml" <<YAML
# 由 workbuddy-deploy.sh 生成 —— 从本仓库源码构建（含逐账号出站代理补丁）
name: ${PROJ_MG}
services:
  workbuddy-manager:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        # 前端构建的 npm 源（中国大陆加速；留空走官方源，失败自动降级）
        NPM_REGISTRY: "${NPM_REGISTRY:-}"
        # next build 的 V8 堆上限；小内存机器可下调
        NODE_MAX_OLD_SPACE: "${NODE_MAX_OLD_SPACE:-3072}"
    image: ${MANAGER_IMAGE}
    container_name: ${MG_NAME}
    restart: unless-stopped
    mem_limit: 320m
    # 日志上限：面板会记录每一次 API 调用，没有上限就是慢性磁盘炸弹
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    environment:
      TZ: Asia/Shanghai
      WB_ADMIN_PASSWORD: "${ADMIN_PASSWORD}"
      WB2API_BASE: http://${UP_NAME}:7863
      WB2API_KEY: "${API_KEY}"
      WB2API_MODE: docker
      WB2API_CONTAINER: ${UP_NAME}
      WB_AUTH_DIR: /opt/workbuddy2api/auths
      WB_UPSTREAM_CONFIG: /opt/workbuddy2api/config.json
      WB_DATA_DIR: /app/data
      WB_SECURE_COOKIE: auto
      WB_TRUST_PROXY: "1"
      WB_ENABLE_DOCS: "0"
    ports:
      - "127.0.0.1:${MANAGER_PORT}:7864"   # 管理端必须藏在反代之后
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

# networks 必须在顶层（不是 service 的子键），嵌进 service 会报
# "additional properties 'external', 'name' not allowed"
networks:
  default:
    name: ${NET_NAME}
    external: true
YAML
  ok "生成面板 docker-compose.yml（源码构建 + 挂上游目录 + docker.sock）"

  chmod 0600 "$UP_DIR/docker-compose.yml" "$MG_DIR/docker-compose.yml" 2>/dev/null || true
  ok "compose 文件已收紧权限（0600，含凭据）"
}

# ---------------------------------------------------------------- 构建启动
build_and_start() {
  step "修正卷属主（容器内 app=10001）"
  chown -R "${UP_UID}:${UP_UID}" "$UP_DIR/auths" "$UP_DIR/data" "$MG_DIR/data" 2>/dev/null || \
    warn "chown 失败（跳过；容器可能以 root 写入）"
  ok "auths/ data/ 已交给 uid ${UP_UID}"

  step "构建镜像（首次约 3~8 分钟）"
  local OUT
  if ! OUT="$(docker compose -f "$UP_DIR/docker-compose.yml" build 2>&1)"; then
    printf '%s\n' "$OUT" | tail -n 15 | sed 's/^/      /' >&2
    die "网关镜像构建失败（上方为 docker 的真实报错）"
  fi
  ok "网关镜像就绪：$WB2API_IMAGE"

  if ! OUT="$(docker compose -f "$MG_DIR/docker-compose.yml" build 2>&1)"; then
    printf '%s\n' "$OUT" | tail -n 15 | sed 's/^/      /' >&2
    die "面板镜像构建失败（上方为 docker 的真实报错）"
  fi
  ok "面板镜像就绪：$MANAGER_IMAGE"

  step "启动服务"
  if ! OUT="$(docker compose -f "$UP_DIR/docker-compose.yml" up -d 2>&1)"; then
    printf '%s\n' "$OUT" | tail -n 8 | sed 's/^/      /' >&2
    die "网关启动失败（上方为 docker compose 的真实报错）"
  fi
  ok "workbuddy2api 已启动"

  # 凭据丢失重生成时 config.json 的 api_key 刚被改写 —— 挂载文件变了但容器不会自动重载
  if [ "${CRED_LOST:-0}" = "1" ]; then
    info "config.json 的 api_key 已更新 —— 重启网关使其生效"
    docker restart "$UP_NAME" >/dev/null 2>&1 || true
  fi

  if ! OUT="$(docker compose -f "$MG_DIR/docker-compose.yml" up -d 2>&1)"; then
    printf '%s\n' "$OUT" | tail -n 8 | sed 's/^/      /' >&2
    die "面板启动失败（上方为 docker compose 的真实报错）"
  fi
  ok "workbuddy-manager 已启动"

  # 密码变更落地：面板只在首启（users.json 不存在）时读取 WB_ADMIN_PASSWORD
  if [ "${PASSWD_RESET:-0}" = "1" ]; then
    info "应用新密码：重置面板管理员…"
    docker rm -f "$MG_NAME" >/dev/null 2>&1 || true
    rm -f "$MG_DIR/data/users.json"
    docker compose -f "$MG_DIR/docker-compose.yml" up -d >/dev/null 2>&1 || die "面板重建失败"
    python3 - "$CRED_FILE" "$ADMIN_PASSWORD" <<'PY'
import sys, shlex
p, pw = sys.argv[1], sys.argv[2]
out = [f"ADMIN_PASSWORD={shlex.quote(pw)}" if l.startswith("ADMIN_PASSWORD=") else l
       for l in open(p).read().split("\n")]
open(p, "w").write("\n".join(out))
PY
    ok "面板管理员密码已更新（凭据文件已同步）"
  fi
}

wait_http() {
  local url="$1" i=1 body=""
  for i in 1 2 3 4 5; do
    body="$(curl -sS --max-time 5 "$url" 2>/dev/null || true)"
    [ -n "$body" ] && break
    sleep 2
  done
  while [ -z "$body" ] && [ "$i" -le 10 ]; do
    sleep 5
    body="$(curl -sS --max-time 5 "$url" 2>/dev/null || true)"
    i=$(( i + 1 ))
  done
  printf '%s' "$body"
}

health_check() {
  step "健康检查（最长等 60 秒）"
  GW_HEALTH_NOTE=""
  local H M
  H="$(wait_http "http://127.0.0.1:${WB2API_PORT}/healthz")"
  if [ -n "$H" ]; then
    ok "网关就绪：$(printf '%s' "$H" | head -c 120)"
    case "$H" in
      *'"healthy":0'*|*'"total":0'*)
        info "还没纳管账号 —— 网关 /healthz 现在返回 503，容器状态也会显示 unhealthy，"
        info "  这是正常现象；扫码加上账号后会自动转 healthy。别被 docker ps 的红字吓到。"
        GW_HEALTH_NOTE="
    · 网关当前还没有账号：docker ps 里 ${UP_NAME} 显示 (unhealthy) 属正常现象，
      因为 /healthz 如实反映「无可用账号」；扫码加上账号后会自动转为 healthy，不影响使用。"
        ;;
    esac
  else
    warn "网关 /healthz 暂无响应（无账号时返回 503 属正常）"
  fi

  M="$(wait_http "http://127.0.0.1:${MANAGER_PORT}/api/healthz")"
  if [ -n "$M" ]; then
    ok "面板就绪：$(printf '%s' "$M" | head -c 120)"
  else
    warn "面板 /api/healthz 暂无响应，最近日志："
    docker logs --tail 5 "$MG_NAME" 2>&1 | sed 's/^/      /' >&2 || true
  fi
}

public_ip() {
  curl -4 -sS --max-time 6 https://api.ipify.org 2>/dev/null \
    || curl -sS --max-time 6 https://api.ipify.org 2>/dev/null \
    || hostname -I | awk '{print $1}'
}

# ---------------------------------------------------------------- 域名绑定
do_bind_domain() {
  local THE_DOMAIN="${1:-}"
  [ -n "$THE_DOMAIN" ] || die "bind-domain 需要一个域名参数：workbuddy-deploy.sh bind-domain wb.example.com"
  DOMAIN="$THE_DOMAIN"

  step "绑定域名（$DOMAIN）"
  detect_proxy_env

  local PUB_IP DNS_OK="" DOM_IP
  PUB_IP="$(public_ip)"
  info "本机公网 IP：$PUB_IP"

  local dns_try
  for dns_try in 1 2 3 4 5; do
    DOM_IP=$( { getent ahostsv4 "$DOMAIN" 2>/dev/null || true; } | awk '{print $1}' | head -1)
    [ -n "$DOM_IP" ] || DOM_IP=$( { getent hosts "$DOMAIN" 2>/dev/null || true; } | awk '{print $1}' | head -1)
    if [ -n "$DOM_IP" ] && [ "$DOM_IP" = "$PUB_IP" ]; then
      DNS_OK=1; ok "DNS 已指向本机（$PUB_IP）"; break
    fi
    if [ -n "$DOM_IP" ]; then
      warn "DNS 指向 $DOM_IP，本机是 $PUB_IP —— 不一致，证书签发会失败"
    else
      warn "域名 $DOMAIN 还没有解析记录，本机公网 IP 是 $PUB_IP"
    fi
    if [ -t 0 ] && [ "$NONINTERACTIVE" != "1" ] && [ "$dns_try" -lt 5 ]; then
      echo "    ${C_BOLD}请到域名 DNS 服务商添加这条记录：${C_0}"
      echo "      ${C_G}A${C_0}    ${DOMAIN}    →    ${PUB_IP}"
      echo "    ${C_D}（域名若走了 Cloudflare 等代理，记得先关掉橙云，否则证书签不下来）${C_0}"
      ask "    加好并保存后按回车立即复检（输入 skip 跳过）" ""
      [ "$REPLY_ASK" = "skip" ] && break
      continue
    fi
    break
  done
  [ -n "$DNS_OK" ] || warn "DNS 仍未就绪 —— 证书可能签不下来；补齐解析后重新执行 bind-domain 即可"

  local PROXY_OK="" SCHEME="https" CERT_OK=""

  if [ "$HAS_NGINX" = "1" ]; then
    info "检测到已运行 Nginx，将通过 Nginx 配置反向代理（跳过 Caddy，避免 80/443 冲突）"
    local DOMAIN_SLUG SITE_FILE
    DOMAIN_SLUG="$(printf '%s' "$DOMAIN" | cut -d, -f1 | tr -d ' ')"
    [ -n "$NGINX_CONF_DIR" ] || NGINX_CONF_DIR="/etc/nginx/conf.d"
    mkdir -p "$NGINX_CONF_DIR"
    SITE_FILE="$NGINX_CONF_DIR/${DOMAIN_SLUG}.conf"

    if [ -f "$SITE_FILE" ]; then
      ok "$DOMAIN 站点 Nginx 配置已存在，跳过覆盖（$SITE_FILE）"
    else
      cat > "$SITE_FILE" <<NGINX
# 由 WorkBuddy-Proxy 部署脚本生成（适配 Nginx / 科技Lion）
server {
    listen 80;
    server_name ${DOMAIN};

    client_max_body_size 50M;

    location / {
        proxy_pass http://127.0.0.1:${MANAGER_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port \$server_port;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # AI 常用流式输出（SSE / Stream）与长连接强化
        proxy_buffering off;
        proxy_cache off;
        proxy_set_header X-Accel-Buffering no;
        chunked_transfer_encoding on;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_connect_timeout 60s;
    }
}
NGINX
      ok "已生成 Nginx 反代配置（已强化 SSE 流式响应）：$SITE_FILE"
    fi

    if [ -n "$API_DOMAIN" ] && [ "$API_DOMAIN" != "$DOMAIN" ]; then
      local API_SLUG ASITE
      API_SLUG="$(printf '%s' "$API_DOMAIN" | cut -d, -f1 | tr -d ' ')"
      ASITE="$NGINX_CONF_DIR/${API_SLUG}.conf"
      if [ -f "$ASITE" ]; then
        ok "$API_DOMAIN 站点 Nginx 配置已存在，跳过覆盖"
      else
        cat > "$ASITE" <<NGINX
# 由 WorkBuddy-Proxy 部署脚本生成（独立 API 域名，只暴露 /v1）
server {
    listen 80;
    server_name ${API_DOMAIN};

    client_max_body_size 50M;

    location /v1/ {
        proxy_pass http://127.0.0.1:${MANAGER_PORT}/v1/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port \$server_port;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_buffering off;
        proxy_cache off;
        proxy_set_header X-Accel-Buffering no;
        chunked_transfer_encoding on;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_connect_timeout 60s;
    }

    location / {
        return 404;
    }
}
NGINX
        ok "已生成 $ASITE（仅 /v1，已强化 SSE 流式响应）"
      fi
    fi

    if eval "${NGINX_TEST_CMD:-nginx -t}" >/dev/null 2>&1; then
      eval "${NGINX_RELOAD_CMD:-systemctl reload nginx || nginx -s reload}" >/dev/null 2>&1 || true
      PROXY_OK=1
      ok "Nginx 语法校验通过并已热重载生效"
    else
      warn "Nginx 配置文件测试有误，请排查（可用 ${NGINX_TEST_CMD:-nginx -t}）"
    fi

    local scheme_try C
    for scheme_try in "https" "http"; do
      C=$(curl -sS --max-time 5 -k -o /dev/null -w "%{http_code}" "${scheme_try}://${DOMAIN}/api/healthz" 2>/dev/null || echo "")
      if [ "$C" = "200" ]; then
        SCHEME="$scheme_try"; CERT_OK=1
        ok "外网访问就绪: ${SCHEME}://${DOMAIN}"
        break
      fi
    done
    [ -n "$CERT_OK" ] || warn "域名暂未通（DNS 未生效或尚未申请 SSL 证书）"
  else
    # --- 原生环境：安装 Caddy（缺了自动装；已有则跳过）---
    install_deps >/dev/null 2>&1 || true
    if ! command -v caddy >/dev/null 2>&1; then
      info "安装 Caddy（官方 apt 源）…"
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gnupg >/dev/null 2>&1 || true
      command -v gpg >/dev/null 2>&1 || die "缺少 gpg(gnupg)，无法导入 Caddy 仓库签名；请先 apt-get install -y gnupg"
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
        || die "下载 Caddy 仓库签名失败（网络不通 dl.cloudsmith.io？）"
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list \
        || die "下载 Caddy 官方 apt 源失败（网络不通 dl.cloudsmith.io？）"
      apt-get update -qq >/dev/null 2>&1 || warn "apt-get update 失败，仍尝试直接安装 caddy"
      local CADDY_OUT
      if ! CADDY_OUT="$(apt-get install -y -qq caddy 2>&1)"; then
        printf '%s\n' "$CADDY_OUT" | tail -n 8 | sed 's/^/      /' >&2
        die "Caddy 安装失败（上方为 apt 的真实报错）"
      fi
    fi
    ok "Caddy $(caddy version 2>/dev/null | awk '{print $1}')"

    # 已知坑：Caddy 以 caddy 用户运行，日志目录必须存在且可写
    mkdir -p /var/log/caddy && chown -R caddy:caddy /var/log/caddy
    mkdir -p /etc/caddy/conf.d

    if [ ! -f /etc/caddy/Caddyfile ]; then
      printf 'import /etc/caddy/conf.d/*.caddy\n' > /etc/caddy/Caddyfile
      ok "新建 Caddyfile（conf.d 模式）"
    elif ! grep -q "conf.d" /etc/caddy/Caddyfile; then
      printf '\nimport /etc/caddy/conf.d/*.caddy\n' >> /etc/caddy/Caddyfile
      ok "主 Caddyfile 已追加 conf.d 引入（原有站点配置保留不动）"
    fi

    local DOMAIN_SLUG SITE_FILE
    DOMAIN_SLUG="$(printf '%s' "$DOMAIN" | cut -d, -f1 | tr -d ' ')"
    SITE_FILE="/etc/caddy/conf.d/${DOMAIN_SLUG}.caddy"
    if [ -f "$SITE_FILE" ] || grep -qE "^[[:space:]]*${DOMAIN} \{" /etc/caddy/Caddyfile 2>/dev/null; then
      ok "$DOMAIN 站点已配置，跳过"
    else
      cat > "$SITE_FILE" <<CADDY
${DOMAIN} {
	reverse_proxy 127.0.0.1:${MANAGER_PORT}
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "no-referrer"
		-Server
	}
	log {
		output file /var/log/caddy/${DOMAIN}.log {
			roll_size 10MiB
			roll_keep 2
		}
	}
}
CADDY
      ok "已生成 $SITE_FILE"
    fi

    if [ -n "$API_DOMAIN" ] && [ "$API_DOMAIN" != "$DOMAIN" ]; then
      local API_SLUG ASITE
      API_SLUG="$(printf '%s' "$API_DOMAIN" | cut -d, -f1 | tr -d ' ')"
      ASITE="/etc/caddy/conf.d/${API_SLUG}.caddy"
      if [ -f "$ASITE" ]; then
        ok "$API_DOMAIN 站点已配置，跳过"
      else
        cat > "$ASITE" <<CADDY
${API_DOMAIN} {
	handle /v1/* {
		reverse_proxy 127.0.0.1:${MANAGER_PORT}
	}
	handle {
		respond "Not Found" 404
	}
}
CADDY
        ok "已生成 $ASITE（仅 /v1，不含面板）"
      fi
    fi

    # 先把站点日志文件按 caddy 身份建好，再校验
    grep -hoE '/var/log/caddy/[^ {]+\.log' /etc/caddy/conf.d/*.caddy 2>/dev/null | sort -u | while read -r _logf; do
      [ -e "$_logf" ] || : > "$_logf" 2>/dev/null || true
      chown caddy:caddy "$_logf" 2>/dev/null || true
      chmod 640 "$_logf" 2>/dev/null || true
    done
    chown -R caddy:caddy /var/log/caddy 2>/dev/null || true

    local CADDY_VALIDATE_OUT
    if ! CADDY_VALIDATE_OUT="$(caddy validate --config /etc/caddy/Caddyfile 2>&1)"; then
      printf '%s\n' "$CADDY_VALIDATE_OUT" | tail -6 | sed 's/^/      /' >&2
      die "Caddyfile 校验失败（上方为真实报错），请检查 /etc/caddy/conf.d/ 下的站点文件"
    fi
    systemctl enable --now caddy >/dev/null 2>&1 || true
    systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 || true
    sleep 2
    if systemctl is-active caddy >/dev/null 2>&1; then
      PROXY_OK=1
      ok "caddy: active（80/443 已监听）"
    else
      warn "caddy 没能启动 —— 日志尾部："
      journalctl -u caddy --no-pager -n 8 2>/dev/null | sed 's/^/      /' >&2 || true
      warn "常见原因：80/443 被占用或安全组拦截"
    fi

    ok "等待证书签发（Let's Encrypt，通常 10~30 秒）…"
    local i C
    for i in $(seq 1 12); do
      C=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" "${SCHEME}://${DOMAIN}/api/healthz" 2>/dev/null || echo "")
      [ "$C" = "200" ] && { CERT_OK=1; break; }
      sleep 5
    done
    if [ -n "$CERT_OK" ]; then
      ok "外网访问就绪: ${SCHEME}://${DOMAIN}"
    else
      warn "域名暂未通（多为 DNS 未生效或 80/443 被安全组拦截），稍后手动验证：curl -I ${SCHEME}://${DOMAIN}"
    fi
  fi   # 结束反代分支

  # 记录绑定状态（与科技Lion的 kpanel 状态文件保持同一约定）
  mkdir -p "$STATE_DIR"
  printf 'domain_only\n' > "$ACCESS_CONF" 2>/dev/null || true
  printf '%s\n' "$MANAGER_PORT" > "$PORT_CONF" 2>/dev/null || true

  # 自动创建对外 API 密钥
  local M
  M=$(curl -sS --max-time 8 "http://127.0.0.1:${MANAGER_PORT}/api/healthz" 2>/dev/null || echo "")
  if [ -n "$M" ]; then
    if [ -n "${MANAGER_API_KEY:-}" ]; then
      ok "外网 API 密钥已存在（.credentials 的 MANAGER_API_KEY）"
    else
      info "自动创建对外 API 密钥（含重试机制）…"
      local MKEY="" attempt CK KR
      for attempt in 1 2 3; do
        CK="$(mktemp)"; chmod 600 "$CK"
        # 密码经 stdin + python JSON 转义传入：不出现在进程列表，也不破坏 JSON
        if printf '%s' "$ADMIN_PASSWORD" \
          | python3 -c 'import json,sys; print(json.dumps({"username":"admin","password":sys.stdin.read()}))' \
          | curl -sS --max-time 10 -c "$CK" -X POST "http://127.0.0.1:${MANAGER_PORT}/api/login" \
              -H "Content-Type: application/json" -d @- >/dev/null 2>&1; then
          KR=$(curl -sS --max-time 10 -b "$CK" -X POST "http://127.0.0.1:${MANAGER_PORT}/api/keys" \
            -H "Content-Type: application/json" -d '{"name":"default"}' 2>/dev/null || echo "")
          rm -f "$CK"
          MKEY=$(printf '%s' "$KR" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('key') or '')
except Exception:
    print('')
" 2>/dev/null || echo "")
          [ -n "$MKEY" ] && break
        else
          rm -f "$CK"
        fi
        sleep 2
      done

      if [ -n "$MKEY" ]; then
        umask 077
        if grep -q '^MANAGER_API_KEY=' "$CRED_FILE" 2>/dev/null; then
          grep -v '^MANAGER_API_KEY=' "$CRED_FILE" > "$CRED_FILE.tmp" || true
          mv "$CRED_FILE.tmp" "$CRED_FILE"
        fi
        printf 'MANAGER_API_KEY=%q\n' "$MKEY" >> "$CRED_FILE"
        umask 022
        ok "API 密钥已生成并保存（$CRED_FILE 的 MANAGER_API_KEY）"
      else
        warn "密钥自动创建失败（重试 3 次超时），可在面板「密钥」页手动创建"
      fi
    fi
  fi

  hr
  printf "\n  ${C_BOLD}域名绑定完成${C_0}\n\n"
  printf "  面板   %s://%s\n" "${SCHEME:-https}" "$DOMAIN"
  if [ -n "$API_DOMAIN" ] && [ "$API_DOMAIN" != "$DOMAIN" ]; then
    printf "  API    %s://%s/v1\n" "${SCHEME:-https}" "$API_DOMAIN"
  else
    printf "  API    %s://%s/v1\n" "${SCHEME:-https}" "$DOMAIN"
  fi
  printf "  代理   %s\n" "$([ "$HAS_NGINX" = "1" ] && echo Nginx || echo Caddy)"
  printf "  证书   %s\n" "$([ -n "$CERT_OK" ] && echo '已签发' || echo '未签发（见上方提示）')"
  hr
}

do_unbind_domain() {
  local THE_DOMAIN="${1:-}"
  [ -n "$THE_DOMAIN" ] || die "unbind-domain 需要一个域名参数：workbuddy-deploy.sh unbind-domain wb.example.com"
  step "删除域名反代配置（$THE_DOMAIN）"
  detect_proxy_env

  local SLUG REMOVED=0
  SLUG="$(printf '%s' "$THE_DOMAIN" | cut -d, -f1 | tr -d ' ')"

  # Nginx 站点
  local dirs="/etc/nginx/conf.d /home/web/conf.d /etc/nginx/sites-enabled"
  local d
  for d in $dirs; do
    if [ -f "$d/${SLUG}.conf" ]; then
      rm -f "$d/${SLUG}.conf" && ok "已删除 $d/${SLUG}.conf" && REMOVED=1
    fi
  done

  # Caddy 站点
  if [ -f "/etc/caddy/conf.d/${SLUG}.caddy" ]; then
    rm -f "/etc/caddy/conf.d/${SLUG}.caddy" && ok "已删除 /etc/caddy/conf.d/${SLUG}.caddy" && REMOVED=1
  fi
  # 主 Caddyfile 里手写过的站点块
  if [ -f /etc/caddy/Caddyfile ] && grep -qE "^[[:space:]]*${SLUG} \{" /etc/caddy/Caddyfile 2>/dev/null; then
    python3 - "/etc/caddy/Caddyfile" "$SLUG" <<'PY'
import re, sys
p, slug = sys.argv[1], sys.argv[2]
src = open(p, encoding='utf-8').read()
# 删掉 "slug { ... }" 顶格块（大括号配平）
pat = re.compile(r'(?ms)^[ \t]*' + re.escape(slug) + r'[ \t]*\{.*?^\}\s*\n?')
new, n = pat.subn('', src)
if n:
    open(p, 'w', encoding='utf-8').write(new)
print(f"removed {n} block(s) from Caddyfile")
PY
    REMOVED=1
  fi

  if [ "$REMOVED" = "0" ]; then
    warn "未找到 $THE_DOMAIN 的反代配置文件（可能从未绑定，或用了其它路径）"
  fi

  # 重载：Nginx 可能是宿主服务，也可能是 kejilion 的 Docker 容器 ——
  # NGINX_TEST_CMD / NGINX_RELOAD_CMD 在检测阶段已经按环境选好了。
  local RELOAD_OK=0
  if [ "$HAS_NGINX" = "1" ]; then
    if eval "${NGINX_TEST_CMD:-nginx -t}" >/dev/null 2>&1; then
      if eval "${NGINX_RELOAD_CMD:-systemctl reload nginx}" >/dev/null 2>&1; then
        ok "Nginx 已重载"
        RELOAD_OK=1
      else
        warn "Nginx 配置校验通过，但重载失败（${NGINX_RELOAD_CMD}）"
      fi
    else
      warn "Nginx 配置校验未通过，已跳过重载 —— 请跑 ${NGINX_TEST_CMD:-nginx -t} 看详情"
    fi
  fi
  if command -v caddy >/dev/null 2>&1 && systemctl is-active caddy >/dev/null 2>&1; then
    if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
      systemctl reload caddy >/dev/null 2>&1 && { ok "Caddy 已重载"; RELOAD_OK=1; } \
        || warn "Caddy 校验通过但重载失败"
    else
      warn "Caddyfile 校验未通过，已跳过重载"
    fi
  fi
  [ "$RELOAD_OK" = "1" ] || warn "反代未重载 —— 配置已删除，但可能需要手动 reload 使其生效"

  printf 'port_only\n' > "$ACCESS_CONF" 2>/dev/null || true
  hr
  printf "\n  ${C_BOLD}域名已解绑${C_0}：%s\n" "$THE_DOMAIN"
  printf "  ${C_D}容器与数据未受影响；面板仍在本机 127.0.0.1:%s 可用。${C_0}\n" "$MANAGER_PORT"
  hr
}

# ---------------------------------------------------------------- 卸载
do_uninstall() {
  step "卸载 WorkBuddy 反代"

  # ══════════════════════════════════════════════════════════════════
  # 闸门 —— 任何破坏性动作之前先过这里。顺序不可调换。
  # 本次生产事故就是因为这一段不存在：脚本直接信了 BASE_DIR 变量。
  # ══════════════════════════════════════════════════════════════════

  # 闸 1：路径本身是否可删（拦 /、系统目录、过浅路径、通配符）
  assert_safe_to_erase "$BASE_DIR" >/dev/null

  # 闸 2：这个目录到底是不是本脚本装的（哨兵 + 参数一致性）
  require_install_mark "卸载"

  # 闸 3：要删的目录与要删的容器必须自洽 ——
  #       哨兵里记录的容器名/端口，必须与当前运行配置一致。
  #       不一致说明参数串了，宁可停手。
  local mk_up mk_mg mk_p1 mk_p2
  mk_up="$(sed -n 's/^UP_NAME=//p' "$INSTALL_MARK" | head -1)"
  mk_mg="$(sed -n 's/^MG_NAME=//p' "$INSTALL_MARK" | head -1)"
  mk_p1="$(sed -n 's/^WB2API_PORT=//p' "$INSTALL_MARK" | head -1)"
  mk_p2="$(sed -n 's/^MANAGER_PORT=//p' "$INSTALL_MARK" | head -1)"
  [ -n "$mk_up" ] && [ "$mk_up" != "$UP_NAME" ] && \
    die "卸载被拒绝：标记里网关容器是 $mk_up，当前是 $UP_NAME —— 不一致"
  [ -n "$mk_mg" ] && [ "$mk_mg" != "$MG_NAME" ] && \
    die "卸载被拒绝：标记里面板容器是 $mk_mg，当前是 $MG_NAME —— 不一致"
  # 用标记里的端口（而非当前变量），保证「要删的就是当初装的那套」
  [ -n "$mk_p1" ] && WB2API_PORT="$mk_p1"
  [ -n "$mk_p2" ] && MANAGER_PORT="$mk_p2"

  printf "  ${C_D}闸门通过：%s（标记于 %s）${C_0}\n" \
    "$BASE_DIR" "$(sed -n 's/^INSTALLED_AT=//p' "$WB_INSTALL_REGISTRY" 2>/dev/null | head -1 || echo '未知')"

  # 把最终要执行的 rm 目标再回显一次 —— 出事也能从日志追溯
  printf "  ${C_D}即将删除目录：%s${C_0}\n" "$BASE_DIR"

  local KEEP_DATA=0
  if [ -t 0 ] && [ "$NONINTERACTIVE" != "1" ]; then
    ask "  是否保留数据目录 auths/ data/（y = 保留并备份到 ${BASE_DIR}.data-backup）" "n"
    case "${REPLY_ASK:-n}" in y|Y|yes|YES) KEEP_DATA=1 ;; esac
  fi

  if [ "$KEEP_DATA" = "1" ]; then
    local BK="${BASE_DIR}.data-backup"
    mkdir -p "$BK"
    [ -d "$UP_DIR/auths" ] && cp -a "$UP_DIR/auths" "$BK/" 2>/dev/null || true
    [ -d "$UP_DIR/data" ]  && cp -a "$UP_DIR/data"  "$BK/" 2>/dev/null || true
    [ -d "$MG_DIR/data" ]  && cp -a "$MG_DIR/data"  "$BK/manager-data" 2>/dev/null || true
    ok "数据已备份到 $BK"
  fi

  if [ -f "$MG_DIR/docker-compose.yml" ]; then
    docker compose -f "$MG_DIR/docker-compose.yml" down --rmi all >/dev/null 2>&1 \
      && ok "面板容器与镜像已移除" \
      || warn "面板 compose down 未完全成功（可能已不存在）"
  fi
  if [ -f "$UP_DIR/docker-compose.yml" ]; then
    docker compose -f "$UP_DIR/docker-compose.yml" down --rmi all >/dev/null 2>&1 \
      && ok "网关容器与镜像已移除" \
      || warn "网关 compose down 未完全成功（可能已不存在）"
  fi

  # 兜底移除漏网容器 / 镜像
  docker rm -f "$MG_NAME" "$UP_NAME" >/dev/null 2>&1 || true
  docker rmi -f "$MANAGER_IMAGE" "$WB2API_IMAGE" >/dev/null 2>&1 || true

  # 共享网络：没有成员时才删
  if docker network inspect "$NET_NAME" >/dev/null 2>&1; then
    local n
    n="$(docker network inspect "$NET_NAME" --format '{{len .Containers}}' 2>/dev/null || echo 0)"
    [ "$n" = "0" ] && docker network rm "$NET_NAME" >/dev/null 2>&1 || true
  fi

  # 自动生成的域名配置一并清掉（避免留下指向死端口的悬空反代）
  # 注意：grep 无匹配时退出码非 0，set -o pipefail + set -e 下会直接终止函数
  #       —— 所以这里用进程替换 + `|| true`，而不是管道。
  local d f
  for d in /etc/nginx/conf.d /home/web/conf.d /etc/caddy/conf.d; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rm -f "$f" && printf "  ${C_G}✓${C_0} 已移除悬空反代配置 %s\n" "$f"
    done < <(grep -rls "127.0.0.1:${MANAGER_PORT}\|127.0.0.1:${WB2API_PORT}" "$d" 2>/dev/null || true)
  done
  detect_proxy_env
  if [ "$HAS_NGINX" = "1" ]; then
    eval "${NGINX_RELOAD_CMD:-systemctl reload nginx}" >/dev/null 2>&1 || true
  fi
  command -v caddy >/dev/null 2>&1 && systemctl reload caddy >/dev/null 2>&1 || true

  rm -rf "$BASE_DIR"
  rm -f "$ACCESS_CONF" "$PORT_CONF"

  # 注册表只在「记的就是这套目录」时才清掉，避免多实例场景误删别人的记录
  if [ -f "$WB_INSTALL_REGISTRY" ]; then
    local reg_dir
    reg_dir="$(sed -n 's/^BASE_DIR=//p' "$WB_INSTALL_REGISTRY" | head -1)"
    if [ "$reg_dir" = "$BASE_DIR" ]; then
      rm -f "$WB_INSTALL_REGISTRY"
    else
      warn "全局注册表记录的是 $reg_dir，与本次卸载的 $BASE_DIR 不同 —— 已保留"
    fi
  fi

  ok "安装目录 $BASE_DIR 已删除"

  hr
  printf "\n  ${C_BOLD}卸载完成${C_0}\n"
  if [ "$KEEP_DATA" = "1" ]; then
    printf "  数据备份：%s\n" "${BASE_DIR}.data-backup"
  else
    printf "  ${C_Y}数据（含账号凭证）已一并删除${C_0}\n"
  fi
  hr
}

# ---------------------------------------------------------------- 状态
do_status() {
  step "运行状态"
  # 若 BASE_DIR 是自动发现的，这里要把哨兵里的容器名/端口套进来，
  # 否则显示的是脚本默认端口，跟实际实例对不上。
  apply_install_mark_identity
  local running
  running="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"

  printf "\n  ${C_BOLD}容器${C_0}\n"
  local c
  for c in "$UP_NAME" "$MG_NAME"; do
    if printf '%s\n' "$running" | grep -qx "$c"; then
      printf "  ${C_G}●${C_0} %-22s %s\n" "$c" "$(docker inspect -f '{{.State.Status}} · up {{.State.StartedAt}}' "$c" 2>/dev/null)"
    elif docker container inspect "$c" >/dev/null 2>&1; then
      printf "  ${C_Y}○${C_0} %-22s 已创建但未运行\n" "$c"
    else
      printf "  ${C_D}·${C_0} %-22s 不存在\n" "$c"
    fi
  done

  printf "\n  ${C_BOLD}端口${C_0}\n"
  printf "  %-22s %s\n" "网关 127.0.0.1:${WB2API_PORT}" "$(ss -tlnp 2>/dev/null | grep -q ":${WB2API_PORT} " && echo 监听中 || echo 未监听)"
  printf "  %-22s %s\n" "面板 127.0.0.1:${MANAGER_PORT}" "$(ss -tlnp 2>/dev/null | grep -q ":${MANAGER_PORT} " && echo 监听中 || echo 未监听)"

  printf "\n  ${C_BOLD}健康检查${C_0}\n"
  local H M
  H="$(curl -sS --max-time 5 "http://127.0.0.1:${WB2API_PORT}/healthz" 2>/dev/null || echo "")"
  M="$(curl -sS --max-time 5 "http://127.0.0.1:${MANAGER_PORT}/api/healthz" 2>/dev/null || echo "")"
  printf "  %-22s %s\n" "网关 /healthz" "${H:-无响应（无账号时 503 属正常）}"
  printf "  %-22s %s\n" "面板 /api/healthz" "${M:-无响应}"

  printf "\n  ${C_BOLD}代理总览（逐账号出站）${C_0}\n"
  do_proxy_list

  printf "\n  ${C_BOLD}域名${C_0}\n"
  if [ -f "$ACCESS_CONF" ]; then
    printf "  模式   %s\n" "$(cat "$ACCESS_CONF" 2>/dev/null)"
  else
    printf "  模式   ${C_D}未绑定域名（仅本机 127.0.0.1）${C_0}\n"
  fi
  # 找出所有指向本服务端口的反代站点配置。注意：
  #   · grep 无匹配时退出码非 0，set -o pipefail 下会让整个函数返回非零 ——
  #     所以这里既用 `|| true` 也显式 `return 0`（status 是只读命令，不该报错退出）。
  local f FOUND=0
  for d in /etc/nginx/conf.d /home/web/conf.d /etc/caddy/conf.d; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      printf "  站点   %s\n" "$f"
      FOUND=1
    done < <(grep -rls "127.0.0.1:${MANAGER_PORT}" "$d" 2>/dev/null || true)
  done
  [ "$FOUND" = "1" ] || printf "  站点   ${C_D}（无）${C_0}\n"

  # 反代服务可用性（Nginx 可能是宿主的，也可能是 kejilion 的 Docker 容器）
  # 注意：NGINX_TEST_CMD 只有 detect_proxy_env 跑过才有值，这里必须先调一次，
  # 否则 eval "" 会失败 → 假警报「配置校验未通过」。
  detect_proxy_env
  printf "\n  ${C_BOLD}反向代理${C_0}\n"
  local rs=""
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '^nginx$'; then
    rs="Nginx（Docker 容器 nginx）"
  elif command -v nginx >/dev/null 2>&1; then
    rs="Nginx（宿主）"
  elif command -v caddy >/dev/null 2>&1; then
    rs="Caddy"
  fi
  printf "  %-22s %s\n" "服务" "${rs:-未检测到}"
  if [ -n "$rs" ]; then
    if eval "${NGINX_TEST_CMD:-nginx -t}" >/dev/null 2>&1; then
      printf "  %-22s %s\n" "配置校验" "通过（${NGINX_TEST_CMD}）"
    else
      printf "  %-22s %s\n" "配置校验" "${C_Y}未通过${C_0}"
      printf "  %-22s %s\n" "" "${C_D}跑 ${NGINX_TEST_CMD:-nginx -t} 看详情${C_0}"
    fi
  fi
  echo
  return 0
}

# ---------------------------------------------------------------- 代理（核心新功能）
proxy_dir() { printf '%s' "$UP_DIR/auths"; }

do_proxy_list() {
  local D
  D="$(proxy_dir)"
  if [ ! -d "$D" ] || ! ls "$D"/*.json >/dev/null 2>&1; then
    printf "  ${C_D}（还没有账号文件；先在面板「账号」页扫码添加账号）${C_0}\n"
    return 0
  fi
  python3 - "$D" <<'PY'
import json, os, sys
d = sys.argv[1]
rows = []
for fn in sorted(os.listdir(d)):
    if not fn.endswith('.json'):
        continue
    p = os.path.join(d, fn)
    try:
        raw = json.load(open(p, encoding='utf-8'))
    except Exception:
        rows.append((fn, '', '', '(解析失败)'))
        continue
    if not isinstance(raw, dict):
        rows.append((fn, '', '', '(格式异常)'))
        continue
    uid = str(raw.get('uid') or raw.get('user_id') or os.path.splitext(fn)[0])
    proxy = str(raw.get('proxy') or '').strip()
    nick = str(raw.get('nickname') or raw.get('name') or '')
    rows.append((fn, uid[:12], proxy or '直连', nick))

if not rows:
    print("  （auths/ 下没有账号文件）")
    sys.exit(0)

w_uid = max(len(r[1]) for r in rows + [('', 'UID', '', '')])
w_proxy = max(len(r[2]) for r in rows + [('', '', 'PROXY', '')])
print(f"  {'UID':<{w_uid}}  {'PROXY':<{w_proxy}}  NICKNAME")
print(f"  {'-'*w_uid}  {'-'*w_proxy}  {'-'*8}")
for fn, uid, proxy, nick in rows:
    print(f"  {uid:<{w_uid}}  {proxy:<{w_proxy}}  {nick}")
print(f"\n  共 {len(rows)} 个账号；配了 proxy 的走该出口，未配的直连。")
PY
}

do_proxy_set() {
  local D TARGET PXY
  D="$(proxy_dir)"
  [ -d "$D" ] || die "账号目录不存在：$D（先安装并添加账号）"

  step "配置账号出站代理"
  do_proxy_list
  echo
  ask "  要配置的账号文件名或 uid（如 26d714e4…，留空取消）" ""
  TARGET="$REPLY_ASK"
  [ -n "$TARGET" ] || { info "已取消"; return 0; }

  # 解析成实际文件
  local FILE=""
  FILE="$(python3 - "$D" "$TARGET" <<'PY'
import json, os, sys
d, want = sys.argv[1], sys.argv[2]
want_l = want.lower()
hits = []
for fn in sorted(os.listdir(d)):
    if not fn.endswith('.json'):
        continue
    p = os.path.join(d, fn)
    if fn == want or fn.lower() == want_l or os.path.splitext(fn)[0].lower() == want_l:
        hits.append(fn); continue
    try:
        raw = json.load(open(p, encoding='utf-8'))
    except Exception:
        continue
    if isinstance(raw, dict):
        uid = str(raw.get('uid') or raw.get('user_id') or '')
        if uid and uid.lower() == want_l:
            hits.append(fn)
print(hits[0] if len(hits) == 1 else ('AMBIGUOUS:' + ','.join(hits) if hits else ''))
PY
)"
  case "$FILE" in
    AMBIGUOUS:*) die "匹配到多个文件：${FILE#AMBIGUOUS:} —— 请用带 .json 的完整文件名" ;;
    "")          die "没找到匹配的账号：$TARGET" ;;
  esac
  ok "目标账号文件：$FILE"

  echo "  ${C_D}格式：scheme://[user[:pass]@]host:port"
  echo "  ${C_D}scheme ∈ http / https / socks5 / socks5h；密码里的 # 必须写成 %23${C_0}"
  ask "  代理地址（留空 = 清除代理、改直连）" ""
  PXY="$REPLY_ASK"

  if [ -n "$PXY" ]; then
    case "$PXY" in
      http://*|https://*|socks5://*|socks5h://*) : ;;
      *) die "代理必须以 http:// / https:// / socks5:// / socks5h:// 开头" ;;
    esac
  fi

  python3 - "$D/$FILE" "$PXY" <<'PY'
import json, os, tempfile, sys
path, pxy = sys.argv[1], sys.argv[2]
raw = json.load(open(path, encoding='utf-8'))
if not isinstance(raw, dict):
    print("ERROR: 账号文件不是 JSON 对象", file=sys.stderr); sys.exit(1)
if pxy:
    raw['proxy'] = pxy
else:
    raw.pop('proxy', None)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, 'w', encoding='utf-8') as f:
    json.dump(raw, f, ensure_ascii=False, indent=2)
    f.write('\n')
os.replace(tmp, path)
print(f"{'已设置' if pxy else '已清除'} proxy = {pxy or '(直连)'}")
PY

  ok "写入完成 —— 网关每 5 秒自动热加载 auths/，无需重启"
  info "验证：等 10 秒后在面板「账号」页看该账号的出站信息，或看网关日志："
  info "  docker logs --tail 20 ${UP_NAME}"

  local UP_UID_OWN=${UP_UID:-10001}
  chown "${UP_UID_OWN}:${UP_UID_OWN}" "$D/$FILE" 2>/dev/null || true
}

do_proxy_menu() {
  while true; do
    printf "\n  ${C_BOLD}代理管理（逐账号出站）${C_0}\n"
    printf "    1) 查看账号与代理总览\n"
    printf "    2) 设置 / 清除某账号的代理\n"
    printf "    3) 返回主菜单\n"
    ask "  选择" "1"
    case "${REPLY_ASK:-1}" in
      1) do_proxy_list; pause_any ;;
      2) do_proxy_set; pause_any ;;
      3) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ---------------------------------------------------------------- 凭据显示
do_credentials() {
  step "凭据"
  if [ ! -f "$CRED_FILE" ]; then
    warn "凭据文件不存在：$CRED_FILE（尚未安装？）"
    return 0
  fi
  printf "\n  ${C_BOLD}文件：%s${C_0}（权限 0600）\n\n" "$CRED_FILE"
  sed 's/^/    /' "$CRED_FILE"
  printf "\n  ${C_D}上游 api_key：网关直连鉴权（Bearer）\n"
  printf "  面板管理员密码：登录面板用\n"
  printf "  MANAGER_API_KEY：对外接各类 OpenAI 兼容客户端用${C_0}\n\n"
}

# ---------------------------------------------------------------- 安装 / 更新
do_install() {
  require_root
  T0=$(date +%s); STEP_NO=0

  # 交互向导（非交互 / --auto 跳过）
  if [ -t 0 ] && [ "$NONINTERACTIVE" != "1" ]; then
    step "部署配置向导"
    echo "  直接回车 = 用方括号里的默认值；Ctrl+C 取消部署"
    echo
    if [ -z "$DOMAIN" ]; then
      ask "  面板域名（留空 = 仅本机访问，之后也能用菜单绑定）" ""
      DOMAIN="$REPLY_ASK"
      if [ -n "$DOMAIN" ]; then
        ask "  独立 API 域名（可选，只暴露 /v1、不含面板；留空 = 与面板同域）" "$API_DOMAIN"
        API_DOMAIN="$REPLY_ASK"
      fi
      echo
    fi
    echo "  ${C_BOLD}管理员密码${C_0}"
    if [ -f "$CRED_FILE" ]; then
      echo "  已有密码保存在 $CRED_FILE"
      ask "  直接回车 = 沿用现有密码；输入新密码（≥8 位）= 重置面板密码" ""
      if [ -n "$REPLY_ASK" ]; then
        if [ ${#REPLY_ASK} -lt 8 ]; then
          warn "少于 8 位，沿用现有密码"
        elif ! password_is_safe "$REPLY_ASK"; then
          warn "含不安全字符，沿用现有密码"
        else
          ADMIN_PASSWORD="$REPLY_ASK"; PASSWD_RESET=1
          ok "部署完成后将重置面板管理员密码"
        fi
      fi
    else
      ask "  管理员密码（直接回车 = 自动生成强密码）" ""
      if [ -z "$REPLY_ASK" ]; then
        ok "将自动生成强密码"
      elif [ ${#REPLY_ASK} -lt 8 ] || ! password_is_safe "$REPLY_ASK"; then
        warn "长度不足或含不安全字符，改用自动生成"
      else
        ADMIN_PASSWORD="$REPLY_ASK"
        ok "使用自定义密码"
      fi
    fi
    echo
  fi

  install_deps
  preflight
  gen_credentials

  # 哨兵 + 全局注册表：在任何容器/文件落地**之前**写好归属凭据。
  # 这样从这一刻起，卸载/更新就有一致性依据；装到一半失败也不会留下
  # 「有目录、没标记」这种卸载拒绝的尴尬状态。
  write_install_mark
  write_global_registry

  sync_source
  write_gateway_config
  write_compose_files
  build_and_start
  health_check

  # 域名
  if [ -n "$DOMAIN" ]; then
    do_bind_domain "$DOMAIN"
  elif [ -t 0 ] && [ "$NONINTERACTIVE" != "1" ]; then
    step "可选：绑定域名"
    echo "  现在面板只绑在 127.0.0.1，浏览器直接访问不了（要 SSH 隧道才行）。"
    ask "  要现在绑定域名吗？（输入域名 = 现在配好；留空 = 跳过）" ""
    if [ -n "$REPLY_ASK" ]; then
      DO_BIND="$REPLY_ASK"
      ask "  独立 API 域名（可选，留空 = 与面板同域）" ""
      API_DOMAIN="$REPLY_ASK"
    fi
    echo
  fi

  # 汇总
  local IP MEM_MB DOMAIN_SUMMARY API_SUMMARY
  IP="$(public_ip)"
  MEM_MB="$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')"
  MEM_MB="${MEM_MB:-?}"
  if [ -n "$DOMAIN" ]; then
    DOMAIN_SUMMARY="https://${DOMAIN}   （未签发证书则为 http，见上方提示）"
    API_SUMMARY="https://${API_DOMAIN:-$DOMAIN}/v1"
  else
    DOMAIN_SUMMARY="http://127.0.0.1:${MANAGER_PORT}   （仅本机，SSH 隧道访问）"
    API_SUMMARY="http://127.0.0.1:${WB2API_PORT}/v1"
  fi

  hr
  cat <<SUM

  ${C_BOLD}${RUN_MODE:-部署完成}${C_0} · 总耗时 $(elapsed)

  网关   ${API_SUMMARY}   （API 端点）
  面板   ${DOMAIN_SUMMARY}   （管理面板）
  服务器 $IP   ·  内存 ${MEM_MB}MB

  ${C_BOLD}凭据（已存 $CRED_FILE，0600）${C_0}
    上游 api_key   : ${API_KEY:0:8}…（完整值看文件）
    面板管理员密码 : ${ADMIN_PASSWORD}

  ${C_BOLD}下一步${C_0}
    1) 加账号：SSH 隧道 ssh -L ${MANAGER_PORT}:127.0.0.1:${MANAGER_PORT} root@${IP}
       浏览器打开 http://localhost:${MANAGER_PORT} → 「账号」→ 添加账号 → 扫码
    2) 配代理：本脚本菜单 7) 代理 —— 给每个账号配独立 SOCKS5/HTTP 出口
    3) 绑域名：本脚本菜单 4) 绑定域名（Nginx 优先，无则 Caddy + 自动签证书）
    4) 看日志：docker logs -f ${UP_NAME} / docker logs -f ${MG_NAME}

  ${C_BOLD}定时积分任务（6 类独立排程）${C_0}
    · 签到 (checkin)   : 09:00 / 21:00      · 活跃 (activity)  : 10:00
    · 猫猫 (travel)    : 09:00 / 21:00      · 保活 (keepalive) : 22:00
    · 开学 (school)    : 12:00              · 夜猫 (cat)       : 01:00
    * 错窗补跑：docker exec -it ${UP_NAME} ./acct.sh task <name>

  ${C_Y}注意${C_0}
${FIRST_RUN_NOTE:-    · 凭据以文件 $CRED_FILE 为准（0600，root 可读）。}
    · 面板容器挂载了 docker.sock 且持有账号明文凭证，等于本机高权限入口：
      只绑 127.0.0.1 + 走 HTTPS + 强密码，别把端口 ${MANAGER_PORT} 暴露到公网。
    · 内存较小的机器（1GB 级）：两个容器已限 256m/320m；
      升级请用本脚本「更新」，不要在面板里触发本机构建（会 OOM）。

SUM
  hr

  if [ -n "${DO_BIND:-}" ]; then
    do_bind_domain "$DO_BIND"
  fi
}

do_update() {
  require_root
  T0=$(date +%s); STEP_NO=0

  # 更新会重建容器 / 覆盖 compose / 重写配置 —— 同样必须确认「这是我们的实例」。
  # 参数指错了地方，这里就会把别人的目录改坏。
  assert_safe_to_erase "$BASE_DIR" >/dev/null
  require_install_mark "更新"

  # 用标记里的容器名/端口，保证更新作用于同一套实例
  local mk_up mk_mg mk_p1 mk_p2
  mk_up="$(sed -n 's/^UP_NAME=//p' "$INSTALL_MARK" | head -1)"
  mk_mg="$(sed -n 's/^MG_NAME=//p' "$INSTALL_MARK" | head -1)"
  mk_p1="$(sed -n 's/^WB2API_PORT=//p' "$INSTALL_MARK" | head -1)"
  mk_p2="$(sed -n 's/^MANAGER_PORT=//p' "$INSTALL_MARK" | head -1)"
  [ -n "$mk_up" ] && UP_NAME="$mk_up"
  [ -n "$mk_mg" ] && MG_NAME="$mk_mg"
  [ -n "$mk_p1" ] && WB2API_PORT="$mk_p1"
  [ -n "$mk_p2" ] && MANAGER_PORT="$mk_p2"

  step "更新（拉最新源码 + 重建镜像 + 重启）"
  SYNC_CODE=1
  if [ ! -f "$CRED_FILE" ]; then
    die "未找到凭据文件（$CRED_FILE）—— 请先执行 install"
  fi
  # shellcheck disable=SC1090
  source "$CRED_FILE"
  API_KEY="${API_KEY:-}"; ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
  RUN_MODE="更新"
  CRED_LOST=0; PASSWD_RESET=0

  if [ -f "$PORT_CONF" ]; then
    local _p
    _p="$(cat "$PORT_CONF" 2>/dev/null || true)"
    case "$_p" in ''|*[!0-9]*) : ;; *) MANAGER_PORT="$_p" ;; esac
  fi

  [ -n "$API_KEY" ] || die "凭据文件缺少 api_key —— 请重新执行 install"
  [ -n "$ADMIN_PASSWORD" ] || die "凭据文件缺少管理密码 —— 请重新执行 install"

  install_deps
  preflight
  sync_source
  write_gateway_config
  write_compose_files
  build_and_start
  health_check

  # 更新成功后刷新哨兵 / 注册表：容器名或端口若变了，这里同步过来，
  # 免得下次卸载时因为标记过期而拒绝执行。
  write_install_mark
  write_global_registry

  hr
  printf "\n  ${C_BOLD}更新完成${C_0} · 总耗时 $(elapsed)\n\n"
  printf "  网关   http://127.0.0.1:%s\n" "$WB2API_PORT"
  printf "  面板   http://127.0.0.1:%s\n\n" "$MANAGER_PORT"
  hr
}

# ---------------------------------------------------------------- 菜单
show_menu() {
  while true; do
    hr
    printf "\n  ${C_BOLD}WorkBuddy 反代 · 一键部署面板${C_0}\n"
    printf "  ${C_D}仓库 %s${C_0}\n\n" "$REPO_URL"
    printf "    1) 安装              首次部署 / 补装（源码构建 + 起容器）\n"
    printf "    2) 更新              拉最新源码 + 重建镜像 + 重启\n"
    printf "    3) 卸载              停容器 + 删镜像 + 删目录\n"
    printf "    4) 绑定域名          写反代配置（Nginx 优先，无则 Caddy + 签证书）\n"
    printf "    5) 删除域名          移除反代配置并重载\n"
    printf "    6) 状态              容器 / 端口 / 健康 / 代理总览\n"
    printf "    7) 代理              逐账号配置出站 SOCKS5 / HTTP 出口\n"
    printf "    8) 凭据              显示 api_key / 面板密码 / 对外密钥\n"
    printf "    0) 退出\n"
    ask "  请选择" "6"

    case "${REPLY_ASK:-6}" in
      1) do_install; pause_any ;;
      2) do_update; pause_any ;;
      3)
        ask "  确认卸载？输入 yes 继续" "no"
        case "${REPLY_ASK:-no}" in
          yes|YES|y|Y) do_uninstall; pause_any ;;
          *) info "已取消" ;;
        esac
        ;;
      4)
        ask "  要绑定的域名（如 wb.example.com）" ""
        if [ -n "$REPLY_ASK" ]; then
          local _d="$REPLY_ASK"
          ask "  独立 API 域名（可选，留空 = 与面板同域）" ""
          API_DOMAIN="$REPLY_ASK"
          do_bind_domain "$_d"
        else
          info "已取消"
        fi
        pause_any
        ;;
      5)
        ask "  要删除的域名" ""
        if [ -n "$REPLY_ASK" ]; then
          do_unbind_domain "$REPLY_ASK"
        else
          info "已取消"
        fi
        pause_any
        ;;
      6) do_status; pause_any ;;
      7) do_proxy_menu ;;
      8) do_credentials; pause_any ;;
      0) printf "\n  ${C_D}再见。${C_0}\n\n"; exit 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ---------------------------------------------------------------- 入口
require_root

case "$ACTION" in
  install)       do_install ;;
  update)        do_update ;;
  uninstall)     do_uninstall ;;
  bind-domain)   require_root; T0=$(date +%s); STEP_NO=0; detect_proxy_env
                 [ -f "$CRED_FILE" ] && { source "$CRED_FILE"; ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"; }
                 do_bind_domain "$ACTION_ARG" ;;
  unbind-domain) do_unbind_domain "$ACTION_ARG" ;;
  status)        do_status ;;
  credentials)   do_credentials ;;
  menu)          show_menu ;;
  "")
    if [ -t 0 ] && [ "$NONINTERACTIVE" != "1" ]; then
      show_menu
    else
      # 管道 / CI 场景：等价于 install --auto
      NONINTERACTIVE=1
      do_install
    fi
    ;;
esac
