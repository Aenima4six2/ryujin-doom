#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
version=${VERSION:-$(<"${repo_dir}/VERSION")}
version=${version#v}
dist_dir=${DIST_DIR:-"${repo_dir}/dist"}
cache_dir=${RYUJIN_DOOM_RELEASE_CACHE:-"${repo_dir}/.cache/release"}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}
windows_runtime_dir=${WINDOWS_RUNTIME_DIR:-}

libusb_version=1.0.30
libusb_url=https://github.com/libusb/libusb/releases/download/v${libusb_version}/libusb-${libusb_version}.tar.bz2
libusb_sha256=fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf
hidapi_version=0.15.0
hidapi_url=https://github.com/libusb/hidapi/archive/refs/tags/hidapi-${hidapi_version}.tar.gz
hidapi_sha256=5d84dec684c27b97b921d2f3b73218cb773cf4ea915caee317ac8fc73cef8136
winsw_version=2.12.0
winsw_url=https://github.com/winsw/winsw/releases/download/v${winsw_version}/WinSW-x64.exe
winsw_sha256=05b82d46ad331cc16bdc00de5c6332c1ef818df8ceefcd49c726553209b3a0da
winsw_license_url=https://raw.githubusercontent.com/winsw/winsw/v${winsw_version}/LICENSE.txt
winsw_license_sha256=1cdf703c10a70e5973bf3acf2a5eeabe7746237155b92db2034aeae26fdf7802
lhm_version=0.9.6
lhm_url=https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/v${lhm_version}/LibreHardwareMonitor.zip
lhm_sha256=086d9f1b5a99e643edc2cfaaac16051685b551e4c5ac0b32a57c58c0e529c001
lhm_license_url=https://raw.githubusercontent.com/LibreHardwareMonitor/LibreHardwareMonitor/v${lhm_version}/LICENSE
lhm_license_sha256=1f256ecad192880510e84ad60474eab7589218784b9a50bc7ceee34c2b91f1d5
lhm_notices_url=https://raw.githubusercontent.com/LibreHardwareMonitor/LibreHardwareMonitor/v${lhm_version}/THIRD-PARTY-NOTICES.txt
lhm_notices_sha256=a60d5ee62f4d700caff38566f42874d554b8b530437c72804fb28b958cfbda9b
pawnio_url=https://raw.githubusercontent.com/LibreHardwareMonitor/LibreHardwareMonitor/v${lhm_version}/LibreHardwareMonitor/Resources/PawnIO_setup.exe
pawnio_sha256=a3a46226c5e2824f4cdd42be0eecbabfc672c86f7889710f5ab1e6ad385b47a0

if [[ $(uname -s) != Linux ]]; then
    echo "build-release.sh must run on Linux" >&2
    exit 1
fi
if [[ ! ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must be a three-part release number such as 1.2.3" >&2
    exit 1
fi

required_commands=(
    awk curl dpkg-deb git install make makensis patch pkg-config rpm rpmbuild
    sed sha256sum tar unzip zip
)
if [[ -z ${windows_runtime_dir} ]]; then
    required_commands+=(cmake x86_64-w64-mingw32-gcc)
fi
missing_commands=()
for command_name in "${required_commands[@]}"; do
    command -v "${command_name}" >/dev/null 2>&1 || missing_commands+=("${command_name}")
done
if (( ${#missing_commands[@]} )); then
    echo "Missing release tools: ${missing_commands[*]}" >&2
    echo "On Ubuntu, install them with:" >&2
    echo "  sudo apt-get install build-essential pkg-config libusb-1.0-0-dev git curl patch zip unzip dpkg-dev rpm nsis" >&2
    echo "  # Add gcc-mingw-w64-x86-64 and cmake only when not supplying WINDOWS_RUNTIME_DIR." >&2
    exit 1
fi

"${repo_dir}/scripts/check-release-tree.sh"

work_dir=$(mktemp -d)
cleanup() {
    find "${work_dir}" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "${dist_dir}" "${cache_dir}"

verify_sha256() {
    local expected=$1
    local path=$2

    [[ -f ${path} ]] && printf '%s  %s\n' "${expected}" "${path}" |
        sha256sum --check --status
}

download_verified() {
    local url=$1
    local expected=$2
    local destination=$3
    local partial="${destination}.part"

    if verify_sha256 "${expected}" "${destination}"; then
        return
    fi
    echo "Downloading ${url##*/}"
    curl -fL "${url}" -o "${partial}"
    if ! verify_sha256 "${expected}" "${partial}"; then
        rm -f "${partial}"
        echo "Checksum verification failed for ${url}" >&2
        exit 1
    fi
    mv -f "${partial}" "${destination}"
}

libusb_archive="${cache_dir}/libusb-${libusb_version}.tar.bz2"
hidapi_archive="${cache_dir}/hidapi-${hidapi_version}.tar.gz"
winsw_exe="${cache_dir}/WinSW-x64-${winsw_version}.exe"
winsw_license="${cache_dir}/WinSW-LICENSE-${winsw_version}.txt"
lhm_archive="${cache_dir}/LibreHardwareMonitor-${lhm_version}.zip"
lhm_license="${cache_dir}/LibreHardwareMonitor-LICENSE-${lhm_version}.txt"
lhm_notices="${cache_dir}/LibreHardwareMonitor-NOTICES-${lhm_version}.txt"
pawnio_setup="${cache_dir}/PawnIO-setup-${lhm_version}.exe"
download_verified "${libusb_url}" "${libusb_sha256}" "${libusb_archive}"
download_verified "${hidapi_url}" "${hidapi_sha256}" "${hidapi_archive}"
download_verified "${winsw_url}" "${winsw_sha256}" "${winsw_exe}"
download_verified "${winsw_license_url}" "${winsw_license_sha256}" "${winsw_license}"
download_verified "${lhm_url}" "${lhm_sha256}" "${lhm_archive}"
download_verified "${lhm_license_url}" "${lhm_license_sha256}" "${lhm_license}"
download_verified "${lhm_notices_url}" "${lhm_notices_sha256}" "${lhm_notices}"
download_verified "${pawnio_url}" "${pawnio_sha256}" "${pawnio_setup}"

windows_prefix="${work_dir}/windows-prefix"
libusb_source="${work_dir}/libusb"
hidapi_source="${work_dir}/hidapi"
lhm_source="${work_dir}/librehardwaremonitor"
lhm_runtime="${work_dir}/hardware-monitor"
mkdir -p "${libusb_source}" "${hidapi_source}" "${windows_prefix}" \
    "${lhm_source}" "${lhm_runtime}"
tar xjf "${libusb_archive}" -C "${libusb_source}" --strip-components=1
tar xzf "${hidapi_archive}" -C "${hidapi_source}" --strip-components=1
unzip -q "${lhm_archive}" -d "${lhm_source}"
install -m 0644 "${lhm_source}"/*.dll "${lhm_runtime}/"
install -m 0644 "${repo_dir}/packaging/windows/cpu-temp.ps1" \
    "${lhm_runtime}/cpu-temp.ps1"

if [[ -n ${windows_runtime_dir} ]]; then
    # GitHub Actions supplies this from a native MSYS2 UCRT64 build on Windows.
    # Keep its runtime pair intact: the executable's import names must exactly
    # match the DLL names installed in the ZIP and setup.exe.
    windows_runtime_dir=$(cd -- "${windows_runtime_dir}" && pwd)
    windows_exe="${windows_runtime_dir}/ryujin-doom.exe"
    windows_libusb_dll="${windows_runtime_dir}/libusb-1.0.dll"
    windows_hidapi_dll="${windows_runtime_dir}/libhidapi-0.dll"
    for runtime_file in "${windows_exe}" "${windows_libusb_dll}" \
        "${windows_hidapi_dll}"; do
        [[ -f ${runtime_file} ]] || {
            echo "Missing native Windows runtime file: ${runtime_file}" >&2
            exit 1
        }
    done
else
    echo "Cross-building shared libusb ${libusb_version}"
    (
        cd "${libusb_source}"
        ./configure --host=x86_64-w64-mingw32 --prefix="${windows_prefix}" \
            --enable-shared --disable-static
        make -j"${jobs}"
        make install
    )

    echo "Cross-building shared HIDAPI ${hidapi_version}"
    cmake -S "${hidapi_source}" -B "${work_dir}/hidapi-build" \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc \
        -DCMAKE_RC_COMPILER=x86_64-w64-mingw32-windres \
        -DCMAKE_INSTALL_PREFIX="${windows_prefix}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DBUILD_SHARED_LIBS=ON \
        -DHIDAPI_BUILD_HIDTEST=OFF \
        -DHIDAPI_WITH_TESTS=OFF
    cmake --build "${work_dir}/hidapi-build" --parallel "${jobs}"
    cmake --install "${work_dir}/hidapi-build"

    echo "Cross-building Windows executable"
    make -C "${repo_dir}" PLATFORM=windows clean
    PKG_CONFIG_LIBDIR="${windows_prefix}/lib/pkgconfig" \
    PKG_CONFIG_PATH= \
    make -C "${repo_dir}" -j"${jobs}" PLATFORM=windows \
        CC=x86_64-w64-mingw32-gcc PKG_CONFIG=pkg-config LDFLAGS='-static-libgcc' all
    windows_exe="${work_dir}/ryujin-doom.exe"
    cp "${repo_dir}/ryujin-doom.exe" "${windows_exe}"
    windows_libusb_dll="${windows_prefix}/bin/libusb-1.0.dll"
    windows_hidapi_dll="${windows_prefix}/bin/libhidapi.dll"
    test -f "${windows_libusb_dll}"
    test -f "${windows_hidapi_dll}"
fi

source_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown/ryujin-doom}"
source_file="${work_dir}/SOURCE.txt"
printf 'Corresponding source code for this build: %s\n' "${source_url}" >"${source_file}"
copying_file="${repo_dir}/LICENSE"
doom_copying_file="${repo_dir}/vendor/doomgeneric/LICENSE"
notices_file="${repo_dir}/THIRD_PARTY_NOTICES.md"

echo "Building native Linux executable"
make -C "${repo_dir}" PLATFORM=linux clean
make -C "${repo_dir}" -j"${jobs}" PLATFORM=linux CC=gcc all
linux_exe="${work_dir}/ryujin-doom"
cp "${repo_dir}/ryujin-doom" "${linux_exe}"

stage_dir="${work_dir}/linux-stage"
install -D -m 0755 "${linux_exe}" "${stage_dir}/usr/lib/ryujin-doom/ryujin-doom"
install -D -m 0755 "${repo_dir}/scripts/fetch-wad.sh" \
    "${stage_dir}/usr/lib/ryujin-doom/fetch-wad.sh"
install -D -m 0755 "${repo_dir}/scripts/ryujin-doom-wad" \
    "${stage_dir}/usr/bin/ryujin-doom-wad"
install -D -m 0644 "${repo_dir}/assets/wads.catalog" \
    "${stage_dir}/usr/share/ryujin-doom/wads.catalog"
install -D -m 0644 "${repo_dir}/packaging/linux/README-WAD.txt" \
    "${stage_dir}/usr/share/ryujin-doom/README-WAD.txt"
install -D -m 0644 "${repo_dir}/README.md" "${stage_dir}/usr/share/doc/ryujin-doom/README.md"
install -D -m 0644 "${copying_file}" "${stage_dir}/usr/share/doc/ryujin-doom/COPYING"
install -D -m 0644 "${doom_copying_file}" \
    "${stage_dir}/usr/share/doc/ryujin-doom/DOOM-COPYING.txt"
install -D -m 0644 "${notices_file}" \
    "${stage_dir}/usr/share/doc/ryujin-doom/THIRD_PARTY_NOTICES.md"
install -D -m 0644 "${source_file}" "${stage_dir}/usr/share/doc/ryujin-doom/SOURCE.txt"
install -D -m 0644 "${repo_dir}/packaging/linux/package/ryujin-doom.service" \
    "${stage_dir}/usr/lib/systemd/system/ryujin-doom.service"
install -D -m 0644 "${repo_dir}/packaging/linux/71-ryujin-doom.rules" \
    "${stage_dir}/usr/lib/udev/rules.d/71-ryujin-doom.rules"
install -d -m 0750 "${stage_dir}/var/lib/ryujin-doom"

deb_root="${work_dir}/deb-root"
cp -a "${stage_dir}" "${deb_root}"
install -d -m 0755 "${deb_root}/DEBIAN"
installed_size=$(du -sk "${stage_dir}" | awk '{ print $1 }')
cat >"${deb_root}/DEBIAN/control" <<EOF
Package: ryujin-doom
Version: ${version}
Section: games
Priority: optional
Architecture: amd64
Maintainer: Ryujin Doom contributors <noreply@example.invalid>
Installed-Size: ${installed_size}
Depends: libc6, libusb-1.0-0, systemd, udev, acl, curl, ca-certificates, unzip, tar
Description: DOOM for the ASUS ROG Ryujin III Extreme LCD
 Runs DOOM attract mode on the cooler LCD and displays live cooler and CPU telemetry.
 Use ryujin-doom-wad to download a free game or import an owned commercial IWAD.
EOF
install -m 0755 "${repo_dir}/packaging/linux/package/post-install.sh" "${deb_root}/DEBIAN/postinst"
install -m 0755 "${repo_dir}/packaging/linux/package/pre-remove-deb.sh" "${deb_root}/DEBIAN/prerm"
install -m 0755 "${repo_dir}/packaging/linux/package/post-remove-deb.sh" "${deb_root}/DEBIAN/postrm"
deb_output="${dist_dir}/ryujin-doom_${version}_amd64.deb"
dpkg-deb --build --root-owner-group "${deb_root}" "${deb_output}"

rpm_top="${work_dir}/rpmbuild"
rpm_db="${rpm_top}/rpmdb"
mkdir -p "${rpm_top}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} "${rpm_db}"
rpm --dbpath "${rpm_db}" --initdb
github_repository=${GITHUB_REPOSITORY:-unknown/ryujin-doom}
sed \
    -e "s|@VERSION@|${version}|g" \
    -e "s|@STAGE_DIR@|${stage_dir}|g" \
    -e "s|@GITHUB_REPOSITORY@|${github_repository}|g" \
    "${repo_dir}/packaging/rpm/ryujin-doom.spec.in" >"${rpm_top}/SPECS/ryujin-doom.spec"
rpmbuild --dbpath "${rpm_db}" --define "_topdir ${rpm_top}" \
    -bb "${rpm_top}/SPECS/ryujin-doom.spec"
rpm_built=$(find "${rpm_top}/RPMS" -type f -name '*.rpm' -print -quit)
rpm_output="${dist_dir}/ryujin-doom-${version}.x86_64.rpm"
cp "${rpm_built}" "${rpm_output}"

linux_bundle="${work_dir}/ryujin-doom-${version}-linux-x86_64"
mkdir -p "${linux_bundle}"
install -m 0755 "${linux_exe}" "${linux_bundle}/ryujin-doom"
install -m 0755 "${repo_dir}/scripts/ryujin-doom-wad" "${linux_bundle}/ryujin-doom-wad"
install -m 0755 "${repo_dir}/scripts/fetch-wad.sh" "${linux_bundle}/fetch-wad.sh"
install -m 0644 "${repo_dir}/assets/wads.catalog" "${linux_bundle}/wads.catalog"
install -m 0644 "${repo_dir}/README.md" "${linux_bundle}/README.md"
install -m 0644 "${copying_file}" "${linux_bundle}/COPYING"
install -m 0644 "${doom_copying_file}" "${linux_bundle}/DOOM-COPYING.txt"
install -m 0644 "${notices_file}" "${linux_bundle}/THIRD_PARTY_NOTICES.md"
install -m 0644 "${source_file}" "${linux_bundle}/SOURCE.txt"
tar -C "${work_dir}" -czf \
    "${dist_dir}/ryujin-doom-${version}-linux-x86_64.tar.gz" \
    "$(basename "${linux_bundle}")"

windows_bundle="${work_dir}/ryujin-doom-${version}-windows-x86_64"
mkdir -p "${windows_bundle}"
install -m 0755 "${windows_exe}" "${windows_bundle}/ryujin-doom.exe"
install -m 0755 "${windows_libusb_dll}" "${windows_bundle}/libusb-1.0.dll"
install -m 0755 "${windows_hidapi_dll}" \
    "${windows_bundle}/$(basename "${windows_hidapi_dll}")"
install -m 0755 "${winsw_exe}" "${windows_bundle}/ryujin-doom-service.exe"
install -m 0644 "${repo_dir}/packaging/windows/ryujin-doom-service.xml" \
    "${windows_bundle}/ryujin-doom-service.xml"
install -m 0644 "${repo_dir}/scripts/ryujin-doom-wad.ps1" \
    "${windows_bundle}/ryujin-doom-wad.ps1"
install -m 0644 "${repo_dir}/packaging/windows/stop-hardware-monitor.ps1" \
    "${windows_bundle}/stop-hardware-monitor.ps1"
install -m 0644 "${repo_dir}/packaging/windows/armoury-crate-stop.ps1" \
    "${windows_bundle}/armoury-crate-stop.ps1"
install -m 0644 "${repo_dir}/packaging/windows/armoury-crate-restore.ps1" \
    "${windows_bundle}/armoury-crate-restore.ps1"
install -m 0644 "${repo_dir}/packaging/windows/ryujin-doom-service.ps1" \
    "${windows_bundle}/ryujin-doom-service.ps1"
install -m 0644 "${repo_dir}/assets/wads.catalog" "${windows_bundle}/wads.catalog"
install -m 0644 "${repo_dir}/README.md" "${windows_bundle}/README.md"
install -m 0644 "${copying_file}" "${windows_bundle}/COPYING.txt"
install -m 0644 "${doom_copying_file}" "${windows_bundle}/DOOM-COPYING.txt"
install -m 0644 "${notices_file}" "${windows_bundle}/THIRD_PARTY_NOTICES.md"
install -m 0644 "${libusb_source}/COPYING" "${windows_bundle}/LIBUSB-LGPL-2.1.txt"
install -m 0644 "${hidapi_source}/LICENSE.txt" "${windows_bundle}/HIDAPI-LICENSE.txt"
install -m 0644 "${hidapi_source}/LICENSE-gpl3.txt" \
    "${windows_bundle}/HIDAPI-GPL-3.0.txt"
install -m 0644 "${winsw_license}" "${windows_bundle}/WINSW-MIT.txt"
install -m 0644 "${lhm_license}" "${windows_bundle}/LIBREHARDWAREMONITOR-MPL-2.0.txt"
install -m 0644 "${lhm_notices}" "${windows_bundle}/LIBREHARDWAREMONITOR-NOTICES.txt"
install -m 0755 "${pawnio_setup}" "${windows_bundle}/PawnIO_setup.exe"
cp -a "${lhm_runtime}" "${windows_bundle}/hardware-monitor"
install -m 0644 "${source_file}" "${windows_bundle}/SOURCE.txt"
(
    cd "${work_dir}"
    zip -qr "${dist_dir}/ryujin-doom-${version}-windows-x86_64.zip" \
        "$(basename "${windows_bundle}")"
)

setup_output="${dist_dir}/ryujin-doom-${version}-setup.exe"
makensis -WX \
    "-DVERSION=${version}" \
    "-DOUTPUT_FILE=${setup_output}" \
    "-DRYUJIN_DOOM_EXE=${windows_exe}" \
    "-DLIBUSB_DLL=${windows_libusb_dll}" \
    "-DHIDAPI_DLL=${windows_hidapi_dll}" \
    "-DHIDAPI_DLL_NAME=$(basename "${windows_hidapi_dll}")" \
    "-DWINSW_EXE=${winsw_exe}" \
    "-DSERVICE_XML=${repo_dir}/packaging/windows/ryujin-doom-service.xml" \
    "-DCOPYING_FILE=${copying_file}" \
    "-DDOOM_COPYING_FILE=${doom_copying_file}" \
    "-DNOTICES_FILE=${notices_file}" \
    "-DLIBUSB_LICENSE=${libusb_source}/COPYING" \
    "-DHIDAPI_LICENSE=${hidapi_source}/LICENSE.txt" \
    "-DHIDAPI_GPL_LICENSE=${hidapi_source}/LICENSE-gpl3.txt" \
    "-DWINSW_LICENSE=${winsw_license}" \
    "-DHARDWARE_MONITOR_DIR=${lhm_runtime}" \
    "-DPAWNIO_SETUP=${pawnio_setup}" \
    "-DLHM_LICENSE=${lhm_license}" \
    "-DLHM_NOTICES=${lhm_notices}" \
    "-DSOURCE_FILE=${source_file}" \
    "-DWAD_HELPER=${repo_dir}/scripts/ryujin-doom-wad.ps1" \
    "-DWAD_CATALOG=${repo_dir}/assets/wads.catalog" \
    "-DWAD_README=${repo_dir}/packaging/windows/README-WAD.txt" \
    "-DSTOP_HARDWARE_MONITOR=${repo_dir}/packaging/windows/stop-hardware-monitor.ps1" \
    "-DARMOURY_STOP=${repo_dir}/packaging/windows/armoury-crate-stop.ps1" \
    "-DARMOURY_RESTORE=${repo_dir}/packaging/windows/armoury-crate-restore.ps1" \
    "-DSERVICE_RUNNER=${repo_dir}/packaging/windows/ryujin-doom-service.ps1" \
    "${repo_dir}/packaging/windows/installer.nsi"

checksum_output="${dist_dir}/SHA256SUMS-${version}.txt"
(
    cd "${dist_dir}"
    sha256sum \
        "$(basename "${deb_output}")" \
        "$(basename "${rpm_output}")" \
        "$(basename "${setup_output}")" \
        "ryujin-doom-${version}-linux-x86_64.tar.gz" \
        "ryujin-doom-${version}-windows-x86_64.zip" \
        >"$(basename "${checksum_output}")"
)

echo "Release assets created in ${dist_dir}:"
printf '  %s\n' \
    "$(basename "${checksum_output}")" \
    "$(basename "${deb_output}")" \
    "$(basename "${rpm_output}")" \
    "$(basename "${setup_output}")" \
    "ryujin-doom-${version}-linux-x86_64.tar.gz" \
    "ryujin-doom-${version}-windows-x86_64.zip"
