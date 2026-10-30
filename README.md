# Multi-EasyGost 一键脚本使用指南

> 本仓库是 [KANIKIG/Multi-EasyGost](https://github.com/KANIKIG/Multi-EasyGost) 的个人 fork（分支 `v2`）。
> 菜单、配置格式与上游保持一致，只修 bug 与安全加固：当前脚本版本 **1.2.9**，gost 固定 **v2.11.2**。
> 逐条改动与验证记录见 [CHANGELOG.md](CHANGELOG.md)。

***
## 感谢

1. 感谢 @ginuerzh 大佬开发的 [gost](https://github.com/ginuerzh/gost) 隧道程序，功能强大使用简单，想要详细了解的朋友可以查看[官方文档](https://docs.ginuerzh.xyz/gost/)
2. 感谢 @风萧萧兮易水寒 大佬的[原始脚本](https://www.fiisi.com/?p=125)
3. 感谢 @STSDUST 提供的 EasyGost 脚本（已删库），此脚本是基于其进行修改增强
4. 感谢 @KANIKIG 维护的 [Multi-EasyGost](https://github.com/KANIKIG/Multi-EasyGost)，本仓库在其基础上做修复

***
## 简介

- 本仓库：`https://github.com/Gaslys/Multi-EasyGost`
- 上游：`https://github.com/KANIKIG/Multi-EasyGost`

***
## 脚本

一键安装并启动菜单：

```bash
curl -fsSL -o gost.sh https://raw.githubusercontent.com/Gaslys/Multi-EasyGost/v2/gost.sh && chmod +x gost.sh && ./gost.sh
```

再次运行只需输入 `./gost.sh` 回车。

> 注：gost v2.11.2 功能稳定，本脚本固定使用该版本。脚本启动时会对比本仓库的版本号提示更新，
> 不会把你更新回上游的旧版本。

### 精简版 `gost-lite.sh`

只做 tcp+udp 不加密转发，菜单只有 安装 / 新增 / 查看 / 删除 / 重启 / 卸载：

```bash
curl -fsSL -o gost-lite.sh https://raw.githubusercontent.com/Gaslys/Multi-EasyGost/v2/gost-lite.sh && chmod +x gost-lite.sh && ./gost-lite.sh
```

它和完整版共用 `/etc/gost/config.json` 与 `rawconf`，同一台机器上两个脚本可以互换。
如果 `rawconf` 里已经有 ss / tls / ws 等其它类型的规则，精简版会拒绝重建配置并提示改用完整版，
不会把这些规则写丢。精简版不带自更新，升级重新下载覆盖即可。

***
## 本 fork 相对上游的改动（1.2.x）

只挑使用者能感知到的部分，完整清单见 [CHANGELOG.md](CHANGELOG.md)。

- 定时重启真正生效：改写 `/etc/cron.d/gost-restart`。上游那行写进 `/etc/crontab` 的
  7 字段 + `?` 会被 cron 判定语法错误直接丢弃，但脚本照样提示「设置成功」。
- 安装成功判定修正：上游检查的 unit 路径写成了 `systemctl`（应为 `systemd`），
  再加上 `test -a` 链式判断的解析问题，实际无法确认 unit 是否装好。
- 配置重建加保护：菜单 6/7/9 重建 `config.json` 前先备份，生成后做 JSON 校验，
  失败自动回滚，并保留 `config.json.bak`。上游是直接删掉重写，写坏就起不来。
- 更新不再原地覆写脚本：改为下载到临时文件、`bash -n` 校验后再原子替换，
  并修复了多次更新后配置备份套娃、导致转发配置丢失的问题。
- 不再从网络下载 systemd unit 与默认配置：改由脚本本地生成，只下载二进制，
  且安装前先跑一次 `gost -V` 校验版本，拦截被篡改、截断或架构不符的文件。
- 权限收紧：二进制 0755、unit 0644、`/etc/gost` 0700、配置 0600。
  上游有 `chmod -R 777`，连 `/usr/lib/systemd/system` 都会被递归改成全局可写。
- 输入校验：端口、主机、密码在读取时即校验，挡掉会破坏 JSON / URI / rawconf 的字符
  （含 `/`、`?`、`%`——`/` 是 rawconf 的分隔符，`?` 与 `%` 会让 gost 解析 URI 失败）。
- 安装改为先下载、解压、跑 `gost -V` 校验，全部通过后才替换旧文件；已安装时重装会二次确认并保留配置。
- 配置重建先写临时文件、校验通过后原子替换，中途中断不会把正在用的 `config.json` 截断。
- 菜单 9 的删除编号改为严格数字校验（上游只判断「含一个数字」，存在 sed 地址注入）。
- 移除失效的国内镜像选项（原地址三个文件全部 404）。

***
## 文件说明

| 文件 | 用途 |
| --- | --- |
| `gost.sh` | 完整版脚本，安装后由它管理 gost |
| `gost-lite.sh` | 精简版脚本，只保留 tcp+udp 不加密转发 |
| `gost.service` | systemd unit，安装时写入 `/usr/lib/systemd/system/` |
| `config.json` | gost 默认配置示例，安装时由脚本生成到 `/etc/gost/` |

***
## 功能

- 用 systemd 与 gost 配置文件管理 gost，reboot 后转发不失效
- 不借助 screen 等工具即可让多条转发规则同时生效
- 支持传输类型：
  - tcp + udp 不加密转发
  - relay + tls
  - relay + ws
  - relay + wss
- 落地机一键创建 ss / socks5 / http 代理（gost 内置）
- 多落地简单型均衡负载（round / random / fifo）
- 转发 CDN 自选节点
- 自定义 TLS 证书：落地机可用 acme.sh 一键申请（HTTP 或 Cloudflare DNS），
  中转机可开启证书校验
- 定时重启任务（`/etc/cron.d/gost-restart`）

***
## 使用注意

- 记得在安全组或防火墙放行你使用的端口，脚本不会自动改 ufw/firewalld。
- 目标地址支持 IPv4、域名和 IPv6 字面量（IPv6 会自动加方括号）；地址里不要带端口，端口单独填。
- 转发配置以 `/etc/gost/rawconf` 为准。菜单 6（重启）也会按 rawconf 重建 `config.json`，
  手工改过的 `config.json` 会被覆盖——上一份会留在 `config.json.bak`。
- 均衡负载的落地列表放在 `/root/<你起的名字>.txt`，改完用菜单 6 重启即可生效。
- 菜单 3 卸载会停止并禁用服务、清理 `/etc/gost` 与定时任务，但不会删除 `gost.sh` 本身。

***
## 已知限制

- gost v2 上游已停止维护，长期看应迁移到 v3（配置格式完全不同）。
- 仅支持 systemd 与 Debian / Ubuntu / CentOS 系发行版。
- `method()` 里仍有两份重复的配置生成分支，属风格问题，本轮保守修复未动。
