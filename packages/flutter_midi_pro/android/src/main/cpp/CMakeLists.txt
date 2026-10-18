# For more information about using CMake with Android Studio, read the
# documentation: https://d.android.com/studio/projects/add-native-code.html

# Sets the minimum version of CMake required to build the native library.
cmake_minimum_required(VERSION 3.4.1)

# Create a variable fluidsynth_DIR to specify where the fluidsynth library is located.
set(fluidsynth_DIR ${CMAKE_CURRENT_SOURCE_DIR}/fluidsynth)
set(fluidsynth_lib_dir ${fluidsynth_DIR}/lib/${ANDROID_ABI})
set(CMAKE_ANDROID_STL_TYPE c++_static)

# Validate/import prebuilt libraries from the ABI-specific directory.
function(import_required_prebuilt target_name)
    set(lib_path "${fluidsynth_lib_dir}/${target_name}.so")
    if(NOT EXISTS "${lib_path}")
        message(FATAL_ERROR "Missing required prebuilt library for ${ANDROID_ABI}: ${lib_path}")
    endif()
    add_library(${target_name} SHARED IMPORTED)
    set_target_properties(${target_name} PROPERTIES IMPORTED_LOCATION "${lib_path}")
endfunction()

function(import_optional_prebuilt target_name)
    set(lib_path "${fluidsynth_lib_dir}/${target_name}.so")
    if(EXISTS "${lib_path}")
        add_library(${target_name} SHARED IMPORTED)
        set_target_properties(${target_name} PROPERTIES IMPORTED_LOCATION "${lib_path}")
    endif()
endfunction()

set(FLUIDSYNTH_REQUIRED_LIBS
    libFLAC
    libfluidsynth
    libfluidsynth-assetloader
    libgio-2.0
    libglib-2.0
    libgmodule-2.0
    libgobject-2.0
    libgthread-2.0
    libinstpatch-1.0
    liboboe
    libogg
    libopus
    libpcre
    libpcreposix
    libsndfile
    libvorbis
    libvorbisenc
    libvorbisfile
)

foreach(lib_name IN LISTS FLUIDSYNTH_REQUIRED_LIBS)
    import_required_prebuilt(${lib_name})
endforeach()

set(cxx_shared_path "${fluidsynth_lib_dir}/libc++_shared.so")
if(NOT EXISTS "${cxx_shared_path}")
    message(FATAL_ERROR "Missing required prebuilt C++ runtime for ${ANDROID_ABI}: ${cxx_shared_path}")
endif()
add_library(cxx_shared SHARED IMPORTED)
set_target_properties(cxx_shared PROPERTIES IMPORTED_LOCATION "${cxx_shared_path}")

# Library that will be called directly from JAVA
add_library(native-lib SHARED native-lib.cpp)

# 16 KB ELF alignment required for arm64-v8a / x86_64 on Android 15+ (Google Play).
target_link_options(native-lib PRIVATE
    "-Wl,-z,max-page-size=16384"
    "-Wl,-z,common-page-size=16384"
)

# Specifies the directory where the C or C++ source coude will look the #include <yourlibrary.h> header files
target_include_directories(native-lib PRIVATE ${fluidsynth_DIR}/include)

# Link everything alltogether. Notice that native-lib should be the first element in the list.
target_link_libraries(
        native-lib
        cxx_shared
        libFLAC
        libfluidsynth
        libfluidsynth-assetloader
        libgio-2.0
        libglib-2.0
        libgmodule-2.0
        libgobject-2.0
        libgthread-2.0
        libinstpatch-1.0
        liboboe
        libogg
        libopus
        libpcre
        libpcreposix
        libsndfile
        libvorbis
        libvorbisenc
        libvorbisfile
        android
        log
)