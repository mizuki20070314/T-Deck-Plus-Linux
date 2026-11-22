# Put the Linux system back on the board: writes the full 16 MB flash image that
# was read just before the display test (Wi-Fi, root password, SSH host key and
# authorized_keys are all inside it).
#
#   powershell -File C:\Users\mizuk\esp32s3-linux\tools\restore_linux.ps1 [-Port COM23]
#
# Takes about 100 seconds. The board reboots into Linux when it finishes.
param([string]$Port = 'COM23')

$bk = 'C:\Users\mizuk\esp32s3-linux\backup\linux-running-20261030-before-display-test.bin'
if ((Get-Item $bk).Length -ne 16777216) { throw "backup has the wrong size: $bk" }

py -m esptool --chip esp32s3 -p $Port -b 460800 --before default-reset --after hard-reset `
    write-flash --flash-mode dio --flash-size 16MB --flash-freq 80m 0x0 $bk
