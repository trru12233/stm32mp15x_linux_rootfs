#!/bin/sh -
# Author dengzhimao@alientek.com
# Date: 2021.07.16
sleep 1
modules=$(uname -r)
path=/boot/$modules
if [ -d $path ]; then
    ln -s -f /boot/$modules /lib/modules/$modules
else
   echo "link modules failed: /boot/$modules does not exist!" > /dev/ttySTM0
fi

