#!/bin/bash
# 在非飞牛的 x86_64 Linux 上，用假的 TRIM_* 环境把 fpk 的生命周期脚本真实跑一遍（含失败路径）。
# 用法: packaging/fnos/test/simulate.sh dist/moontvplus_<版本>_x86.fpk [工作目录]
# 不需要 root；只监听 127.0.0.1 以外也无妨（HOSTNAME=0.0.0.0），测试端口默认 39310/39311。

set -uo pipefail

FPK="$(realpath "${1:?用法: simulate.sh <x86 fpk> [工作目录]}")"
WORK="${2:-$(mktemp -d)}"
PORT="${SIM_PORT:-39310}"
BUSY_PORT="${SIM_BUSY_PORT:-39311}"
PASS=0
FAIL=0

ok()   { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
step() { echo; echo "== $*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

T="${WORK}/moontvplus"
rm -rf "$T"
mkdir -p "${T}/target" "${T}/var" "${T}/etc" "${T}/pkg"
tar -xf "$FPK" -C "${T}/pkg" || { echo "解不开 $FPK"; exit 1; }
tar -xzf "${T}/pkg/app.tgz" -C "${T}/target" || { echo "解不开 app.tgz"; exit 1; }
CMD="${T}/pkg/cmd"

export TRIM_APPNAME=moontvplus TRIM_APPDEST="${T}/target" TRIM_PKGVAR="${T}/var" TRIM_PKGETC="${T}/etc"
export TRIM_APPVER="$(sed -n 's/^version=//p' "${T}/pkg/manifest")"
TEMPLOG="${T}/templog"

run() {  # 脚本名 [参数] —— 带全新的 TRIM_TEMP_LOGFILE 运行
  : > "$TEMPLOG"
  TRIM_TEMP_LOGFILE="$TEMPLOG" "${CMD}/$1" "${@:2}"
}
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }
login() {  # user pass → 打印 ok 字段（JSON 由 python 生成，密码里的引号等字符不会破坏请求体）
  python3 -I -c 'import json,sys; print(json.dumps({"username": sys.argv[1], "password": sys.argv[2]}))' "$1" "$2" \
    | curl -s --max-time 10 -H 'Content-Type: application/json' --data-binary @- "http://127.0.0.1:${PORT}/api/login" \
    | python3 -I -c 'import sys,json; print(json.load(sys.stdin).get("ok"))' 2>/dev/null
}
settings() { ( . "${T}/etc/settings.env"; eval "echo \"\${$1}\"" ); }

echo "fpk:  $FPK"
echo "工作: $T"
echo "版本: $TRIM_APPVER"

step "1. 安装前检查（install_init）"
python3 -I -c "import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', $BUSY_PORT)); s.listen(); time.sleep(600)" &
BLOCKER=$!
sleep 0.5
wizard_port="$BUSY_PORT" run install_init; rc=$?
check "端口被占用时安装被拒绝" [ "$rc" != 0 ]
check "并给出可读原因" grep -q "已被其他程序占用" "$TEMPLOG"
wizard_port="80" run install_init; rc=$?
check "端口 80 被拒绝" [ "$rc" != 0 ]
wizard_port="$PORT" run install_init
check "正常端口通过" [ $? = 0 ]

step "2. 安装（install_callback）"
wizard_port="$PORT" wizard_username=admin wizard_password='pa$$w0rd"x' run install_callback
check "install_callback 成功" [ $? = 0 ]
check "settings.env 权限 600" [ "$(stat -c %a "${T}/etc/settings.env")" = 600 ]
check "特殊字符密码原样保存" [ "$(settings MOONTV_PASSWORD)" = 'pa$$w0rd"x' ]
CRON1="$(settings MOONTV_CRON_PASSWORD)"
check "生成了随机 cron 密码" [ "${#CRON1}" = 32 ]
check "应用本体已解压到 var/server" [ -f "${T}/var/server/start.js" ]
check "版本戳一致" [ "$(cat "${T}/var/server/.fpk-version")" = "$(cat "${T}/target/server.version")" ]

step "3. 启动 / 状态（main）"
run main status; check "未启动时 status=3" [ $? = 3 ]
run main start
check "start 成功" [ $? = 0 ]
run main status; check "启动后 status=0" [ $? = 0 ]
PID="$(cat "${T}/var/logs/moontvplus.pid")"
check "pid 是内置 node 本身" grep -q "runtime/node/bin/node" "/proc/${PID}/cmdline"
check "内置 node 用自带的 libstdc++" grep -q "${T}/target/runtime/node/lib/libstdc++.so.6" "/proc/${PID}/maps"
check "登录页 200" [ "$(http_code "http://127.0.0.1:${PORT}/login")" = 200 ]
check "Socket.IO 200" [ "$(http_code "http://127.0.0.1:${PORT}/socket.io/?EIO=4&transport=polling")" = 200 ]
check "站长账号能登录" [ "$(login admin 'pa$$w0rd"x')" = True ]
check "错误密码登录失败" [ "$(login admin wrong)" != True ]
check "SQLite 数据库建在 var/data" [ -s "${T}/var/data/moontv.db" ]
check "manifest.json 在 var 里生成" [ -f "${T}/var/server/public/manifest.json" ]
code="$(http_code "http://127.0.0.1:${PORT}/api/cron/mtvpls")"
check "默认 cron 密码 mtvpls 被拒绝（401，实际 ${code}）" [ "$code" = 401 ]
# 202 = 已受理、后台执行；429 = start.js 启动后已自动触发过、处于冷却期。两者都说明密码通过了校验。
code="$(http_code --max-time 60 "http://127.0.0.1:${PORT}/api/cron/${CRON1}")"
check "随机 cron 密码通过校验（202/429，实际 ${code}）" [ "$code" = 202 -o "$code" = 429 ]
run main start; check "重复 start 幂等" [ $? = 0 ]
check "重复 start 不起第二个进程" [ "$(cat "${T}/var/logs/moontvplus.pid")" = "$PID" ]

step "4. 修改站长账号（config_callback）"
wizard_username="" wizard_password="newpass99" "${CMD}/config_callback"
check "config_callback 成功" [ $? = 0 ]
check "用户名留空保持不变" [ "$(settings MOONTV_USERNAME)" = admin ]
check "cron 密码保持不变" [ "$(settings MOONTV_CRON_PASSWORD)" = "$CRON1" ]
check "已自动重启（pid 变化）" [ "$(cat "${T}/var/logs/moontvplus.pid" 2>/dev/null)" != "$PID" ]
check "新密码能登录" [ "$(login admin newpass99)" = True ]
check "旧密码不能登录" [ "$(login admin 'pa$$w0rd"x')" != True ]

step "5. 停止"
run main stop; check "stop 成功" [ $? = 0 ]
run main status; check "停止后 status=3" [ $? = 3 ]
check "进程已退出" [ -z "$(pgrep -f "${T}/target/runtime/node/bin/node" || true)" ]

step "6. 端口被占用时启动失败要如实报告"
sed -i "s/^MOONTV_PORT=.*/MOONTV_PORT=${BUSY_PORT}/" "${T}/etc/settings.env"
run main start; rc=$?
check "start 返回失败" [ "$rc" != 0 ]
check "原因写进 TRIM_TEMP_LOGFILE" grep -q "已被其他程序占用" "$TEMPLOG"
sed -i "s/^MOONTV_PORT=.*/MOONTV_PORT=${PORT}/" "${T}/etc/settings.env"

step "7. 应用起不来时不能谎报成功"
mv "${T}/var/server/start.js" "${T}/var/server/start.js.bak"
echo 'process.exit(3)' > "${T}/var/server/start.js"
run main start; rc=$?
check "进程立即退出时 start 返回失败" [ "$rc" != 0 ]
check "并给出原因" grep -q "启动失败" "$TEMPLOG"
check "失败后没有残留 pidfile" [ ! -e "${T}/var/logs/moontvplus.pid" ]
mv -f "${T}/var/server/start.js.bak" "${T}/var/server/start.js"

step "8. 升级（upgrade_init / upgrade_callback）"
run main start >/dev/null
DB_INODE="$(stat -c %i "${T}/var/data/moontv.db")"
run upgrade_init; check "upgrade_init 停止了服务" [ "$(run main status; echo $?)" = 3 ]
echo "$(cat "${T}/target/server.version")-next" > "${T}/target/server.version"   # 模拟新版本
touch "${T}/var/server/marker-old"
run upgrade_callback; check "upgrade_callback 成功" [ $? = 0 ]
check "按新版本重新解压" [ ! -e "${T}/var/server/marker-old" ]
check "数据库没动" [ "$(stat -c %i "${T}/var/data/moontv.db")" = "$DB_INODE" ]
run main start; check "升级后能启动" [ $? = 0 ]
check "升级后旧账号数据仍可登录" [ "$(login admin newpass99)" = True ]
run main stop >/dev/null

step "9. 重装（保留 cron 密码，向导值覆盖）"
wizard_port="$PORT" wizard_username=boss wizard_password=another66 run install_callback
check "重装成功" [ $? = 0 ]
check "用户名被向导值覆盖" [ "$(settings MOONTV_USERNAME)" = boss ]
check "cron 密码保留" [ "$(settings MOONTV_CRON_PASSWORD)" = "$CRON1" ]

step "10. 卸载"
run main start >/dev/null
run uninstall_init; check "uninstall_init 停止了服务" [ "$(run main status; echo $?)" = 3 ]
wizard_keep_data=true "${CMD}/uninstall_callback"
check "保留数据：应用本体已删" [ ! -e "${T}/var/server" ]
check "保留数据：数据库还在" [ -s "${T}/var/data/moontv.db" ]
check "保留数据：配置还在" [ -f "${T}/etc/settings.env" ]
wizard_keep_data=false "${CMD}/uninstall_callback"
check "不保留：数据库已删" [ ! -e "${T}/var/data" ]
check "不保留：配置已删" [ ! -e "${T}/etc/settings.env" ]
mkdir -p "${WORK}/not-ours/server" "${WORK}/not-ours/data"
TRIM_PKGVAR="${WORK}/not-ours" wizard_keep_data=false "${CMD}/uninstall_callback"
check "路径不含 moontvplus 时拒绝删除" test -d "${WORK}/not-ours/server" -a -d "${WORK}/not-ours/data"
rm -rf "${WORK}/not-ours"

kill "$BLOCKER" 2>/dev/null
pkill -f "${T}/target/runtime/node/bin/node" 2>/dev/null
echo
echo "通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" = 0 ]
