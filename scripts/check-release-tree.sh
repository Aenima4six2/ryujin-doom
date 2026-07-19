#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "${repo_dir}"

for required_file in LICENSE THIRD_PARTY_NOTICES.md; do
    [[ -f ${required_file} ]] || {
        echo "Missing required licensing file: ${required_file}" >&2
        exit 1
    }
done

mapfile -t tracked_files < <(git ls-files --cached --others --exclude-standard)
bad_paths=()
for tracked_file in "${tracked_files[@]}"; do
    lower_path=${tracked_file,,}
    case ${lower_path} in
        vendor/*|dist/*|wads/*|*.wad|*.pk3|*.exe|*.dll|*.deb|*.rpm)
            bad_paths+=("${tracked_file}")
            continue
            ;;
    esac

    if [[ -f ${tracked_file} ]]; then
        magic=$(LC_ALL=C od -An -tx1 -N4 -- "${tracked_file}" 2>/dev/null |
            tr -d '[:space:]')
        case ${magic} in
            49574144|50574144|7f454c46|4d5a*) bad_paths+=("${tracked_file}") ;;
        esac
    fi
done

if (( ${#bad_paths[@]} )); then
    echo "Refusing to release: generated or game-data files could be committed:" >&2
    printf '  %s\n' "${bad_paths[@]}" >&2
    exit 1
fi

echo "Release tree audit: no committable WADs, vendor trees, or generated binaries"
