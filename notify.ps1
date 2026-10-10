param(
    [switch]$ForceTest
)

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$configDir = Join-Path $root 'config'
$stateDir = Join-Path $root 'state'
$sentDir = Join-Path $stateDir 'sent'
$logDir = Join-Path $root 'logs'
$enabledFile = Join-Path $stateDir 'enabled.flag'
$accountFile = Join-Path $configDir 'wechat-test-account.dpapi'
$lastResultFile = Join-Path $stateDir 'last-result.json'

foreach ($dir in @($configDir, $stateDir, $sentDir, $logDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Write-NotifierLog {
    param([string]$Message)
    try {
        $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath (Join-Path $logDir 'notifier.log') -Value $line -Encoding UTF8
    }
    catch {
        # 通知日志不能反过来影响 Codex 正常结束。
    }
}

function Complete-Hook {
    param([bool]$Success, [string]$Message)
    $result = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        success = $Success
        message = $Message
    } | ConvertTo-Json -Compress
    try {
        [IO.File]::WriteAllText($lastResultFile, $result, [Text.UTF8Encoding]::new($true))
    }
    catch {
        # 即使状态文件暂时不可写，也必须向 Stop Hook 返回合法 JSON。
    }
    [Console]::Out.Write('{}')
}

function Get-TestAccountConfig {
    if (-not (Test-Path -LiteralPath $accountFile)) {
        throw '尚未配置微信公众平台接口测试号。请运行 MANAGE.cmd。'
    }
    $encrypted = (Get-Content -Raw -LiteralPath $accountFile).Trim()
    if ([string]::IsNullOrWhiteSpace($encrypted)) {
        throw '微信测试号配置为空。'
    }
    if ($encrypted -notmatch '^[0-9a-fA-F]+$' -or ($encrypted.Length % 2) -ne 0) {
        throw '微信测试号加密配置格式无效。'
    }
    $cipher = New-Object byte[] ($encrypted.Length / 2)
    for ($index = 0; $index -lt $cipher.Length; $index++) {
        $cipher[$index] = [Convert]::ToByte($encrypted.Substring($index * 2, 2), 16)
    }
    Add-Type -AssemblyName System.Security
    $clearBytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $cipher, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try {
        $plain = [Text.Encoding]::Unicode.GetString($clearBytes)
        $config = $plain | ConvertFrom-Json
    }
    finally {
        $plain = $null
        [Array]::Clear($clearBytes, 0, $clearBytes.Length)
        [Array]::Clear($cipher, 0, $cipher.Length)
    }
    foreach ($name in @('appId', 'appSecret', 'openId', 'templateId')) {
        if ([string]::IsNullOrWhiteSpace([string]$config.$name)) {
            throw ('微信测试号配置缺少：' + $name)
        }
    }
    return $config
}

function Test-BackgroundSuggestion {
    param([string]$Message)
    $text = $Message.Trim()
    if (-not ($text.StartsWith('{') -and $text.EndsWith('}'))) { return $false }
    try {
        $candidate = $text | ConvertFrom-Json -ErrorAction Stop
        $properties = @($candidate.PSObject.Properties)
        # 只过滤建议生成的专用 JSON；正文提及 suggestion 或包含其他字段仍正常通知。
        return ($properties.Count -eq 1 -and $properties[0].Name -ceq 'suggestion' -and
            ($null -eq $properties[0].Value -or $properties[0].Value -is [string]))
    }
    catch { return $false }
}

try {
    if ((-not $ForceTest) -and (-not (Test-Path -LiteralPath $enabledFile))) {
        Complete-Hook -Success $true -Message '通知开关已关闭。'
        exit 0
    }

    if ($ForceTest) {
        $event = [pscustomobject]@{
            session_id = 'manual-test'
            turn_id = 'manual-test-{0}' -f ([DateTimeOffset]::Now.ToUnixTimeMilliseconds())
            cwd = $root
            hook_event_name = 'Stop'
            last_assistant_message = '这是一条测试通知。收到它说明微信通知配置正常。'
        }
    }
    else {
        $inputJson = [Console]::In.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($inputJson)) {
            throw 'Hook 没有收到事件数据。'
        }
        $event = $inputJson | ConvertFrom-Json
        if ($event.hook_event_name -ne 'Stop') {
            Complete-Hook -Success $true -Message '忽略非 Stop 事件。'
            exit 0
        }
    }

    $sessionId = if ($event.session_id) { [string]$event.session_id } else { 'unknown-session' }
    $turnId = if ($event.turn_id) { [string]$event.turn_id } else { '' }
    $message = if ($event.last_assistant_message) { [string]$event.last_assistant_message } else { '本轮任务已结束。' }
    if ((-not $ForceTest) -and (Test-BackgroundSuggestion -Message $message)) {
        Write-NotifierLog '已忽略后台输入建议。'
        Complete-Hook -Success $true -Message '已忽略后台输入建议。'
        exit 0
    }
    if ($message.Length -gt 1800) {
        $message = $message.Substring(0, 1800) + "`n`n（摘要已截断，请远程查看完整回复）"
    }

    if (-not $ForceTest) {
        $dedupeSource = if ($turnId) { $turnId } else { $sessionId + '|' + $message }
        $bytes = [Text.Encoding]::UTF8.GetBytes($dedupeSource)
        $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
        $sentMarker = Join-Path $sentDir ($hash + '.flag')
        if (Test-Path -LiteralPath $sentMarker) {
            Complete-Hook -Success $true -Message '本轮已经通知过，已去重。'
            exit 0
        }
    }

    $account = Get-TestAccountConfig
    $cwd = if ($event.cwd) { [string]$event.cwd } else { '' }
    $projectName = if ($cwd) { Split-Path -Leaf $cwd } else { 'Codex' }
    if ([string]::IsNullOrWhiteSpace($projectName)) { $projectName = 'Codex' }
    $title = if ($ForceTest) { 'Codex 通知测试' } else { 'Codex 工作已完成' }
    $sentAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $projectValue = $projectName
    if ($projectValue.Length -gt 20) { $projectValue = $projectValue.Substring(0, 20) }
    $summary = ($message -replace '\s+', ' ').Trim()
    if ($summary.Length -gt 20) { $summary = $summary.Substring(0, 20) }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $tokenUri = 'https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential&appid={0}&secret={1}' -f `
        [Uri]::EscapeDataString([string]$account.appId), [Uri]::EscapeDataString([string]$account.appSecret)
    $tokenResponse = Invoke-RestMethod -Method Get -Uri $tokenUri -TimeoutSec 15
    if ([string]::IsNullOrWhiteSpace([string]$tokenResponse.access_token)) {
        throw ('微信 access_token 获取失败：{0} {1}' -f $tokenResponse.errcode, $tokenResponse.errmsg)
    }

    $payload = @{
        touser = [string]$account.openId
        template_id = [string]$account.templateId
        data = @{
            first = @{ value = $title }
            project = @{ value = $projectValue }
            time = @{ value = $sentAt }
            content = @{ value = $summary }
            remark = @{ value = '可远程打开 Codex 查看详情。' }
        }
    } | ConvertTo-Json -Depth 6
    $sendUri = 'https://api.weixin.qq.com/cgi-bin/message/template/send?access_token=' + `
        [Uri]::EscapeDataString([string]$tokenResponse.access_token)
    $response = Invoke-RestMethod -Method Post -Uri $sendUri -Body ([Text.Encoding]::UTF8.GetBytes($payload)) `
        -ContentType 'application/json; charset=utf-8' -TimeoutSec 15
    if ($null -eq $response.errcode -or [int]$response.errcode -ne 0) {
        throw ('微信模板消息发送失败：{0} {1}' -f $response.errcode, $response.errmsg)
    }
    $providerName = '微信官方测试号'

    if (-not $ForceTest) {
        New-Item -ItemType File -Path $sentMarker -Force | Out-Null
    }
    Write-NotifierLog ($providerName + ' 微信通知发送成功。')
    Complete-Hook -Success $true -Message ($providerName + ' 微信通知发送成功。')
}
catch {
    Write-NotifierLog ('微信通知发送失败：' + $_.Exception.Message)
    Complete-Hook -Success $false -Message $_.Exception.Message
    exit 0
}
