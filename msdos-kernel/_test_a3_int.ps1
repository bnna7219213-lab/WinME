$qemu = "C:\qemu\qemu-system-i386.exe"
$img = "C:\Users\bnna7\workspace\msdos-kernel\win9x\win9x.img"
$dbg = "C:\Users\bnna7\workspace\msdos-kernel\win9x\dbg_int.log"
Remove-Item $dbg -ErrorAction SilentlyContinue
& $qemu -drive "file=$img,format=raw,if=floppy" -boot a -no-reboot -m 16 -serial file:$dbg -d int,int -D "$dbg" -no-shutdown