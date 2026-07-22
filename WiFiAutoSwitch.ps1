# ============================================================
# 配置区域
# ============================================================
$ssid_2G = "你的2.4Gwifi名称"           # 2.4G SSID  
$ssid_5G = "你的5G wifi名称"        # 5G SSID  

$checkInterval = 2.5                # 检查间隔（秒）5
$switchCooldown = 8              # 切换冷却时间（秒）15
$retryCount = 2                   # 连接失败重试次数 
$retryDelay = 2                   # 重试间隔（秒） 
$connectStabilize = 3             # 连接后额外等待（秒），等待网络生效 

#$lastProxyOn 最开始的来源是更朴素的用途：记录上一次检测到的代理状态，用来判断代理有没有变化。改成$lastAppliedProxyOn。这个变量有点奇妙有些地方我弃用了有些地方存在，不影响我使用我懒得修


# ============================================================
# 函数定义
# ============================================================
function Write-Log {
    param(
        [string]$msg,
        [string]$level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $color = @{
        "INFO"  = "White"
        "OK"    = "Green"
        "WARN"  = "Yellow"
        "ERROR" = "Red"
    }[$level]

    if (-not $color) {
        $color = "White"
    }

    Write-Host "[$timestamp] [$level] $msg" -ForegroundColor $color
}

# ============================================================
# 代理检测函数：仅读取注册表 ProxyEnable
# ============================================================
function Test-ProxyStatus {
    <#
    .SYNOPSIS
        仅读取 Windows 系统代理开关注册表
        HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ProxyEnable
        返回 [PSCustomObject]@{ IsProxyOn = $bool; Success = $bool }
    #>
    $result = [PSCustomObject]@{ IsProxyOn = $false; Success = $false }

    try {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        $value = (Get-ItemProperty -Path $regPath -Name ProxyEnable -ErrorAction Stop).ProxyEnable
        $proxyEnable = ($value -eq 1)

        $result.IsProxyOn = $proxyEnable
        $result.Success = $true

        Write-Log "代理状态（注册表 ProxyEnable）：$(if ($proxyEnable) { '开启' } else { '关闭' })" "INFO"
    } catch {
        Write-Log "读取注册表 ProxyEnable 失败：$_" "ERROR"
        $result.Success = $false
    }

    return $result
}


# ============================================================
function Connect-2G {
    param([string]$ssid)
        # 新增：前置判定
    if ((Get-CurrentSSID) -eq $ssid) {
        Write-Log "当前已经是目标2.4G，无需切换" "OK"
        return $true
    }

    Write-Log "快速切换到2.4G：$ssid"

    for ($i = 1; $i -le $retryCount; $i++) {
        Write-Log "尝试连接 $ssid（第 $i 次）" "INFO"
        netsh wlan connect name="$ssid" | Out-Null
       

        # 动态等待，最多5秒，每秒检查一次
        for ($j = 1; $j -le 5; $j++) {
            Start-Sleep -Seconds 1
            if ((Get-CurrentSSID) -eq $ssid) {
                Write-Log "✅ 2.4G 连接成功，用时 ${j}s" "OK"
                return $true
            }
        }

        if ($i -lt $retryCount) {
            Write-Log "连接失败，等待 ${retryDelay}s 后重试..." "WARN"
            Start-Sleep -Seconds $retryDelay
        }
    }

    Write-Log "❌ 2.4G 连接失败，已重试 $retryCount 次" "ERROR"
    return $false
}

# ============================================================
function Connect-5G {
    param([string]$ssid)

    # 新增：前置判定
    if ((Get-CurrentSSID) -eq $ssid) {
        Write-Log "当前已经是目标5G，无需切换" "OK"
        return $true
    }
    Write-Log "切换5G：$ssid"

    for ($i = 1; $i -le $retryCount; $i++) {

        Write-Log "5G连接尝试 $i/$retryCount"

        # 刺激网卡重新扫描
        netsh wlan disconnect | Out-Null

        Start-Sleep -Seconds 3

        netsh wlan connect name="$ssid" | Out-Null
       

        # 动态等待
        for ($j = 1; $j -le 5; $j++) {

            if ((Get-CurrentSSID) -eq $ssid) {

                Write-Log "✅ 5G成功，用时 ${j}s" "OK"
                return $true
            }

            Start-Sleep -Seconds 1
        }


        if($i -lt $retryCount){
            Start-Sleep -Seconds 2
        }
    }

    Write-Log "❌ 5G失败" "ERROR"
    return $false
}

# ============================================================
function Get-CurrentSSID {
    try {
        $interface = netsh wlan show interfaces |
            Select-String -Pattern "^\s*SSID\s*:" |
            Select-Object -First 1

        if ($interface) {
            return (($interface.ToString() -split ":", 2)[1]).Trim()
        }
    } catch {
        Write-Log "获取当前 WiFi 失败：$_" "WARN"
    }

    return $null
}

function Test-WiFiProfile {
    param([string]$ssid)

    try {
        $profiles = netsh wlan show profiles |
            Select-String ":\s+(.+)$" |
            ForEach-Object {
                $_.Matches.Groups[1].Value.Trim()
            }

        return $profiles -contains $ssid
    } catch {
        Write-Log "检查 WiFi 配置文件失败：$_" "WARN"
        return $false
    }
}

function Send-Notification {
    param(
        [string]$title,
        [string]$message
    )

    Write-Log "🔔 通知：$title - $($message -replace "`n", " / ")" "INFO"

    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime

        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]

        $safeTitle = [Security.SecurityElement]::Escape($title)
        $safeMessage = [Security.SecurityElement]::Escape($message)

        $template = @"
<toast>
    <visual>
        <binding template="ToastGeneric">
            <text>$safeTitle</text>
            <text>$safeMessage</text>
        </binding>
    </visual>
</toast>
"@

        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)

        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml

        $appID = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"

        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(
            $appID
        ).Show($toast)
    } catch {
        Write-Log "通知发送失败：$_" "WARN"
    }
}

# 注意：原 Connect-WiFi 函数已被移除，不再使用

# ============================================================
# 启动前检查
# ============================================================
Write-Log "🚀 WiFi 自动切换脚本启动" "INFO"
Write-Log "检测逻辑：读取注册表 ProxyEnable（HKCU\...\Internet Settings）" "INFO"
Write-Log "规则：ProxyEnable=1 → $ssid_2G (2.4G)" "INFO"
Write-Log "规则：ProxyEnable=0 → $ssid_5G (5G)" "INFO"
Write-Log "切换冷却时间：${switchCooldown}s" "INFO"

Send-Notification `
    -title "WiFi自动切换" `
    -message "开始检测`n注册表代理开关"

if (-not (Test-WiFiProfile -ssid $ssid_2G)) {
    Write-Log "⚠️ 警告：未找到 $ssid_2G 的配置文件，切换可能失败" "WARN"
}

if (-not (Test-WiFiProfile -ssid $ssid_5G)) {
    Write-Log "⚠️ 警告：未找到 $ssid_5G 的配置文件，切换可能失败" "WARN"
}

# ============================================================
# 初始化状态变量
# ============================================================
$lastSwitchTime = (Get-Date).AddSeconds(-$switchCooldown)

# 睡眠/唤醒补丁：记录最后正常WiFi
$lastSSID = Get-CurrentSSID

# WiFi丢失标记
$wifiLost = $false
$wifiLostStartTime = $null


# 获取初始代理状态（若检测失败，默认视为关闭）
$initialStatus = Test-ProxyStatus
if ($initialStatus.Success) {
    $lastAppliedProxyOn = $initialStatus.IsProxyOn
    Write-Log "初始代理状态：$(if ($lastAppliedProxyOn) { '开启' } else { '关闭' })" "INFO"
} else {
    $lastAppliedProxyOn = $false
    Write-Log "⚠️ 初始代理状态检测失败，默认视为关闭" "WARN"
    Send-Notification -title "WiFi自动切换" -message "初始检测异常`n请手动检查代理设置"
}

# ============================================================
# 启动同步：根据初始代理状态切换WiFi
# ============================================================
$currentSSID = Get-CurrentSSID

if ($lastAppliedProxyOn) {
    $targetSSID = $ssid_2G
    $targetName = "2.4G"
    $switchReason = "代理开启"
} else {
    $targetSSID = $ssid_5G
    $targetName = "5G"
    $switchReason = "代理关闭"
}

Write-Log "当前 WiFi：$(if ($currentSSID) { $currentSSID } else { '未连接或无法识别' })" "INFO"
Write-Log "启动目标 WiFi：$targetSSID（$targetName，$switchReason）" "INFO"

if ($currentSSID -ne $targetSSID) {
    Write-Log "➡️ 当前 WiFi 与目标不一致，开始执行启动同步" "INFO"

    # 根据代理状态选择连接函数
    if ($lastAppliedProxyOn) {
        $success = Connect-2G -ssid $ssid_2G
    } else {
        $success = Connect-5G -ssid $ssid_5G
    }

    if ($success) {
        $lastSwitchTime = Get-Date
        Send-Notification `
            -title "WiFi自动切换" `
            -message "已切换到$targetName`n原因：$switchReason"
    } else {
        Write-Log "⚠️ 启动同步失败" "WARN"
    }
} else {
    Write-Log "✅ 当前 WiFi 已符合代理状态，无需切换" "OK"
}

# ============================================================
# 主循环
# ProxyEnable状态 → WiFi状态校准 → 必要时切换 WiFi

# 若代理状态检测失败：
# 保持当前WiFi，不执行切换，等待下一轮检测

# 切换仅在当前WiFi与目标WiFi不一致时触发
# 并受冷却机制限制

# ============================================================
$needCorrection = $false   # 新增：唤醒后需要纠错的标志

while ($true) {

    # =====================================================
    # 睡眠/唤醒补丁
    # =====================================================

    $currentSSIDNow = Get-CurrentSSID

    if ($lastSSID -and -not $currentSSIDNow) {

    if (-not $wifiLost) {

        Write-Log "检测到WiFi丢失，开始计时..." "WARN"

        $wifiLost = $true
        $wifiLostStartTime = Get-Date
    }


    $lostSeconds = ((Get-Date) - $wifiLostStartTime).TotalSeconds


    if ($lostSeconds -ge 60) {

        Write-Log "WiFi丢失超过60秒，启动恢复检查" "WARN"

        $needCorrection = $true
    }
}
else {

    # WiFi恢复，清除丢失状态

    if($wifiLost){

        Write-Log "WiFi已恢复，清除丢失状态" "INFO"
    }

    $wifiLost = $false
    $wifiLostStartTime = $null

    if($currentSSIDNow){
        $lastSSID = $currentSSIDNow
    }
}


    # WiFi恢复后记录
    if ($currentSSIDNow) {

        if ($wifiLost) {
            Write-Log "WiFi恢复，等待校准完成后更新记录" "INFO"
        }

        # 只有已经超过60秒丢失才纠错
        if ($wifiLost -and $wifiLostStartTime) {

            $lostSeconds = ((Get-Date) - $wifiLostStartTime).TotalSeconds

            if ($lostSeconds -ge 60) {

                Write-Log "WiFi恢复，且丢失超过60秒，准备校准" "INFO"

                $needCorrection = $true
            }
        }

        $wifiLost = $false
        $wifiLostStartTime = $null

    }

    # ----- 新增：唤醒后的纠错处理（仅在需要时执行） -----
    if ($needCorrection) {
        Write-Log "WiFi已恢复，等待 2 秒让系统自动处理..." "INFO"
        Start-Sleep -Seconds 2

        # 重新读取当前SSID和代理状态
        $currentSSID = Get-CurrentSSID
        if ($currentSSID) {
            $status = Test-ProxyStatus
            if ($status.Success) {
                $proxyOn = $status.IsProxyOn
                $targetSSID = if ($proxyOn) { $ssid_2G } else { $ssid_5G }
                $targetName = if ($proxyOn) { "2.4G" } else { "5G" }

                if ($currentSSID -ne $targetSSID) {
                    Write-Log "⚠️ 恢复后WiFi ($currentSSID) 与目标 ($targetSSID) 不符，尝试纠正" "WARN"
                    # 检查冷却
                    $timeSinceSwitch = (Get-Date) - $lastSwitchTime
                    if ($timeSinceSwitch.TotalSeconds -ge $switchCooldown) {
                        # 执行切换
                        if ($proxyOn) {
                            $success = Connect-2G -ssid $ssid_2G
                        } else {
                            $success = Connect-5G -ssid $ssid_5G
                        }
                        if ($success) {
                            $lastSwitchTime = Get-Date
                            $lastAppliedProxyOn = $proxyOn

                            $lastSSID = Get-CurrentSSID   # <--- 新增：纠错成功后更新 lastSSID

                            $needCorrection = $false   # 纠错成功，清除标志
                            Send-Notification -title "WiFi自动切换" -message "唤醒后已纠正到$targetName"
                            Write-Log "✅ 纠错成功" "OK"
                        } else {
                            Write-Log "❌ 纠错失败，下次循环将重试" "WARN"
                            # 失败时保持 needCorrection = $true，下次循环继续尝试
                            # 冷却不更新，下次循环会再次检查冷却
                        }
                    } else {
                        $remaining = [Math]::Ceiling($switchCooldown - $timeSinceSwitch.TotalSeconds)
                        Write-Log "⏳ 冷却中，剩余 ${remaining}s，等待冷却后再纠错" "WARN"
                        # 冷却未到，不清除标志，下次循环再试
                    }
                } else {
                    Write-Log "恢复后WiFi已符合代理状态，无需纠错" "OK"

                    $lastSSID = $currentSSID   # <--- 新增：已匹配则立即更新 lastSSID

                    $needCorrection = $false   # 已匹配，清除标志
                }
            } else {
                Write-Log "⚠️ 无法读取代理状态，暂不纠错，下次循环重试" "WARN"
                # 不清除标志，下次循环重试
            }
        } else {
            Write-Log "⚠️ 恢复后WiFi仍未连接，等待下次循环" "WARN"
            # 不清除标志，下次循环继续等待
        }
    }


    # =====================================================

    $status = Test-ProxyStatus

    # ----- 检测失败处理 -----
    if (-not $status.Success) {
        Write-Log "⚠️ 代理状态检测失败，保持当前 WiFi 不变" "WARN"
        Send-Notification -title "WiFi自动切换" -message "检测异常，请手动检查`n注册表读取失败"
        Start-Sleep -Seconds $checkInterval
        continue
    }

    $currentProxyOn = $status.IsProxyOn

    # ====================================
    # 原：基于 $lastAppliedProxyOn 的变化判断
    # 新：基于当前代理状态与当前SSID比较，触发修正
    $currentSSID = Get-CurrentSSID
    $targetSSID = if ($currentProxyOn) { $ssid_2G } else { $ssid_5G }
    $targetName = if ($currentProxyOn) { "2.4G" } else { "5G" }
    $switchReason = if ($currentProxyOn) { "代理开启" } else { "代理关闭" }

    if ($currentSSID -ne $targetSSID) {
        Write-Log "WiFi状态不符合代理状态，需要修正。当前：$currentSSID，目标：$targetSSID" "WARN"

        $timeSinceSwitch = (Get-Date) - $lastSwitchTime

        if ($timeSinceSwitch.TotalSeconds -ge $switchCooldown) {
            Write-Log "➡️ 开始切换至 $targetSSID（$targetName，$switchReason）" "INFO"

            if ($currentProxyOn) {
                $success = Connect-2G -ssid $ssid_2G
            } else {
                $success = Connect-5G -ssid $ssid_5G
            }

            if ($success) {
                $lastSwitchTime = Get-Date
                # 按新逻辑不再依赖 $lastAppliedProxyOn，故不更新它（保留变量但不使用）
                # $lastAppliedProxyOn = $currentProxyOn
                Send-Notification -title "WiFi自动切换" -message "已切换到$targetName`n原因：$switchReason"
            } else {
                Write-Log "⚠️ WiFi 切换失败，下次循环将重试" "WARN"
            }
        } else {
            $remaining = [Math]::Ceiling($switchCooldown - $timeSinceSwitch.TotalSeconds)
            Write-Log "⏳ 切换冷却中，约剩余 ${remaining}s，等待冷却" "WARN"
        }
    } else {
        Write-Log "当前WiFi已符合代理状态" "INFO"
    }


    Start-Sleep -Seconds $checkInterval
}
