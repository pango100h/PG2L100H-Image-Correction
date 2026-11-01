==========================================================
基于紫光同创 PG2L100H 的实时视频畸变校正与显示系统
—— 源代码说明
==========================================================

一、开发环境
    FPGA      : 紫光同创 Logos2 系列 PG2L100H-6IFBG676
    开发板    : MES2L676-100HP（核心板 + 底板）
    EDA 工具  : Pango Design Suite 2022.2-SP6.4
    仿真/建模 : Python 3（仅用于算法建模与图像源生成，不参与综合）

二、目录结构
    01_工程文件/
        img_correct.pds         PDS 工程文件，双击可直接打开
        hdmi_loop_tx.fdc        引脚约束（含 HDMI 输出、I2C、UART、LED）
        source/                 RTL 源码
            img_correct_top.v   顶层 + 全部功能模块（含 img_path 校正流水线、
                                仿射矩阵、uart_cmd 串口指令、自适应 Gamma）
            ms7210_cfg.v        MS7210 发送芯片 I2C 配置（49 条寄存器）
            i2c_master.v        I2C 主机底层时序
            img_correction.v    畸变校正（早期版本，保留供对照）
            resample_interp.v   双线性插值（早期版本，保留供对照）
            distort_correct_pipe.v / timing_640x480.v / vga_driver.v
                                早期 VGA 实验版本，保留供对照
        ipcore/                 IP 核（PLL、双口 RAM），PDS 自动生成

    02_上位机串口控制台/
        control.html            网页版控制台（Chrome/Edge 原生 Web Serial）
        start_console.bat       本地起服务并自动打开浏览器

    03_脚本与参数/
        gen_rom_img.py          图像源打包脚本（512×512 → 4 个 256×256 bank）
        apply_sda_fix.py        I2C SDA 仲裁补丁脚本
        build_chain.sh          一键编译脚本
        build_gamma_demo.sh     Gamma 演示版编译脚本
        gam_lut.hex             Gamma 查找表（4 档 × 256 点）
        rom_ee/eo/oe/oo.hex     片内 ROM 图像数据（按像素奇偶拆分四块）

三、编译方法
    方式一（图形界面）：用 PDS 打开 01_工程文件/img_correct.pds，
        菜单 Tools → Configuration 烧录，或直接点 Generate Bitstream。
    方式二（命令行）：
        cd 01_工程文件
        <PDS安装路径>/bin/pds_shell.exe -project img_correct.pds -run gen_bit_stream
    编译产物在 generate_bitstream/img_correct_top.sbit。

四、主要参数（img_correct_top.v 顶部）
    GAMMA_EN    1 = 开启自适应 Gamma
    GAMMA_DEMO  1 = 四档曲线每 5 秒循环（灰阶演示用），0 = 按帧均值自动选档
    AF_EN       1 = 开启仿射几何变换（每 5 秒轮换四种预设）
    畸变系数    k1/k2/p1/p2 三套并存，改 4 行常数即切换桶形/枕形/纯径向
    归一化因子  S_Q16 = 54700（s = 0.83466），用于消除校正后黑边

五、串口指令协议（115200 8N1，ASCII，末尾回车）
    S + 24 个十六进制字符   一次写入 a,b,c,d,tx,ty 六个仿射系数
                            a~d 为 Q12（1.0 = 4096），tx/ty 为 Q8 有符号
    M0 ~ M3                 回到内置预设，关闭自定义矩阵
    G0 ~ G4                 固定 Gamma 档 0~3；4 = 恢复自适应
    D                       全部参数恢复默认
    示例：S10000000000001000000000000000（恒等矩阵）

六、说明
    采集侧 30 根信号的引脚分配与采样时序均按官方参考设计实现；
    受本板 HDMI 接收前端硬件限制，实测 TMDS 解码无法稳定建立，
    因此交付版本采用片内 ROM 图像源作为输入，以稳定复现校正链路。
    更换可用的采集源后，帧缓存与校正流水线无需改动。
