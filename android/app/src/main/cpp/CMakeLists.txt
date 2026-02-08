cmake_minimum_required(VERSION 3.22.1)
project("mirror")

add_library(mirror SHARED
    mirror_native.c
    lz4.c
)

target_include_directories(mirror PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

target_link_libraries(mirror
    android   # ANativeWindow
    log       # __android_log_print
)
