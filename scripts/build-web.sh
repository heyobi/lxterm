#!/bin/sh
# The accelerated engine's core (Settings › Accelerated engine): the same core and lxrun built
# for WebAssembly with Emscripten, plus the network and shared-folder bridges, as
# lxios/web/lxweb.js + lxweb.wasm. lxios/web/engine.js runs it in a worker of a hidden
# WKWebView (lxios/LxTerm/WebEngine.swift).
set -eu
cd "$(dirname "$0")/.."
CORE=$(ls core/*.c | grep -v oracle.c)
emcc -O2 -std=gnu11 -w     -sENVIRONMENT=worker -sMODULARIZE=1 -sEXPORT_NAME=createLx -sINVOKE_RUN=0 -sFORCE_FILESYSTEM=1     -sEXPORTED_RUNTIME_METHODS=FS,callMain,ENV -sALLOW_MEMORY_GROWTH=1 -sALLOW_TABLE_GROWTH=1 -sMAXIMUM_MEMORY=4GB -sSTACK_SIZE=8MB     -sEXIT_RUNTIME=1 --post-js lxios/webjs/netbridge.js --post-js lxios/webjs/filesbridge.js     -o lxios/web/lxweb.js tools/lxrun.c $CORE
ls -la lxios/web
