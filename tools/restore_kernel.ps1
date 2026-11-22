# Put the shipped 0.9.1 kernel back into the "linux" partition (0x140000).
# Only the kernel is written; /etc, /home, the rootfs and the firmware are untouched.
#
#   powershell -File C:\Users\mizuk\esp32s3-linux\tools\restore_kernel.ps1 [-Port COM23]
#
# Takes about 20 seconds; the board reboots into the original kernel.
param([string]$Port = 'COM23')

$img = 'C:\Users\mizuk\esp32s3-linux\kernel-work\out\xipImage-shipped-0.9.1'
$want = '79389da8c8ca10b74fabee1a72408ce3feadd9ca19dd686f26255120cc685fde'
$have = (Get-FileHash -Algorithm SHA256 $img).Hash.ToLower()
if ($have -ne $want) { throw "shipped kernel image does not match the official hash: $have" }

py -m esptool --chip esp32s3 -p $Port -b 460800 --before default-reset --after hard-reset `
    write-flash 0x140000 $img
