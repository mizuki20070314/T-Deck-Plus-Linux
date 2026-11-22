# Flash a kernel image into the "linux" partition, wait for the board to come
# back on SSH, and save + summarise its dmesg. If it never comes back, record
# what the USB console printed instead.
#
#   powershell -File kernel_test.ps1 -Image C:\...\xipImage-amoled [-Port COM23] [-Board 192.168.0.8]
#
# Undo with restore_kernel.ps1.
param(
    [Parameter(Mandatory = $true)][string]$Image,
    [string]$Port = 'COM23',
    [string]$Board = '192.168.0.8',
    [int]$WaitSec = 150
)

$logdir = 'C:\Users\mizuk\esp32s3-linux\logs'
New-Item -ItemType Directory -Force -Path $logdir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$size = (Get-Item $Image).Length
if ($size -gt 0x400000) { throw "kernel is $size bytes: more than the 4 MiB linux partition" }
"image: $Image ($size bytes) sha256=" + (Get-FileHash -Algorithm SHA256 $Image).Hash.ToLower().Substring(0, 16)

py -m esptool --chip esp32s3 -p $Port -b 460800 --before default-reset --after hard-reset `
    write-flash 0x140000 $Image 2>&1 | ForEach-Object { "$_" } |
    Where-Object { $_ -match 'Wrote|Hash of data|error|Error|fatal' }
if ($LASTEXITCODE -ne 0) { throw "esptool failed ($LASTEXITCODE)" }

$t0 = Get-Date
$up = $false
while (((Get-Date) - $t0).TotalSeconds -lt $WaitSec) {
    $o = ssh -o BatchMode=yes -o ConnectTimeout=4 "root@$Board" 'echo BOARD-UP' 2>&1 | Out-String
    if ($o -match 'BOARD-UP') { $up = $true; break }
    Start-Sleep -Seconds 4
}

if ($up) {
    "board is up after {0:N0}s" -f ((Get-Date) - $t0).TotalSeconds
    $dm = ssh -o BatchMode=yes "root@$Board" 'uname -a; echo ----; dmesg' 2>&1 | Out-String
    $f = Join-Path $logdir "kernel-test-$stamp.dmesg.txt"
    Set-Content -Path $f -Value $dm -Encoding utf8
    "full dmesg saved to $f"
    "--- interesting lines ---"
    ($dm -split "`n") | Where-Object { $_ -match 'amoled|esp32_spi|spi[0-9]|fb[0-9]|fbcon|framebuffer|pinctrl|gpio|Linux version|Oops|BUG|WARN|panic|Unable|failed|error|Console:|tty' } | Select-Object -First 60
} else {
    "board did NOT come back on SSH within $WaitSec s; USB console output follows"
    $f = Join-Path $logdir "kernel-test-$stamp.usb.txt"
    py C:\Users\mizuk\esp32s3-linux\tools\capture.py $Port 15 $f
    "log: $f"
}
