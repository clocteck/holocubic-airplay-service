idf_component_register(
    SRCS
        "build_stub.c"
    INCLUDE_DIRS
        "."
    REQUIRES
        espressif__esp_audio_codec
)

# The firmware loads modules through its stable module_abi.h, so build the
# actual core as a self-contained PIC shared object instead of linking it into
# this throw-away IDF application. This intentionally does not depend on the
# elf_loader component's host sources (which lag IDF 6), only on its ELF format.
idf_build_get_property(airplay_build_dir BUILD_DIR)
idf_build_get_property(airplay_include_dirs COMPILE_INCLUDE_DIRECTORIES)
idf_build_get_property(airplay_compile_defs COMPILE_DEFINITIONS)
idf_component_get_property(airplay_codec_dir espressif__esp_audio_codec COMPONENT_DIR)

set(airplay_so_obj_dir "${airplay_build_dir}/airplay_core_objs")
set(airplay_so_output "${airplay_build_dir}/airplay_core.so")
set(airplay_package_output "${CMAKE_SOURCE_DIR}/../package/modules/airplay_core.so")
set(airplay_patched_lib_dir "${airplay_build_dir}/patched_libs")
set(airplay_patched_codec_lib "${airplay_patched_lib_dir}/libesp_audio_codec_airplay_picfix.a")
string(REPLACE "-elf-gcc" "-elf-objcopy" airplay_objcopy "${CMAKE_C_COMPILER}")
string(REPLACE "-elf-gcc" "-elf-strip" airplay_strip "${CMAKE_C_COMPILER}")

add_custom_command(
    OUTPUT "${airplay_patched_codec_lib}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${airplay_patched_lib_dir}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${airplay_codec_dir}/lib/${IDF_TARGET}/libesp_audio_codec.a"
            "${airplay_patched_codec_lib}"
    COMMAND "${airplay_objcopy}"
            --rename-section .rodata.dec_lib$0=.data.airplay_dec_lib,alloc,load,contents,data
            --rename-section .iram1=.text.airplay_iram,alloc,load,contents,code
            --rename-section .iram1.literal=.literal.airplay_iram,alloc,load,contents
            "${airplay_patched_codec_lib}"
    DEPENDS "${airplay_codec_dir}/lib/${IDF_TARGET}/libesp_audio_codec.a"
    VERBATIM
)

set(airplay_include_flags
    "-I${CMAKE_CURRENT_SOURCE_DIR}"
    "-I${airplay_build_dir}/config"
    "-I${IDF_PATH}/components/esp_common/include"
    "-I${IDF_PATH}/components/esp_hw_support/include"
    "-I${airplay_codec_dir}/include"
    "-I${airplay_codec_dir}/include/decoder"
    "-I${airplay_codec_dir}/include/decoder/impl"
)
foreach(include_dir IN LISTS airplay_include_dirs)
    list(APPEND airplay_include_flags "-I${include_dir}")
endforeach()

set(airplay_definition_flags "")
foreach(definition IN LISTS airplay_compile_defs)
    list(APPEND airplay_definition_flags "-D${definition}")
endforeach()

set(airplay_compile_flags
    -c
    -std=gnu17
    # Keep the production dynamic module at the qualified size-optimised
    # setting.  The -O2 variant caused a launcher restart while iPhone
    # negotiated encrypted ALAC, so it must not ship until root-caused.
    -Os
    -Wall
    -Wextra
    -Werror
    -fPIC
    -fvisibility=hidden
    -fdata-sections
    -ffunction-sections
    -fno-jump-tables
    -fno-tree-switch-conversion
    -fno-builtin-memcpy
    -fno-builtin-memmove
    -fno-builtin-memset
    -fno-builtin-strlen
    -fno-builtin-strcpy
    -fno-builtin-malloc
    -fno-builtin-calloc
    -fno-builtin-realloc
    -fno-builtin-free
)

set(airplay_so_objects "")
foreach(source_file IN ITEMS airplay_core.c airplay_crypto.c)
    string(REPLACE ".c" ".o" object_name "${source_file}")
    set(object_file "${airplay_so_obj_dir}/${object_name}")
    list(APPEND airplay_so_objects "${object_file}")
    add_custom_command(
        OUTPUT "${object_file}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${airplay_so_obj_dir}"
        COMMAND ${CMAKE_C_COMPILER}
                ${airplay_compile_flags}
                ${airplay_definition_flags}
                ${airplay_include_flags}
                "${CMAKE_CURRENT_SOURCE_DIR}/${source_file}"
                -o "${object_file}"
        DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/${source_file}"
                "${CMAKE_CURRENT_SOURCE_DIR}/airplay_crypto.h"
                "${CMAKE_CURRENT_SOURCE_DIR}/airplay_socket_abi.h"
                "${CMAKE_CURRENT_SOURCE_DIR}/module_abi.h"
        VERBATIM
    )
endforeach()

set(airplay_link_flags
    -shared
    -fPIC
    -static-libgcc
    -nostdlib
    -nostartfiles
    -Wl,-Bsymbolic
    -Wl,--gc-sections
    -Wl,--exclude-libs,ALL
    -Wl,--allow-shlib-undefined
    -Wl,-z,notext
    -Wl,--no-check-sections
    -Wl,-N
    -Wl,-Map,${airplay_build_dir}/airplay_core_so.map
)

add_custom_command(
    OUTPUT "${airplay_so_output}"
    COMMAND ${CMAKE_C_COMPILER}
            ${airplay_link_flags}
            -o "${airplay_so_output}"
            ${airplay_so_objects}
            "${airplay_patched_codec_lib}"
            -lgcc
    COMMAND "${airplay_strip}"
            --strip-unneeded
            --remove-section=.comment
            --remove-section=.got.loc
            --remove-section=.dynamic
            --remove-section=.xt.lit
            --remove-section=.xt.prop
            --remove-section=.xtensa.info
            "${airplay_so_output}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_SOURCE_DIR}/../package/modules"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${airplay_so_output}" "${airplay_package_output}"
    DEPENDS ${airplay_so_objects} "${airplay_patched_codec_lib}"
    VERBATIM
)

add_custom_target(airplay_core_so DEPENDS "${airplay_so_output}")
