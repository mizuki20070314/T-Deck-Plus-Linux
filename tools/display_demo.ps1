# Show three things on the AMOLED, one after another (about 45 seconds in all):
#   A  all pixels on        - tests power, reset and the register path only
#   B  test pattern         - tests the Quad-SPI pixel path (border, corner colors, circles, bars)
#   C  console text grid    - tests fbcon and shows which rows/columns the round glass cuts off
#
#   powershell -File C:\Users\mizuk\esp32s3-linux\tools\display_demo.ps1 [-Phases ABC] [-HoldSec 8]
#
# e.g. -Phases C draws only the console text grid and leaves it on screen.
# B and C are made for the framebuffer and console size the board reports: 466x466 (58x29
# characters) for the whole square, 328x320 (41x20) for the console that fits the round glass.
param([string]$Board = '192.168.0.8', [int]$HoldSec = 8, [string]$Phases = 'ABC')

$imgdir = 'C:\Users\mizuk\esp32s3-linux\kernel-work\testimg'
$dev = '/sys/bus/spi/devices/spi0.0'

function Run([string]$cmd) {
    $p = Start-Process -FilePath ssh -ArgumentList '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', "root@$Board", $cmd `
        -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\dd_out.txt" -RedirectStandardError "$env:TEMP\dd_err.txt"
    if (-not $p.WaitForExit(60000)) { $p.Kill(); Write-Output "TIMEOUT: $cmd" }
    Get-Content "$env:TEMP\dd_out.txt" -Raw
    $e = Get-Content "$env:TEMP\dd_err.txt" -Raw
    if ($e) { Write-Output "stderr: $e" }
}

# framebuffer size and console size, as the board reports them
$w, $h = ((Run 'cat /sys/class/graphics/fb0/virtual_size').Trim() -split ',') | ForEach-Object { [int]$_ }
$rows, $cols = ((Run 'stty -F /dev/tty1 size').Trim() -split ' ') | ForEach-Object { [int]$_ }
Write-Output "framebuffer ${w}x${h}, console ${cols}x${rows}"

$img = "$imgdir\fbtest-$w.rgb565"
if (-not (Test-Path $img)) { py -I C:\Users\mizuk\esp32s3-linux\tools\make_fb_test.py $imgdir $w | Out-Null }

# text grid: row numbers and a column ruler, # in the four corners
$grid = "$env:TEMP\console-grid.txt"
$lines = for ($r = 1; $r -le $rows; $r++) {
    $text = (('{0:00} ' -f $r) + ('0123456789' * 12)).Substring(0, $cols)
    if ($r -eq 1 -or $r -eq $rows) { $text = '#' + $text.Substring(1, $cols - 2) + '#' }
    $text
}
[IO.File]::WriteAllText($grid, ($lines -join "`n"), (New-Object Text.UTF8Encoding($false)))

scp -O -o BatchMode=yes $img $grid "root@${Board}:/tmp/" 2>&1 | Out-Null

if ($Phases -match 'A') {
    Write-Output "[A] all pixels on: the whole panel should turn WHITE for $HoldSec s"
    Run "echo 23 > $dev/cmd"
    Start-Sleep -Seconds $HoldSec
    Run "echo 13 > $dev/cmd"
}

if ($Phases -match 'B') {
    Write-Output "[B] test pattern for $($HoldSec + 4) s: white frame, red/green/blue/yellow corner squares, circles, 8 color bars, gray ramp, an L"
    Run 'printf ''\033[9;0]'' > /dev/tty1'
    Run "head -c $($w * $h * 2) /tmp/fbtest-$w.rgb565 > /dev/fb0"
    Start-Sleep -Seconds ($HoldSec + 4)
}

if ($Phases -match 'C') {
    Write-Output "[C] console text: $rows lines of $cols columns, # in the 4 corners (stays on screen)"
    Run 'printf ''\033[9;0]\033[2J\033[H'' > /dev/tty1; cat /tmp/console-grid.txt > /dev/tty1'
    Write-Output "done: the console grid stays on the display"
}
