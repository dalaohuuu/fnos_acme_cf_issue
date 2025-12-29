# FnOS + acme.sh + Cloudflare DNS 自动签发证书（示例脚本）

> ⚠️ **重要声明**
>
> 本项目是一个 **示例 / 思路分享脚本**，用于展示如何在 **飞牛 OS (FnOS)** 上，
> 使用 **acme.sh + Cloudflare DNS API** 自动签发 SSL 证书，并将证书直接写入飞牛系统所需的位置。
>
> 脚本会：
> - 以 **root 权限** 运行
> - 写入 `/usr/trim/var/trim_connect/ssls`
> - 修改 `/usr/trim/etc/network_gateway_cert.conf`
> - 更新 PostgreSQL 数据库 `trim_connect`
> - 重启相关服务
>
> **请在理解脚本逻辑、并完成系统备份后再使用。风险自负。**

---

## 1.适用场景

- 飞牛 OS（FnOS）
- 没有公网 IP / 内网环境
- DNS 托管在 **Cloudflare**
- 需要使用 **DNS-01** 方式申请 / 续期证书
- 希望 **不通过飞牛 Web UI**，直接自动管理证书

---

## 2.工作原理（简述）

1. 使用 `acme.sh` + Cloudflare DNS API（`dns_cf`）签发证书  
2. 在飞牛证书目录中创建：
/usr/trim/var/trim_connect/ssls/&lt;domain&gt;/&lt;timestamp&gt;/
3. 写入证书文件：
- `<domain>.crt`
- `<domain>.key`
- `fullchain.crt`
- `issuer_certificate.crt`
4. 更新 PostgreSQL 数据库 `trim_connect.cert` 表
5. 更新 `/usr/trim/etc/network_gateway_cert.conf`
6. 重启飞牛相关服务，使证书生效

---

## 3.使用步骤（请严格按顺序）
需使用root运行：
获取root权限：
```
sudo -i
```

---

### 3.1：创建配置文件（ENV_FILE，必须先做）

> ⚠️ **脚本运行依赖 `ENV_FILE`，必须先创建**

在任意工作目录（建议单独建一个目录）执行：

```
mkdir -p ~/fnos-acme && cd ~/fnos-acme
```
然后以 root 身份创建 ENV_FILE：

用您自己的域名和Cloudflare API Token，替换下段代码中的：
fn.example.com 和 PASTE_YOUR_CLOUDFLARE_API_TOKEN_HERE 后粘贴到命令行:
```
tee ENV_FILE <<'EOF'
DOMAIN=fn.example.com
#yes:申请泛域名；no：不申请泛域名
WILDCARD=yes

# Cloudflare API Token
CF_TOKEN=PASTE_YOUR_CLOUDFLARE_API_TOKEN_HERE

# DNS 生效等待时间（秒）
DNS_SLEEP=120

# 证书服务商
CERT_SERVER=letsencrypt

# 飞牛 OS 路径（一般不用改）
SSLS_DIR=/usr/trim/var/trim_connect/ssls
NGX_CONF=/usr/trim/etc/network_gateway_cert.conf

# 数据库配置
DB_NAME=trim_connect
DB_USER=postgres

# 重启服务（按需修改）
RELOAD_CMD="systemctl restart webdav.service smbftpd.service trim_nginx.service"

# 清理旧证书目录（天）
CLEAN_OLD_DAYS=90
EOF

```
⚠️ ENV_FILE 包含敏感信息，请妥善保管，不要上传到 GitHub

### 3.2：下载脚本
仍在同一目录下执行：

```
curl -fsSL \
https://raw.githubusercontent.com/dalaohuuu/fnos_acme_cf_issue/refs/heads/main/fnos_acme_cf_issue.sh \
-o fnos_acme_cf_issue.sh
```
```
chmod +x fnos_acme_cf_issue.sh
```
### 3.3：第一次运行（dry-run，强烈推荐）
```
./fnos_acme_cf_issue.sh
```
或显式指定：
```
./fnos_acme_cf_issue.sh --dry-run
```
dry-run 模式下：

不会真正修改系统

不会写数据库

不会重启服务

只打印将要执行的操作

请认真检查输出。

### 3.4：确认无误后，正式执行
```
./fnos_acme_cf_issue.sh --apply
```
这一步会真正：

签发证书

写入飞牛证书目录

更新数据库

更新 nginx 配置

重启服务
### 3.5:首次使用，需要到飞牛管理界面切换为刚申请的证书
"首次申请证书，需登录飞牛网页手动切换证书，方法："
"系统设置——安全性——证书——服务配置——切换刚申请的证书。"

## 4.常见问题
### Q1：为什么必须先创建 ENV_FILE？
脚本启动时会立即读取 ENV_FILE，如果不存在会直接退出，以防止误操作。

### Q2：为什么默认是 dry-run？
为了安全。示例脚本默认不改系统，只有显式 --apply 才会真正执行。

### Q3：是否支持自动续期？
支持。acme.sh 会自动安装 cron 任务，后续续期仍会执行同样流程。

## 5.安全建议（强烈）
不要把 ENV_FILE 提交到 Git 仓库

定期轮换 Cloudflare API Token

执行前建议备份：

/usr/trim/etc/network_gateway_cert.conf

数据库 trim_connect（至少 cert 表）

/usr/trim/var/trim_connect/ssls/<domain>/

## 6.License
MIT License

免责声明
本项目为 非官方示例脚本，仅供学习与参考。
因使用本脚本造成的任何数据丢失、服务中断或系统损坏，作者不承担任何责任。