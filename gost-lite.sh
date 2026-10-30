#!/bin/bash
# gost 精简版: 只做 tcp+udp 不加密流量转发
# 与完整版 gost.sh 共用 /etc/gost 下的 config.json 与 rawconf, 两个脚本可以随时互换
Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Green_background_prefix="\033[42;37m" && Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Warn="${Red_font_prefix}[警告]${Font_color_suffix}"
Cyan_font_prefix="\033[36m"
Bold="\033[1m"
shell_version="1.0.3"
ct_new_ver="2.11.2"
gost_conf_path="/etc/gost/config.json"
raw_conf_path="/etc/gost/rawconf"
cron_file="/etc/cron.d/gost-restart"
reinstall_confirmed=0

function die() {
  echo -e "${Error} $*" >&2
  exit 1
}
function warn() {
  echo -e "${Warn} $*" >&2
}

function json_ok() {
  local f="$1"
  [[ -s ${f} ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq empty "${f}" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${f}" >/dev/null 2>&1
  else
    grep -q '"ServeNodes"' "${f}" && tail -c 3 "${f}" | grep -q "}"
  fi || return 1
  grep -q '://' "${f}"
}

function check_root() {
  [[ $EUID != 0 ]] && echo -e "${Error} 当前非ROOT账号(或没有ROOT权限)，无法继续操作，请更换ROOT账号或使用 ${Green_background_prefix}sudo su${Font_color_suffix} 命令获取临时ROOT权限（执行后可能会提示输入当前账号的密码）。" && exit 1
}

function check_sys() {
  case "$(uname -m)" in
  x86_64 | amd64) bit="amd64" ;;
  i386 | i486 | i586 | i686) bit="386" ;;
  aarch64 | arm64) bit="armv8" ;;
  armv7l | armv7) bit="armv7" ;;
  armv6l | armv6) bit="armv6" ;;
  armv5l | armv5*) bit="armv5" ;;
  *)
    echo "无法识别当前架构 $(uname -m)，请输入芯片架构，/386/armv5/armv6/armv7/armv8"
    read -r bit
    case "${bit}" in
    386 | armv5 | armv6 | armv7 | armv8 | amd64) ;;
    *) die "不支持的架构: ${bit}" ;;
    esac
    ;;
  esac
}

# 下载失败直接中止, 不再降级为跳过证书校验重试
function download() {
  local url="$1" dest="$2"
  if command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 --timeout=20 -O "${dest}" "${url}" && return 0
    warn "下载失败（网络不通或证书校验未通过），已中止，未改动现有安装"
    return 1
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 180 -o "${dest}" "${url}" && return 0
    warn "下载失败（网络不通或证书校验未通过），已中止，未改动现有安装"
    return 1
  fi
  return 1
}

function Installation_dependency() {
  local pkgs=""
  command -v wget >/dev/null 2>&1 || pkgs="${pkgs} wget"
  command -v gzip >/dev/null 2>&1 || pkgs="${pkgs} gzip"
  [[ -z ${pkgs} ]] && return 0
  echo -e "${Info} 缺少依赖:${pkgs}，正在安装 ..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y ${pkgs} || die "依赖安装失败，请手动安装:${pkgs}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ${pkgs} || die "依赖安装失败，请手动安装:${pkgs}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ${pkgs} || die "依赖安装失败，请手动安装:${pkgs}"
  else
    die "未找到可用的包管理器，请手动安装:${pkgs}"
  fi
}

function check_file() {
  [[ -d /usr/lib/systemd/system ]] || mkdir -p /usr/lib/systemd/system || die "无法创建 /usr/lib/systemd/system，当前系统可能没有 systemd"
}

function check_nor_file() {
  rm -f /usr/bin/gost
  rm -f /usr/lib/systemd/system/gost.service
  rm -rf /etc/gost
}

# 先下载、解压、跑 gost -V 校验, 全部通过后才动旧文件
function Install_ct() {
  check_root
  Installation_dependency
  check_file
  check_sys

  local bin_url tmpdir backup_dir="" ans
  bin_url="https://github.com/ginuerzh/gost/releases/download/v${ct_new_ver}/gost-linux-${bit}-${ct_new_ver}.gz"

  if [[ -x /usr/bin/gost || -f /usr/lib/systemd/system/gost.service || -d /etc/gost ]]; then
    if ((reinstall_confirmed)); then
      :
    else
      echo -e "${Warn} 检测到已安装的 gost：将替换二进制与 unit，现有转发配置会保留"
      read -r -p "是否继续重装？[y/N]:" ans
      [[ ${ans} == [Yy] ]] || {
        echo "已取消"
        return 1
      }
    fi
    backup_dir=$(mktemp -d "${HOME:-/root}/.gost-backup.XXXXXX") || die "无法创建备份目录"
    if [[ -d /etc/gost ]]; then
      cp -a /etc/gost/. "${backup_dir}/" || die "备份 /etc/gost 失败，已中止安装"
    fi
  fi

  tmpdir=$(mktemp -d "${HOME:-/root}/.gost-install.XXXXXX") || die "无法创建临时目录"
  echo -e "${Info} 正在下载 gost v${ct_new_ver} (${bit}) ..."
  if ! download "${bin_url}" "${tmpdir}/gost.gz"; then
    rm -rf "${tmpdir}"
    die "gost 下载失败，现有安装未改动"
  fi
  if ! gunzip -f "${tmpdir}/gost.gz"; then
    rm -rf "${tmpdir}"
    die "gost 解压失败，下载内容可能已损坏，现有安装未改动"
  fi
  chmod 0755 "${tmpdir}/gost"
  if ! "${tmpdir}/gost" -V 2>&1 | grep -qF "${ct_new_ver}"; then
    rm -rf "${tmpdir}"
    die "下载的 gost 无法运行或版本不符（可能被篡改、不完整，或架构选择错误），已中止安装，现有安装未改动"
  fi

  check_nor_file

  cat >"${tmpdir}/gost.service" <<'UNIT'
[Unit]
Description=gost
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=5
LimitNOFILE=65535
ExecStart=/usr/bin/gost -C /etc/gost/config.json

[Install]
WantedBy=multi-user.target
UNIT
  cat >"${tmpdir}/config.json" <<'CONF'
{
    "Debug": true,
    "Retries": 0,
    "ServeNodes": [
        "udp://127.0.0.1:65532"
    ]
}
CONF

  install -m 0755 "${tmpdir}/gost" /usr/bin/gost || { rm -rf "${tmpdir}"; die "安装 gost 二进制失败，原配置备份在 ${backup_dir:-无}"; }
  install -m 0644 "${tmpdir}/gost.service" /usr/lib/systemd/system/gost.service || { rm -rf "${tmpdir}"; die "安装 service 文件失败，原配置备份在 ${backup_dir:-无}"; }
  mkdir -p /etc/gost && chmod 0700 /etc/gost
  install -m 0644 "${tmpdir}/config.json" /etc/gost/config.json || { rm -rf "${tmpdir}"; die "安装默认配置失败，原配置备份在 ${backup_dir:-无}"; }

  if [[ -n ${backup_dir} && -f "${backup_dir}/rawconf" ]]; then
    install -m 0644 "${backup_dir}/rawconf" "${raw_conf_path}" || warn "恢复 rawconf 失败"
    if [[ -f "${backup_dir}/config.json" ]]; then
      install -m 0600 "${backup_dir}/config.json" "${gost_conf_path}" || warn "恢复 config.json 失败"
    fi
    echo -e "${Info} 已恢复原有转发配置"
  fi
  [[ -n ${backup_dir} ]] && rm -rf "${backup_dir}"
  rm -rf "${tmpdir}"

  systemctl daemon-reload
  systemctl enable gost >/dev/null 2>&1
  systemctl restart gost
  sleep 1
  echo "------------------------------"
  if [[ -x /usr/bin/gost && -f /usr/lib/systemd/system/gost.service && -f /etc/gost/config.json ]] && systemctl is-active --quiet gost; then
    echo "gost安装成功"
  else
    echo "gost没有安装成功，请执行 systemctl status gost 及 journalctl -u gost -n 50 查看原因"
  fi
}

function Uninstall_ct() {
  check_root
  local ans
  echo -e "${Warn} 即将停止并删除 gost、/etc/gost 下的全部转发配置和定时重启任务"
  read -r -p "确认卸载？[y/N]:" ans
  [[ ${ans} == [Yy] ]] || {
    echo "已取消"
    return 1
  }
  systemctl stop gost >/dev/null 2>&1
  systemctl disable gost >/dev/null 2>&1
  rm -f /usr/bin/gost
  rm -f /usr/lib/systemd/system/gost.service
  rm -rf /etc/gost
  rm -f "${cron_file}"
  systemctl daemon-reload
  echo "gost已经成功删除"
}

# 主机拼进 URI/配置前的统一处理: IPv6 字面量要加方括号, 否则 "地址:端口" 会有歧义
# 顺带挡掉"把 IP:端口 填进地址栏"这种常见错误(冒号只有一个且不是 IPv6)
function uri_host() {
  local h="$1" colons
  [[ ${h} == \[*\] ]] && {
    printf '%s' "${h}"
    return 0
  }
  [[ ${h} != *:* ]] && {
    printf '%s' "${h}"
    return 0
  }
  [[ ${h} =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
  colons=${h//[^:]/}
  (( ${#colons} >= 2 )) || return 1
  printf '[%s]' "${h}"
}

function valid_port() {
  local v="$1" label="$2"
  [[ ${v} =~ ^[0-9]+$ ]] && ((10#${v} >= 1 && 10#${v} <= 65535)) || die "${label}必须是 1-65535 的数字"
}
function valid_host() {
  local v="$1" label="$2"
  [[ -n ${v} ]] || die "${label}不能为空"
  [[ ${v} != *[[:space:]]* && ${v} != *'"'* && ${v} != *\\* && ${v} != *'#'* && ${v} != *'@'* && ${v} != */* && ${v} != *'?'* && ${v} != *'%'* ]] ||
    die "${label}不能包含空格、引号、反斜杠、#、@、/、?、%"
}

# 解析一行 rawconf: nonencrypt/本地端口#目标IP#目标端口
# 返回 0 正常, 1 行无效, 2 是别的规则类型(完整版脚本写的)
function parse_rule() {
  local line="${1%$'\r'}" f1 host dport extra
  [[ -z ${line//[[:space:]]/} ]] && return 1
  IFS='#' read -r f1 host dport extra <<<"${line}"
  r_type=${f1%%/*}
  if [[ ${r_type} != "nonencrypt" ]]; then
    # 只有形如 ss/xxx#...#... 的才算完整版的规则, 其余一律当坏行
    [[ ${line} == *"#"*"#"* ]] && return 2
    return 1
  fi
  [[ -n ${extra} ]] && return 1
  r_sport=${f1#*/}
  r_dhost=${host}
  r_dport=${dport}
  [[ ${r_sport} =~ ^[0-9]+$ && ${r_dport} =~ ^[0-9]+$ ]] || return 1
  ((10#${r_sport} >= 1 && 10#${r_sport} <= 65535)) || return 1
  ((10#${r_dport} >= 1 && 10#${r_dport} <= 65535)) || return 1
  [[ -n ${r_dhost} ]] || return 1
  [[ ${r_dhost} != *[[:space:]]* && ${r_dhost} != *'"'* && ${r_dhost} != *\\* && ${r_dhost} != *'#'* && ${r_dhost} != *'@'* && ${r_dhost} != */* && ${r_dhost} != *'?'* && ${r_dhost} != *'%'* ]] || return 1
  return 0
}

function count_rules() {
  local n=0 line
  [[ -f ${raw_conf_path} ]] || {
    echo 0
    return
  }
  while IFS= read -r line || [[ -n ${line} ]]; do
    parse_rule "${line}" && n=$((n + 1))
  done <"${raw_conf_path}"
  echo "${n}"
}

# rawconf 里有没有完整版写的 ss/tls/ws 等规则
function has_foreign_rules() {
  local line
  [[ -f ${raw_conf_path} ]] || return 1
  while IFS= read -r line || [[ -n ${line} ]]; do
    parse_rule "${line}"
    (($? == 2)) && return 0
  done <"${raw_conf_path}"
  return 1
}
# 精简版只认 nonencrypt; 混有其它类型时拒绝重建, 否则会把它们写丢
function ensure_lite() {
  if has_foreign_rules; then
    warn "检测到 ${raw_conf_path} 里还有精简版不支持的规则类型（ss / tls / ws 等）"
    warn "为了不把它们的配置写丢，这里不重建配置；请改用完整版 gost.sh 管理这台机器"
    return 1
  fi
  return 0
}

# 由 rawconf 重建 config.json: 写临时文件, 校验通过后原子替换
function rebuild_config() {
  local target="${gost_conf_path}" tmp line n=0 lineno=0 dup=0 seen=" " p
  local -a sports dests
  ensure_lite || return 1
  if [[ ! -f ${raw_conf_path} ]]; then
    warn "未找到 ${raw_conf_path}，没有可用的转发规则"
    return 1
  fi
  while IFS= read -r line || [[ -n ${line} ]]; do
    lineno=$((lineno + 1))
    [[ -z ${line//[[:space:]]/} ]] && continue
    parse_rule "${line}"
    case $? in
    0) ;;
    2)
      warn "第 ${lineno} 行是其它类型的规则（${r_type}），精简版不处理，已跳过"
      continue
      ;;
    *)
      warn "第 ${lineno} 行无法解析，已跳过（格式应为 nonencrypt/本地端口#目标IP#目标端口）"
      continue
      ;;
    esac
    p=$((10#${r_sport}))
    if [[ ${seen} == *" ${p} "* ]]; then
      warn "本地端口 ${p} 在 rawconf 里出现了不止一次，gost 会因端口冲突起不来，已中止"
      dup=1
      continue
    fi
    seen+="${p} "
    sports+=("${p}")
    dests+=("${r_dhost}:$((10#${r_dport}))")
    n=$((n + 1))
  done <"${raw_conf_path}"
  ((dup)) && return 1
  if ((n == 0)); then
    warn "没有可用的转发规则"
    return 1
  fi

  tmp="${target}.new.$$"
  {
    printf '{\n    "Debug": true,\n    "Retries": 0,\n    "ServeNodes": [\n'
    printf '        "tcp://:%s/%s",\n        "udp://:%s/%s"\n' "${sports[0]}" "${dests[0]}" "${sports[0]}" "${dests[0]}"
    printf '    ]'
    if ((n > 1)); then
      printf ',\n    "Routes": [\n'
      for ((i = 1; i < n; i++)); do
        printf '        {\n            "Retries": 0,\n            "ServeNodes": [\n'
        printf '                "tcp://:%s/%s",\n                "udp://:%s/%s"\n' "${sports[i]}" "${dests[i]}" "${sports[i]}" "${dests[i]}"
        printf '            ]\n        }%s\n' "$([[ ${i} -eq $((n - 1)) ]] && echo '' || echo ',')"
      done
      printf '    ]'
    fi
    printf '\n}\n'
  } >"${tmp}" || {
    rm -f "${tmp}"
    warn "无法写入 ${tmp}"
    return 1
  }

  if ! json_ok "${tmp}"; then
    warn "生成的配置无效，已保留上一份配置"
    rm -f "${tmp}"
    return 1
  fi
  chmod 0600 "${tmp}"
  if [[ -f ${target} ]]; then
    cp -a "${target}" "${target}.bak" 2>/dev/null && chmod 0600 "${target}.bak" 2>/dev/null
  else
    # 没有"上一份配置"时清掉旧 .bak: 否则这次重启失败会回滚到一份无关的旧配置,
    # 比如刚删光的规则被复活
    rm -f "${target}.bak"
  fi
  if ! mv -f "${tmp}" "${target}"; then
    warn "替换配置失败，已保留上一份配置"
    rm -f "${tmp}"
    return 1
  fi
  chmod 0600 "${target}"
  return 0
}

# 重启并确认真的起来了; 起不来就回滚, 避免一条坏规则把所有转发带下去
function restart_gost() {
  local bak="${gost_conf_path}.bak"
  systemctl restart gost
  sleep 1
  systemctl is-active --quiet gost && return 0
  sleep 2
  systemctl is-active --quiet gost && return 0
  if [[ -f ${bak} ]]; then
    warn "gost 未能启动，正在回滚到上一份配置 $(basename "${bak}")"
    cp -a "${bak}" "${gost_conf_path}" && chmod 0600 "${gost_conf_path}"
    systemctl restart gost
    sleep 1
    if systemctl is-active --quiet gost; then
      warn "已回滚，本次改动未生效；请检查端口是否被其它程序占用后重试"
      return 1
    fi
  else
    warn "没有可回滚的上一份配置（${bak} 不存在）"
  fi
  warn "gost 仍未启动，请执行 systemctl status gost 及 journalctl -u gost -n 50 查看原因"
  return 1
}

function snapshot_rawconf() {
  raw_conf_snap=$(mktemp) || die "无法创建临时文件"
  raw_conf_snap_had=0
  if [[ -f ${raw_conf_path} ]]; then
    cp -a "${raw_conf_path}" "${raw_conf_snap}" || die "备份 rawconf 失败"
    raw_conf_snap_had=1
  fi
}
function restore_rawconf() {
  if ((raw_conf_snap_had)); then
    if install -m 0644 "${raw_conf_snap}" "${raw_conf_path}"; then
      warn "已撤销本次对 rawconf 的改动"
    else
      warn "恢复 rawconf 失败，请手动检查 ${raw_conf_path}"
    fi
  else
    rm -f "${raw_conf_path}"
  fi
  [[ -n ${raw_conf_snap} ]] && rm -f "${raw_conf_snap}"
}
function commit_rawconf() {
  [[ -n ${raw_conf_snap} ]] && rm -f "${raw_conf_snap}"
}

function listen_port_taken() {
  local port="$1" line
  [[ -f ${raw_conf_path} ]] || return 1
  while IFS= read -r line || [[ -n ${line} ]]; do
    parse_rule "${line}" || continue
    [[ $((10#${r_sport})) == "${port}" ]] && return 0
  done <"${raw_conf_path}"
  return 1
}

function list_rules() {
  local line i=0
  if [[ ! -f ${raw_conf_path} ]]; then
    warn "还没有任何转发规则，先执行菜单 2 新增"
    return 1
  fi
  echo -e " 序号 | 本地端口 | 转发到"
  echo -e "--------------------------------------------------------"
  while IFS= read -r line || [[ -n ${line} ]]; do
    i=$((i + 1))
    parse_rule "${line}"
    case $? in
    0) echo -e "  ${i}  | ${r_sport}\t| ${r_dhost}:${r_dport}" ;;
    2) echo -e "  ${i}  | 其它类型 | ${r_type}（内容已隐藏，请用完整版 gost.sh 管理）" ;;
    *) [[ -z ${line//[[:space:]]/} ]] || echo -e "  ${i}  | 无法解析 | 内容已隐藏，请手动查看 ${raw_conf_path}" ;;
    esac
    echo -e "--------------------------------------------------------"
  done <"${raw_conf_path}"
}

function add_rule() {
  local port ip dport
  command -v gost >/dev/null 2>&1 || die "gost 尚未安装，请先执行菜单 1 安装"
  [[ -d /etc/gost ]] || die "配置目录 /etc/gost 不存在，请先执行菜单 1 重新安装"
  ensure_lite || return 1
  echo -e "------------------------------------------------------------------"
  read -r -p "本机用哪个端口接收流量: " port
  valid_port "${port}" "本地监听端口"
  port=$((10#${port}))
  listen_port_taken "${port}" && die "端口 ${port} 已被现有规则占用，请换一个"
  echo -e "------------------------------------------------------------------"
  echo -e "流量转发到哪个 IP 或域名（落地机地址，也可以是 127.0.0.1）"
  read -r -p "请输入: " ip
  valid_host "${ip}" "目标IP或域名"
  ip=$(uri_host "${ip}") || die "目标地址格式不对：带冒号的只支持 IPv6 地址，端口在下一步单独填"
  echo -e "------------------------------------------------------------------"
  read -r -p "转发到${ip}的哪个端口: " dport
  valid_port "${dport}" "目标端口"
  dport=$((10#${dport}))

  snapshot_rawconf
  # rawconf 末尾没有换行时(手改/别的工具写过)先补一个, 否则新规则会接在上一条后面, 两条一起失效
  [[ -s ${raw_conf_path} && -n $(tail -c 1 "${raw_conf_path}") ]] && printf '\n' >>"${raw_conf_path}"
  printf 'nonencrypt/%s#%s#%s\n' "${port}" "${ip}" "${dport}" >>"${raw_conf_path}" || {
    restore_rawconf
    die "写入 ${raw_conf_path} 失败"
  }
  if rebuild_config && restart_gost; then
    commit_rawconf
    echo -e "${Info} 已生效: 本机 ${port} -> ${ip}:${dport} (tcp+udp)"
    list_rules
  else
    restore_rawconf
  fi
}

function delete_rule() {
  local line num total=0
  list_rules || return 1
  read -r -p "请输入要删除的规则序号：" num
  [[ ${num} =~ ^[0-9]+$ ]] || {
    echo "请输入正确数字"
    return 1
  }
  total=$(awk 'END{print NR}' "${raw_conf_path}" 2>/dev/null)
  ((10#${num} >= 1 && 10#${num} <= ${total:-0})) || {
    echo "请输入正确数字"
    return 1
  }
  snapshot_rawconf
  sed -i "${num}d" "${raw_conf_path}" || {
    restore_rawconf
    die "删除失败"
  }
  # 删光了就停服务, 旧配置留作 .bak, 免得菜单 5 又把刚删的规则拉起来
  if (($(count_rules) == 0)); then
    systemctl stop gost >/dev/null 2>&1
    [[ -f ${gost_conf_path} ]] && mv -f "${gost_conf_path}" "${gost_conf_path}.bak" 2>/dev/null
    commit_rawconf
    echo -e "${Info} 规则已全部删除，gost 服务已停止"
    return 0
  fi
  if rebuild_config && restart_gost; then
    commit_rawconf
    echo -e "${Info} 已删除，服务已重启"
    list_rules
  else
    restore_rawconf
  fi
  return 0
}

function restart_all() {
  command -v gost >/dev/null 2>&1 || die "gost 尚未安装，请先执行菜单 1 安装"
  ensure_lite || return 1
  if (($(count_rules) == 0)); then
    warn "当前没有转发规则，先执行菜单 2 新增"
    return 1
  fi
  if rebuild_config && restart_gost; then
    echo -e "${Info} 已按 rawconf 重建配置并重启"
  fi
}

function show_banner() {
  local ver state color rules
  echo
  echo -e "  ${Bold}${Green_font_prefix}gost 精简版${Font_color_suffix}   ${Bold}v${shell_version}${Font_color_suffix}   ${Cyan_font_prefix}只做 tcp+udp 不加密转发${Font_color_suffix}"
  echo -e "  ------------------------------------------------------------"
  if command -v gost >/dev/null 2>&1; then
    ver=$(gost -V 2>/dev/null | awk '{print $2}')
    if systemctl is-active --quiet gost 2>/dev/null; then
      state="运行中"
      color="${Green_font_prefix}"
    else
      state="未运行"
      color="${Red_font_prefix}"
    fi
    rules=$(count_rules)
    if has_foreign_rules; then
      rules="${rules} 条（另有其它类型规则，请用完整版管理）"
    else
      rules="${rules} 条"
    fi
    echo -e "  ${color}●${Font_color_suffix} ${state} · gost ${ver:-未知} · 转发规则 ${rules}"
  else
    echo -e "  ${Red_font_prefix}●${Font_color_suffix} 未安装 · 选择 1 开始安装"
  fi
  echo -e "  完整版（ss / tls / ws / 均衡负载 / 证书）见同仓库 gost.sh"
  echo
  echo -e "    ${Green_font_prefix}1${Font_color_suffix} 安装      ${Green_font_prefix}2${Font_color_suffix} 新增      ${Green_font_prefix}3${Font_color_suffix} 查看      ${Green_font_prefix}4${Font_color_suffix} 删除"
  echo -e "    ${Green_font_prefix}5${Font_color_suffix} 重启      ${Green_font_prefix}6${Font_color_suffix} 卸载      ${Cyan_font_prefix}0${Font_color_suffix} 退出"
  echo -e "  ------------------------------------------------------------"
  echo
}

check_root
show_banner
read -r -e -p " 请输入数字 [0-6]:" num
case "$num" in
1) Install_ct ;;
2) add_rule ;;
3) list_rules ;;
4) delete_rule ;;
5) restart_all ;;
6) Uninstall_ct ;;
0) exit 0 ;;
*) echo "  请输入正确数字 [0-6]" ;;
esac
