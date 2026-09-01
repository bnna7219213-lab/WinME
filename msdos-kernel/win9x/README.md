# 轴线 A：Win9x 方向（DOS 之上的保护模式外壳）

## 概述
从 M0 的 MS-DOS 玩具内核出发，沿 Win95 → Win98 → WinMe 方向演进。
核心特征：实模式 DOS 底层 + 保护模式 GUI 外壳，DPMI、VMM/VxD 抽象。

按代际（generation）拆分到独立子目录（M-A5 重构）：
- **win95/** — A1（实↔保护模式切换）+ A2（DPMI / int 0x31）。保留 M0 16 位实模式启动路径。
- **win98/** — 在 win95 之上 + A3（VMM/VxD 抽象、轮转调度）。
- **winme/** — 在 win98 之上 + A4（GUI 雏形）。**移除非必要的实模式启动路径**，改用 32 位 `boot32` 加载器 + 32 位 flat 内核（与 M-D2 同型管线），即「无实模式启动」的 A4 实现。

## 目录结构
```
win9x/
  README.md                — 本文件
  build.bat                — 转发到 win95/ 代构建（遗留入口）
  run.bat                  — 转发到 win95 代 QEMU 引导
  win95/                   — A1+A2 (实模式 boot + 保护模式 PM/DPMI)
    build.bat              — M0 实模式 boot.asm + a1/a2 内核 → win95.img (+ 遗留 win9x.img)
    verify.ps1             — M-A1 无头验证 (0xE9)
    boot.asm               — M0 实模式引导扇区（自包含副本）
    a1_kernel_pm.asm       — M-A1: 实模式↔保护模式切换
    a2_*.asm               — M-A2: DPMI 相关测试/实现
  win98/                   — + A3 (VMM/VxD)
    build.bat              — M0 实模式 boot.asm + a3 内核 → win98.img
    verify.ps1             — M-A3 无头验证 (0xE9)
    boot.asm               — M0 实模式引导扇区（自包含副本）
    a3_vmm.asm             — M-A3: VMM/VxD 调度演示
  winme/                   — + A4 (GUI 雏形，无实模式启动)
    build.bat              — 32 位 boot32 加载器 + a4 内核 → winme.img
    verify.ps1             — M-A4（无实模式）无头验证 (0xE9)
    boot32.asm             — 32 位 flat 加载器（公共副本）
    boot32_vga.asm         — 32 位 + mode 13h 钩子版本
    a4_gui.asm             — M-A4: 32 位 flat GUI（= 原 a4x，无实模式）
    a4_gui_realmode.asm    — M-A4 原始 teal 实模式版（保留，由根 _build_a4.ps1 构建）
```

## 里程碑
- [x] M0 基线 (已在 msdos-kernel/src/ 验证)
- [x] M-A1: 实↔保护模式切换 (win95/)
- [x] M-A2: DPMI (int 0x31) (win95/)
- [x] M-A3: VMM/VxD (win98/)
- [x] M-A4: GUI 雏形 (winme/，无实模式启动；teal 实模式版保留于 winme/a4_gui_realmode.asm)

## 构建与验证
```
# 分代构建
win9x\win95\build.bat      → win9x\win95\win95.img   (+ 遗留 win9x\win9x.img)
win9x\win98\build.bat      → win9x\win98\win98.img
win9x\winme\build.bat      → win9x\winme\winme.img

# 分代无头验证
powershell -File win9x\win95\verify.ps1
powershell -File win9x\win98\verify.ps1
powershell -File win9x\winme\verify.ps1

# M-A4 teal 实模式版（独立管线）
powershell -File _build_a4.ps1      # → win9x\win9x_a4.img
powershell -File _test_a4.ps1

# 全轴冒烟（Axis A 走 win95 代）
powershell -File _qemu_test.ps1
```

## 代际要点
- **win95 / win98** 保留 M0 16 位实模式引导扇区（`boot.asm`），符合 Win95/98「DOS 之下实模式 + 之上保护模式」的真实启动模型。
- **winme** 移除非必要的实模式启动路径：内核为 32 位 flat（加载到 0x100000），由 32 位 `boot32` 加载器直接接管，不再经过 M0 实模式 boot。这正是原 `a4x_gui.asm` 的形态（已并入 `a4_gui.asm`）。
