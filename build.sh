#!/bin/bash

TARGET=rootfs.ext4
label=rootfs
current_path=`pwd`
if [ -f ${TARGET} ];then
    rm ${TARGET}
fi
size=`du -bs $current_path | awk '{print $1}'`
echo "rootfs size=$size"
size=$[size+size/3]

echo "make_ext4fs -L $label -l $size ${TARGET} ./"
make_ext4fs -L $label -s -l $size ${TARGET} ./