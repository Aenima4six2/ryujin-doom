#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
catalog=${RYUJIN_DOOM_WAD_CATALOG:-"${repo_dir}/assets/wads.catalog"}
wad_dir=${RYUJIN_DOOM_WAD_DIR:-"${repo_dir}/wads"}
cache_dir=${RYUJIN_DOOM_WAD_CACHE:-"${wad_dir}/.cache"}
temporary=

cleanup() {
    if [[ -n ${temporary} ]]; then
        rm -f -- "${temporary}"
    fi
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage:
  fetch-wad.sh list
  fetch-wad.sh fetch <id> [<id> ...]
  fetch-wad.sh fetch all
  fetch-wad.sh path <id>
EOF
}

find_record() {
    local requested=$1

    awk -F '|' -v requested="${requested}" '
        $0 !~ /^#/ && $1 == requested { print; found = 1; exit }
        END { if (!found) exit 1 }
    ' "${catalog}"
}

verify_sha256() {
    local expected=$1
    local path=$2

    [[ -f ${path} ]] && printf '%s  %s\n' "${expected}" "${path}" |
        sha256sum --check --status
}

list_wads() {
    printf '%-16s %-24s %-8s %s\n' ID TITLE VERSION LICENSE
    awk -F '|' '
        $0 !~ /^#/ { printf "%-16s %-24s %-8s %s\n", $1, $2, $3, $10 }
    ' "${catalog}"
}

wad_path() {
    local record
    local id title version url archive_sha format member output output_sha license

    record=$(find_record "$1") || {
        echo "Unknown WAD '$1'; run '$0 list' to see available IDs" >&2
        return 1
    }
    IFS='|' read -r id title version url archive_sha format member output output_sha license <<<"${record}"
    printf '%s/%s\n' "${wad_dir}" "${output}"
}

fetch_one() {
    local requested=$1
    local record id title version url archive_sha format member output output_sha license
    local archive part destination

    record=$(find_record "${requested}") || {
        echo "Unknown WAD '${requested}'; run '$0 list' to see available IDs" >&2
        return 1
    }
    IFS='|' read -r id title version url archive_sha format member output output_sha license <<<"${record}"

    case "${output}" in
        *.wad) ;;
        *) echo "Unsafe catalog output '${output}'" >&2; return 1 ;;
    esac

    mkdir -p "${wad_dir}" "${cache_dir}"
    destination="${wad_dir}/${output}"
    if verify_sha256 "${output_sha}" "${destination}"; then
        echo "${title} ${version} already verified: ${destination}"
        return
    fi

    archive="${cache_dir}/${url##*/}"
    if ! verify_sha256 "${archive_sha}" "${archive}"; then
        part="${archive}.part"
        echo "Downloading ${title} ${version}"
        curl -fL --connect-timeout 10 --max-time 180 --retry 2 \
            "${url}" -o "${part}"
        if ! verify_sha256 "${archive_sha}" "${part}"; then
            rm -f "${part}"
            echo "Checksum verification failed for ${url}" >&2
            return 1
        fi
        mv -f "${part}" "${archive}"
    fi

    temporary=$(mktemp "${wad_dir}/.${output}.XXXXXX")
    case "${format}" in
        zip) unzip -p "${archive}" "${member}" >"${temporary}" ;;
        tar.gz) tar xOzf "${archive}" "${member}" >"${temporary}" ;;
        *) echo "Unsupported archive format '${format}'" >&2; return 1 ;;
    esac

    if ! verify_sha256 "${output_sha}" "${temporary}"; then
        echo "Extracted ${output} failed checksum verification" >&2
        return 1
    fi
    mv -f "${temporary}" "${destination}"
    temporary=
    echo "Installed ${title} ${version}: ${destination}"
}

case ${1:-} in
    list)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        list_wads
        ;;
    path)
        [[ $# -eq 2 ]] || { usage >&2; exit 2; }
        wad_path "$2"
        ;;
    fetch)
        shift
        [[ $# -gt 0 ]] || { usage >&2; exit 2; }
        if [[ $1 == all ]]; then
            [[ $# -eq 1 ]] || { usage >&2; exit 2; }
            mapfile -t wad_ids < <(awk -F '|' '$0 !~ /^#/ { print $1 }' "${catalog}")
        else
            wad_ids=("$@")
        fi
        for wad_id in "${wad_ids[@]}"; do
            fetch_one "${wad_id}"
        done
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
