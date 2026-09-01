# MS-DOS 风格玩具内核（16 位实模式）

一个独立、可真实引导运行的 x86 16 位实模式内核玩具项目。灵感源自经典的
MS-DOS：一个 stage-1 引导扇区把内核从软盘读入内存，内核提供一个迷你命令
shell 与一个 DOS 风格的软中断系统调用接口（`int 0x20`）。

项目定位：**独立可运行玩具内核**（不纳入 `linux_improved` 的"逐版本演化"
框架）。架构目标：**纯 16 位实模式**，最贴近真实 MS-DOS，用 NASM 汇编编写，
可在 QEMU / Bochs 中以软盘方式真实引导。

## 目录结构

```
msdos-kernel/
├── src/
│   ├── boot.asm      # stage-1 引导扇区 (org 0x7C00, 512B + 0x55AA)
│   └── kernel.asm     # 实模式内核 (org 0x0000 @ 0x1000:0)
├── build.bat         # 编译并打包 1.44MB 软盘镜像 dos.img
├── run.bat           # 用 qemu-system-i386 启动 dos.img
├── bochsrc.txt       # Bochs 配置（可选）
└── dos.img            # 构建产物（软盘镜像）
```

## 构建

需要 NASM（已验证 NASM 3.01 通过）：

```bat
build.bat
```

它会：
1. `nasm -f bin src/boot.asm  -o build/boot.bin`   （必须正好 512 字节）
2. `nasm -f bin src/kernel.asm -o build/kernel.bin`
3. 用 PowerShell 把 `boot.bin` 写入镜像 0 扇区、`kernel.bin` 写入第 2 扇区起，
   生成 1.44MB 软盘镜像 `dos.img`。

## 运行

本机已安装 QEMU（`C:\qemu\qemu-system-i386.exe`，版本 11.0.50），可直接运行：

```bat
run.bat
```

`run.bat` 使用 `-nographic` 把 VGA 文本与键盘都接到当前控制台，启动后即可
看到 banner 并输入命令（输入 `halt` 或关闭窗口退出）。

若需在**无头 / 自动化**环境观测内核输出，`kernel.asm` 的 `puts` 会把每个字符同时
写到 QEMU 调试端口 `0xE9`，可用 `run_verify.ps1` 捕获：

```powershell
powershell -File run_verify.ps1   # 用 -debugcon 抓 0xE9 输出，验证 ver/help/echo
```

或手动：

```bat
qemu-system-i386 -fda dos.img -boot a -display none -debugcon file:dbg.log
```

（Bochs 亦可：`bochs -q -f bochsrc.txt`）

## 引导流程

1. BIOS 把软盘 0 扇区的 512 字节加载到 `0x7C00` 并执行。
2. `boot.asm` 打印 banner，用 BIOS `int 0x13` 把内核（**软盘第 2 扇区起**，最多 16 扇区）
   读到 `0x1000:0x0000`，然后 `jmp 0x1000:0`。
   > 注意：软盘扇区从 1 开始编号，第 1 扇区是 boot 自身（镜像偏移 0），
   > 内核必须落在镜像偏移 **512**（= 第 2 扇区）。打包脚本 `pack.ps1` 把内核
   > 写入镜像偏移 512，与 bootloader 的读取位置严格对齐。
3. `kernel.asm` 设置 `int 0x20` 系统调用处理程序，打印 banner，并通过一次
   `int 0x20` 演示系统调用，最后进入命令循环。

## 支持的命令

| 命令            | 说明                          |
|-----------------|-------------------------------|
| `help`          | 显示帮助                      |
| `ver`           | 显示版本                      |
| `cls`           | 清屏                          |
| `echo <text>`  | 打印文本                      |
| `halt`          | 停机                          |

## 系统调用接口（int 0x20，DOS 风格）

| AH  | 功能                                 |
|-----|--------------------------------------|
| 0x00| 停机（`cli; hlt`）                  |
| 0x01| 打印 `DS:DX` 指向的 `$` 结尾字符串   |

## 机验说明

- 本仓库环境已用 NASM 完成编译并生成 `dos.img`，构建可复现。
- **已在本机 QEMU 11.0.50 实跑验证通过**：QEMU 成功引导软盘，bootloader 加载内核，
  内核在 VGA 文本模式（及 0xE9 调试端口）打印：
  ```
  MS-DOS Kernel v0.1 (16-bit real mode)
  (c) toy kernel project. Type 'help' for commands.
  C:\>
  ```
  并通过无头自启动演示逐项验证了 `ver` / `help` / `echo` / 未知命令 的输出。
- 关键修复记录：早期版本引导后内核输出为乱码，根因是打包脚本把内核写入镜像
  偏移 **1024**（第 3 扇区），而 bootloader 从**第 2 扇区**（偏移 512）读取，
  错位整整一个扇区，导致加载到内存的是零填充空洞。修正 `pack.ps1` 写入偏移为 512 后
  引导完全正常。
