find_program(CYGPATH cygpath)
if(CYGPATH)
    execute_process(
        COMMAND cygpath -am ${CMAKE_CURRENT_LIST_DIR}
        OUTPUT_STRIP_TRAILING_WHITESPACE
        OUTPUT_VARIABLE reporoot
        RESULT_VARIABLE rr)
    if(rr)
        message(STATUS "Failed to covert path: ${rr}")
    endif()
else()
    set(reporoot0 ${CMAKE_CURRENT_LIST_DIR})
    # Convert to CMake path for readability
    file(TO_CMAKE_PATH "${reporoot0}" reporoot)
endif()

message(STATUS "reporoot = [${reporoot}]")

set(dry_run FALSE)
if(DEFINED ENV{QSW_DRY_RUN} AND NOT "$ENV{QSW_DRY_RUN}" STREQUAL "")
    string(TOUPPER "$ENV{QSW_DRY_RUN}" qsw_dry_run_env)
    if(NOT qsw_dry_run_env STREQUAL "0" AND NOT qsw_dry_run_env STREQUAL "FALSE" AND NOT qsw_dry_run_env STREQUAL "OFF" AND NOT qsw_dry_run_env STREQUAL "NO")
        set(dry_run TRUE)
    endif()
endif()

set(default_qemu_ref "v11.0.0")
set(qemu_ref "${default_qemu_ref}")
if(DEFINED ENV{QSW_QEMU_VERSION} AND NOT "$ENV{QSW_QEMU_VERSION}" STREQUAL "")
    set(qemu_ref "$ENV{QSW_QEMU_VERSION}")
elseif(DEFINED ENV{QSW_QEMU_REF} AND NOT "$ENV{QSW_QEMU_REF}" STREQUAL "")
    set(qemu_ref "$ENV{QSW_QEMU_REF}")
endif()

set(default_docker_backend "windows")
if(NOT WIN32)
    set(default_docker_backend "linux")
endif()

set(docker_backend "${default_docker_backend}")
if(DEFINED ENV{QSW_DOCKER_BACKEND} AND NOT "$ENV{QSW_DOCKER_BACKEND}" STREQUAL "")
    string(TOLOWER "$ENV{QSW_DOCKER_BACKEND}" docker_backend)
elseif(WIN32 AND DEFINED ENV{QSW_WSL_DISTRO} AND NOT "$ENV{QSW_WSL_DISTRO}" STREQUAL "")
    set(docker_backend "wsl")
endif()

if(WIN32 AND docker_backend STREQUAL "linux")
    set(docker_backend "wsl")
endif()

set(use_windows_container FALSE)
if(docker_backend STREQUAL "windows")
    set(use_windows_container TRUE)
endif()

set(reporoot_in_docker "${reporoot}")
set(docker_image "qemubuild")
set(wsl_project_root)

if(docker_backend STREQUAL "wsl")
    find_program(WSL wsl)
    if(NOT WSL)
        message(FATAL_ERROR "wsl not found in PATH")
    endif()

    set(wsl_distro "$ENV{QSW_WSL_DISTRO}")
    if("${wsl_distro}" STREQUAL "")
        set(wsl_distro "Ubuntu-24.04")
    endif()

    execute_process(
        COMMAND ${WSL} -d ${wsl_distro} wslpath -a ${CMAKE_CURRENT_LIST_DIR}
        OUTPUT_STRIP_TRAILING_WHITESPACE
        OUTPUT_VARIABLE reporoot_in_docker
        RESULT_VARIABLE rr)
    if(rr)
        message(FATAL_ERROR "Failed to convert path to WSL form: ${rr}")
    endif()

    set(wsl_cache_root "$ENV{QSW_WSL_MIRROR_ROOT}")
    if("${wsl_cache_root}" STREQUAL "")
        execute_process(
            COMMAND ${WSL} -d ${wsl_distro} sh -lc "printf '%s/.cache/qemu-static-windows' \"$HOME\""
            OUTPUT_STRIP_TRAILING_WHITESPACE
            OUTPUT_VARIABLE wsl_cache_root
            RESULT_VARIABLE rr)
        if(rr)
            message(FATAL_ERROR "Failed to determine WSL mirror root: ${rr}")
        endif()
    endif()

    get_filename_component(repo_name "${CMAKE_CURRENT_LIST_DIR}" NAME)
    string(SHA256 reporoot_hash "${reporoot}")
    string(SUBSTRING "${reporoot_hash}" 0 12 reporoot_hash_short)
    set(wsl_project_root "${wsl_cache_root}/${repo_name}-${reporoot_hash_short}")

    set(docker_image "qemubuild-linux")
elseif(docker_backend STREQUAL "linux")
    set(docker_image "qemubuild-linux")
elseif(NOT docker_backend STREQUAL "windows")
    message(FATAL_ERROR "Unsupported QSW_DOCKER_BACKEND: ${docker_backend}")
endif()

if(DEFINED ENV{QSW_DOCKER_IMAGE} AND NOT "$ENV{QSW_DOCKER_IMAGE}" STREQUAL "")
    set(docker_image "$ENV{QSW_DOCKER_IMAGE}")
endif()

message(STATUS "docker backend = [${docker_backend}]")
message(STATUS "docker image = [${docker_image}]")
message(STATUS "docker mount root = [${reporoot_in_docker}]")
message(STATUS "qemu ref = [${qemu_ref}]")
if(dry_run)
    message(STATUS "dry run = [TRUE]")
endif()
if(docker_backend STREQUAL "wsl")
    message(STATUS "wsl mirror root = [${wsl_project_root}]")
endif()

find_program(GIT git)
if(NOT GIT)
    message(FATAL_ERROR "git not found in PATH")
endif()

function(resolve_repo_ref repo_relpath repo_ref out_var)
    set(repo_dir "${CMAKE_CURRENT_LIST_DIR}/${repo_relpath}")

    execute_process(
        COMMAND ${GIT} -C ${repo_dir} rev-parse "${repo_ref}^{commit}"
        OUTPUT_STRIP_TRAILING_WHITESPACE
        OUTPUT_VARIABLE repo_commit
        RESULT_VARIABLE resolve_result
        ERROR_QUIET)

    if(resolve_result)
        if(dry_run)
            message(STATUS "Dry-run would fetch ${repo_relpath} to resolve ${repo_ref}")
            set(${out_var} "" PARENT_SCOPE)
            return()
        endif()

        message(STATUS "Fetching ${repo_relpath} refs from origin")
        execute_process(
            COMMAND ${GIT} -C ${repo_dir} fetch --tags origin
            RESULT_VARIABLE fetch_result)
        if(fetch_result)
            message(FATAL_ERROR "Failed to fetch ${repo_relpath} refs from origin")
        endif()

        execute_process(
            COMMAND ${GIT} -C ${repo_dir} rev-parse "${repo_ref}^{commit}"
            OUTPUT_STRIP_TRAILING_WHITESPACE
            OUTPUT_VARIABLE repo_commit
            RESULT_VARIABLE resolve_result
            ERROR_QUIET)
        if(resolve_result)
            message(FATAL_ERROR "Failed to resolve ${repo_relpath} ref ${repo_ref}")
        endif()
    endif()

    set(${out_var} "${repo_commit}" PARENT_SCOPE)
endfunction()

function(ensure_repo_ref repo_relpath repo_ref)
    set(repo_dir "${CMAKE_CURRENT_LIST_DIR}/${repo_relpath}")

    resolve_repo_ref("${repo_relpath}" "${repo_ref}" requested_commit)
    if("${requested_commit}" STREQUAL "")
        return()
    endif()

    execute_process(
        COMMAND ${GIT} -C ${repo_dir} rev-parse HEAD
        OUTPUT_STRIP_TRAILING_WHITESPACE
        OUTPUT_VARIABLE current_commit
        RESULT_VARIABLE current_result)
    if(current_result)
        message(FATAL_ERROR "Failed to read current commit for ${repo_relpath}")
    endif()

    if(current_commit STREQUAL requested_commit)
        message(STATUS "${repo_relpath} already at ${repo_ref}")
        return()
    endif()

    execute_process(
        COMMAND ${GIT} -C ${repo_dir} diff --quiet --ignore-submodules=all --exit-code
        RESULT_VARIABLE worktree_clean)
    execute_process(
        COMMAND ${GIT} -C ${repo_dir} diff --cached --quiet --ignore-submodules=all --exit-code
        RESULT_VARIABLE index_clean)
    if(NOT worktree_clean EQUAL 0 OR NOT index_clean EQUAL 0)
        message(FATAL_ERROR "${repo_relpath} has local changes; cannot switch to ${repo_ref}")
    endif()

    if(dry_run)
        message(STATUS "Dry-run would checkout ${repo_relpath} at ${repo_ref}")
        return()
    endif()

    message(STATUS "Checking out ${repo_relpath} at ${repo_ref}")
    execute_process(
        COMMAND ${GIT} -C ${repo_dir} checkout --detach ${requested_commit}
        RESULT_VARIABLE checkout_result)
    if(checkout_result)
        message(FATAL_ERROR "Failed to checkout ${repo_relpath} at ${repo_ref}")
    endif()

    execute_process(
        COMMAND ${GIT} -C ${repo_dir} submodule sync --recursive
        RESULT_VARIABLE submodule_sync_result)
    if(submodule_sync_result)
        message(FATAL_ERROR "Failed to sync nested submodules for ${repo_relpath}")
    endif()

    execute_process(
        COMMAND ${GIT} -C ${repo_dir} submodule update --init --recursive
        RESULT_VARIABLE submodule_update_result)
    if(submodule_update_result)
        message(FATAL_ERROR "Failed to update nested submodules for ${repo_relpath}")
    endif()

    if(docker_backend STREQUAL "wsl")
        set_property(GLOBAL PROPERTY QSW_DOCKER_SOURCES_READY FALSE)
    endif()
endfunction()

function(apply_repo_patches patch_dir repo_relpath)
    file(GLOB patch_files LIST_DIRECTORIES false "${CMAKE_CURRENT_LIST_DIR}/patches/${patch_dir}/*.patch")
    if(NOT patch_files)
        return()
    endif()

    set(repo_dir "${CMAKE_CURRENT_LIST_DIR}/${repo_relpath}")
    set(sources_changed FALSE)
    foreach(patch_file IN LISTS patch_files)
        get_filename_component(patch_name "${patch_file}" NAME)

        execute_process(
            COMMAND ${GIT} -C ${repo_dir} apply --check ${patch_file}
            RESULT_VARIABLE can_apply
            OUTPUT_QUIET
            ERROR_QUIET)

        if(can_apply EQUAL 0)
            if(dry_run)
                message(STATUS "Patch would apply: ${patch_dir}/${patch_name}")
            else()
                message(STATUS "Applying patch ${patch_dir}/${patch_name}")
                execute_process(
                    COMMAND ${GIT} -C ${repo_dir} apply ${patch_file}
                    RESULT_VARIABLE apply_result)
                if(apply_result)
                    message(FATAL_ERROR "Failed to apply patch ${patch_file}")
                endif()
                set(sources_changed TRUE)
            endif()
        else()
            execute_process(
                COMMAND ${GIT} -C ${repo_dir} apply --reverse --check ${patch_file}
                RESULT_VARIABLE already_applied
                OUTPUT_QUIET
                ERROR_QUIET)
            if(already_applied EQUAL 0)
                message(STATUS "Patch already applied: ${patch_dir}/${patch_name}")
            else()
                message(FATAL_ERROR "Patch ${patch_file} does not apply cleanly")
            endif()
        endif()
    endforeach()

    if(docker_backend STREQUAL "wsl" AND sources_changed)
        set_property(GLOBAL PROPERTY QSW_DOCKER_SOURCES_READY FALSE)
    endif()
endfunction()

function(ensure_docker_sources)
    if(NOT docker_backend STREQUAL "wsl")
        return()
    endif()

    get_property(docker_sources_ready GLOBAL PROPERTY QSW_DOCKER_SOURCES_READY)
    if(docker_sources_ready)
        return()
    endif()

    set(sync_script [=[mkdir -p /srcs-mirror && rm -rf /srcs-mirror/* /srcs-mirror/.[!.]* /srcs-mirror/..?* && tar -C /srcs-host -cf - sources toolchains | tar -C /srcs-mirror -xf - && python3 - <<'PY'
from pathlib import Path
root = Path('/srcs-mirror')
script_suffixes = {'.py', '.sh', '.pl'}
for path in root.rglob('*'):
    if not path.is_file():
        continue
    try:
        data = path.read_bytes()
    except OSError:
        continue
    if b'\r\n' not in data:
        continue
    with path.open('rb') as handle:
        head = handle.readline()
    if not (head.startswith(b'#!') or path.suffix in script_suffixes or path.name == 'configure'):
        continue
    path.write_bytes(data.replace(b'\r\n', b'\n'))
PY]=])

    message(STATUS "Syncing sources into WSL mirror")
    execute_process(COMMAND
        ${WSL} -d ${wsl_distro} docker run --rm
        "-v${reporoot_in_docker}:${dockerroot}srcs-host"
        "-v${wsl_project_root}:${dockerroot}srcs-mirror"
        ${docker_image}
        ${dockershell}
        "${sync_script}"
        RESULT_VARIABLE rr)
    if(rr)
        message(FATAL_ERROR "Failed to sync WSL mirror")
    endif()

    set_property(GLOBAL PROPERTY QSW_DOCKER_SOURCES_READY TRUE)
endfunction()

function(run_docker script)
    if(dry_run)
        message(STATUS "Dry-run docker command: ${script}")
        return()
    endif()

    if(docker_backend STREQUAL "wsl")
        ensure_docker_sources()
        execute_process(COMMAND
            ${WSL} -d ${wsl_distro} docker run ${isolation} --rm
            "-vtmp:${dockerroot}objs"
            "-vlibs:${dockerroot}libs"
            "-vdist:${dockerroot}dist"
            "${docker_source_mount}"
            "-v${reporoot_in_docker}/out:${dockerroot}out"
            ${docker_image}
            ${dockershell} "${script}"
            RESULT_VARIABLE rr)
    else()
        execute_process(COMMAND
            docker run ${isolation} --rm
            "-vtmp:${dockerroot}objs"
            "-vlibs:${dockerroot}libs"
            "-vdist:${dockerroot}dist"
            "-v${reporoot_in_docker}:${dockerroot}srcs"
            "-v${reporoot_in_docker}/out:${dockerroot}out"
            ${docker_image}
            ${dockershell} "${script}"
            RESULT_VARIABLE rr)
    endif()
    if(rr)
        message(FATAL_ERROR "Failed to run ${script}")
    endif()
endfunction()

function(ensure_source_layout_compatible_build_dirs)
    get_property(source_layout_checked GLOBAL PROPERTY QSW_SOURCE_LAYOUT_CHECKED)
    if(source_layout_checked)
        return()
    endif()

    if(use_windows_container)
        set(layout_check_script "mkdir -p ${cmakeroot}objs && rm -rf ${cmakeroot}objs/fakepoxy ${cmakeroot}objs/glib ${cmakeroot}objs/pixman ${cmakeroot}objs/libslirp ${cmakeroot}objs/virglrenderer ${cmakeroot}objs/SDL2 ${cmakeroot}objs/qemu && printf '%s' '${source_root}' > ${cmakeroot}objs/.qsw-source-root")
    else()
        set(layout_check_script "mkdir -p ${cmakeroot}objs && if [ -f ${cmakeroot}objs/.qsw-source-root ] && [ \"$(cat ${cmakeroot}objs/.qsw-source-root)\" = '${source_root}' ]; then :; else rm -rf ${cmakeroot}objs/fakepoxy ${cmakeroot}objs/glib ${cmakeroot}objs/pixman ${cmakeroot}objs/libslirp ${cmakeroot}objs/virglrenderer ${cmakeroot}objs/SDL2 ${cmakeroot}objs/qemu && printf '%s' '${source_root}' > ${cmakeroot}objs/.qsw-source-root; fi")
    endif()

    run_docker("${layout_check_script}")
    set_property(GLOBAL PROPERTY QSW_SOURCE_LAYOUT_CHECKED TRUE)
endfunction()

function(build_meson projname adddef)
    if(use_windows_container AND projname STREQUAL "virglrenderer")
        message(STATUS "Reset Meson build dir for ${projname}")
        run_docker("rm -rf ${cmakeroot}objs/${projname}")
    endif()
    message(STATUS "Meson setup ${projname}")
    run_docker("PKG_CONFIG_PATH=${cmakeroot}libs/lib/pkgconfig ${shell_crosscompile} ${meson} setup --prefix=${cmakeroot}libs --buildtype=release -Ddefault_library=static ${adddef} ${meson_crosscompile} ${source_root}/deps/${projname} ${cmakeroot}objs/${projname}")
    if(use_windows_container AND projname STREQUAL "virglrenderer")
        message(STATUS "Disable Meson thin archives for ${projname}")
        run_docker("sed -i 's/csrDT/csrD/g' ${cmakeroot}objs/${projname}/build.ninja")
    endif()
    message(STATUS "Meson compile ${projname}")
    run_docker("${meson} compile -C ${cmakeroot}objs/${projname}")
    run_docker("${meson} install -C ${cmakeroot}objs/${projname}")
endfunction()

file(MAKE_DIRECTORY ${CMAKE_CURRENT_LIST_DIR}/out)

set(source_root_rel "sources")
set(toolchain_root_rel "toolchains")
set(mingw_cross_file_rel "${toolchain_root_rel}/x86_64-w64-mingw32.txt")

if(use_windows_container)
    set(shell_crosscompile)
    set(meson_crosscompile)
    set(cmake_crosscompile)
    set(qemu_crosscompile)
    set(qemu_iconv_ldflag "--extra-ldflags=-liconv")
    set(cmake_crossflag)
    set(isolation --isolation process)
    set(dockerroot "c:\\")
    set(cmakeroot "c:/")
    set(dockershell "c:\\msys64\\msys2_shell.cmd" -here -no-start -ucrt64 -defterm -c)
    set(cmake "/ucrt64/bin/cmake")
    set(meson "/ucrt64/bin/meson")
else()
    message(STATUS "Crosscompiling...")
    set(shell_crosscompile "CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++ CFLAGS=-mcrtdll=ucrt CXXFLAGS=-mcrtdll=ucrt PKG_CONFIG=pkg-config")
    set(shell_crosscompile_qemu "CFLAGS=-mcrtdll=ucrt CXXFLAGS=-mcrtdll=ucrt PKG_CONFIG=pkg-config")
    set(meson_crosscompile "--cross-file ${cmakeroot}/srcs/${mingw_cross_file_rel}")
    set(qemu_crosscompile "--cross-prefix=x86_64-w64-mingw32- --host-cc=cc --extra-ldflags=-mcrtdll=ucrt")
    set(qemu_iconv_ldflag)
    set(cmake_crosscompile "-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc -DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++ -DCMAKE_C_FLAGS=-mcrtdll=ucrt -DCMAKE_CXX_FLAGS=-mcrtdll=ucrt")
    set(cmake_crossflag "-mcrtdll=ucrt")
    set(isolation)
    set(dockerroot "/")
    set(cmakeroot "/")
    set(dockershell sh -c)
    set(cmake "cmake")
    set(meson "meson")
endif()

set(docker_source_mount "-v${reporoot_in_docker}:${dockerroot}srcs")
if(docker_backend STREQUAL "wsl")
    set(docker_source_mount "-v${wsl_project_root}:${dockerroot}srcs")
    set_property(GLOBAL PROPERTY QSW_DOCKER_SOURCES_READY FALSE)
endif()

set(source_root "${cmakeroot}srcs/${source_root_rel}")

file(MAKE_DIRECTORY ${CMAKE_CURRENT_LIST_DIR}/out)

ensure_repo_ref("${source_root_rel}/qemu" "${qemu_ref}")

ensure_source_layout_compatible_build_dirs()

# GL implementation (Anglembed + Fakepoxy)
apply_repo_patches("anglembed" "${source_root_rel}/anglembed")
message(STATUS "Fakepoxy(Anglembed) configure")
run_docker("${cmake} -G Ninja ${cmake_crosscompile} -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=${cmakeroot}libs -B ${cmakeroot}objs/fakepoxy -S ${source_root}/fakepoxy")
message(STATUS "Fakepoxy(Anglembed) build")
run_docker("${cmake} --build ${cmakeroot}objs/fakepoxy")

# Deps
build_meson(glib "")
build_meson(pixman "")
apply_repo_patches("libslirp" "${source_root_rel}/deps/libslirp")
build_meson(libslirp "")
#build_meson(libepoxy "-Degl=yes")
apply_repo_patches("virglrenderer" "${source_root_rel}/deps/virglrenderer")
build_meson(virglrenderer "")

# SDL2
message(STATUS "SDL2 configure")
run_docker("${cmake} -G Ninja ${cmake_crosscompile} -DSDL_STATIC=ON -DSDL_SHARED=OFF -DSDL_OPENGL=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DCMAKE_BUILD_TYPE=RelWithDebInfo '-DCMAKE_C_FLAGS=-DSDL_VIDEO_STATIC_ANGLE -DKHRONOS_STATIC ${cmake_crossflag}' -DCMAKE_INSTALL_PREFIX=${cmakeroot}libs -B ${cmakeroot}objs/SDL2 -S ${source_root}/deps/SDL2")
message(STATUS "SDL2 build")
run_docker("${cmake} --build ${cmakeroot}objs/SDL2")
message(STATUS "SDL2 install")
run_docker("${cmake} --install ${cmakeroot}objs/SDL2")

# QEMU
apply_repo_patches("qemu" "${source_root_rel}/qemu")
message(STATUS "Reset qemu build dir")
run_docker("rm -rf ${cmakeroot}objs/qemu")
message(STATUS "qemu configure")
run_docker("mkdir -p ${cmakeroot}objs/qemu && cd ${cmakeroot}objs/qemu && ${shell_crosscompile_qemu} PKG_CONFIG_PATH=${cmakeroot}libs/lib/pkgconfig ${source_root}/qemu/configure --enable-whpx --enable-system --enable-slirp --enable-vnc --target-list=aarch64-softmmu,arm-softmmu,avr-softmmu,riscv32-softmmu,riscv64-softmmu,x86_64-softmmu --prefix=${cmakeroot}dist --disable-gio --disable-curl --disable-zstd --disable-bzip2 --disable-curses --disable-gnutls --static --disable-werror '--extra-cflags=-DLIBSLIRP_STATIC ${cmake_crossflag}' ${qemu_iconv_ldflag} ${qemu_crosscompile}")
if(use_windows_container)
    message(STATUS "Disable Meson thin archives for qemu")
    run_docker("sed -i 's/csrDT/csrD/g' ${cmakeroot}objs/qemu/build.ninja")
endif()
message(STATUS "qemu install")
run_docker("ninja -C ${cmakeroot}objs/qemu install")

# Extract files
message(STATUS "Extracting...")
run_docker("cp -rp ${cmakeroot}dist/* ${cmakeroot}/out/")
message(STATUS "Done")
