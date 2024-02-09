current_time=$(TZ='Asia/Shanghai' date "+%Y%m%d_%H%M%S")
mv done/new-boot.img Delta_boot_${current_time}.img
mv Delta_boot_${current_time}.img done/
