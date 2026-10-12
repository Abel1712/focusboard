# FocusBoard - receive screen time from the "FocusBoard Sync" phone app.
#
# Runs only when you start it (Sync phone shortcut / Ctrl+Alt+P):
#   1. makes a one-time 256-bit key and shows it as a QR code (sync.html)
#   2. listens on your local network for at most 2 minutes
#   3. accepts one upload that is encrypted + signed with that key (AES-256-CBC + HMAC-SHA256)
#   4. hands the data to FocusBoard, then stops listening and forgets the key
param([switch]$NoWindow, [switch]$Loopback)   # testing only: no QR window / listen on 127.0.0.1 only

$ErrorActionPreference = 'Stop'
$dir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$fbDir    = Split-Path -Parent $dir
$port     = 47820
$seconds  = 120
$utf8     = New-Object System.Text.UTF8Encoding $false

function Write-Js($name, $text) { [IO.File]::WriteAllText((Join-Path $dir $name), $text, $utf8) }
function Js-Str($s) { '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"' }

# ---------- one-time key + local addresses ----------
$master = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($master); $rng.Dispose()
$keyB64 = [Convert]::ToBase64String($master).TrimEnd('=').Replace('+', '-').Replace('/', '_')
$session = [guid]::NewGuid().ToString('N').Substring(0, 12)

$ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)' -and $_.AddressState -eq 'Preferred' } |
    Sort-Object { if ($_.InterfaceAlias -match 'Wi-?Fi|Wireless|WLAN') { 0 } elseif ($_.InterfaceAlias -match 'vEthernet|VirtualBox|VMware|Hyper-V') { 2 } else { 1 } } |
    Select-Object -First 4 -ExpandProperty IPAddress)

function HmacSha256([byte[]]$key, [byte[]]$data) {
    $h = New-Object Security.Cryptography.HMACSHA256 -ArgumentList (, $key)
    try { return $h.ComputeHash($data) } finally { $h.Dispose() }
}
$encKey = HmacSha256 $master ([Text.Encoding]::ASCII.GetBytes('enc'))
$macKey = HmacSha256 $master ([Text.Encoding]::ASCII.GetBytes('mac'))

$expires = [DateTimeOffset]::UtcNow.AddSeconds($seconds).ToUnixTimeMilliseconds()
Write-Js 'status.js' "window.SYNC={session:$(Js-Str $session),state:'waiting'};"
if ($ips.Count -eq 0) {
    Write-Js 'pair.js' "window.PAIR={session:$(Js-Str $session),error:'No Wi-Fi connection found. Connect this laptop to your Wi-Fi or your phone''s hotspot, then try again.'};"
} else {
    $qr = "FBSYNC1;$port;$keyB64;" + ($ips -join ',')
    Write-Js 'pair.js' "window.PAIR={session:$(Js-Str $session),qr:$(Js-Str $qr),expires:$expires,ips:$(Js-Str ($ips -join ', '))};"
}

# ---------- open the QR window (same Chrome profile as FocusBoard, so it can save the data) ----------
if (-not $NoWindow) {
    $browser = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                 "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                 "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
                 "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    $url = ([Uri](Join-Path $dir 'sync.html')).AbsoluteUri
    $profileDir = Join-Path $fbDir 'chrome-profile'
    Start-Process $browser -ArgumentList "--app=`"$url`" --user-data-dir=`"$profileDir`" --no-first-run --no-default-browser-check --disable-background-mode --window-size=480,760"
}
if ($ips.Count -eq 0) { exit }

# ---------- tiny HTTP receiver ----------
function Find-HeaderEnd([byte[]]$a) {
    $max = [Math]::Min($a.Length - 4, 16384)
    for ($i = 0; $i -le $max; $i++) { if ($a[$i] -eq 13 -and $a[$i + 1] -eq 10 -and $a[$i + 2] -eq 13 -and $a[$i + 3] -eq 10) { return $i } }
    return -1
}
function Read-Request($stream) {
    $buf = New-Object byte[] 65536; $ms = New-Object IO.MemoryStream; $end = -1
    while ($end -lt 0) {
        $n = $stream.Read($buf, 0, $buf.Length); if ($n -le 0) { return $null }
        $ms.Write($buf, 0, $n); $all = $ms.ToArray(); $end = Find-HeaderEnd $all
        if ($end -lt 0 -and $ms.Length -gt 16384) { return $null }
    }
    $all = $ms.ToArray(); $lines = [Text.Encoding]::ASCII.GetString($all, 0, $end) -split "`r`n"
    $first = $lines[0] -split ' '; $len = 0
    foreach ($l in $lines) { if ($l -match '^Content-Length:\s*(\d+)') { $len = [int]$matches[1] } }
    if ($len -le 0 -or $len -gt 8MB) { return @{ method = $first[0]; path = $first[1]; body = $null } }
    $body = New-Object byte[] $len; $have = [Math]::Min($all.Length - ($end + 4), $len)
    [Array]::Copy($all, $end + 4, $body, 0, $have); $off = $have
    while ($off -lt $len) { $n = $stream.Read($body, $off, $len - $off); if ($n -le 0) { break }; $off += $n }
    return @{ method = $first[0]; path = $first[1]; body = $body }
}
function Send-Response($stream, [int]$code, [string]$text) {
    $b = [Text.Encoding]::UTF8.GetBytes($text)
    $reason = @{ 200 = 'OK'; 403 = 'Forbidden'; 404 = 'Not Found'; 400 = 'Bad Request' }[$code]
    $h = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $code $reason`r`nContent-Type: application/json`r`nContent-Length: $($b.Length)`r`nConnection: close`r`n`r`n")
    $stream.Write($h, 0, $h.Length); $stream.Write($b, 0, $b.Length); $stream.Flush()
}
function Open-Payload([byte[]]$body) {
    try {
        $j = [Text.Encoding]::UTF8.GetString($body) | ConvertFrom-Json
        $iv = [Convert]::FromBase64String($j.iv); $ct = [Convert]::FromBase64String($j.ct); $mac = [Convert]::FromBase64String($j.mac)
        if ($iv.Length -ne 16 -or $mac.Length -ne 32) { return $null }
        $expect = HmacSha256 $macKey ([byte[]]($iv + $ct))
        $diff = 0; for ($i = 0; $i -lt 32; $i++) { $diff = $diff -bor ($expect[$i] -bxor $mac[$i]) }   # constant-time compare
        if ($diff -ne 0) { return $null }
        $aes = [Security.Cryptography.Aes]::Create()
        $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.Key = $encKey; $aes.IV = $iv
        try { $plain = $aes.CreateDecryptor().TransformFinalBlock($ct, 0, $ct.Length) } finally { $aes.Dispose() }
        $text = [Text.Encoding]::UTF8.GetString($plain)
        $null = $text | ConvertFrom-Json          # must be valid JSON
        return $text
    } catch { return $null }
}

$listener = New-Object System.Net.Sockets.TcpListener ($(if ($Loopback) { [Net.IPAddress]::Loopback } else { [Net.IPAddress]::Any }), $port)
try { $listener.Start() } catch {
    Write-Js 'status.js' "window.SYNC={session:$(Js-Str $session),state:'error',message:'Port $port is busy. Close other Sync windows and try again.'};"
    exit
}
$deadline = (Get-Date).AddSeconds($seconds); $done = $false; $attempts = 0
try {
    while (-not $done -and (Get-Date) -lt $deadline -and $attempts -lt 10) {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 200; continue }
        $client = $listener.AcceptTcpClient(); $attempts++
        try {
            $client.ReceiveTimeout = 15000; $client.SendTimeout = 15000
            $stream = $client.GetStream()
            $req = Read-Request $stream
            if ($null -eq $req -or $req.method -ne 'POST' -or $req.path -ne '/sync') { Send-Response $stream 404 '{"ok":false}'; continue }
            if ($null -eq $req.body) { Send-Response $stream 400 '{"ok":false}'; continue }
            $text = Open-Payload $req.body
            if ($null -eq $text) { Send-Response $stream 403 '{"ok":false}'; continue }
            $safe = $text.Replace([string][char]0x2028, ' ').Replace([string][char]0x2029, ' ')
            Write-Js 'status.js' "window.SYNC={session:$(Js-Str $session),state:'done',at:$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()),data:$safe};"
            Send-Response $stream 200 '{"ok":true}'
            $done = $true
        } catch { } finally { $client.Close() }
    }
} finally {
    $listener.Stop()
    if (-not $done) { Write-Js 'status.js' "window.SYNC={session:$(Js-Str $session),state:'timeout'};" }
    # forget the key
    Write-Js 'pair.js' "window.PAIR={session:$(Js-Str $session),ended:true};"
}
