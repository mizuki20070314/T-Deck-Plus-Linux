# Put htop on the board's AMOLED console and take a picture of the result.
#
#   powershell -File C:\Users\mizuk\esp32s3-linux\tools\htop_show.ps1 [-NoSnapshot] [-Install]
#
# -Install also copies htop itself to /home/bin (flash, survives reboots). htop and its
# settings are kept in /home, so after a reboot only this script (or htop_start.sh) is needed.
# With the boot-time autostart on (htop_autostart.ps1), init runs htop: this script then only
# replaces its settings (/home/bin/htoprc) and restarts it.
param(
    [string]$Board = '192.168.0.8',
    [switch]$Install,
    [switch]$NoSnapshot,
    [string]$Out = 'C:\Users\mizuk\esp32s3-linux\htop\snapshot-round.png'
)

$tools = 'C:\Users\mizuk\esp32s3-linux\tools'
# the board script and config must have LF line endings
foreach ($f in 'htop_start.sh', 'htoprc') {
    $t = [IO.File]::ReadAllText("$tools\$f") -replace "`r`n", "`n"
    [IO.File]::WriteAllText("$tools\$f", $t, (New-Object Text.UTF8Encoding($false)))
}
if ($Install) {
    # a running executable cannot be overwritten, but it can be replaced: copy beside it, then rename
    ssh -o BatchMode=yes "root@$Board" 'mkdir -p /home/bin' 2>&1 | Out-Null
    scp -O -o BatchMode=yes C:\Users\mizuk\esp32s3-linux\htop\out\htop "root@${Board}:/home/bin/htop.new" 2>&1 | Out-Null
    ssh -o BatchMode=yes "root@$Board" 'chmod 755 /home/bin/htop.new && mv /home/bin/htop.new /home/bin/htop' 2>&1 | Out-Null
}
scp -O -o BatchMode=yes "$tools\htop_start.sh" "$tools\htoprc" "root@${Board}:/tmp/" 2>&1 | Out-Null

$p = Start-Process -FilePath ssh -ArgumentList '-o', 'BatchMode=yes', "root@$Board", 'sh /tmp/htop_start.sh' `
    -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\hs_out.txt" -RedirectStandardError "$env:TEMP\hs_err.txt"
if (-not $p.WaitForExit(90000)) { $p.Kill(); Write-Output 'TIMEOUT: ssh did not return' }
Get-Content "$env:TEMP\hs_out.txt"
Get-Content "$env:TEMP\hs_err.txt" -ErrorAction SilentlyContinue | Select-Object -First 5

if (-not $NoSnapshot) {
    Start-Sleep -Seconds 4     # let htop draw a few frames (CPU% needs two samples)
    powershell -NoProfile -File "$tools\fb_snapshot.ps1" -Out $Out -Scale 2 -Round
}
