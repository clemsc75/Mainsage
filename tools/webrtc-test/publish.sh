#!/usr/bin/env bash
# Publie une vidéo de test 9:16 vers MediaMTX (RTSP) avec le numéro d'image
# écrit en binaire (16 carrés de 16 px en haut à gauche) et en clair.
# Usage : ./publish.sh [rtsp://hote:8554/test] [images_par_seconde]
set -euo pipefail
URL="${1:-rtsp://localhost:8554/test}"
FPS="${2:-25}"
date +%s%3N > start.txt   # instant de départ (ms), lu par la page pour estimer la latence
BITS="geq=lum='if(lt(X,256)*lt(Y,16),255*bitand(floor(N/pow(2,floor(X/16))),1),lum(X,Y))':cb='cb(X,Y)':cr='cr(X,Y)'"
exec ffmpeg -re -f lavfi -i "testsrc2=size=540x960:rate=${FPS}" \
  -vf "${BITS}" \
  -c:v libx264 -preset ultrafast -tune zerolatency -g "${FPS}" -bf 0 -pix_fmt yuv420p \
  -f rtsp -rtsp_transport tcp "${URL}"
