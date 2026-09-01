# run.ps1 — Run winme kernel with RTL8139 NIC and QEMU user networking
# Kernel connects to 10.0.2.2:8080 (SLIRP gateway) where serve_a4.py listens
Get-Process qemu-system-i386 -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 1
& 'C:\qemu\qemu-system-i386.exe' ^
    -drive file='C:\Users\bnna7\workspace\msdos-kernel\win9x\winme\winme_net.img',format=raw,if=floppy ^
    -netdev user,id=net0 ^
    -device rtl8139,netdev=net0 ^
    -no-reboot -display none -serial mon:stdio -debugcon stdio 2>&1 | Select -First 200 > C:\Users\bnna7\workspace\msdos-kernel\win9x\winme\out.txt