#!/bin/bash
# v47 = 灰阶图 + Gamma 四档轮换(演示) + 仿射关   —— 用于 Gamma 验证录屏
# v48 = 照片   + Gamma 自适应     + 仿射开     —— 观赏版
cd /d/pango/img_correct/img_correct_backup_vga || exit 1
PDS=/d/pango/PDS_2022.2-SP6.4/bin/pds_shell.exe
SRC=source/img_correct_top.v
PHOTO="C:/Users/16970/.workbuddy/clipboard-images/clipboard-2026-10-31T11-21-47-946Z-bb238e8c.jpg"

cp $SRC $SRC.keep_v46_full
cp rom_ee.hex rom_ee.hex.photo_keep

echo "########## v47  灰阶图 + Gamma 四档轮换 + 仿射关 ##########"
python gen_rom_img.py gray
sed -i "s/parameter GAMMA_DEMO = 1'b0;/parameter GAMMA_DEMO = 1'b1;/" $SRC
sed -i "s/parameter AF_EN = 1'b1;/parameter AF_EN = 1'b0;/" $SRC
grep -n "GAMMA_DEMO =\|AF_EN =" $SRC
$PDS -project img_correct.pds -run gen_bit_stream > build_v47_gray.log 2>&1
echo "v47 E级错误数: $(grep -c '^E:' build_v47_gray.log)"
cp generate_bitstream/img_correct_top.sbit generate_bitstream/burn/v47_gray_gamma.sbit && echo "v47 sbit OK"

echo "########## v48  照片 + Gamma 自适应 + 仿射开 ##########"
python gen_rom_img.py photo "$PHOTO"
sed -i "s/parameter GAMMA_DEMO = 1'b1;/parameter GAMMA_DEMO = 1'b0;/" $SRC
sed -i "s/parameter AF_EN = 1'b0;/parameter AF_EN = 1'b1;/" $SRC
grep -n "GAMMA_DEMO =\|AF_EN =" $SRC
$PDS -project img_correct.pds -run gen_bit_stream > build_v48_photo.log 2>&1
echo "v48 E级错误数: $(grep -c '^E:' build_v48_photo.log)"
cp generate_bitstream/img_correct_top.sbit generate_bitstream/burn/v48_photo_gamma.sbit && echo "v48 sbit OK"

echo "########## DONE ##########"
ls -l generate_bitstream/burn/v47_gray_gamma.sbit generate_bitstream/burn/v48_photo_gamma.sbit
md5sum generate_bitstream/burn/v47_gray_gamma.sbit generate_bitstream/burn/v48_photo_gamma.sbit
