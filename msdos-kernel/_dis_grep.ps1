$raw = [System.IO.File]::ReadAllBytes('C:\Users\bnna7\workspace\msdos-kernel\win9x\_d.txt')
$s = [System.Text.Encoding]::ASCII.GetString($raw)
$lines = $s -split "`n"
Write-Output "===== EIP 0x10063F vicinity (search 0001006xx) ====="
foreach ($l in $lines) {
    if ($l -match '0001006[0-9A-F][0-9A-F]') {
        Write-Output $l
    }
}
Write-Output "===== function labels ====="
foreach ($l in $lines) {
    if ($l -match '>gdi_rect:|>gdi_vgrad:|>gdi_frame3d:|>draw_btn:|>draw_wnd:|>draw_desktop:|>user_dispatch:|>wp_b:|>wp_w:|>wp_t:|>wp_m:|>gdi_init:|>gdi_flip:') {
        Write-Output $l
    }
}
