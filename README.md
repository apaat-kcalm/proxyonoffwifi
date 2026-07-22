# proxyonoffwifi

Clash Verge +水晶ux9h 无线网卡+双频wifi深坑
- 代理5g连不了,2.4g能连
- 网卡5g扫描很慢

因为深坑，我懒得换网卡也懒得手动切，所以借助ai写的😂

WiFiAutoSwitch.ps1：
- ProxyEnable 开/关 → WiFi 状态校准 → 目标 WiFi
- 2.4G / 5G 独立连接执行线
- 切换冷却机制
  - 睡眠/唤醒自动检测并纠正恢复后的 WiFi 状态
- 状态通知线
  - 彩色运行日志（INFO / OK / WARN / ERROR）
  - Windows 桌面通知
- 异常恢复线
  - 失败保持 + 重试
...

代理开关
- 手动切/写个autohotkey图形化界面切都可以
- 手动点击运行WiFiAutoSwitch.ps1后，无管理员权限，powershell窗口后台要挂着
