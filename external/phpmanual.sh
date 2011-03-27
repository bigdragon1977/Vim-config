#!/bin/bash
# Author: Leszek Krupinski <leszek@php.net>
# Last Change: pon lip 01 11:00  2002 C

# Update MANUAL_DIR to be the location of your php manual

BROWSER="lynx"
MANUAL_DIR="MANUAL_DIR="${HOME}/.vim/manual/php/php-chunked-xhtml/""

if [ "$#" -ne 1 ]; then
   echo "Bad number of arguments"
   exit
fi

PLIK=`echo -n "$1" | tr _ -`
FULL="${MANUAL_DIR}function.${PLIK}.html"

if [ ! -f "${FULL}" ]; then
   echo "No manual for that function!"
   exit
else
   $BROWSER $FULL
fi
