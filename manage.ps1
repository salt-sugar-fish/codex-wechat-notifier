param(
    [ValidateSet('menu', 'enable', 'disable', 'toggle', 'status', 'configure', 'setopenid', 'test')]
    [string]$Action = 'menu'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$configDir = Join-Path $root 'config'
$stateDir = Join-Path $root 'state'
$logDir = Join-Path $root 'logs'
$enabledFile = Join-Path $stateDir 'enabled.flag'
$accountFile = Join-Path $configDir 'wechat-test-account.dpapi'
$lastResultFile = Join-Path $stateDir 'last-result.json'

foreach ($dir in @($configDir, $stateDir, $logDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Show-Status {
    $enabled = Test-Path -LiteralPath $enabledFile
    $configured = Test-Path -LiteralPath $accountFile
    Write-Host ''
    Write-Host ('微信通知：{0}' -f $(if ($enabled) { '已开启' } else { '已关闭' })) -ForegroundColor $(if ($enabled) { 'Green' } else { 'Yellow' })
    Write-Host ('微信官方测试号：{0}' -f $(if ($configured) { '已加密配置' } else { '尚未配置' }))
    if (Test-Path -LiteralPath $lastResultFile) {
        try {
            $last = Get-Content -Raw -Encoding UTF8 -LiteralPath $lastResultFile | ConvertFrom-Json
            Write-Host ('最近结果：{0} - {1}' -f $last.timestamp, $last.message)
        }
        catch { }
    }
    Write-Host ''
}

function Enable-Notifications {
    New-Item -ItemType File -Path $enabledFile -Force | Out-Null
    Write-Host '微信通知已开启。' -ForegroundColor Green
}

function Disable-Notifications {
    if (Test-Path -LiteralPath $enabledFile) {
        Remove-Item -LiteralPath $enabledFile -Force
    }
    Write-Host '微信通知已关闭。' -ForegroundColor Yellow
}

function Configure-Token {
    Write-Host '请从微信公众平台“接口测试号”页面复制以下四项。' -ForegroundColor Cyan
    Write-Host '密钥输入时不会显示；请勿把这些值发到聊天里。'
    $appId = (Read-Host 'appID').Trim()
    $appSecretSecure = Read-Host 'appsecret（输入不显示）' -AsSecureString
    $secretCredential = New-Object System.Management.Automation.PSCredential('wechat-test-account', $appSecretSecure)
    $appSecret = $secretCredential.GetNetworkCredential().Password
    $openId = (Read-Host '关注测试号后显示的微信号（OpenID）').Trim()
    $templateId = (Read-Host '新增测试模板后显示的模板ID').Trim()
    foreach ($item in @($appId, $appSecret, $openId, $templateId)) {
        if ([string]::IsNullOrWhiteSpace($item)) { throw '四项配置都不能为空。' }
    }
    $json = @{ appId = $appId; appSecret = $appSecret; openId = $openId; templateId = $templateId } | ConvertTo-Json -Compress
    $secureJson = ConvertTo-SecureString -String $json -AsPlainText -Force
    $encrypted = $secureJson | ConvertFrom-SecureString
    [IO.File]::WriteAllText($accountFile, $encrypted, [Text.Encoding]::ASCII)
    $appSecret = $null
    $json = $null
    Write-Host ('微信测试号配置已用 Windows DPAPI 加密保存在：' + $accountFile) -ForegroundColor Green
    Write-Host '只有当前 Windows 用户可解密。'
}

function Set-OpenId {
    if (-not (Test-Path -LiteralPath $accountFile)) {
        throw '尚未保存测试号配置，请先执行完整配置。'
    }
    $encrypted = (Get-Content -Raw -LiteralPath $accountFile).Trim()
    $secure = $encrypted | ConvertTo-SecureString
    $credential = New-Object System.Management.Automation.PSCredential('wechat-test-account', $secure)
    $plain = $credential.GetNetworkCredential().Password
    $config = $plain | ConvertFrom-Json
    $plain = $null

    Write-Host '请在官方测试号网页的“测试号二维码 → 用户列表”复制 OpenID。' -ForegroundColor Cyan
    Write-Host '不要填写测试号名称中的 wxid_...。'
    $openId = (Read-Host '正确的 OpenID').Trim()
    if ([string]::IsNullOrWhiteSpace($openId)) { throw 'OpenID 不能为空。' }
    if ($openId -match '^wxid_') { throw '这仍是 wxid，不是用户列表里的 OpenID。' }
    $config.openId = $openId
    $json = $config | ConvertTo-Json -Compress
    $secureJson = ConvertTo-SecureString -String $json -AsPlainText -Force
    [IO.File]::WriteAllText($accountFile, ($secureJson | ConvertFrom-SecureString), [Text.Encoding]::ASCII)
    $json = $null
    Write-Host 'OpenID 已更新，其他三项保持不变。' -ForegroundColor Green
}

function Send-Test {
    if (-not (Test-Path -LiteralPath $accountFile)) {
        throw '请先配置微信公众平台接口测试号。'
    }
    & (Join-Path $root 'notify.ps1') -ForceTest | Out-Null
    if (Test-Path -LiteralPath $lastResultFile) {
        $last = Get-Content -Raw -Encoding UTF8 -LiteralPath $lastResultFile | ConvertFrom-Json
        if ($last.success) {
            Write-Host '测试通知已发送，请查看微信。' -ForegroundColor Green
        }
        else {
            Write-Host ('测试失败：' + $last.message) -ForegroundColor Red
        }
    }
}

if ($Action -eq 'menu') {
    while ($true) {
        Clear-Host
        Write-Host 'Codex 微信通知管理' -ForegroundColor Cyan
        Show-Status
        Write-Host '1. 开启通知'
        Write-Host '2. 关闭通知'
        Write-Host '3. 切换开关'
        Write-Host '4. 配置/更换微信官方测试号'
        Write-Host '5. 发送测试通知'
        Write-Host '6. 查看状态'
        Write-Host '7. 只修正 OpenID'
        Write-Host '0. 退出'
        $choice = Read-Host '请选择'
        try {
            switch ($choice) {
                '1' { Enable-Notifications }
                '2' { Disable-Notifications }
                '3' { if (Test-Path -LiteralPath $enabledFile) { Disable-Notifications } else { Enable-Notifications } }
                '4' { Configure-Token }
                '5' { Send-Test }
                '6' { Show-Status }
                '7' { Set-OpenId }
                '0' { return }
                default { Write-Host '无效选项。' -ForegroundColor Red }
            }
        }
        catch {
            Write-Host ('操作失败：' + $_.Exception.Message) -ForegroundColor Red
        }
        Read-Host '按回车继续' | Out-Null
    }
}

switch ($Action) {
    'enable' { Enable-Notifications }
    'disable' { Disable-Notifications }
    'toggle' { if (Test-Path -LiteralPath $enabledFile) { Disable-Notifications } else { Enable-Notifications } }
    'status' { Show-Status }
    'configure' { Configure-Token }
    'setopenid' { Set-OpenId }
    'test' { Send-Test }
}
