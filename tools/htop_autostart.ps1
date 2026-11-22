# Show htop on the board's AMOLED console from boot on (or stop doing that).
#
#   powershell -File C:\Users\mizuk\esp32s3-linux\tools\htop_autostart.ps1 -Enable
#   powershell -File C:\Users\mizuk\esp32s3-linux\tools\htop_autostart.ps1 -Disable
#   powershell -File C:\Users\mizuk\esp32s3-linux\tools\htop_autostart.ps1            (status)
#
# -Enable puts /home/bin/htop-launch and /home/bin/htoprc on the board and adds one line to
# /etc/inittab (both are flash, so they survive reboots), then asks init to reread it, which
# starts htop on tty1 at once. -Disable takes the line out again. The first -Enable keeps the
# board's original inittab as /etc/inittab.before-htop and as backup\board-etc-inittab-before-htop-autostart.
# HTOP.md has the details.
param(
    [string]$Board = '192.168.0.8',
    [switch]$Enable,
    [switch]$Disable
)

$tools = 'C:\Users\mizuk\esp32s3-linux\tools'
$backup = 'C:\Users\mizuk\esp32s3-linux\backup\board-etc-inittab-before-htop-autostart'
$sshOpt = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10')

if ($Enable -and $Disable) { throw 'give -Enable or -Disable, not both' }

# files that go to the board must have LF line endings
foreach ($f in 'htop_launch.sh', 'htop_autostart_board.sh', 'htoprc') {
    $t = [IO.File]::ReadAllText("$tools\$f") -replace "`r`n", "`n"
    [IO.File]::WriteAllText("$tools\$f", $t, (New-Object Text.UTF8Encoding($false)))
}

if ($Enable) {
    # Keep the board's own inittab on the PC too, the first time, before anything changes it.
    if (-not (Test-Path $backup)) {
        scp -O @sshOpt "root@${Board}:/etc/inittab" $backup 2>&1 | Out-Null
        if (-not (Test-Path $backup)) { throw 'could not copy /etc/inittab from the board' }
        if ((Get-Content $backup -Raw) -match 'htop-launch') {
            Remove-Item $backup
            throw 'the board inittab already has the htop line, so it is not the original; not saving it as the backup'
        }
        Write-Output "saved the board's inittab as $backup"
    }
    scp -O @sshOpt "$tools\htop_launch.sh" "$tools\htoprc" "$tools\htop_autostart_board.sh" "root@${Board}:/tmp/" 2>&1 | Out-Null
    ssh @sshOpt "root@$Board" 'sh /tmp/htop_autostart_board.sh enable' 2>&1
} elseif ($Disable) {
    scp -O @sshOpt "$tools\htop_autostart_board.sh" "root@${Board}:/tmp/" 2>&1 | Out-Null
    ssh @sshOpt "root@$Board" 'sh /tmp/htop_autostart_board.sh disable' 2>&1
} else {
    scp -O @sshOpt "$tools\htop_autostart_board.sh" "root@${Board}:/tmp/" 2>&1 | Out-Null
    ssh @sshOpt "root@$Board" 'sh /tmp/htop_autostart_board.sh status' 2>&1
}
