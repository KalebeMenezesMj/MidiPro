param([switch]$DebugBrowser)

$ErrorActionPreference = 'Stop'
$tools = 'D:\midipro-tools'
$flutter = Join-Path $tools 'flutter\bin\flutter.bat'
$node = 'C:\Program Files\nodejs\node.exe'
$serverScript = Join-Path $tools 'serve-web.js'
$webRoot = Join-Path $tools 'midipro-web-app'
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$chromeProfile = Join-Path $tools 'chrome-profile'
$url = 'http://127.0.0.1:5180'

$env:FLUTTER_ROOT = Join-Path $tools 'flutter'
$env:PUB_CACHE = Join-Path $tools 'pub-cache'
Set-Location $PSScriptRoot

& $flutter pub get
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $flutter build web --release --output $webRoot
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if (-not (Test-Path $node)) { throw 'Node.js não encontrado para servir o build Web.' }
if (-not (Test-Path $chrome)) { throw 'Google Chrome não encontrado.' }

$listener = Get-NetTCPConnection -LocalPort 5180 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($listener) {
  $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $($listener.OwningProcess)"
  throw "A porta 5180 já está ocupada por $($owner.Name) (PID $($owner.ProcessId)). Feche o servidor anterior e tente novamente."
}

$server = Start-Process -FilePath $node `
  -ArgumentList @($serverScript, $webRoot) `
  -WorkingDirectory $tools -PassThru -WindowStyle Normal
$ready = $false
for ($attempt = 0; $attempt -lt 60; $attempt++) {
  try {
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2
    if ($response.StatusCode -eq 200 -and $response.Content.Contains('<title>MIDI Pro</title>')) {
      $ready = $true
      break
    }
  } catch {
    Start-Sleep -Milliseconds 500
  }
}
if (-not $ready) { throw "Servidor Web não iniciou (PID $($server.Id))." }

New-Item -ItemType Directory -Path $chromeProfile -Force | Out-Null
$chromeArguments = @("--user-data-dir=$chromeProfile")
if ($DebugBrowser) { $chromeArguments += '--remote-debugging-port=9228' }
$chromeArguments += $url
Start-Process -FilePath $chrome -ArgumentList $chromeArguments
Write-Host "MIDI Pro aberto em $url. A biblioteca do navegador ficará salva no perfil em $chromeProfile."
