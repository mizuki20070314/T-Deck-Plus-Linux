# Put the browser-controlled screen (screend) on the board, or take it off again.
#
#   powershell -File C:\Users\mizuk\esp32s3-linux\tools\screen_install.ps1                 install, or update the files
#   powershell -File ...\screen_install.ps1 -NewPassword                                    ... with a new admin password
#   powershell -File ...\screen_install.ps1 -Status
#   powershell -File ...\screen_install.ps1 -Uninstall                                      htop-launch takes tty1 back
#
# Afterwards the page is http://<board>:8080/ (user "admin", the password is in
# secrets\screen-admin-password.txt). What changes on the board, and why: SCREEN.md and
# tools\screend\install_board.sh. screend itself is built by build-scripts\wsl-screend-build.sh.
param(
    [string]$Board = '192.168.0.8',
    [int]$Port = 8080,
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$NewPassword
)

$src = 'C:\Users\mizuk\esp32s3-linux\tools\screend'
$binary = 'C:\Users\mizuk\esp32s3-linux\screend\out\screend'
$fastfetch = 'C:\Users\mizuk\esp32s3-linux\fastfetch\out\fastfetch'
$pwFile = 'C:\Users\mizuk\esp32s3-linux\secrets\screen-admin-password.txt'
$o = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10')

# the text files that go to the board must have LF line endings
foreach ($f in 'install_board.sh', 'index.html') {
    $t = [IO.File]::ReadAllText("$src\$f") -replace "`r`n", "`n"
    [IO.File]::WriteAllText("$src\$f", $t, (New-Object Text.UTF8Encoding($false)))
}

function Send-ToBoard([string]$AuthFile) {
    ssh @o "root@$Board" 'rm -rf /tmp/screend-install; mkdir -p /tmp/screend-install' 2>&1 | Out-Null
    scp -O @o "$src\install_board.sh" "$src\index.html" "root@${Board}:/tmp/screend-install/" 2>&1 | Out-Null
    if (Test-Path $binary) { scp -O @o $binary "root@${Board}:/tmp/screend-install/screend" 2>&1 | Out-Null }
    if (Test-Path $fastfetch) { scp -O @o $fastfetch "root@${Board}:/tmp/screend-install/fastfetch" 2>&1 | Out-Null }
    if ($AuthFile) { scp -O @o $AuthFile "root@${Board}:/tmp/screend-install/auth" 2>&1 | Out-Null }
}

if ($Status) {
    Send-ToBoard
    ssh @o "root@$Board" 'sh /tmp/screend-install/install_board.sh status; rm -rf /tmp/screend-install' 2>&1
    return
}
if ($Uninstall) {
    Send-ToBoard
    ssh @o "root@$Board" 'sh /tmp/screend-install/install_board.sh uninstall; rm -rf /tmp/screend-install' 2>&1
    return
}

if (-not (Test-Path $binary)) { throw "$binary is missing: run build-scripts\wsl-screend-build.sh and copy the result there" }

# the admin password: made once, kept on the PC (not printed); only a PBKDF2-SHA-256 hash goes to the board
if ($NewPassword -or -not (Test-Path $pwFile)) {
    $chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] 20
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $new = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    New-Item -ItemType Directory -Force (Split-Path $pwFile) | Out-Null
    [IO.File]::WriteAllText($pwFile, "$new`n", (New-Object Text.UTF8Encoding($false)))
    Write-Output "new admin password saved in $pwFile"
}
$pw = (Get-Content $pwFile -Raw).Trim()
$salt = New-Object byte[] 8
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
$kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($pw, $salt, 10000, [Security.Cryptography.HashAlgorithmName]::SHA256)
$hash = $kdf.GetBytes(32)
$hex = { param($b) ($b | ForEach-Object { $_.ToString('x2') }) -join '' }
$authLine = 'admin:pbkdf2-sha256:10000:' + (& $hex $salt) + ':' + (& $hex $hash)
$authFile = Join-Path $env:TEMP 'screend-auth.tmp'
[IO.File]::WriteAllText($authFile, "$authLine`n", (New-Object Text.UTF8Encoding($false)))

try {
    Send-ToBoard $authFile
} finally {
    Remove-Item $authFile -ErrorAction SilentlyContinue
}
ssh @o "root@$Board" 'sh /tmp/screend-install/install_board.sh install; rc=$?; rm -rf /tmp/screend-install; exit $rc' 2>&1
if ($LASTEXITCODE -ne 0) { throw 'the install on the board failed (see above)' }

# from the PC: without the login the page must refuse, with it the page must answer
$url = "http://${Board}:$Port/"
try { Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20 | Out-Null; Write-Output 'WARNING: the page answered without a login' }
catch { Write-Output ("without login: HTTP " + [int]$_.Exception.Response.StatusCode + " (expected 401)") }
$h = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$pw")) }
$r = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 30
Write-Output ("with login:    HTTP " + $r.StatusCode + ", " + $r.RawContentLength + " bytes")
Write-Output ''
Write-Output "page:     $url"
Write-Output "login:    admin / the password in $pwFile"
