cmake_minimum_required(VERSION 3.18)
project(s2p C)

# Исходники ядра лежат в корне репозитория: core/*.c — те же, что использует прототип на Python.
set(CORE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../core)

add_library(s2p SHARED
    ${CORE_DIR}/jbig2_generic.c
    ${CORE_DIR}/s2p_page.c)

target_compile_options(s2p PRIVATE -O2 -Wall -Wextra)
target_link_libraries(s2p m)
# Совместимость со страницами памяти 16 КБ (Android 15+)
target_link_options(s2p PRIVATE "-Wl,-z,max-page-size=16384")
