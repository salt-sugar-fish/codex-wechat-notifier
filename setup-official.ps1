$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$setupUrl = 'https://mp.weixin.qq.com/debug/cgi-bin/sandbox?t=sandbox/login'
$template = @'
{{first.DATA}}
项目：{{project.DATA}}
时间：{{time.DATA}}
结果：{{content.DATA}}
{{remark.DATA}}
'@

Set-Clipboard -Value $template
Start-Process $setupUrl

Clear-Host
Write-Host '微信官方测试号配置向导' -ForegroundColor Cyan
Write-Host ''
Write-Host '浏览器已打开，模板内容也已复制到剪贴板。' -ForegroundColor Green
Write-Host '你只需要在官方页面完成：'
Write-Host '1. 微信扫码登录。'
Write-Host '2. 扫“测试号二维码”关注自己的测试号。'
Write-Host '3. 在“模板消息接口”新增测试模板，标题填：Codex 完成通知'
Write-Host '4. 模板内容直接按 Ctrl+V 粘贴（已经复制好）。'
Write-Host ''
Write-Host '页面上准备好 appID、appsecret、你的 OpenID、模板ID 后再继续。'
Read-Host '准备好后按回车' | Out-Null

& (Join-Path $root 'manage.ps1') -Action configure
Write-Host ''
Write-Host '正在通过微信官方接口发送测试通知……' -ForegroundColor Cyan
& (Join-Path $root 'manage.ps1') -Action test
Write-Host ''
Write-Host '配置结束。通知开关仍保持原状态；需要时双击 ON.cmd，回来后双击 OFF.cmd。'
Read-Host '按回车退出' | Out-Null
