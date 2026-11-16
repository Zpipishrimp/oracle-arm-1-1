#Requires -Version 5.1
<#
============================================================
   甲骨文 OCI 新建/升级实例脚本（Windows PowerShell 版）
   由 oci-help.sh 改写，适配 Windows 10 + PowerShell 5.1
============================================================

   与原 sh 版的主要差异：
     1. 不再需要 jq —— 用 PowerShell 原生 ConvertFrom-Json 解析
     2. 不再需要 bash/sh —— 直接双击 oci-help.cmd 或用 PowerShell 运行
     3. Telegram 用 curl.exe 发送（Win10 1803+ 自带，支持 socks5 代理）
     4. 日志与 success.json 固定落在脚本所在目录，不受当前工作目录影响

   前置条件：
     - 已安装 OCI CLI（安装后 oci.exe 必须在 PATH 里，命令行执行 oci -v 能出版本）

   用法示例（在脚本所在目录打开 PowerShell）：
     powershell -ExecutionPolicy Bypass -File .\oci-help.ps1 --help
     powershell -ExecutionPolicy Bypass -File .\oci-help.ps1 --launch
     powershell -ExecutionPolicy Bypass -File .\oci-help.ps1 --update
     powershell -ExecutionPolicy Bypass -File .\oci-help.ps1 --launch --shape-config 2 12
#>

#====== 新建实例配置相关 ======#
# 区域ID                 [availability_domain]
$Available_Domain = 'xxxx:AP-xxxxx-1-AD-1'
# 镜像                   [source_id]
$Image_ID = 'ocid1.image.oc1.ap-xxxxx-1.xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
# 子网ID                 [subnet_id]
$Subnet_ID = 'ocid1.subnet.oc1.ap-xxxxx-1.xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
# 公钥                   [ssh_authorized_keys]
$SSH_Key_PUB = 'ssh-rsa xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx ssh-key-xxxx-xx-xx'
# 租户ID                 [compartment_id]
$Compartment_ID = 'ocid1.tenancy.oc1..xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
# 配置                   [shape]
$Shape = 'VM.Standard.A1.Flex'
# CPU数目
$CPU = 1
# 内存大小(GB)
$RAM = 6
# 引导卷大小(GB)
$HD = 50
# 实例名称
$Instance_Name = 'instance-xxxx-xxxx'

#====== 升级实例配置相关 ======#
# 升级的实例OCID          [实例详细信息页面的OCID]
$Instance_ID = 'ocid1.instance.oc1.ap-xxxxx-1.xxxxxxxxxxxxxx'
# 升级到CPU个数
$Upd_CPU = 2
# 升级到内存大小(GB)
$Upd_RAM = 12

#====== 新建/升级实例时间间隔 ======#
# 指定一个时间范围，随机生成时间间隔（单位：秒）
$min_Time = 60
$max_Time = 120

#====== OCI个人资料名称 ======#
# 执行 oci setup config 配置时所起的 profile 名称，直接回车默认 DEFAULT
# 注意：PowerShell 里 $PROFILE 是内置变量，这里用 $OciProfile 避免冲突
$OciProfile = 'DEFAULT'

#====== Telegram bot 消息提醒配置相关 ======#
# 发送消息提醒。0: 不发送；1: 发送
$SEND_MSG = 0
# Telegram bot token，通过 BotFather(https://t.me/BotFather) 创建 Bot 获取
$TOKEN = 'xxxxxxxxxx:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
# 接收消息的Telegram ID，通过 IDBot(https://t.me/myidbot) 获取
$CHAT_ID = 'xxxxxxxxx'
# 使用代理访问 Telegram API。0: 不使用；1: 使用
$PROXY = 0
# Socks5 代理（curl 支持 socks5:// 与 socks5h://）
$PROXY_URL = 'socks5://127.0.0.1:10808'
# Http 代理示例
# $PROXY_URL = 'http://127.0.0.1:10809'

###============================== 以下区域无需修改 ==============================###
$PROJECT = '甲骨文 OCI 新建/升级实例'
$VER = '1.0.0'
$SCRIPT_DIR = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$LOG_DIR = Join-Path $SCRIPT_DIR 'log'
$LOG_FILE = Join-Path $LOG_DIR 'OCI.log'
$NO_TIMESTAMP = 0
# 保存日志到文件。0:不保存；1:保存
$SAVE_LOG = 1
$URL = "https://api.telegram.org/bot$TOKEN/sendMessage"

#################################################################################
# 日志输出                                                                       #
#################################################################################
function Write-Log {
    param(
        [string]$Text,
        [string]$Color = 'White'
    )
    $line = $Text
    if ($NO_TIMESTAMP -eq 0) {
        $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    }
    Write-Host $line -ForegroundColor $Color
    if ($SAVE_LOG -eq 1) {
        try { Add-Content -LiteralPath $LOG_FILE -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    }
}

function Write-Info { param([string]$Text) Write-Log -Text $Text -Color Green }
function Write-Warn { param([string]$Text) Write-Log -Text $Text -Color Yellow }
function Write-Err  { param([string]$Text) Write-Log -Text $Text -Color Red }
function Write-Dbg  { param([string]$Text) Write-Log -Text $Text -Color White }

#################################################################################
# 调用 OCI CLI 并解析结果                                                        #
#################################################################################
function Invoke-OciCli {
    param([string[]]$CliArgs)
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # 2>&1 把 stderr 一并收进来（oci 的错误 JSON 走的是 stderr）
        $out = & oci @CliArgs 2>&1 | ForEach-Object { $_.ToString() }
    } finally {
        $ErrorActionPreference = $prevPref
    }
    return ($out -join "`n")
}

function ConvertFrom-OciOutput {
    <# 把 oci 的原始输出转成对象：
       1) 去掉 "ServiceError:" 前缀
       2) 截取第一个 { 到最后一个 } 之间的 JSON
       3) 解析失败返回 $null #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $body = $Text
    $idx = $Text.IndexOf('ServiceError:')
    if ($idx -ge 0) { $body = $Text.Substring($idx + 'ServiceError:'.Length) }
    $s = $body.IndexOf('{')
    $e = $body.LastIndexOf('}')
    if ($s -lt 0 -or $e -le $s) { return $null }
    $body = $body.Substring($s, $e - $s + 1)
    try { return ($body | ConvertFrom-Json) } catch { return $null }
}

function Get-JsonField {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Save-JsonFile {
    param([string]$Path, [string]$Content)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

#################################################################################
# Telegram 消息提醒                                                              #
#################################################################################
function Get-TelegramArgs {
    param([string]$Text, [bool]$UseMarkdown)
    $prefix = '甲骨文信息'
    if ($UseMarkdown) { $prefix = '*甲骨文信息*' }
    $cliArgs = @('-s', '-S', '--connect-timeout', '10', '--max-time', '10', '-X', 'POST')
    if ($PROXY -eq 1) { $cliArgs += @('-x', $PROXY_URL) }
    $cliArgs += @($URL)
    if ($UseMarkdown) { $cliArgs += @('--data-urlencode', 'parse_mode=Markdown') }
    $cliArgs += @('--data-urlencode', "chat_id=$CHAT_ID")
    $cliArgs += @('--data-urlencode', "text=$prefix`n$Text")
    return $cliArgs
}

function Send-Telegram {
    param([string]$Text)
    if ($SEND_MSG -ne 1) { return }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -eq $curl) {
        Write-Err '未找到 curl.exe，无法发送 Telegram 消息（Win10 1803 及以上自带）'
        return
    }

    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $result = (& curl.exe @(Get-TelegramArgs -Text $Text -UseMarkdown $true) 2>&1 |
                ForEach-Object { $_.ToString() }) -join ' '
        # curl 退出码为 0 不代表发送成功（Telegram 返回 400 时 curl 仍是 0），必须看响应体
        if ($result -notmatch '"ok":true') {
            # 消息里含 * _ 等字符时 Markdown 解析会失败，退回纯文本再发一次
            $result = (& curl.exe @(Get-TelegramArgs -Text $Text -UseMarkdown $false) 2>&1 |
                    ForEach-Object { $_.ToString() }) -join ' '
        }
    } finally {
        $ErrorActionPreference = $prevPref
    }
    if ($result -match '"ok":true') {
        Write-Info 'Telegram 消息提醒发送成功'
    } else {
        Write-Err ("Telegram 消息提醒发送失败, " + $result)
    }
}

#################################################################################
# 新建 / 升级 主循环                                                             #
#################################################################################
function Get-OciTempDir {
    <#
      挑一个不含空格的目录来放临时 JSON 文件。
      原因：oci 的 file:// 参数无法加引号包裹，路径里一旦有空格就会被拆成两个参数。
    #>
    foreach ($d in @($env:TEMP, $env:TMP, $SCRIPT_DIR, 'C:\Windows\Temp')) {
        if (-not [string]::IsNullOrWhiteSpace($d) -and $d -notmatch '\s' -and (Test-Path -LiteralPath $d)) {
            return $d
        }
    }
    throw '找不到不含空格的临时目录，无法生成 oci 的 JSON 参数文件'
}

function New-OciJsonFile {
    <#
      把 JSON 落到临时文件，返回 oci 支持的 file:// 参数值。

      为什么不直接把 JSON 当命令行参数传：
        PowerShell 5.1 调用外部 exe（oci.exe）时，参数里同时含「空格」和「双引号」
        会被拆成多个参数，且双引号被原样吞掉。实测 $meta =
        '{"ssh_authorized_keys": "ssh-rsa AAAA... sD ssh-key-2026-11-16"}'
        传给 oci 后变成三段：
            '{ssh_authorized_keys: ssh-rsa' / 'AAAAB3...' / 'ssh-key-2026-11-16}'
        oci 因此报 "Got unexpected extra arguments"。
        同理 --shape-config '{"ocpus":1,"memory_in_gbs":6}' 会变成
        '{ocpus:1,memory_in_gbs:6}'（引号丢失，JSON 非法）。
    #>
    param([string]$Name, [string]$Json)
    $path = Join-Path (Get-OciTempDir) $Name
    Save-JsonFile -Path $path -Content $Json
    return 'file://' + $path
}

function Get-SshKeyJson {
    param([string]$Key)
    # 一个公钥里含空格（算法、Base64、注释三段），多个公钥含换行，JSON 里都要转义
    $one = (($Key -split "`r?`n") | Where-Object { $_.Trim() -ne '' } |
            ForEach-Object { $_.Trim() }) -join '\n'
    if ($one -notmatch '^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-\S+)\s+[A-Za-z0-9+/=]+') {
        Write-Warn '公钥格式看起来不对：应以 ssh-rsa / ssh-ed25519 / ecdsa-sha2-* 开头'
    }
    return '{"ssh_authorized_keys": "' + $one + '"}'
}

function Get-LaunchArgs {
    $metaUri = New-OciJsonFile -Name 'oci-help-metadata.json' -Json (Get-SshKeyJson $SSH_Key_PUB)
    $shapeUri = New-OciJsonFile -Name 'oci-help-shape.json' `
        -Json ('{"ocpus":' + $CPU + ',"memory_in_gbs":' + $RAM + '}')
    return @(
        'compute', 'instance', 'launch',
        '--profile', $OciProfile,
        '--availability-domain', $Available_Domain,
        '--image-id', $Image_ID,
        '--subnet-id', $Subnet_ID,
        '--shape', $Shape,
        '--assign-public-ip', 'true',
        '--metadata', $metaUri,
        '--compartment-id', $Compartment_ID,
        '--shape-config', $shapeUri,
        '--boot-volume-size-in-gbs', "$HD",
        '--display-name', $Instance_Name
        # 想提高「单位时间尝试次数」可加 '--no-retry'：oci 内核默认对 500 自带重试，
        # 一次失败要耗 2 分钟左右；关掉它每次请求几秒就返回，由本脚本循环负责重试。
    )
}

function Get-UpdateArgs {
    $shapeUri = New-OciJsonFile -Name 'oci-help-shape-update.json' `
        -Json ('{"ocpus":' + $Upd_CPU + ',"memory_in_gbs":' + $Upd_RAM + '}')
    return @(
        'compute', 'instance', 'update',
        '--profile', $OciProfile,
        '--instance-id', $Instance_ID,
        '--shape-config', $shapeUri,
        '--force'
    )
}

function Wait-NextTry {
    $interval = Get-Random -Minimum $min_Time -Maximum $max_Time
    Write-Dbg "等待 $interval 秒后重试..."
    Start-Sleep -Seconds $interval
}

function Get-OciLocalAuthInfo {
    <#
      401 时给出可核对的本地信息：config 里的指纹 + 公钥文件路径。
      401 的典型原因：oci setup config 只在本地生成了密钥对，公钥没上传到控制台用户。
    #>
    $cfg = Join-Path $HOME '.oci\config'
    $fp = '(未读到 fingerprint)'
    if (Test-Path -LiteralPath $cfg) {
        foreach ($line in Get-Content -LiteralPath $cfg -ErrorAction SilentlyContinue) {
            if ($line -match '^\s*fingerprint\s*=\s*(.+?)\s*$') { $fp = $Matches[1]; break }
        }
    }
    return [pscustomobject]@{
        Fingerprint = $fp
        PublicKey   = (Join-Path $HOME '.oci\oci_api_key_public.pem')
    }
}

function Get-BriefText {
    <# 把 oci 的长 JSON 错误压缩成一行，便于日志里看 #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '(空响应)' }
    $m = [regex]::Match($Text, '"message"\s*:\s*"([^"]{0,160})')
    if ($m.Success) { return $m.Groups[1].Value }
    $one = ($Text -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
    if ($one.Length -gt 160) { $one = $one.Substring(0, 160) + '...' }
    return $one
}

function Test-TransientError {
    <#
      判断错误是否属于「瞬时」的、应该重试而不是退出的情况：
        1) CLI/SDK 层根本没拿到 HTTP 响应（因此没有 status 字段）：连接超时、连接重置、重试耗尽
        2) 502/503 网关类错误
      典型日志：RequestException: { "message": "The connection to endpoint timed out." }
      这类错误如果当成致命错误处理，会让抢机脚本在半夜掉线，所以一律重试。
    #>
    param($Json, [string]$Text)
    if ($Text -match 'RequestException|ConnectionError|Connection aborted|timed out|Temporary failure|Max retries|SSLError|ReadTimeout|ConnectTimeout') {
        return $true
    }
    $code = "$(Get-JsonField $Json 'status')"
    if ($code -eq '502' -or $code -eq '503') { return $true }
    return $false
}

function Start-LaunchInstance {
    $msg = "开始新建实例「${Instance_Name}: ${CPU}C${RAM}G」"
    Write-Info $msg
    Send-Telegram $msg

    while ($true) {
        Write-Warn '正在尝试新建实例...'
        $text = Invoke-OciCli (Get-LaunchArgs)
        $json = ConvertFrom-OciOutput $text
        $status = Get-JsonField $json 'status'
        $message = Get-JsonField $json 'message'
        $msgText = "Message: ${message}, Status: ${status}"

        # 网络层/网关层瞬时错误：记录后重试，不中断抢机
        if (Test-TransientError -Json $json -Text $text) {
            Write-Warn ("瞬时错误, 稍后重试: " + (Get-BriefText $text))
            Wait-NextTry
            continue
        }

        switch ("$status") {
            '500' { Write-Dbg $msgText; break }
            '429' { Write-Dbg $msgText; break }
            '400' {
                Write-Err $msgText
                Send-Telegram "脚本已停止, $msgText"
                return
            }
            '401' {
                Write-Err $msgText
                $auth = Get-OciLocalAuthInfo
                Write-Err "→ 本地 config 指纹: $($auth.Fingerprint)"
                Write-Err "→ 待登记的公钥文件: $($auth.PublicKey)"
                Write-Err '→ 控制台「我的概要文件 → API 密钥」里必须有上面这个指纹；没有就点「添加 API 密钥」粘贴公钥文件内容'
                Send-Telegram "脚本已停止, $msgText（请核对该指纹是否已登记到用户的 API 密钥: $($auth.Fingerprint)）"
                return
            }
            '404' {
                Write-Err $msgText
                Send-Telegram "脚本已停止, $msgText"
                return
            }
            '409' {
                Write-Err $msgText
                Send-Telegram "脚本已停止, $msgText"
                return
            }
            default {
                $ok = ($null -ne (Get-JsonField $json 'data')) -or ($text -match '"data"')
                if ($ok) {
                    $successText = "实例「${Instance_Name}: ${CPU}C${RAM}G」新建成功, 实例详细信息请查看 success.json"
                    Write-Info $successText
                    Send-Telegram $successText
                    Save-JsonFile (Join-Path $SCRIPT_DIR 'success.json') $text
                    Start-Sleep -Seconds 3
                    return
                }
                $errText = "脚本已停止, " + (Get-BriefText $text)
                Write-Err $errText
                Send-Telegram $errText
                return
            }
        }
        Wait-NextTry
    }
}

function Start-UpdateInstance {
    $msg = "开始升级实例到「${Upd_CPU} Core CPU, ${Upd_RAM} GB RAM」"
    Write-Info $msg
    Send-Telegram $msg

    while ($true) {
        Write-Warn '正在尝试升级实例...'
        $text = Invoke-OciCli (Get-UpdateArgs)
        $json = ConvertFrom-OciOutput $text
        $status = Get-JsonField $json 'status'
        $message = Get-JsonField $json 'message'
        $msgText = "Message: ${message}, Status: ${status}"

        # 网络层/网关层瞬时错误：记录后重试，不中断升级
        if (Test-TransientError -Json $json -Text $text) {
            Write-Warn ("瞬时错误, 稍后重试: " + (Get-BriefText $text))
            Wait-NextTry
            continue
        }

        switch ("$status") {
            '500' { Write-Dbg $msgText; break }
            '429' { Write-Dbg $msgText; break }
            '400' {
                Write-Err $msgText
                Send-Telegram "脚本已停止, $msgText"
                return
            }
            '401' {
                Write-Err $msgText
                Send-Telegram "脚本已停止, $msgText"
                return
            }
            '404' {
                Write-Err $msgText
                Send-Telegram "脚本已停止, $msgText"
                return
            }
            '409' {
                Write-Err $msgText
                Send-Telegram "脚本已停止, $msgText"
                return
            }
            default {
                $ok = ($null -ne (Get-JsonField $json 'data')) -or ($text -match '"data"')
                if ($ok) {
                    $successText = "实例已成功升级到「${Upd_CPU} Core CPU, ${Upd_RAM} GB RAM」, 实例详细信息请查看 success.json"
                    Write-Info $successText
                    Send-Telegram $successText
                    Save-JsonFile (Join-Path $SCRIPT_DIR 'success.json') $text
                    Start-Sleep -Seconds 3
                    return
                }
                $errText = "脚本已停止, " + (Get-BriefText $text)
                Write-Err $errText
                Send-Telegram $errText
                return
            }
        }
        Wait-NextTry
    }
}

#################################################################################
# 帮助 / 版本                                                                    #
#################################################################################
function Show-Version {
    Write-Host $PROJECT
    Write-Host "v$VER"
}

function Show-Help {
    Show-Version
    Write-Host @"
Usage: oci-help.ps1 <command> ... [parameters ...]

Commands:
    -h, --help               Show this help message.
    -v, --version            Show version info.
    --launch                 Create instance.
    --update                 Update instance.

Parameters:
    --available-domain       区域ID
    --image-id               系统镜像ID
    --subnet-id              子网ID
    --shape                  配置类型
    --shape-config           配置参数：CPU个数 内存大小(GB)，例如 --shape-config 2 12
    --boot-volume-size       引导卷大小（GB）
    --ssh-key-pub            SSH公钥
    --compartment-id         租户ID
    --instance-name          实例名称
    --instance-id            实例OCID，升级实例需要。
    --profile                配置oci时指定的别名，默认为DEFAULT。
                             当一台机器上面为多个甲骨文账号配置oci时，
                             需要指定不同的别名区分。

Examples:
    powershell -ExecutionPolicy Bypass -File .\oci-help.ps1 --launch
    powershell -ExecutionPolicy Bypass -File .\oci-help.ps1 --update --shape-config 2 12
"@
}

#################################################################################
# 初始化与参数解析                                                               #
#################################################################################
function Initialize-Script {
    Write-Info "$PROJECT 脚本正在启动..."
    if (-not (Test-Path -LiteralPath $LOG_DIR)) {
        Write-Info '创建日志目录'
        New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
    }
    $ociCmd = Get-Command oci -ErrorAction SilentlyContinue
    if ($null -eq $ociCmd) {
        Write-Err 'oci 命令行工具未安装或不在 PATH 中，请先安装 OCI CLI 并重新打开命令行窗口'
        Write-Err 'Windows 安装方式：https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm'
        return $false
    }
    # 原 sh 版还需要 jq，这里用 PowerShell 原生 JSON 解析，无需 jq
    return $true
}

function Invoke-Process {
    param([string[]]$CliArgs)

    $Command = ''
    $i = 0
    while ($i -lt $CliArgs.Count) {
        $a = $CliArgs[$i]
        if ($a -eq '--help' -or $a -eq '-h') { Show-Help; return }
        elseif ($a -eq '--version' -or $a -eq '-v') { Show-Version; return }
        elseif ($a -eq '--launch') { $Command = 'launch' }
        elseif ($a -eq '--update') { $Command = 'update' }
        elseif ($a -eq '--available-domain') { $i++; $script:Available_Domain = $CliArgs[$i] }
        elseif ($a -eq '--image-id') { $i++; $script:Image_ID = $CliArgs[$i] }
        elseif ($a -eq '--subnet-id') { $i++; $script:Subnet_ID = $CliArgs[$i] }
        elseif ($a -eq '--shape') { $i++; $script:Shape = $CliArgs[$i] }
        elseif ($a -eq '--ssh-key-pub') { $i++; $script:SSH_Key_PUB = $CliArgs[$i] }
        elseif ($a -eq '--compartment-id') { $i++; $script:Compartment_ID = $CliArgs[$i] }
        elseif ($a -eq '--shape-config') {
            if (($i + 2) -lt $CliArgs.Count) {
                $script:CPU = $CliArgs[$i + 1]
                $script:RAM = $CliArgs[$i + 2]
                $script:Upd_CPU = $CliArgs[$i + 1]
                $script:Upd_RAM = $CliArgs[$i + 2]
                $i += 2
            } else {
                Write-Err '--shape-config 需要两个参数：CPU个数 和 内存大小(GB)'
                return
            }
        }
        elseif ($a -eq '--boot-volume-size') { $i++; $script:HD = $CliArgs[$i] }
        elseif ($a -eq '--instance-name') { $i++; $script:Instance_Name = $CliArgs[$i] }
        elseif ($a -eq '--profile') { $i++; $script:OciProfile = $CliArgs[$i] }
        elseif ($a -eq '--instance-id') { $i++; $script:Instance_ID = $CliArgs[$i] }
        else {
            Write-Err "Unknown parameter : $a"
            return
        }
        $i++
    }

    if (-not (Initialize-Script)) { return }

    switch ($Command) {
        'launch' { Start-LaunchInstance }
        'update' { Start-UpdateInstance }
        default {
            if ($Command) { Write-Err "Invalid command: $Command" }
            Show-Help
        }
    }
}

function Invoke-Main {
    param([string[]]$CliArgs)
    if ($null -eq $CliArgs -or $CliArgs.Count -eq 0) { Show-Help; return }
    $first = $CliArgs[0]
    if ($first.StartsWith('-')) {
        Invoke-Process $CliArgs
    } elseif ($first -eq 'launch' -or $first -eq 'update') {
        Initialize-Script | Out-Null
        if ($first -eq 'launch') { Start-LaunchInstance } else { Start-UpdateInstance }
    } else {
        Show-Help
    }
}

#################################################################################
# 入口（Ctrl + C 时尽量发一条停止通知）                                          #
#################################################################################
$script:Finished = $false
try {
    Invoke-Main $args
    $script:Finished = $true
} finally {
    if (-not $script:Finished) {
        Write-Err '检测到中断（Ctrl + C），正在终止脚本...'
        Send-Telegram '脚本已停止运行。'
    }
}
