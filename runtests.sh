#!/bin/sh
# runtests.sh --
#    Bourne shell script to control a program that uses funit
#    Name of the program: first argument
#
#    $Id: runtests.sh,v 1.2 2008/01/26 11:15:10 arjenmarkus Exp $
#
set -e 
echo "Compiling code"
make -s


if [ ! -d test_wavefields ] ; then
    echo "Downloading test wavefield files"
    wget http://geophysik.uni-muenchen.de/~staehler/test_wavefields.tar.gz
    echo "Unpacking test wavefield files"
    tar -xf test_wavefields.tar.gz
fi

if test -f OUTPUT_test ; then
    rm OUTPUT_test
fi

if test -f runtests.log ; then
    rm runtests.log
fi

echo "Running test"
set +e 
echo ALL >ftnunit.run

chk=1
until test ! -f ftnunit.lst -a $chk -eq 0 ; do
    chk=0
    #valgrind --tool=memcheck $1 $2 $3 $4 $5 $6 $7 $8 $9 >>runtests.log 2>&1
    $1 $2 $3 $4 $5 $6 $7 $8 $9 >>runtests.log 2>&1
done

rm ftnunit.run
