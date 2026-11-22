# Take a picture of what the board's console shows: dump /dev/fb0, convert to PNG.
#
#   powershell -File C:\Users\mizuk\esp32s3-linux\tools\fb_snapshot.ps1 [-Out path.png] [-Scale 2] [-Round]
#
# This is the framebuffer in RAM (what fbcon drew), not a photo of the panel.
# -Round places it on the 466x466 panel at the DT offsets and greys out what the round
# glass hides (-At 'x,y' is the panel position of the first pixel, default 68,72).
param(
    [string]$Board = '192.168.0.8',
    [string]$Out = 'C:\Users\mizuk\esp32s3-linux\htop\snapshot.png',
    [int]$Scale = 2,
    [switch]$Round,
    [string]$At = '68,72'
)

$raw = "$env:TEMP\fb_snapshot.raw"
Remove-Item $raw -ErrorAction SilentlyContinue
$cmd = 'cat /sys/class/graphics/fb0/virtual_size; cat /dev/fb0 > /tmp/fb.raw'
$p = Start-Process -FilePath ssh -ArgumentList '-o', 'BatchMode=yes', "root@$Board", $cmd `
    -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\fb_out.txt" -RedirectStandardError "$env:TEMP\fb_err.txt"
if (-not $p.WaitForExit(60000)) { $p.Kill(); throw 'ssh timed out' }
$size = ((Get-Content "$env:TEMP\fb_out.txt" -Raw).Trim() -replace ',', 'x')
scp -O -o BatchMode=yes "root@${Board}:/tmp/fb.raw" $raw 2>&1 | Out-Null
ssh -o BatchMode=yes "root@$Board" 'rm -f /tmp/fb.raw' 2>&1 | Out-Null
$pyArgs = @('-I', 'C:\Users\mizuk\esp32s3-linux\tools\fb_snapshot.py', $raw, $Out, '--size', $size, '--scale', $Scale)
if ($Round) { $pyArgs += @('--at', $At) }
py @pyArgs
