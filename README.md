# Oracle 甲骨文 ARM 实例自动抢购脚本

Oracle Cloud 免费 ARM 实例（`VM.Standard.A1.Flex`）长期缺货，手动点只能靠运气。
本项目通过 OCI CLI 高频轮询 `instance launch`，抢到就停，并把实例信息写入 `success.json`。

提供两套实现，参数完全一致：

| 目录 | 平台 | 依赖 |
|---|---|---|
| [`shell/`](shell/) | Linux / macOS | `bash`、`sh`、`jq` |
| [`powershell/`](powershell/) | **Windows 10 / 11** | PowerShell 5.1（系统自带）、`oci` CLI |

## 致谢

原作者：[lemoex](https://github.com/lemoex/oci-help) ｜ 上游仓库：<https://github.com/lemoex/oci-help>
本仓库在此基础上增加了 Windows PowerShell 版实现，并修复了若干踩坑点（见文末「与 sh 版的差异」）。

---

## 一、前置条件

### 1. 安装 OCI CLI

**Windows**（任选一种）：

```powershell
# 方式 A：MSI 安装包（推荐，官方 Releases）
# https://github.com/oracle/oci-cli/releases  →  oci-cli-*-windows.msi
# 国内下载慢可在原地址前加镜像前缀：https://gh-proxy.com/<原始URL>

# 方式 B：pip（要求 Python 3.8 ~ 3.12，版本过高会装不上）
pip install oci-cli
```

装完**新开一个命令行窗口**，执行 `oci -v` 能看到版本号即可。

### 2. 配置 API 密钥

```bat
oci setup config
```

依次填写：用户 OCID、租户 OCID、区域（如 `ap-tokyo-1`）、密钥保存路径，profile 名直接回车即 `DEFAULT`。

> ⚠️ **最容易踩的坑**：`oci setup config` 只在本地生成密钥对，**不会自动上传公钥**。
> 必须去控制台「我的概要文件 → API 密钥 → 添加 API 密钥 → **粘贴公钥**」，
> 把生成的 `oci_api_key_public.pem` 内容贴进去。
> 注意别选「生成 API 密钥对」，那会新建一对密钥，本地私钥当场作废。

验证是否真的通了：

```bat
oci iam region list
```

返回区域列表 JSON 才算成功。若返回 `401 NotAuthenticated`，说明公钥没登记上（与权限、配额无关）。

---

## 二、获取创建实例需要的参数

### 方法一：从 Terraform 配置里取（最省事）

控制台创建实例 → 勾选「保存为堆栈」→ 下载配置 → 解压得到 `main.tf`，里面就有
`availability_domain`、`source_id`、`subnet_id`、`compartment_id`。

### 方法二：从浏览器开发者工具取

按 F12 打开网络面板 → 点「创建实例」→ 在请求载荷里找同上那几个字段。

---

## 三、Windows 版用法

```bat
cd /d D:\Software\oracle

:: 先改 powershell\oci-help.ps1 顶部的参数，再执行
oci-help.cmd --launch
```

`oci-help.cmd` 是启动器（自动绕过执行策略），也可以直接调 PowerShell：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\oci-help.ps1 --launch
```

### 常用参数

```bat
oci-help.cmd --help                                  :: 查看全部参数
oci-help.cmd --launch                                :: 新建实例（1C6G，读脚本顶部配置）
oci-help.cmd --launch --shape-config 2 12            :: 新建 2 核 12G
oci-help.cmd --launch --instance-name arm2           :: 指定实例名
oci-help.cmd --update                                :: 升级实例配置（停机升级）
oci-help.cmd --update --instance-id ocid1.instance.oc1.ap-xxxxx-1.xxxx --shape-config 4 24
oci-help.cmd --launch --profile MYPROFILE            :: 指定 oci profile
```

### 需要改的 7 个参数（`powershell\oci-help.ps1` 顶部）

| 变量 | 含义 | 来源 |
|---|---|---|
| `$Available_Domain` | 可用性域 | `main.tf` 的 `availability_domain` |
| `$Image_ID` | 镜像 OCID | `main.tf` 的 `source_id` |
| `$Subnet_ID` | 子网 OCID | `main.tf` 的 `subnet_id` |
| `$SSH_Key_PUB` | 登录用 SSH 公钥 | `C:\Users\<你>\.ssh\id_rsa.pub` 内容，**整行粘贴** |
| `$Compartment_ID` | 租户（或区间）OCID | `main.tf` 的 `compartment_id` |
| `$Instance_Name` | 实例显示名 | 自定 |
| `$Instance_ID` | 要升级的实例 OCID | 仅 `--update` 需要 |

`$min_Time` / `$max_Time` 是重试间隔（秒），默认 60–120。**不建议调到 30 以下**，
并发过高会触发 `429 TooManyRequests`，反而抢不到。

### Telegram 抢到通知（可选）

```powershell
$SEND_MSG = 1
$TOKEN    = '<BotFather 给的 token>'
$CHAT_ID  = '<@myidbot 查到的 ID>'
$PROXY    = 1                        # 国内需要走代理
$PROXY_URL = 'socks5://127.0.0.1:10808'
```

---

## 四、Linux 版用法

```bash
chmod +x oci-help.sh
./oci-help.sh --launch
./oci-help.sh --update
```

后台长跑建议用 `screen`：

```bash
screen -S oci-help ./oci-help.sh --launch   # 启动
# Ctrl+A 然后按 D 分离；screen -r oci-help 重新连接
```

---

## 五、常见报错对照

| 输出 | 含义 | 处理 |
|---|---|---|
| `Out of host capacity. Status: 500` | 该区域 ARM 没库存（**最常见，属正常**） | 继续等，脚本会自己重试；可换可用性域 |
| `401 NotAuthenticated` | API 公钥没登记或指纹不匹配 | 控制台「API 密钥」粘贴公钥，核对指纹 |
| `LimitExceeded` | 免费额度已满（4 OCPU / 24 GB） | 降配或先删掉闲置实例 |
| `429 TooManyRequests` | 请求太密被限流 | 调大 `$min_Time` / `$max_Time` |
| `The connection to endpoint timed out` | 网络抖动 | PowerShell 版自动重试，不中断 |
| `PublicKey 属性无效` | 与 OCI 无关，是 v2rayN 校验报错 | 检查节点 REALITY 参数是否完整 |

---

## 六、与 sh 版的差异（PowerShell 版做过的事）

1. **不再依赖 `jq`** —— 用 `ConvertFrom-Json` 原生解析。
2. **JSON 参数改用 `file://` 传递** —— PowerShell 5.1 给原生 exe 传参时，含空格 + 双引号的参数
   会被拆成多段且引号丢失，`--metadata`（SSH 公钥）、`--shape-config` 必然报
   `Got unexpected extra arguments`。现改为写临时 JSON 文件后用 `file://` 传入。
3. **Telegram 发送校验响应体** —— `curl` 退出码为 0 不代表发送成功（Telegram 返回 400 时仍是 0），
   现在检查 `"ok":true`，失败自动退回纯文本重发一次。
4. **瞬时网络错误自动重试** —— `RequestException` / `timed out` / `502` / `503` 不再终止循环，
   只有 `400/401/404/409` 这类需要人工处理的错误才停。
5. **文件编码要求** —— `.ps1` 必须 **UTF-8 带 BOM + CRLF**，否则 PowerShell 5.1 读中文会乱码、
   here-string 直接解析失败。用编辑器改动时注意右下角的编码与换行显示。

---

## 七、免责声明

本项目仅用于自动化调用你自己账号下的 OCI API，不涉及任何鉴权绕过。
高频轮询请自行控制频率，避免触发风控；由此产生的账号风险由使用者自负。

## Star History

如果这个项目帮你抢到了机器，欢迎点个 ⭐
