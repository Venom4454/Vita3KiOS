# Hinoki's 3DS core: Azahar as one dynamic library with a small C API (hinoki_azahar.h).
# Added to Azahar's tree by vita3k/ios/n3ds/azahar/apply.py (as src/hinoki).

add_library(azahar_hinoki SHARED
    hinoki_azahar.cpp
    hinoki_azahar.h
    hinoki_sink.cpp
)

set_target_properties(azahar_hinoki PROPERTIES
    OUTPUT_NAME "azahar_hinoki"
    PREFIX "lib"
    INSTALL_NAME_DIR "@rpath"
    BUILD_WITH_INSTALL_NAME_DIR ON
)

target_link_libraries(azahar_hinoki PRIVATE
    audio_core citra_common citra_core input_common network video_core
    Boost::boost Threads::Threads fmt::fmt
)

if (APPLE)
    target_link_libraries(azahar_hinoki PRIVATE
        "-framework Foundation" "-framework AVFoundation" "-framework AudioToolbox"
        "-framework CoreAudio" "-framework IOSurface" "-framework Metal" "-framework QuartzCore"
        "-Wl,-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/exports.txt"
        "-Wl,-dead_strip"
    )
endif()
