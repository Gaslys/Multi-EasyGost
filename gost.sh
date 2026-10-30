#!/bin/bash
Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Green_background_prefix="\033[42;37m" && Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Warn="${Red_font_prefix}[警告]${Font_color_suffix}"
Cyan_font_prefix="\033[36m"
Bold="\033[1m"
shell_version="1.2.3"
ct_new_ver="2.11.2" # 2.x 不再跟随官方更新
gost_conf_path="/etc/gost/config.json"
raw_conf_path="/etc/gost/rawconf"
# 自用 fork: 自检更新指向自己的仓库, 避免更新时把自己修的版本降级回上游
update_url="https://raw.githubusercontent.com/Gaslys/Multi-EasyGost/v2/gost.sh"
cron_file="/etc/cron.d/gost-restart"
# 均衡负载的落地列表必须放在 gost 进程(User=root)可读的位置, 且与配置里写的路径一致
peer_dir="/root"

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
    # 没有校验工具时退化为最小检查, 至少挡住空文件和明显残缺
    grep -q '"ServeNodes"' "${f}" && tail -c 3 "${f}" | grep -q "}"
  fi
}

# 由 rawconf 重新生成 config.json: 先备份、生成后校验、失败回滚, 避免把坏配置推给 gost
function regen_config() {
  local bak
  regen_stopped=0
  [[ -d /etc/gost ]] || die "gost 尚未安装或配置文件目录不存在，请先执行菜单 1 安装"
  if [[ ! -f ${raw_conf_path} ]]; then
    warn "未找到转发配置 ${raw_conf_path}，跳过重建，仅重启服务"
    return 0
  fi
  # 规则被删光时不能写空配置: gost 对 "ServeNodes": [] 直接报 invalid config 退出,
  # 保留旧配置又会让刚删掉的规则继续生效, 所以这里直接把服务停掉
  if (( $(count_rules) == 0 )); then
    systemctl stop gost >/dev/null 2>&1
    # 把旧配置挪走: 否则菜单 4/6 一启动, 刚删掉的规则就会按旧配置复活
    if [[ -f ${gost_conf_path} ]]; then
      mv -f "${gost_conf_path}" "${gost_conf_path}.bak" 2>/dev/null
      chmod 0600 "${gost_conf_path}.bak" 2>/dev/null
    fi
    regen_stopped=1
    echo -e "${Info} 已没有可用的转发规则，gost 服务已停止，旧配置已保留为 config.json.bak"
    return 0
  fi
  local dup
  dup=$(duplicate_ports)
  if [[ -n ${dup} ]]; then
    warn "以下监听端口在多条规则里重复，gost 会因 address already in use 起不来：$(echo "${dup}" | tr '\n' ' ')"
    warn "已保留当前配置未覆盖，请用菜单 9 删除冲突规则后重试"
    return 1
  fi
  bak=$(mktemp) || die "无法创建临时文件"
  if [[ -f ${gost_conf_path} ]]; then
    cp -a "${gost_conf_path}" "${bak}" || die "备份现有配置失败，已中止"
  fi
  : >"${gost_conf_path}" || die "无法写入 ${gost_conf_path}（权限不足？）"
  confstart
  writeconf
  local rc=$?
  conflast
  if ((rc != 0)) || ! json_ok "${gost_conf_path}"; then
    warn "生成的配置无效，已回滚到上一份配置（请检查 rawconf 是否被手工改坏）"
    if [[ -s ${bak} ]]; then
      cp -a "${bak}" "${gost_conf_path}"
    else
      rm -f "${gost_conf_path}"
    fi
    rm -f "${bak}"
    return 1
  fi
  if [[ -s ${bak} ]]; then
    cp -a "${bak}" "${gost_conf_path}.bak"
    chmod 0600 "${gost_conf_path}.bak"
  fi
  rm -f "${bak}"
  chmod 0600 "${gost_conf_path}"
  return 0
}

# 用户输入会原样拼进 JSON / gost URI, 这里挡掉会破坏解析的字符
function valid_secret() {
  local v="$1" label="$2"
  [[ -n ${v} ]] || die "${label}不能为空"
  [[ ${v} != *[[:space:]]* && ${v} != *'"'* && ${v} != *\\* && ${v} != *'#'* && ${v} != *'@'* && ${v} != *':'* ]] ||
    die "${label}不能包含空格、引号、反斜杠、#、@、:（这些字符会破坏配置文件与 URI 的解析）"
}
function valid_host() {
  local v="$1" label="$2"
  [[ -n ${v} ]] || die "${label}不能为空"
  [[ ${v} != *[[:space:]]* && ${v} != *'"'* && ${v} != *\\* && ${v} != *'#'* && ${v} != *'@'* ]] ||
    die "${label}不能包含空格、引号、反斜杠、#、@"
}
function valid_port() {
  local v="$1" label="$2"
  [[ ${v} =~ ^[0-9]+$ ]] && ((10#${v} >= 1 && 10#${v} <= 65535)) || die "${label}必须是 1-65535 的数字"
}

function checknew() {
  command -v gost >/dev/null 2>&1 || die "gost 尚未安装，请先执行菜单 1 安装"
  local old_ver backup_dir
  old_ver=$(gost -V 2>&1 | awk '{print $2}')
  echo "你的gost版本为:""$old_ver"""
  echo -n 是否更新\(y/n\)\:
  read -r checknewnum
  if [[ ${checknewnum} == [Yy] ]]; then
    # 用 mktemp 备份: 原来固定备份到 /tmp/gost, 第二次更新时 /tmp/gost 已存在,
    # cp -r 会变成 /tmp/gost/gost, 恢复后 rawconf 跑到子目录里, 转发配置全部丢失
    backup_dir=$(mktemp -d "${HOME:-/root}/.gost-backup.XXXXXX") || die "无法创建备份目录"
    if [[ -d /etc/gost ]]; then
      cp -a /etc/gost/. "${backup_dir}/" || die "备份 /etc/gost 失败，已中止更新"
    fi
    Install_ct
    # Install_ct 会重建 /etc/gost（装着默认配置），这里把用户原有配置放回去
    if [[ -f "${backup_dir}/rawconf" ]]; then
      install -m 0644 "${backup_dir}/rawconf" "${raw_conf_path}" || warn "恢复 rawconf 失败"
      if [[ -f "${backup_dir}/config.json" ]]; then
        install -m 0644 "${backup_dir}/config.json" "${gost_conf_path}" || warn "恢复 config.json 失败"
      fi
      echo -e "${Info} 已恢复原有转发配置"
    fi
    rm -rf "${backup_dir}"
    systemctl restart gost
    sleep 1
    systemctl is-active --quiet gost || warn "gost 未能正常启动，请执行 systemctl status gost 查看原因"
  else
    exit 0
  fi
}
function check_sys() {
  if [[ -f /etc/redhat-release ]]; then
    release="centos"
  elif grep -qi "debian" /etc/issue 2>/dev/null; then
    release="debian"
  elif grep -qi "ubuntu" /etc/issue 2>/dev/null; then
    release="ubuntu"
  elif grep -qiE "centos|red hat|redhat" /etc/issue 2>/dev/null; then
    release="centos"
  elif grep -qi "debian" /proc/version 2>/dev/null; then
    release="debian"
  elif grep -qi "ubuntu" /proc/version 2>/dev/null; then
    release="ubuntu"
  elif grep -qiE "centos|red hat|redhat" /proc/version 2>/dev/null; then
    release="centos"
  fi

  # 常见架构直接自动识别，识别不出再让用户手选，避免 aarch64 机器被要求瞎猜
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
function download() {
  local url="$1" dest="$2"
  if command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 --timeout=20 -O "${dest}" "${url}" && return 0
    warn "TLS 校验失败，回退为不校验证书重试一次（请自行确认下载源可信）"
    wget -q --no-check-certificate --tries=3 --timeout=20 -O "${dest}" "${url}" && return 0
    return 1
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 180 -o "${dest}" "${url}" && return 0
    warn "TLS 校验失败，回退为不校验证书重试一次（请自行确认下载源可信）"
    curl -fsSLk --retry 3 --connect-timeout 10 --max-time 180 -o "${dest}" "${url}"
    return $?
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
function check_root() {
  [[ $EUID != 0 ]] && echo -e "${Error} 当前非ROOT账号(或没有ROOT权限)，无法继续操作，请更换ROOT账号或使用 ${Green_background_prefix}sudo su${Font_color_suffix} 命令获取临时ROOT权限（执行后可能会提示输入当前账号的密码）。" && exit 1
}
function check_new_ver() {
  # deprecated
  ct_new_ver=$(wget --no-check-certificate -qO- -t2 -T3 https://api.github.com/repos/ginuerzh/gost/releases/latest | grep "tag_name" | head -n 1 | awk -F ":" '{print $2}' | sed 's/\"//g;s/,//g;s/ //g;s/v//g')
  if [[ -z ${ct_new_ver} ]]; then
    ct_new_ver="2.11.2"
    echo -e "${Error} gost 最新版本获取失败，正在下载v${ct_new_ver}版"
  else
    echo -e "${Info} gost 目前最新版本为 ${ct_new_ver}"
  fi
}
function check_file() {
  if [[ ! -d /usr/lib/systemd/system ]]; then
    mkdir -p /usr/lib/systemd/system || die "无法创建 /usr/lib/systemd/system，当前系统可能没有 systemd"
  fi
}
function check_nor_file() {
  rm -f /usr/bin/gost
  rm -f /usr/lib/systemd/system/gost.service
  rm -rf /etc/gost
}
function Install_ct() {
  check_root
  check_nor_file
  Installation_dependency
  check_file
  check_sys

  local bin_url tmpdir
  # 原来的国内镜像(gotunnel.oss-cn-shenzhen.aliyuncs.com)已失效, 三个文件全部 404,
  # 选"是"只会白等一次失败, 因此移除该选项, 统一从 GitHub Releases 下载
  bin_url="https://github.com/ginuerzh/gost/releases/download/v${ct_new_ver}/gost-linux-${bit}-${ct_new_ver}.gz"

  tmpdir=$(mktemp -d "${HOME:-/root}/.gost-install.XXXXXX") || die "无法创建临时目录"
  echo -e "${Info} 正在下载 gost v${ct_new_ver} (${bit}) ..."
  if ! download "${bin_url}" "${tmpdir}/gost.gz"; then
    rm -rf "${tmpdir}"
    die "gost 下载失败，请检查网络连接或更换下载源"
  fi
  if ! gunzip -f "${tmpdir}/gost.gz"; then
    rm -rf "${tmpdir}"
    die "gost 解压失败，下载内容可能已损坏"
  fi
  chmod 0755 "${tmpdir}/gost"
  # 装之前先跑一下：能执行且版本号正确，才说明这是完整、未篡改、架构匹配的二进制
  if ! "${tmpdir}/gost" -V 2>&1 | grep -qF "${ct_new_ver}"; then
    rm -rf "${tmpdir}"
    die "下载的 gost 无法运行或版本不符（可能被篡改、不完整，或架构选择错误），已中止安装"
  fi

  # systemd unit 与默认配置改为脚本本地生成，不再从网络下载，
  # 避免 unit 文件被中间人替换后以 root 身份执行
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

  install -m 0755 "${tmpdir}/gost" /usr/bin/gost || { rm -rf "${tmpdir}"; die "安装 gost 二进制失败"; }
  install -m 0644 "${tmpdir}/gost.service" /usr/lib/systemd/system/gost.service || { rm -rf "${tmpdir}"; die "安装 service 文件失败"; }
  mkdir -p /etc/gost && chmod 0700 /etc/gost
  install -m 0644 "${tmpdir}/config.json" /etc/gost/config.json || { rm -rf "${tmpdir}"; die "安装默认配置失败"; }
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
  systemctl stop gost >/dev/null 2>&1
  systemctl disable gost >/dev/null 2>&1
  rm -f /usr/bin/gost
  rm -f /usr/lib/systemd/system/gost.service
  rm -rf /etc/gost
  rm -f "${cron_file}"
  systemctl daemon-reload
  echo "gost已经成功删除"
}
function Start_ct() {
  # 规则被删光时 config.json 已移走; 若 rawconf 存在但为空, 直接启动只会拿到旧配置
  if [[ -f ${raw_conf_path} ]] && (( $(count_rules) == 0 )); then
    warn "当前没有转发规则，请先用菜单 7 新增（若想直接用现有 config.json，可删除 ${raw_conf_path}）"
    return 1
  fi
  if ! systemctl start gost 2>/dev/null; then
    warn "启动失败，gost 可能尚未安装，请先执行菜单 1"
    return 1
  fi
  sleep 1
  if systemctl is-active --quiet gost; then
    echo "已启动"
  else
    warn "gost 未能启动，请执行 systemctl status gost 及 journalctl -u gost -n 50 查看原因"
  fi
}
function Stop_ct() {
  systemctl stop gost 2>/dev/null
  if systemctl is-active --quiet gost; then
    warn "gost 仍未停止，请执行 systemctl status gost 查看原因"
  else
    echo "已停止"
  fi
}
function Restart_ct() {
  regen_config || warn "配置重建失败，已回滚到上一份配置，继续以旧配置重启"
  if ((regen_stopped)); then
    echo "当前没有转发规则，gost 保持停止；执行菜单 7 新增规则后会自动启动"
    return 0
  fi
  systemctl restart gost
  sleep 1
  systemctl is-active --quiet gost || warn "gost 未能正常启动，请执行 systemctl status gost 查看原因"
  echo "已重读配置并重启"
}
function read_protocol() {
  echo -e "请问您要设置哪种功能: "
  echo -e "-----------------------------------"
  echo -e "[1] tcp+udp流量转发, 不加密"
  echo -e "说明: 一般设置在国内中转机上"
  echo -e "-----------------------------------"
  echo -e "[2] 加密隧道流量转发"
  echo -e "说明: 用于转发原本加密等级较低的流量, 一般设置在国内中转机上"
  echo -e "     选择此协议意味着你还有一台机器用于接收此加密流量, 之后须在那台机器上配置协议[3]进行对接"
  echo -e "-----------------------------------"
  echo -e "[3] 解密由gost传输而来的流量并转发"
  echo -e "说明: 对于经由gost加密中转的流量, 通过此选项进行解密并转发给本机的代理服务端口或转发给其他远程机器"
  echo -e "      一般设置在用于接收中转流量的国外机器上"
  echo -e "-----------------------------------"
  echo -e "[4] 一键安装ss/socks5/http代理"
  echo -e "说明: 使用gost内置的代理协议，轻量且易于管理"
  echo -e "-----------------------------------"
  echo -e "[5] 进阶：多落地均衡负载"
  echo -e "说明: 支持各种加密方式的简单均衡负载"
  echo -e "-----------------------------------"
  echo -e "[6] 进阶：转发CDN自选节点"
  echo -e "说明: 只需在中转机设置"
  echo -e "-----------------------------------"
  read -p "请选择: " numprotocol

  if [ "$numprotocol" == "1" ]; then
    flag_a="nonencrypt"
  elif [ "$numprotocol" == "2" ]; then
    encrypt
  elif [ "$numprotocol" == "3" ]; then
    decrypt
  elif [ "$numprotocol" == "4" ]; then
    proxy
  elif [ "$numprotocol" == "5" ]; then
    enpeer
  elif [ "$numprotocol" == "6" ]; then
    cdn
  else
    echo "type error, please try again"
    exit
  fi
}
function read_s_port() {
  if [ "$flag_a" == "ss" ]; then
    echo -e "-----------------------------------"
    read -p "请输入ss密码: " flag_b
    valid_secret "${flag_b}" "ss密码"
  elif [ "$flag_a" == "socks" ]; then
    echo -e "-----------------------------------"
    read -p "请输入socks密码: " flag_b
    valid_secret "${flag_b}" "socks密码"
  elif [ "$flag_a" == "http" ]; then
    echo -e "-----------------------------------"
    read -p "请输入http密码: " flag_b
    valid_secret "${flag_b}" "http密码"
  else
    echo -e "------------------------------------------------------------------"
    echo -e "请问你要将本机哪个端口接收到的流量进行转发?"
    read -p "请输入: " flag_b
    valid_port "${flag_b}" "本地监听端口"
    listen_port_taken "${flag_b}" && die "端口 ${flag_b} 已被现有规则占用，请换一个（多条规则不能监听同一端口）"
  fi
}
function read_d_ip() {
  if [ "$flag_a" == "ss" ]; then
    echo -e "------------------------------------------------------------------"
    echo -e "请问您要设置的ss加密(仅提供常用的几种): "
    echo -e "-----------------------------------"
    echo -e "[1] aes-256-gcm"
    echo -e "[2] aes-256-cfb"
    echo -e "[3] chacha20-ietf-poly1305"
    echo -e "[4] chacha20"
    echo -e "[5] rc4-md5"
    echo -e "[6] AEAD_CHACHA20_POLY1305"
    echo -e "-----------------------------------"
    read -p "请选择ss加密方式: " ssencrypt

    if [ "$ssencrypt" == "1" ]; then
      flag_c="aes-256-gcm"
    elif [ "$ssencrypt" == "2" ]; then
      flag_c="aes-256-cfb"
    elif [ "$ssencrypt" == "3" ]; then
      flag_c="chacha20-ietf-poly1305"
    elif [ "$ssencrypt" == "4" ]; then
      flag_c="chacha20"
    elif [ "$ssencrypt" == "5" ]; then
      flag_c="rc4-md5"
    elif [ "$ssencrypt" == "6" ]; then
      flag_c="AEAD_CHACHA20_POLY1305"
    else
      echo "type error, please try again"
      exit
    fi
  elif [ "$flag_a" == "socks" ]; then
    echo -e "-----------------------------------"
    read -p "请输入socks用户名: " flag_c
    valid_secret "${flag_c}" "socks用户名"
  elif [ "$flag_a" == "http" ]; then
    echo -e "-----------------------------------"
    read -p "请输入http用户名: " flag_c
    valid_secret "${flag_c}" "http用户名"
  elif [[ "$flag_a" == "peer"* ]]; then
    echo -e "------------------------------------------------------------------"
    echo -e "请输入落地列表文件名"
    read -e -p "自定义但不同配置应不重复，不用输入后缀，例如ips1、iplist2: " flag_c
    [[ ${flag_c} =~ ^[A-Za-z0-9_-]+$ ]] || die "文件名只能包含字母、数字、下划线和连字符"
    # 原来 touch 在当前工作目录建文件, 但生成的配置里写死 /root/xxx.txt:
    # 只要不是从 /root 运行脚本, 落地列表就建错地方, 均衡负载静默失效
    local peer_file="${peer_dir}/${flag_c}.txt"
    if [[ -f ${peer_file} ]]; then
      read -e -p "${peer_file} 已存在，是否覆盖？[y/N]:" overwrite
      [[ ${overwrite} == [Yy] ]] || die "已取消，可先编辑 ${peer_file} 后再用菜单 6 重启生效"
    fi
    mkdir -p "${peer_dir}" && : >"${peer_file}" || die "无法写入 ${peer_file}"
    echo -e "------------------------------------------------------------------"
    echo -e "请依次输入你要均衡负载的落地ip与端口"
    while true; do
      echo -e "请问你要将本机从${flag_b}接收到的流量转发向的IP或域名?"
      read -p "请输入: " peer_ip
      valid_host "${peer_ip}" "落地IP或域名"
      echo -e "请问你要将本机从${flag_b}接收到的流量转发向${peer_ip}的哪个端口?"
      read -p "请输入: " peer_port
      valid_port "${peer_port}" "落地端口"
      echo -e "$peer_ip:$peer_port" >>"${peer_file}"
      read -e -p "是否继续添加落地？[Y/n]:" addyn
      [[ -z ${addyn} ]] && addyn="y"
      if [[ ${addyn} == [Nn] ]]; then
        echo -e "------------------------------------------------------------------"
        echo -e "已创建 ${peer_file}，您可以随时编辑该文件修改落地信息，重启gost即可生效"
        echo -e "------------------------------------------------------------------"
        break
      else
        echo -e "------------------------------------------------------------------"
        echo -e "继续添加均衡负载落地配置"
      fi
    done
  elif [[ "$flag_a" == "cdn"* ]]; then
    echo -e "------------------------------------------------------------------"
    echo -e "将本机从${flag_b}接收到的流量转发向的自选ip:"
    read -p "请输入: " flag_c
    valid_host "${flag_c}" "自选IP"
    echo -e "请问你要将本机从${flag_b}接收到的流量转发向${flag_c}的哪个端口?"
    echo -e "[1] 80"
    echo -e "[2] 443"
    echo -e "[3] 自定义端口（如8080等）"
    read -p "请选择端口: " cdnport
    if [ "$cdnport" == "1" ]; then
      flag_c="$flag_c:80"
    elif [ "$cdnport" == "2" ]; then
      flag_c="$flag_c:443"
    elif [ "$cdnport" == "3" ]; then
      read -p "请输入自定义端口: " customport
      valid_port "${customport}" "自定义端口"
      flag_c="$flag_c:$customport"
    else
      echo "type error, please try again"
      exit
    fi
  else
    echo -e "------------------------------------------------------------------"
    echo -e "请问你要将本机从${flag_b}接收到的流量转发向哪个IP或域名?"
    echo -e "注: IP既可以是[远程机器/当前机器]的公网IP, 也可是以本机本地回环IP(即127.0.0.1)"
    echo -e "具体IP地址的填写, 取决于接收该流量的服务正在监听的IP(详见: https://github.com/KANIKIG/Multi-EasyGost)"
    if [[ ${is_cert} == [Yy] ]]; then
      echo -e "注意: 落地机开启自定义tls证书，务必填写${Red_font_prefix}域名${Font_color_suffix}"
    fi
    read -p "请输入: " flag_c
    valid_host "${flag_c}" "目的地IP或域名"
  fi
}
function read_d_port() {
  if [ "$flag_a" == "ss" ]; then
    echo -e "------------------------------------------------------------------"
    echo -e "请问你要设置ss代理服务的端口?"
    read -p "请输入: " flag_d
    valid_port "${flag_d}" "ss代理端口"
    listen_port_taken "${flag_d}" && die "端口 ${flag_d} 已被现有规则占用，请换一个"
  elif [ "$flag_a" == "socks" ]; then
    echo -e "------------------------------------------------------------------"
    echo -e "请问你要设置socks代理服务的端口?"
    read -p "请输入: " flag_d
    valid_port "${flag_d}" "socks代理端口"
    listen_port_taken "${flag_d}" && die "端口 ${flag_d} 已被现有规则占用，请换一个"
  elif [ "$flag_a" == "http" ]; then
    echo -e "------------------------------------------------------------------"
    echo -e "请问你要设置http代理服务的端口?"
    read -p "请输入: " flag_d
    valid_port "${flag_d}" "http代理端口"
    listen_port_taken "${flag_d}" && die "端口 ${flag_d} 已被现有规则占用，请换一个"
  elif [[ "$flag_a" == "peer"* ]]; then
    echo -e "------------------------------------------------------------------"
    echo -e "您要设置的均衡负载策略: "
    echo -e "-----------------------------------"
    echo -e "[1] round - 轮询"
    echo -e "[2] random - 随机"
    echo -e "[3] fifo - 自上而下"
    echo -e "-----------------------------------"
    read -p "请选择均衡负载类型: " numstra

    if [ "$numstra" == "1" ]; then
      flag_d="round"
    elif [ "$numstra" == "2" ]; then
      flag_d="random"
    elif [ "$numstra" == "3" ]; then
      flag_d="fifo"
    else
      echo "type error, please try again"
      exit
    fi
  elif [[ "$flag_a" == "cdn"* ]]; then
    echo -e "------------------------------------------------------------------"
    read -p "请输入host:" flag_d
    valid_host "${flag_d}" "host"
  else
    echo -e "------------------------------------------------------------------"
    echo -e "请问你要将本机从${flag_b}接收到的流量转发向${flag_c}的哪个端口?"
    read -p "请输入: " flag_d
    valid_port "${flag_d}" "目的地端口"
    if [[ ${is_cert} == [Yy] ]]; then
      flag_d="$flag_d?secure=true"
    fi
  fi
}
function writerawconf() {
  # 用 printf 而不是 echo: 密码以 -n/-e 开头时 echo 会当成选项吞掉内容
  printf '%s/%s#%s#%s\n' "$flag_a" "$flag_b" "$flag_c" "$flag_d" >>"$raw_conf_path"
}
function rawconf() {
  read_protocol
  read_s_port
  read_d_ip
  read_d_port
  writerawconf
}
function eachconf_retrieve() {
  d_server=${trans_conf#*#}
  d_port=${d_server#*#}
  d_ip=${d_server%#*}
  flag_s_port=${trans_conf%%#*}
  s_port=${flag_s_port#*/}
  is_encrypt=${flag_s_port%/*}
}
function confstart() {
  echo "{
    \"Debug\": true,
    \"Retries\": 0,
    \"ServeNodes\": [" >>$gost_conf_path
}
function multiconfstart() {
  echo "        {
            \"Retries\": 0,
            \"ServeNodes\": [" >>$gost_conf_path
}
function conflast() {
  echo "    ]
}" >>$gost_conf_path
}
function multiconflast() {
  if [ $i -eq $count_line ]; then
    echo "            ]
        }" >>$gost_conf_path
  else
    echo "            ]
        }," >>$gost_conf_path
  fi
}
function encrypt() {
  echo -e "请问您要设置的转发传输类型: "
  echo -e "-----------------------------------"
  echo -e "[1] tls隧道"
  echo -e "[2] ws隧道"
  echo -e "[3] wss隧道"
  echo -e "注意: 同一则转发，中转与落地传输类型必须对应！本脚本默认开启tcp+udp"
  echo -e "-----------------------------------"
  read -p "请选择转发传输类型: " numencrypt

  if [ "$numencrypt" == "1" ]; then
    flag_a="encrypttls"
    echo -e "注意: 选择 是 将针对落地的自定义证书开启证书校验保证安全性，稍后落地机务必填写${Red_font_prefix}域名${Font_color_suffix}"
    read -e -p "落地机是否开启了自定义tls证书？[y/n]:" is_cert
  elif [ "$numencrypt" == "2" ]; then
    flag_a="encryptws"
  elif [ "$numencrypt" == "3" ]; then
    flag_a="encryptwss"
    echo -e "注意: 选择 是 将针对落地的自定义证书开启证书校验保证安全性，稍后落地机务必填写${Red_font_prefix}域名${Font_color_suffix}"
    read -e -p "落地机是否开启了自定义tls证书？[y/n]:" is_cert
  else
    echo "type error, please try again"
    exit
  fi
}
function enpeer() {
  echo -e "请问您要设置的均衡负载传输类型: "
  echo -e "-----------------------------------"
  echo -e "[1] 不加密转发"
  echo -e "[2] tls隧道"
  echo -e "[3] ws隧道"
  echo -e "[4] wss隧道"
  echo -e "注意: 同一则转发，中转与落地传输类型必须对应！本脚本默认同一配置的传输类型相同"
  echo -e "此脚本仅支持简单型均衡负载，具体可参考官方文档"
  echo -e "gost均衡负载官方文档：https://docs.ginuerzh.xyz/gost/load-balancing"
  echo -e "-----------------------------------"
  read -p "请选择转发传输类型: " numpeer

  if [ "$numpeer" == "1" ]; then
    flag_a="peerno"
  elif [ "$numpeer" == "2" ]; then
    flag_a="peertls"
  elif [ "$numpeer" == "3" ]; then
    flag_a="peerws"
  elif [ "$numpeer" == "4" ]; then
    flag_a="peerwss"

  else
    echo "type error, please try again"
    exit
  fi
}
function cdn() {
  echo -e "请问您要设置的CDN传输类型: "
  echo -e "-----------------------------------"
  echo -e "[1] 不加密转发"
  echo -e "[2] ws隧道"
  echo -e "[3] wss隧道"
  echo -e "注意: 同一则转发，中转与落地传输类型必须对应！"
  echo -e "此功能只需在中转机设置"
  echo -e "-----------------------------------"
  read -p "请选择CDN转发传输类型: " numcdn

  if [ "$numcdn" == "1" ]; then
    flag_a="cdnno"
  elif [ "$numcdn" == "2" ]; then
    flag_a="cdnws"
  elif [ "$numcdn" == "3" ]; then
    flag_a="cdnwss"
  else
    echo "type error, please try again"
    exit
  fi
}
function cert() {
  echo -e "-----------------------------------"
  echo -e "[1] ACME一键申请证书"
  echo -e "[2] 手动上传证书"
  echo -e "-----------------------------------"
  echo -e "说明: 仅用于落地机配置，默认使用的gost内置的证书可能带来安全问题，使用自定义证书提高安全性"
  echo -e "     配置后对本机所有tls/wss解密生效，无需再次设置"
  read -p "请选择证书生成方式: " numcert

  if [ "$numcert" == "1" ]; then
    check_sys
    if [[ ${release} == "centos" ]]; then
      yum install -y socat
    else
      apt-get install -y socat
    fi
    read -p "请输入ZeroSSL的账户邮箱(至 zerossl.com 注册即可)：" zeromail
    read -p "请输入解析到本机的域名：" domain
    curl https://get.acme.sh | sh
    "$HOME"/.acme.sh/acme.sh --set-default-ca --server zerossl
    "$HOME"/.acme.sh/acme.sh --register-account -m "${zeromail}" --server zerossl
    echo -e "ACME证书申请程序安装成功"
    echo -e "-----------------------------------"
    echo -e "[1] HTTP申请（需要80端口未占用）"
    echo -e "[2] Cloudflare DNS API 申请（需要输入APIKEY）"
    echo -e "-----------------------------------"
    read -p "请选择证书申请方式: " certmethod
    if [ "$certmethod" == "1" ]; then
      echo -e "请确认本机${Red_font_prefix}80${Font_color_suffix}端口未被占用, 否则会申请失败"
      if "$HOME"/.acme.sh/acme.sh --issue -d "${domain}" --standalone -k ec-256 --force; then
        echo -e "SSL 证书生成成功，默认申请高安全性的ECC证书"
        if [ ! -d "$HOME/gost_cert" ]; then
          mkdir $HOME/gost_cert
        fi
        if "$HOME"/.acme.sh/acme.sh --installcert -d "${domain}" --fullchainpath $HOME/gost_cert/cert.pem --keypath $HOME/gost_cert/key.pem --ecc --force; then
          echo -e "SSL 证书配置成功，且会自动续签，证书及秘钥位于用户目录下的 ${Red_font_prefix}gost_cert${Font_color_suffix} 目录"
          echo -e "证书目录名与证书文件名请勿更改; 删除 gost_cert 目录后用脚本重启,即自动启用gost内置证书"
          echo -e "-----------------------------------"
        fi
      else
        echo -e "SSL 证书生成失败"
        exit 1
      fi
    else
      read -p "请输入Cloudflare账户邮箱：" cfmail
      read -p "请输入Cloudflare Global API Key：" cfkey
      export CF_Key="${cfkey}"
      export CF_Email="${cfmail}"
      if "$HOME"/.acme.sh/acme.sh --issue --dns dns_cf -d "${domain}" --standalone -k ec-256 --force; then
        echo -e "SSL 证书生成成功，默认申请高安全性的ECC证书"
        if [ ! -d "$HOME/gost_cert" ]; then
          mkdir $HOME/gost_cert
        fi
        if "$HOME"/.acme.sh/acme.sh --installcert -d "${domain}" --fullchainpath $HOME/gost_cert/cert.pem --keypath $HOME/gost_cert/key.pem --ecc --force; then
          echo -e "SSL 证书配置成功，且会自动续签，证书及秘钥位于用户目录下的 ${Red_font_prefix}gost_cert${Font_color_suffix} 目录"
          echo -e "证书目录名与证书文件名请勿更改; 删除 gost_cert 目录后使用脚本重启, 即重新启用gost内置证书"
          echo -e "-----------------------------------"
        fi
      else
        echo -e "SSL 证书生成失败"
        exit 1
      fi
    fi

  elif [ "$numcert" == "2" ]; then
    if [ ! -d "$HOME/gost_cert" ]; then
      mkdir $HOME/gost_cert
    fi
    echo -e "-----------------------------------"
    echo -e "已在用户目录建立 ${Red_font_prefix}gost_cert${Font_color_suffix} 目录，请将证书文件 cert.pem 与秘钥文件 key.pem 上传到该目录"
    echo -e "证书与秘钥文件名必须与上述一致，目录名也请勿更改"
    echo -e "上传成功后，用脚本重启gost会自动启用，无需再设置; 删除 gost_cert 目录后用脚本重启,即重新启用gost内置证书"
    echo -e "-----------------------------------"
  else
    echo "type error, please try again"
    exit
  fi
}
function decrypt() {
  echo -e "请问您要设置的解密传输类型: "
  echo -e "-----------------------------------"
  echo -e "[1] tls"
  echo -e "[2] ws"
  echo -e "[3] wss"
  echo -e "注意: 同一则转发，中转与落地传输类型必须对应！本脚本默认开启tcp+udp"
  echo -e "-----------------------------------"
  read -p "请选择解密传输类型: " numdecrypt

  if [ "$numdecrypt" == "1" ]; then
    flag_a="decrypttls"
  elif [ "$numdecrypt" == "2" ]; then
    flag_a="decryptws"
  elif [ "$numdecrypt" == "3" ]; then
    flag_a="decryptwss"
  else
    echo "type error, please try again"
    exit
  fi
}
function proxy() {
  echo -e "------------------------------------------------------------------"
  echo -e "请问您要设置的代理类型: "
  echo -e "-----------------------------------"
  echo -e "[1] shadowsocks"
  echo -e "[2] socks5(强烈建议加隧道用于Telegram代理)"
  echo -e "[3] http"
  echo -e "-----------------------------------"
  read -p "请选择代理类型: " numproxy
  if [ "$numproxy" == "1" ]; then
    flag_a="ss"
  elif [ "$numproxy" == "2" ]; then
    flag_a="socks"
  elif [ "$numproxy" == "3" ]; then
    flag_a="http"
  else
    echo "type error, please try again"
    exit
  fi
}
function method() {
  if [ $i -eq 1 ]; then
    if [ "$is_encrypt" == "nonencrypt" ]; then
      echo "        \"tcp://:$s_port/$d_ip:$d_port\",
        \"udp://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "cdnno" ]; then
      echo "        \"tcp://:$s_port/$d_ip?host=$d_port\",
        \"udp://:$s_port/$d_ip?host=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peerno" ]; then
      echo "        \"tcp://:$s_port?ip=${peer_dir}/$d_ip.txt&strategy=$d_port\",
        \"udp://:$s_port?ip=${peer_dir}/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "encrypttls" ]; then
      echo "        \"tcp://:$s_port\",
        \"udp://:$s_port\"
    ],
    \"ChainNodes\": [
        \"relay+tls://$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "encryptws" ]; then
      echo "        \"tcp://:$s_port\",
    	\"udp://:$s_port\"
	],
	\"ChainNodes\": [
    	\"relay+ws://$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "encryptwss" ]; then
      echo "        \"tcp://:$s_port\",
		  \"udp://:$s_port\"
	],
	\"ChainNodes\": [
		\"relay+wss://$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peertls" ]; then
      echo "        \"tcp://:$s_port\",
    	\"udp://:$s_port\"
	],
	\"ChainNodes\": [
    	\"relay+tls://:?ip=${peer_dir}/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peerws" ]; then
      echo "        \"tcp://:$s_port\",
    	\"udp://:$s_port\"
	],
	\"ChainNodes\": [
    	\"relay+ws://:?ip=${peer_dir}/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peerwss" ]; then
      echo "        \"tcp://:$s_port\",
    	\"udp://:$s_port\"
	],
	\"ChainNodes\": [
    	\"relay+wss://:?ip=${peer_dir}/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "cdnws" ]; then
      echo "        \"tcp://:$s_port\",
    	\"udp://:$s_port\"
	],
	\"ChainNodes\": [
    	\"relay+ws://$d_ip?host=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "cdnwss" ]; then
      echo "        \"tcp://:$s_port\",
    	\"udp://:$s_port\"
	],
	\"ChainNodes\": [
    	\"relay+wss://$d_ip?host=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "decrypttls" ]; then
      if [ -d "$HOME/gost_cert" ]; then
        echo "        \"relay+tls://:$s_port/$d_ip:$d_port?cert=/root/gost_cert/cert.pem&key=/root/gost_cert/key.pem\"" >>$gost_conf_path
      else
        echo "        \"relay+tls://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
      fi
    elif [ "$is_encrypt" == "decryptws" ]; then
      echo "        \"relay+ws://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "decryptwss" ]; then
      if [ -d "$HOME/gost_cert" ]; then
        echo "        \"relay+wss://:$s_port/$d_ip:$d_port?cert=/root/gost_cert/cert.pem&key=/root/gost_cert/key.pem\"" >>$gost_conf_path
      else
        echo "        \"relay+wss://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
      fi
    elif [ "$is_encrypt" == "ss" ]; then
      echo "        \"ss://$d_ip:$s_port@:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "socks" ]; then
      echo "        \"socks5://$d_ip:$s_port@:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "http" ]; then
      echo "        \"http://$d_ip:$s_port@:$d_port\"" >>$gost_conf_path
    else
      echo "config error"
    fi
  elif [ $i -gt 1 ]; then
    if [ "$is_encrypt" == "nonencrypt" ]; then
      echo "                \"tcp://:$s_port/$d_ip:$d_port\",
                \"udp://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peerno" ]; then
      echo "                \"tcp://:$s_port?ip=${peer_dir}/$d_ip.txt&strategy=$d_port\",
                \"udp://:$s_port?ip=${peer_dir}/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "cdnno" ]; then
      echo "                \"tcp://:$s_port/$d_ip?host=$d_port\",
                \"udp://:$s_port/$d_ip?host=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "encrypttls" ]; then
      echo "                \"tcp://:$s_port\",
                \"udp://:$s_port\"
            ],
            \"ChainNodes\": [
                \"relay+tls://$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "encryptws" ]; then
      echo "                \"tcp://:$s_port\",
	            \"udp://:$s_port\"
	        ],
	        \"ChainNodes\": [
	            \"relay+ws://$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "encryptwss" ]; then
      echo "                \"tcp://:$s_port\",
		        \"udp://:$s_port\"
		    ],
		    \"ChainNodes\": [
		        \"relay+wss://$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peertls" ]; then
      echo "                \"tcp://:$s_port\",
                \"udp://:$s_port\"
            ],
            \"ChainNodes\": [
                \"relay+tls://:?ip=${peer_dir}/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peerws" ]; then
      echo "                \"tcp://:$s_port\",
                \"udp://:$s_port\"
            ],
            \"ChainNodes\": [
                \"relay+ws://:?ip=${peer_dir}/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peerwss" ]; then
      echo "                \"tcp://:$s_port\",
                \"udp://:$s_port\"
            ],
            \"ChainNodes\": [
                \"relay+wss://:?ip=${peer_dir}/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "cdnws" ]; then
      echo "                \"tcp://:$s_port\",
                \"udp://:$s_port\"
            ],
            \"ChainNodes\": [
                \"relay+ws://$d_ip?host=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "cdnwss" ]; then
      echo "                 \"tcp://:$s_port\",
                \"udp://:$s_port\"
            ],
            \"ChainNodes\": [
                \"relay+wss://$d_ip?host=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "decrypttls" ]; then
      if [ -d "$HOME/gost_cert" ]; then
        echo "        		  \"relay+tls://:$s_port/$d_ip:$d_port?cert=/root/gost_cert/cert.pem&key=/root/gost_cert/key.pem\"" >>$gost_conf_path
      else
        echo "        		  \"relay+tls://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
      fi
    elif [ "$is_encrypt" == "decryptws" ]; then
      echo "        		  \"relay+ws://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "decryptwss" ]; then
      if [ -d "$HOME/gost_cert" ]; then
        echo "        		  \"relay+wss://:$s_port/$d_ip:$d_port?cert=/root/gost_cert/cert.pem&key=/root/gost_cert/key.pem\"" >>$gost_conf_path
      else
        echo "        		  \"relay+wss://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
      fi
    elif [ "$is_encrypt" == "ss" ]; then
      echo "        \"ss://$d_ip:$s_port@:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "socks" ]; then
      echo "        \"socks5://$d_ip:$s_port@:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "http" ]; then
      echo "        \"http://$d_ip:$s_port@:$d_port\"" >>$gost_conf_path
    else
      echo "config error"
    fi
  else
    echo "config error"
    exit
  fi
}

function writeconf() {
  local trans_conf idx=0 total=0
  # 先数一遍有效行: multiconflast 用 count_line 判断是否是最后一个对象(决定加不加逗号)
  while IFS= read -r trans_conf || [[ -n ${trans_conf} ]]; do
    trans_conf=${trans_conf%$'\r'}
    [[ -z ${trans_conf//[[:space:]]/} ]] && continue
    [[ ${trans_conf} != *"#"*"#"* ]] && continue
    total=$((total + 1))
  done <"${raw_conf_path}"
  count_line=${total}
  while IFS= read -r trans_conf || [[ -n ${trans_conf} ]]; do
    trans_conf=${trans_conf%$'\r'} # 兼容 Windows 换行, 否则 \r 会进到 JSON 字符串里
    [[ -z ${trans_conf//[[:space:]]/} ]] && continue
    if [[ ${trans_conf} != *"#"*"#"* ]]; then
      warn "跳过无法解析的配置行: ${trans_conf}"
      continue
    fi
    idx=$((idx + 1))
    i=${idx}
    eachconf_retrieve
    if ((idx == 1)); then
      method
    else
      if ((idx == 2)); then
        echo "    ],
    \"Routes\": [" >>"${gost_conf_path}"
      fi
      multiconfstart
      method
      multiconflast
    fi
  done <"${raw_conf_path}"
  if ((idx == 0)); then
    warn "没有可用的转发配置"
    return 1
  fi
  return 0
}
function show_all_conf() {
  echo -e "                      GOST 配置                        "
  echo -e "--------------------------------------------------------"
  echo -e "序号|方法\t    |本地端口\t|目的地地址:目的地端口"
  echo -e "--------------------------------------------------------"

  count_line=$(awk 'END{print NR}' $raw_conf_path)
  for ((i = 1; i <= $count_line; i++)); do
    trans_conf=$(sed -n "${i}p" $raw_conf_path)
    eachconf_retrieve

    if [ "$is_encrypt" == "nonencrypt" ]; then
      str="不加密中转"
    elif [ "$is_encrypt" == "encrypttls" ]; then
      str=" tls隧道 "
    elif [ "$is_encrypt" == "encryptws" ]; then
      str="  ws隧道 "
    elif [ "$is_encrypt" == "encryptwss" ]; then
      str=" wss隧道 "
    elif [ "$is_encrypt" == "peerno" ]; then
      str=" 不加密均衡负载 "
    elif [ "$is_encrypt" == "peertls" ]; then
      str=" tls隧道均衡负载 "
    elif [ "$is_encrypt" == "peerws" ]; then
      str="  ws隧道均衡负载 "
    elif [ "$is_encrypt" == "peerwss" ]; then
      str=" wss隧道均衡负载 "
    elif [ "$is_encrypt" == "decrypttls" ]; then
      str=" tls解密 "
    elif [ "$is_encrypt" == "decryptws" ]; then
      str="  ws解密 "
    elif [ "$is_encrypt" == "decryptwss" ]; then
      str=" wss解密 "
    elif [ "$is_encrypt" == "ss" ]; then
      str="   ss   "
    elif [ "$is_encrypt" == "socks" ]; then
      str=" socks5 "
    elif [ "$is_encrypt" == "http" ]; then
      str=" http "
    elif [ "$is_encrypt" == "cdnno" ]; then
      str="不加密转发CDN"
    elif [ "$is_encrypt" == "cdnws" ]; then
      str="ws隧道转发CDN"
    elif [ "$is_encrypt" == "cdnwss" ]; then
      str="wss隧道转发CDN"
    else
      str=""
    fi

    if [[ ${is_encrypt} == "cdnno" || ${is_encrypt} == "cdnws" || ${is_encrypt} == "cdnwss" ]]; then
      echo -e " $i  |$str  |$s_port\t|$d_ip host=$d_port"
    elif [[ ${is_encrypt} == "ss" || ${is_encrypt} == "socks" || ${is_encrypt} == "http" ]]; then
      # 这三类里 s_port 存的是密码、d_ip 存的是加密方式/用户名, 原表格会把密码当端口打印
      echo -e " $i  |$str  |$d_port\t|$d_ip (密码已隐藏)"
    else
      echo -e " $i  |$str  |$s_port\t|$d_ip:$d_port"
    fi
    echo -e "--------------------------------------------------------"
  done
}

cron_restart() {
  echo -e "------------------------------------------------------------------"
  echo -e "gost定时重启任务: "
  echo -e "-----------------------------------"
  echo -e "[1] 配置gost定时重启任务"
  echo -e "[2] 删除gost定时重启任务"
  echo -e "-----------------------------------"
  read -p "请选择: " numcron
  if [[ ${numcron} == "1" ]]; then
    echo -e "------------------------------------------------------------------"
    echo -e "gost定时重启任务类型: "
    echo -e "-----------------------------------"
    echo -e "[1] 每？小时重启"
    echo -e "[2] 每日？点重启"
    echo -e "-----------------------------------"
    read -p "请选择: " numcrontype
    local cron_line
    if [[ ${numcrontype} == "1" ]]; then
      echo -e "-----------------------------------"
      read -p "每？小时重启: " cronhr
      if ! [[ ${cronhr} =~ ^[0-9]+$ ]] || ((10#${cronhr} < 1 || 10#${cronhr} > 23)); then
        die "小时数必须是 1-23 的整数"
      fi
      cron_line="0 */${cronhr} * * * root systemctl restart gost"
    elif [[ ${numcrontype} == "2" ]]; then
      echo -e "-----------------------------------"
      read -p "每日？点重启: " cronhr
      if ! [[ ${cronhr} =~ ^[0-9]+$ ]] || ((10#${cronhr} > 23)); then
        die "时刻必须是 0-23 的整数"
      fi
      cron_line="0 ${cronhr} * * * root systemctl restart gost"
    else
      echo "type error, please try again"
      exit
    fi
    # 写独立文件而不是往 /etc/crontab 追加:
    # 原来那行是 7 字段且星期位写成 "?", vixie/cronie 会判定语法错误整行丢弃,
    # 而脚本照样提示"设置成功"; 删除时 sed /gost/d 还会误删别人的任务
    mkdir -p /etc/cron.d || die "无法创建 /etc/cron.d"
    echo "${cron_line}" >"${cron_file}" && chmod 0644 "${cron_file}" || die "写入定时任务失败"
    echo -e "定时重启设置成功！"
    systemctl is-active --quiet cron 2>/dev/null || systemctl is-active --quiet crond 2>/dev/null ||
      warn "cron 服务似乎未运行，请确认已安装并启动 cron/crond"
  elif [[ ${numcron} == "2" ]]; then
    if [[ -f ${cron_file} ]]; then
      rm -f "${cron_file}" && echo -e "定时重启任务删除完成！"
    else
      echo -e "未找到 gost 定时重启任务"
    fi
  else
    echo "type error, please try again"
    exit
  fi
}

# 统计 rawconf 里有效规则条数(与 writeconf 的判定保持一致)
function count_rules() {
  local n=0 line
  [[ -f ${raw_conf_path} ]] || {
    echo 0
    return
  }
  while IFS= read -r line || [[ -n ${line} ]]; do
    line=${line%$'\r'}
    [[ -z ${line//[[:space:]]/} ]] && continue
    [[ ${line} != *"#"*"#"* ]] && continue
    n=$((n + 1))
  done <"${raw_conf_path}"
  echo "${n}"
}

# 取一条 rawconf 规则实际占用的监听端口
# ss/socks/http 的第二个字段存的是密码, 监听端口在第三段
function rule_listen_port() {
  local line="$1" t f1 rest f3 sp
  t=${line%%/*}
  f1=${line%%#*}
  sp=${f1#*/}
  rest=${line#*#}
  f3=${rest#*#}
  local p
  case "${t}" in
  ss | socks | http) p=${f3} ;;
  *) p=${sp} ;;
  esac
  # 归一成十进制: "010000" 与 "10000" 是同一个端口
  [[ ${p} =~ ^[0-9]+$ ]] && p=$((10#${p}))
  echo "${p}"
}

# 该监听端口是否已被现有规则占用
function listen_port_taken() {
  local port="$1" line
  [[ ${port} =~ ^[0-9]+$ ]] && port=$((10#${port}))
  [[ -f ${raw_conf_path} ]] || return 1
  while IFS= read -r line || [[ -n ${line} ]]; do
    line=${line%$'\r'}
    [[ -z ${line//[[:space:]]/} ]] && continue
    [[ ${line} != *"#"*"#"* ]] && continue
    [[ $(rule_listen_port "${line}") == "${port}" ]] && return 0
  done <"${raw_conf_path}"
  return 1
}

# 列出 rawconf 里重复的监听端口(gost 会因 address already in use 起不来)
function duplicate_ports() {
  local line
  [[ -f ${raw_conf_path} ]] || return 0
  while IFS= read -r line || [[ -n ${line} ]]; do
    line=${line%$'\r'}
    [[ -z ${line//[[:space:]]/} ]] && continue
    [[ ${line} != *"#"*"#"* ]] && continue
    rule_listen_port "${line}"
  done <"${raw_conf_path}" | sort | uniq -d
}

function show_banner() {
  local ver state color rules
  echo
  echo -e "  ${Bold}${Green_font_prefix}gost 一键安装配置脚本${Font_color_suffix}   ${Bold}v${shell_version}${Font_color_suffix}"
  echo -e "  ${Cyan_font_prefix}Gaslys fork of KANIKIG/Multi-EasyGost${Font_color_suffix}"
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
    echo -e "  ${color}●${Font_color_suffix} ${state} · gost ${ver:-未知} · 转发规则 ${rules} 条"
  else
    echo -e "  ${Red_font_prefix}●${Font_color_suffix} 未安装 · 选择 1 开始安装"
  fi
  echo -e "  文档 https://github.com/Gaslys/Multi-EasyGost"
  echo
  echo -e "    ${Green_font_prefix}1${Font_color_suffix} 安装      ${Green_font_prefix}2${Font_color_suffix} 更新      ${Green_font_prefix}3${Font_color_suffix} 卸载      ${Green_font_prefix}4${Font_color_suffix} 启动"
  echo -e "    ${Green_font_prefix}5${Font_color_suffix} 停止      ${Green_font_prefix}6${Font_color_suffix} 重启      ${Green_font_prefix}7${Font_color_suffix} 新增      ${Green_font_prefix}8${Font_color_suffix} 查看"
  echo -e "    ${Green_font_prefix}9${Font_color_suffix} 删除      ${Green_font_prefix}10${Font_color_suffix} 定时重启 ${Green_font_prefix}11${Font_color_suffix} 证书     ${Cyan_font_prefix}0${Font_color_suffix} 退出"
  echo -e "  ------------------------------------------------------------"
  echo
}

update_sh() {
  local ol_version tmp
  ol_version=$(curl -fsSL --connect-timeout 5 --max-time 8 "${update_url}" 2>/dev/null | grep -m1 "shell_version=" | awk -F '=|"' '{print $3}')
  # 只在远端版本严格更新时提示, 否则修改版本号后会被判定为"有新版本"并降级覆盖
  newer=$(printf '%s\n%s\n' "${shell_version}" "${ol_version}" | sort -V | tail -n 1)
  if [ -n "$ol_version" ]; then
    if [[ -n ${newer} && ${newer} == "${ol_version}" && ${ol_version} != "${shell_version}" ]]; then
      echo -e "存在新版本，是否更新 [Y/N]?"
      read -r update_confirm
      case $update_confirm in
      [yY][eE][sS] | [yY])
        tmp=$(mktemp) || {
          warn "无法创建临时文件，已保留当前脚本"
          return 1
        }
        if ! curl -fsSL --connect-timeout 10 --max-time 60 -o "$tmp" "${update_url}"; then
          rm -f "$tmp"
          warn "新版本下载失败，已保留当前脚本"
          return 1
        fi
        # 先确认下到的是脚本而不是错误页，再原子替换。
        # 原来是 wget -N 原地覆写正在执行的脚本, bash 边读边执行, 可能读到半截文件
        if ! bash -n "$tmp" 2>/dev/null || ! grep -q "^shell_version=\"${ol_version}\"" "$tmp"; then
          rm -f "$tmp"
          warn "下载内容不是有效脚本或版本不符，已保留当前脚本"
          return 1
        fi
        chmod 0755 "$tmp"
        if ! mv -f "$tmp" "$0"; then
          rm -f "$tmp"
          warn "替换脚本失败，请手动下载更新"
          return 1
        fi
        echo -e "更新完成，请重新运行脚本"
        exit 0
        ;;
      *) ;;

      esac
    else
      echo -e "  ${Green_font_prefix}当前版本为最新版本！${Font_color_suffix}"
    fi
  else
    echo -e "  ${Red_font_prefix}脚本最新版本获取失败，请检查与 github 的连接！${Font_color_suffix}"
  fi
}

check_root
show_banner
update_sh
read -e -p " 请输入数字 [0-11]:" num
case "$num" in
1)
  Install_ct
  ;;
2)
  checknew
  ;;
3)
  Uninstall_ct
  ;;
4)
  Start_ct
  ;;
5)
  Stop_ct
  ;;
6)
  Restart_ct
  ;;
7)
  rawconf
  if regen_config; then
    if ((regen_stopped)); then
      warn "配置为空，服务保持停止"
    else
      systemctl restart gost
      sleep 1
      systemctl is-active --quiet gost || warn "gost 未能正常启动，请执行 systemctl status gost 查看原因"
      echo -e "配置已生效，当前配置如下"
      echo -e "--------------------------------------------------------"
      show_all_conf
    fi
  else
    warn "新规则未通过校验，已保留上一份配置；请用菜单 8 核对 rawconf 后重试"
  fi
  ;;
8)
  show_all_conf
  ;;
9)
  show_all_conf
  read -p "请输入你要删除的配置编号：" numdelete
  count_line=$(awk 'END{print NR}' "${raw_conf_path}" 2>/dev/null)
  # 原来只校验"含一个数字", "1e 命令" 这类输入能通过; GNU sed 的 e 地址修饰符会执行命令
  if [[ ${numdelete} =~ ^[0-9]+$ ]] && ((10#${numdelete} >= 1 && 10#${numdelete} <= ${count_line:-0})); then
    sed -i "${numdelete}d" "${raw_conf_path}"
    if regen_config; then
      if ((regen_stopped)); then
        echo -e "配置已删除，规则已清空，gost 服务已停止"
      else
        systemctl restart gost
        sleep 1
        systemctl is-active --quiet gost || warn "gost 未能正常启动，请执行 systemctl status gost 查看原因"
        echo -e "配置已删除，服务已重启"
      fi
    else
      warn "剩余配置未通过校验，已保留上一份配置；请用菜单 8 核对 rawconf 后重试"
    fi
  else
    echo "请输入正确数字"
  fi
  ;;
10)
  cron_restart
  ;;
11)
  cert
  ;;
0)
  exit 0
  ;;
*)
  echo "  请输入正确数字 [0-11]"
  ;;
esac
