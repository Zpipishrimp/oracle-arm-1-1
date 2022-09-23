# 致谢
作者：lemoex  
  
[原链接](https://github.com/lemoex/oci-help)
  
# 甲骨文实例抢购教程

## 获取用户 OCID 和租户 OCID
登录甲骨文网站
1. 点击右上角头像 -> 点击类似 oracleidentitycloudservice/xxx@xx.com 的条目，进入后即可看到用户的 OCID。
2. 点击右上角头像 -> 点击类似 租户:xxx 的条目, 进入页面后即可获取租户的 OCID。

## 获取创建实例需要的参数
### 方法一
登录甲骨文网站，创建实例--保存为堆栈(Save as stack),下载 Terraform 配置，解压得到 main.tf 用文本编辑器打开即可。
### 方法二
登录甲骨文网站，创建实例，按F12打开浏览器开发者工具，点击创建实例发起请求，在开发者工具的网络中找到对应的网络请求获取参数。


### 方法二
下载 [oci-help.sh] （https://github.com/Serendipper-1/oracle-arm-1-1/tree/main/shell）脚本。
用文本编辑器打开 oci-help.sh，根据上面获取到的参数修改脚本。保存后通过下面命令运行脚本开始新建或者升级实例。
```
# 新建实例
./oci-help.sh --launch
# 升级实例
./oci-help.sh --update
```

## 使用 screen 在后台运行
### 在 screen 会话中运行程序
```
# 在 screen 中运行 oci-help
screen -S oci-help ./oci-help

# 在 screen 中运行新建实例命令
screen -S oci-help ./oci-help.sh --launch
# 在 screen 中运行升级实例命令
screen -S oci-help ./oci-help.sh --update
```

### 从 screen 会话中分离
按住 Ctrl 键不松，依次按字母 A 和 D 键，即可从当前screen中分离；或者直接关闭终端窗口。

### 重新连接 screen 会话
```
screen -r oci-help
```

### 终止 screen 会话
在 screen 会话中 按下 Ctrl 不松，按下字母 D 键，即可终止该 screen 会话。
