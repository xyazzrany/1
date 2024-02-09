Magiskboot=bin/magiskboot
BOOTIMAGE="$1"

# Flags
[ -z $KEEPVERITY ] && KEEPVERITY=false
[ -z $KEEPFORCEENCRYPT ] && KEEPFORCEENCRYPT=false
[ -z $PATCHVBMETAFLAG ] && PATCHVBMETAFLAG=false
[ -z $RECOVERYMODE ] && RECOVERYMODE=false
[ -z $SYSTEM_ROOT ] && SYSTEM_ROOT=false
[ -z $ISENCRYPTED ] && ISENCRYPTED=false
export KEEPVERITY
export KEEPFORCEENCRYPT
export PATCHVBMETAFLAG

#########
# Unpack
#########

CHROMEOS=false

echo "Unpacking boot image"
$Magiskboot unpack "$BOOTIMAGE"

case $? in
  0 ) ;;
  1 )
    echo "Unsupported/Unknown image format"
    ;;
  2 )
    echo "ChromeOS boot image detected"
    ;;
  * )
    echo "Unable to unpack boot image"
    ;;
esac

###################
# Ramdisk Restores
###################

# Test patch status and do restore
echo "Checking ramdisk status"
if [ -e ramdisk.cpio ]; then
  $Magiskboot cpio ramdisk.cpio test
  STATUS=$?
else
  # Stock A only legacy SAR, or some Android 13 GKIs
  STATUS=0
fi
case $((STATUS & 3)) in
  0 )  # Stock boot
    echo "Stock boot image detected"
    SHA1=$($Magiskboot sha1 "$BOOTIMAGE")
    cat $BOOTIMAGE > stock_boot.img
    cp -af ramdisk.cpio ramdisk.cpio.orig
    ;;
  1 )  # Magisk patched
    echo "Magisk patched boot image detected"
    # Find SHA1 of stock boot image
    [ -z $SHA1 ] && SHA1=$($Magiskboot cpio ramdisk.cpio sha1)
    $Magiskboot cpio ramdisk.cpio restore
    cp -af ramdisk.cpio ramdisk.cpio.orig
    rm -f stock_boot.img
    ;;
  2 )  # Unsupported
    echo "Boot image patched by unsupported programs"
    echo "Please restore back to stock boot image"
    ;;
esac

# Work around custom legacy Sony /init -> /(s)bin/init_sony : /init.real setup
INIT=init
if [ $((STATUS & 4)) -ne 0 ]; then
  INIT=init.real
fi

##################
# Ramdisk Patches
##################

echo "- Patching ramdisk"

echo -n "RANDOMSEED=" > config
# https://github.com/topjohnwu/Magisk/pull/6340#issuecomment-1287594661
tr -dc A-Za-z0-9 </dev/urandom | head -c 8 >> config
echo -ne "\n" >> config
echo "KEEPVERITY=$KEEPVERITY" >> config
echo "KEEPFORCEENCRYPT=$KEEPFORCEENCRYPT" >> config
echo "PATCHVBMETAFLAG=$PATCHVBMETAFLAG" >> config
echo "RECOVERYMODE=$RECOVERYMODE" >> config
[ ! -z $SHA1 ] && echo "SHA1=$SHA1" >> config

# Compress to save precious ramdisk space
$Magiskboot compress=xz bin/magisk32 magisk32.xz
$Magiskboot compress=xz bin/magisk64 magisk64.xz
$Magiskboot compress=xz bin/stub.apk stub.xz

$Magiskboot cpio ramdisk.cpio \
"add 0750 $INIT bin/magiskinit" \
"mkdir 0750 overlay.d" \
"mkdir 0750 overlay.d/sbin" \
"add 0644 overlay.d/sbin/magisk32.xz magisk32.xz" \
"add 0644 overlay.d/sbin/magisk64.xz magisk64.xz" \
"add 0644 overlay.d/sbin/stub.xz stub.xz" \
"patch" \
"backup ramdisk.cpio.orig" \
"mkdir 000 .backup" \
"add 000 .backup/.magisk config"

rm -rf ramdisk.cpio.orig config magisk*.xz stub.xz stub.apk

#################
# Binary Patches
#################

for dt in dtb kernel_dtb extra; do
  [ -f $dt ] && $Magiskboot dtb $dt patch && echo "Patch fstab in $dt"
done

if [ -f kernel ]; then
  PATCHEDKERNEL=false
  # Remove Samsung RKP
  $Magiskboot hexpatch kernel \
  49010054011440B93FA00F71E9000054010840B93FA00F7189000054001840B91FA00F7188010054 \
  A1020054011440B93FA00F7140020054010840B93FA00F71E0010054001840B91FA00F7181010054 \
  && PATCHEDKERNEL=true

  # Remove Samsung defex
  # Before: [mov w2, #-221]   (-__NR_execve)
  # After:  [mov w2, #-32768]
  $Magiskboot hexpatch kernel 821B8012 E2FF8F12 && PATCHEDKERNEL=true

  # Force kernel to load rootfs for legacy SAR devices
  # skip_initramfs -> want_initramfs
  $SYSTEM_ROOT && $Magiskboot hexpatch kernel \
  736B69705F696E697472616D667300 \
  77616E745F696E697472616D667300 \
  && PATCHEDKERNEL=true

  # If the kernel doesn't need to be patched at all,
  # keep raw kernel to avoid bootloops on some weird devices
  $PATCHEDKERNEL || rm -f kernel
fi

#################
# Repack & Flash
#################
echo "打包boot"
$Magiskboot repack "$BOOTIMAGE"  || echo "打包完成"

rm -rf stock_boot.img *kernel* *dtb* ramdisk.cpio*
