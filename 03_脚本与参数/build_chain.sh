#!/bin/bash
# v45 = ROM基线 + SDA仲裁修复；v46 = v43(含Gamma+仿射) + SDA仲裁修复
cd /d/pango/img_correct/img_correct_backup_vga || exit 1
PDS=/d/pango/PDS_2022.2-SP6.4/bin/pds_shell.exe

echo "########## BUILD v45 (ROM + SDA fix) ##########"
$PDS -project img_correct.pds -run gen_bit_stream > build_v45_sdafix.log 2>&1
if [ $? -ne 0 ]; then echo "v45 BUILD FAILED"; fi
grep -c "^E:" build_v45_sdafix.log
cp generate_bitstream/img_correct_top.sbit generate_bitstream/burn/v45_sdafix.sbit && echo "v45 sbit OK"

echo "########## PREPARE v46 (v43 + SDA fix) ##########"
cp source/img_correct_top.v source/img_correct_top.v.v45_sdafix
cp source/img_correct_top.v.keep_v43 source/img_correct_top.v
python apply_sda_fix.py source/img_correct_top.v
grep -n "tx_sda_en\|GAMMA_EN =\|AF_EN =" source/img_correct_top.v

echo "########## BUILD v46 ##########"
$PDS -project img_correct.pds -run gen_bit_stream > build_v46_full.log 2>&1
if [ $? -ne 0 ]; then echo "v46 BUILD FAILED"; fi
grep -c "^E:" build_v46_full.log
cp generate_bitstream/img_correct_top.sbit generate_bitstream/burn/v46_full.sbit && echo "v46 sbit OK"

echo "########## DONE ##########"
ls -l generate_bitstream/burn/v45_sdafix.sbit generate_bitstream/burn/v46_full.sbit
md5sum generate_bitstream/burn/v45_sdafix.sbit generate_bitstream/burn/v46_full.sbit
