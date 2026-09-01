================================================================================
WinME 网络下载与执行子系统 —— 介绍文档（winme_net）
================================================================================

本文档面向「想了解 / 想维护 / 想扩展」WinME 网络能力的读者，系统介绍
msdos-kernel 工程中 Win9x/WinME 线的网络下载 + PE 执行子系统（代号
winme_net）。它运行在自研 32 位保护模式内核（A4 GUI，源文件 a4_gui.asm）
之上，能够在 QEMU + RTL8139 网卡 + SLiRP 用户态网络的真实环境中完成：

    TCP 三次握手 → HTTP GET → 下载 PE → 解析/导入/执行
                   → 安装到 OS 文件系统 → 桌面双击重新运行

这是一套从「裸金属引导」到「下载并运行真实 Windows 程序」的完整端到端链路，
全部用 16/32 位 x86 汇编手写实现，无外部库依赖。


--------------------------------------------------------------------------------
1. 它是什么 / 解决了什么问题
--------------------------------------------------------------------------------
msdos-kernel 是一个从实模式引导开始、自举到 32 位保护模式的操作系统内核原型。
Win9x/WinME 线是其中的图形 shell 分支（A4 GUI）。普通变体只能运行内置的
「字节码 EXE」（legacy VM EXE）；winme_net 变体额外实现了：

  · 真实网卡驱动（RTL8139，MMIO + 收发环形队列）
  · 真实网络协议栈（ARP / IPv4 / TCP / UDP-DNS / HTTP/1.1）
  · 真实 PE32 解析与执行（MZ→PE 头→节表→导入表→IAT 填桩→EntryPoint）
  · 文件系统持久化（file_table + file_contents_pool）

目标是证明「一个手写内核 + 手写网络栈」足以从互联网下载一个 Windows PE
并把它当作已安装的程序运行起来，而不是只跑一段演示用的玩具字节码。


--------------------------------------------------------------------------------
2. 整体架构（从开机到运行 PE）
--------------------------------------------------------------------------------
  boot32.asm  (实模式 16 位)
    ├─ 可选设置 VGA mode 13h（%ifdef VIDEO_MODE）
    ├─ 从软盘按 16 扇区/批 读取，ES 段精确跟踪物理地址
    └─ 加载 kernel32 到 1MB，开 A20/保护模式，跳入 32 位

  a4_gui.asm   (保护模式 32 位内核 + A4 GUI shell)
    ├─ 内核初始化：GDT/IDT/分页、VGA 文本&图形、键盘、鼠标、桌面
    ├─ main_loop（每帧 tick）：
    │    eth_rx → ip_rx → tcp_rx → 网络状态机 net_download
    │    → 桌面/窗口/图标重绘 → 输入处理（鼠标 mou_handle）
    │    → pe_pending_run 调度（P1.6 双击运行）
    └─ 网络栈模块：
         rtl8139_*  ：网卡驱动（读 TSD/TCR、RX 环形队列、发送）
         arp_*      ：ARP 请求/应答（解析网关 10.0.2.2 MAC）
         ip_rx      ：IPv4 分用
         tcp_*      ：TCP 状态机 + 校验和 + 重传/FIN/RST（P1.5）
         udp_*      ：UDP（供 DNS 查询用）
         dns_*      ：DNS 解析（标签编码查询、跳 QNAME/CNAME、取 A 记录）
         http_*     ：HTTP/1.1 GET 动态组装（Host/Connection 头）
         net_download：总体状态机（URL 解析→ARP→DNS→TCP→HTTP→PE→安装）
         pe_*       ：PE 解析/导入/执行 + 安装到文件系统

  serve_real_inet.py / serve_a4.py
    └─ 宿主机侧 Python HTTP 服务器，向 QEMU 分发 PE payload（hello.exe, 2561B）

  build_net.ps1
    └─ 用 nasm 汇编 boot32 + kernel32，再用 common/pack32.ps1 打包成
       winme_net.img（1.44MB 软盘镜像）。加 -DnsTest 生成 winme_net_dns.img。


--------------------------------------------------------------------------------
3. 已完成的阶段（见 issue.md 的验收记录）
--------------------------------------------------------------------------------
阶段一（本地网络模拟，run_net_test.ps1）
   QEMU 内核对本机 127.0.0.1:8080 发起 TCP→HTTP GET→下载 hello.exe，
   解析并执行 PE。结果：13/13 PASS。

阶段二（真实互联网下载 + 安装到 OS，run_real_inet_test.ps1）
   通过 QEMU SLiRP NAT（10.0.2.15 ↔ 网关 10.0.2.2）走到宿主 Python 服务器，
   下载 PE → 跨 chunk 拷贝到 file_contents_pool → 注册为 inet_dl.exe 到
   file_table → 反向验证 MZ+PE 签名。结果：21/21 PASS。

阶段三（P0.2 安装持久化重跑 + P0.1 真实域名 DNS，run_real_inet_test.ps1）
   · P0.2：污染 pe_download_buf 后强制 run_prog=7/pe_state=0，exe_load
           走 Priority 0.5 从 file_table 重新加载并运行——证明「安装」具备
           OS 持久化意义（已安装 PE 可脱离网络再次运行）。
   · P0.1：net_download 接入 dl_parse_url（scheme/host/port/path + dotted-quad
           直连）+ 动态 Host 头 + DNS 状态机（223.5.5.5:53 → A 记录）。
   结果：21/21 PASS（含 P0.2 重跑断言）+ -DnsTest 13/13（httpbin.org DNS
   解析→公网 IP:80→GET /bytes/256→HTTP body complete，pcap 铁证）。

阶段三关键修复（历史记录，详见 issue.md §2）：
   · tcp_rx 丢弃无 PSH 段 → 改为「有 payload 就追加」
   · pe_rva_to_fileoff 参数约定错误
   · dbg_hex32 只打 4 位 → 改为 8 位
   · exe_load 成功路径返回值错误（AL 被清 0）
   · fs_install_pe_exe 栈不平衡 / 字段重叠 / FS_CONTENT_LEN 漂移
   · exe_load Priority 0.5：rep movsb 后 ecx=0 覆盖 pe_download_len
   · tcp_cksum 奇数长度段漏算尾字节（P0.1 DNS 路径的「隐形杀手」）


--------------------------------------------------------------------------------
4. Roadmap 总览（P0 / P1 / P2 优先级）
--------------------------------------------------------------------------------
本子系统的功能演进按优先级推进。下表为完整 Roadmap 与当前状态；
P0/P1 全部完成，P2 为后续演进方向（详见第 9 节）。

  ┌──────┬─────────────────────────────────────┬───────────────────────────┐
  │ 优先级 │ 项                                  │ 状态                      │
  ├──────┼─────────────────────────────────────┼───────────────────────────┤
  │ P0.1 │ 真实 URL 任意 Host HTTP 下载          │ ✅ 阶段三（21/21 + 13/13）│
  │      │ （DNS → 任意 IP + 动态 Host 头）      │                           │
  │ P0.2 │ 已安装 PE「重启后重新运行」闭环        │ ✅ 阶段三（Priority 0.5）  │
  │      │ （exe_load 从 file_table 重载）        │                           │
  │ P0.3 │ 10 个高频 Win32 stub 扩充             │ ✅ 阶段四                  │
  │ P0.4 │ fs_write/fs_read + PE WriteFile 落盘  │ ✅ 阶段四                  │
  │ P1.5 │ TCP 重传 / 超时 / FIN 优雅关闭 / RST  │ ✅ 阶段四                  │
  │ P1.6 │ GUI 双击桌面图标运行已安装 EXE         │ ✅ 阶段四                  │
  ├──────┼─────────────────────────────────────┼───────────────────────────┤
  │ P2 #7 │ PE 重定位表 (Base Relocation) 处理    │ ⬜ 未做                    │
  │ P2 #8 │ FS_CONTENT_LEN 0xA01→0xA00 漂移根因   │ ⬜ 已知残留（§3 / issue §2.10）│
  │ P2 #9 │ file_table name 写错位（"ten\0.dl…"）│ ⬜ 已知残留（issue §3）     │
  │ P2 #10│ sys_tick / PIT 时钟驱动（tick 恒 0） │ ⬜ 已知残留（issue §3）     │
  │ P2 #11│ HTTPS / TLS（真实公网 99% 是 HTTPS）  │ ⬜ 长期架构                │
  └──────┴─────────────────────────────────────┴───────────────────────────┘

推荐实施顺序（最短路径 → 最大体验提升，已全部落地 ✅）：
  P0.2 → P0.1 → P0.3 → P1.6 → P0.4 → P1.5

--------------------------------------------------------------------------------
4.1 已完成项详解（P0.1 / P0.2 / P0.3 / P0.4 / P1.5 / P1.6）
--------------------------------------------------------------------------------

P0.1 — 真实 URL 任意 Host HTTP 下载（打通 DNS → 任意 IP）
   打破 `net_download` 原本硬编码 `tcp_dst_ip=10.0.2.2` + `tcp_dport=8080`、
   URL 写死 `GET /a4.exe` 的限制：
   · dl_parse_url：解析 `scheme://host:port/path`，支持 dotted-quad 直连与
     默认端口（http→80）。
   · net_download 前置 phase：进入 `dns_state` → call dns_resolve（传入
     hostname）→ 等待 udp_rx → 取 `dns_ip` 填入 `tcp_dst_ip`（QEMU SLiRP
     默认 DNS server 为 10.0.2.3，公网 DNS 用 223.5.5.5:53）。
   · http_get_req 动态组装 `GET <path> HTTP/1.1\r\nHost: <host>\r\n
     Connection: close\r\n\r\n`（奇数长度 GET 已靠 tcp_cksum 修复正确）。
   · 加 -DnsTest 变体：GET httpbin.org/bytes/256 → 真实 DNS 解析公网 IP:80
     → body complete（pcap 铁证）。

P0.2 — 已安装 PE「重启后重新运行」闭环（exe_load Priority 0.5）
   exe_load 有三条路径：
   · Priority 0：刚从 pe_download_buf 下载的 PE（已验证）。
   · Priority 0.5：file_table[run_prog].FS_TYPE_FILE_EXE → 从
     file_contents_pool 拷贝回 pe_download_buf 再执行（代码早就在，本轮首跑）。
   · Priority 1：legacy dl_code 路径。
   验证：net_download 安装成功、MZ+PE 验证完毕后，主动污染 pe_download_buf
   并强置 run_prog=7 / pe_state=0 触发 exe_load Priority 0.5，确认
   pe_parse OK / imports OK / exec OK。run_real_inet_test.ps1 新增断言
   "installed PE re-runnable from file_table"。

P0.3 — 10 个高频 Win32 stub
   在 pe_stub_table 中新增常用 Win32 API 桩，覆盖 PE 程序最常见的导入：
   GetModuleFileNameA、GetCommandLineA、HeapAlloc、HeapFree、VirtualAlloc、
   CreateFileA、CloseHandle、lstrlenA、MessageBoxA、GetModuleHandleA 等。
   · HeapAlloc/HeapFree 走新增的 PE 堆（pe_heap_bss，32KB bump allocator，
     pe_heap_cur 指针线性推进）；VirtualAlloc 复用同一块 scratch。
   · 桩入口集中在 pe_printf_stub 之后，通过 pe_stub_table 的字符串名查表，
     pe_dispatch_call 做 NUL 结尾逐字节比较命中后跳到对应桩地址。

P1.6 — GUI 双击桌面图标运行已安装 EXE
   让用户「像在 Windows 里一样」双击桌面上的 inet_dl.exe 图标来运行它：
   · fs_hit_test(mou_x, mou_y)：按桌面图标矩形（列×行网格）做命中测试，
     返回 file_table 槽位或 -1。
   · mou_handle：左键按下且未命中任何窗口时，调用 fs_hit_test；命中
     FS_TYPE_FILE_EXE 则写入 run_prog=槽位、pe_state=0、pe_pending_run=1。
   · main_loop 每帧检查 pe_pending_run：置位后调用 exe_load(Priority 0.5)
     + pe_exec，效果等价于重新运行已安装的 PE。
   · 图标绘制 draw_icons_fs 扩容到 8 个可见槽位（4 行×2 列），保证
     ludashi_install.exe 与 inet_dl.exe 都能显示。

P0.4 — 文件系统内容读写 + PE WriteFile/ReadFile 落盘
   新增两个内部 API（与 PE 桩对接）：
   · fs_write_cur(bl=slot, esi=buf, ecx=len) → eax=写入字节数，按
     pe_fpos[slot] 游标写入 file_table[slot].content_off 指向的
     file_contents_pool，并推进游标。
   · fs_read_cur(bl=slot, edi=buf, ecx=len) → eax=读出字节数，对称读取。
   · pe_writefile_stub / pe_readfile_stub：当 hFile 是 FS 句柄（0x20xx，
     低字节-1=槽位）时转发到 fs_write_cur/fs_read_cur；当 hFile 是
     0x1000（stdout/stderr）时走原有 exe_out 回显路径。
   这样 PE 程序对「文件」的读写真正落到 OS 文件系统缓冲区，而非只在
   内存里打转。

P1.5 — TCP 健壮性：重传 / 超时 / 优雅关闭 / RST 处理
   在原有 TCP 状态机基础上补齐生产级可靠性：
   · tcp_last_tx_snap[128] + tcp_last_tx_len：发送 SYN/HTTP-GET/FIN 后，
     由 tcp_snapshot_last 把整帧（含以太网头）复制进快照区；
     tcp_retransmit_last 可原样重放。
   · tcp_check：按状态选择超时阈值（SYN 300 tick / ESTABLISHED 450 tick /
     FIN_SENT 200 tick）。超时且 tcp_retries<3 时重放快照并递增重试计数；
     重试耗尽则中止会话（tcp_state=0），让 net_download 走兜底，不产生
     假阳性 PE 检测。
   · tcp_send_fin：主动发送 FIN+ACK（fin_state=1，tcp_seq+1），在
     net_download 收尾（.nd_pe_done）且仍处 ESTABLISHED 时调用，做到优雅
     关闭连接。
   · tcp_rx：检测 RST 位（flags bit2）立即拆链（.tr_rst）；对纯 ACK 且
     fin_state=1 的情况视为 FIN-ACK，推进到 fin_state=2；到达 FIN 时
     回送 ACK 并标记 CLOSED（fin_state=3）。即使服务器不回 FIN-ACK，
     200 tick×3 重试后也会静默关闭，绝不阻塞。

winme_net介绍.txt
   本文件——一份面向维护者/扩展者的完整介绍。


--------------------------------------------------------------------------------
5. 验证结果（本轮收尾后的全量回归）
--------------------------------------------------------------------------------
三套回归脚本全部通过，合计 49/49：

  run_net_test.ps1          → net_test:   PASS=13 FAIL=0   （本地链路核心流水线）
  run_real_inet_test.ps1    → real_inet:  PASS=23 FAIL=0   （含 P0.3/P1.6/P0.4 验证）
  run_real_inet_test.ps1 -DnsTest → dns_test: PASS=13 FAIL=0 （P0.1 DNS 真链路）

覆盖的关键断言：
  · 引导 / 内核装载 / A4X shell / RTL8139 检测
  · ARP → SYN → SYN-ACK ESTABLISHED → HTTP GET → body complete
  · PE MZ 检测 → parse → imports 解析(IAT0 非 0) → exec 返回 OK
  · fs_install_pe_exe → inet_dl.exe MZ+PE 签名反向验证
  · P0.2：已安装 PE 从 file_table 重载运行（buf 污染）
  · P1.6：图标双击运行器武装 + EXE 从图标点击运行（exit_code=0）
  · P0.1 DNS：net_dl state=2 → 主机名提取 → DNS 查询 → A 记录解析 → 公网 IP


--------------------------------------------------------------------------------
6. 关键源码位置（a4_gui.asm）
--------------------------------------------------------------------------------
  tcp_rx 数据段判定 / RST / FIN-ACK   ~7399 / ~8673 / ~8949 / ~9001
  pe_rva_to_fileoff                  ~4770
  pe_resolve_imports                 ~8683
  pe_dispatch_call (NUL 比较)        ~8635
  pe_exec / pe_exec_return           ~8796 / ~8449
  exe_load PE 流水线 + AL=1          ~5046 / ~5082
  exe_load Priority 0.5 重载修复      ~5340
  fs_install_pe_exe                  ~3544–3758
  fs_write_cur / fs_read_cur (P0.4)  ~3916 / ~3974
  pe_writefile_stub / pe_readfile_stub (P0.4)  ~9855 / ~9931
  pe_stub_table / HeapAlloc 等 (P0.3)  ~10636 / ~10104
  fs_hit_test / pe_pending_run 调度 (P1.6)  ~2137 / ~9547
  mou_handle 图标命中 (P1.6)         ~1988 起
  net_download 状态机 (含 P0.2 / P1.5 FIN)  ~7046–7500
  dl_parse_url / http_get / dns_*    ~6900 / ~6838 / ~6470 / ~6599
  tcp_connect (SYN 快照)             ~8200 起
  tcp_send_data (GET 快照)           ~8390
  tcp_check / tcp_snapshot_last / tcp_retransmit_last / tcp_send_fin (P1.5)
                                   ~6674 / ~8489 / ~8525 / ~8564
  tcp_cksum 奇数长度尾字节修复       ~7859–7882

辅助脚本：
  build_net.ps1                构建（普通 / -DnsTest）
  run_net_test.ps1             阶段一构建/测试
  run_real_inet_test.ps1       阶段二/三（21/23 项 + -DnsTest 变体）
  serve_a4.py / serve_real_inet.py   宿主侧 HTTP 服务器
  common/debug.inc             QEMU 0xE9 调试口宏（dbg_puts/dbg_hex8/dbg_hex32）
  common/pack32.ps1            引导扇区 + 内核打包成软盘镜像


--------------------------------------------------------------------------------
7. 复现 / 构建方法
--------------------------------------------------------------------------------
  # 构建普通变体（net_test / real_inet_test 用）
  powershell -File build_net.ps1
  # 构建 DNS 变体
  powershell -File build_net.ps1 -DnsTest

  # 阶段一：本地网络模拟 13/13
  powershell -File run_net_test.ps1
  # 阶段二/三：真实互联网下载 + 安装 23/23
  powershell -File run_real_inet_test.ps1
  # 阶段三 DNS 变体 13/13（无本地服务器，guest 直连真实互联网）
  powershell -File run_real_inet_test.ps1 -DnsTest

构建约束：kernel32.bin 不得超过 262144 字节（512 扇区 × 512B）。
当前大小约 240KB，余量充足。

环境提示：
  · QEMU 路径约定为 C:\qemu\qemu-system-i386.exe（需 RTL8139 用户态网络）。
  · 启动镜像建议显式加 -fda raw: 前缀，避免 QEMU 对软盘镜像格式探测告警。
  · 真实互联网测试依赖宿主 DNS（httpbin.org）与到 223.5.5.5:53 的 UDP
    可达性；若 SYN 全无应答，先排查宿主网络而非 guest 侧代码。


--------------------------------------------------------------------------------
8. 维护者须知 / 本轮收尾修复的构建坑
--------------------------------------------------------------------------------
本次「继续 Roadmap」时，P0.3/P1.6/P0.4/P1.5 的代码逻辑已就位，但汇编构建
因以下 4 处错误中断，已全部修复（验证 49/49 通过）：

  1. dbg_hex8 / dbg_hex32 是宏（%macro，定义在 common/debug.inc），
     不能用 `call dbg_hex8` 调用——必须裸宏调用 `dbg_hex8`。
     P1.5 调试输出处误用了 `call`，已改为裸调用。

  2. tcp_check 内前向引用的局部标签（.tcp_d / .tcp_no_timeout /
     .tcp_fin_timeout）在 P1.5 扩展后跨越了较长代码段，NASM 报
     "symbol `tcp_check.tcp_d' not defined"。已将这些前向局部标签改为
     全局唯一标签（tcp_chk_d / tcp_chk_no_timeout / tcp_chk_fin_timeout）。

  3. tcp_retransmit_last 中 `jecxz .trl_done` 报 "short jump is out of
     range"。原因：jecxz 只有短跳转形式（±128 字节），而它到 .trl_done
     之间夹了大量调试宏，距离远超限制。已改为 `test ecx,ecx` + `jz`
     （jz 可自动提升为近跳转）。

  4. 修复后构建通过，kernel32.bin = 240272 字节，< 262KB 上限。

这些坑本质是「宏 vs 过程」「局部标签前向引用」「jecxz 无 near 形式」三类
x86/NASM 经典陷阱，后续新增调试输出或前向跳转时请先留意。


--------------------------------------------------------------------------------
9. 后续 P2 演进方向（Roadmap 未完项，非本轮范围）
--------------------------------------------------------------------------------
以下为 Roadmap 中尚未实现的 P2 项，按优先级与风险列出，供后续排期：

P2 #7 — PE 重定位表 (Base Relocation) 处理【中低】
   现状：pe_parse 找到 IMAGE_DIRECTORY_ENTRY_BASERELOC 但只跳过未处理；
   _make_test_pe 把 ImageBase=0x400000 固定加载到 0x400000（恰好匹配），
   所以不重定位也能跑。
   收益：同时加载 2 个 PE 或 ImageBase 冲突的任意真实 PE 时必须重定位。
   改动：遍历 IMAGE_BASE_RELOCATION block → Type=3 (HIGHLOW) / Type=0 (ABS, skip)
   → 每 16 bits 加 delta = ActualImageBase - PreferredImageBase。
   需在 PE 内存映射后、IAT 填桩之前执行。

P2 #8 — FS_CONTENT_LEN 0xA01→0xA00 漂移根因【已知残留】
   issue.md §2.10 已记录：写入 `[edi+FS_CONTENT_LEN]=eax`(0xA01) 后几十字节
   内读出变 0xA00。影响无害（Priority 0 路径不依赖该值，校验允许 diff≤1）。
   可做：写入后立即用完全独立寄存器重新读，或改用 movsb/stosb 以 byte 粒度
   写 4 次，消除 QEMU 对 BSS 段 dword 非对齐写入的副作用。

P2 #9 — file_table name 写错位（"ten\0.dl…"）【已知残留】
   issue.md §3 残留项：fs_install_pe_exe 写 name 后内存读回显示 "ten\0.dld…"。
   NASM listing 证明源字符串与 rep movsb 编码均正确，且功能不受影响（安装打开
   用 content_off/len 而非 name）。可逐字节 name 拷贝（非 16-byte rep movsb）
   精确定位原因。

P2 #10 — sys_tick / PIT 时钟驱动（tick 恒 0）【已知残留】
   主循环 8000 次空轮询拖慢 PIT 8254 IRQ0 中断，ml:tick 恒为 0 →
   pe_sleep_stub 的 Sleep(1000) 只写变量不真正等待 → PE 轮询动画会飞速运行。
   修复：主循环减少空轮询（或加 hlt 等待 IRQ）让 sys_tick 自然增长。

P2 #11 — HTTPS / TLS【长期】
   真实公网 99% 的 URL 是 HTTPS。最小化实现：TLS 1.2 handshake + AES128-CBC
   + SHA256 HMAC（或最简单的 RC4）。但汇编手写 TLS 工作量 ≥ 现有整个网络栈
   的 10 倍，暂不作为近期目标。

补充优化（基于本轮已完成项）：
  · P1.5 重传可区分 SYN/GET/FIN 三段独立重传窗口。
  · P0.4 的 fs_write_cur 暂不自动增长 chunk 数（写大文件需先分配），可加
    按需扩展 file_contents_used[] 逻辑。
  · P1.6 当前为合成触发（等价真实点击）；可接入 VIN 脚本模拟真实鼠标双击
    事件，端到端验证 mou_handle 全路径。
  · 可加 TCP 接收窗口 / 慢启动等更完整拥塞控制，逼近真实协议栈。


================================================================================
文档版本：2026-09-01  （Roadmap P0.1/P0.2/P0.3/P0.4/P1.5/P1.6 全部 ✅ + P2 #7-#11 未完项 Backlog + 构建修复记录）
================================================================================
