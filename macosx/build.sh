#!/bin/bash

#
# This script is known to work on:
# OS X 10.5.8, Xcode 3.1.2, SDK 10.5, MacPorts 2.3.3
# OS X 10.9.5, Xcode 5.1.1, SDK 10.9, MacPorts 2.3.2
# OS X 10.10.3, XCode 6.3.2, SDK 10.10, Homebrew 0.9.5/8da6986
#
# You may need to set PATH to include the location of your
# PackageMaker binary, if your system is old enough to need that.
# Setting MACOSX_DEPLOYMENT_TARGET will select an SDK as usual.
#
# If you are using Homebrew, you should install protobuf (and any
# other future Homebrew dependencies) with
# `--universal --build-bottle`.
# The first option should be fairly obvious; the second has the side
# effect of disabling Homebrew's overzealous processor optimization
# with (effectively) `-march=native`.
#
#
# Modern Homebrew protobuf/abseil builds are dynamic-only, so static
# linking is not generally available. This script now vendors non-system
# dylibs into the package prefix and rewrites load paths to keep the
# resulting package portable across Apple Silicon machines.
#

set -e

toolchain_family()
{
    case "$1" in
        /opt/homebrew/*)
            echo "homebrew"
            ;;
        /opt/zerobrew/*)
            echo "zerobrew"
            ;;
        /opt/local/*)
            echo "macports"
            ;;
        *)
            echo "other"
            ;;
    esac
}

force_dependency_toolchain()
{
    case "${MOSH_DEP_TOOLCHAIN:-auto}" in
        auto)
            return 0
            ;;
        homebrew)
            dep_prefix="/opt/homebrew"
            ;;
        zerobrew)
            dep_prefix="/opt/zerobrew/prefix"
            ;;
        *)
            echo "Unsupported MOSH_DEP_TOOLCHAIN='${MOSH_DEP_TOOLCHAIN}'. Use auto|homebrew|zerobrew." >&2
            return 1
            ;;
    esac

    if [ ! -d "$dep_prefix" ]; then
        echo "Requested dependency toolchain prefix not found: $dep_prefix" >&2
        return 1
    fi

    export PATH="${dep_prefix}/bin:$PATH"
    unset CPATH
    unset C_INCLUDE_PATH
    unset CPLUS_INCLUDE_PATH
    unset OBJC_INCLUDE_PATH
    unset LIBRARY_PATH

    pc_paths=()
    [ -d "${dep_prefix}/lib/pkgconfig" ] && pc_paths+=("${dep_prefix}/lib/pkgconfig")
    [ -d "${dep_prefix}/share/pkgconfig" ] && pc_paths+=("${dep_prefix}/share/pkgconfig")
    [ -d "${dep_prefix}/opt/openssl@3/lib/pkgconfig" ] && pc_paths+=("${dep_prefix}/opt/openssl@3/lib/pkgconfig")
    if [ ${#pc_paths[@]} -gt 0 ]; then
        export PKG_CONFIG_PATH=$(IFS=:; echo "${pc_paths[*]}")
    fi
    unset PKG_CONFIG_LIBDIR

    echo "Forcing dependency toolchain: ${MOSH_DEP_TOOLCHAIN} (${dep_prefix})"
}

force_dependency_toolchain

is_system_dylib()
{
    case "$1" in
        /System/Library/*|/usr/lib/*)
            return 0
            ;;
    esac
    return 1
}

list_non_system_dylibs()
{
    otool -L "$1" | tail -n +2 | awk '{print $1}' | while IFS= read -r dep
    do
        case "$dep" in
            ""|@*|[^/]*)
                continue
                ;;
        esac
        if ! is_system_dylib "$dep"; then
            echo "$dep"
        fi
    done
}

resolve_protoc()
{
    if [ -n "$PROTOC" ]; then
        echo "$PROTOC"
        return 0
    fi

    if which -s pkg-config && pkg-config --exists protobuf; then
        protobuf_prefix=$(pkg-config --variable=prefix protobuf 2> /dev/null || true)
        if [ -n "$protobuf_prefix" ] && [ -x "${protobuf_prefix}/bin/protoc" ]; then
            echo "${protobuf_prefix}/bin/protoc"
            return 0
        fi
    fi

    if which -s protoc; then
        command -v protoc
        return 0
    fi

    echo "Cannot find protoc. Install protobuf and ensure protoc is on PATH." >&2
    return 1
}

resolve_existing_dylib_path()
{
    dep="$1"
    if [ -e "$dep" ]; then
        echo "$dep"
        return 0
    fi

    dep_base=$(basename "$dep")
    dep_parent=$(dirname "$(dirname "$dep")")
    candidate="${dep_parent}/lib/${dep_base}"
    if [ -e "$candidate" ]; then
        echo "$candidate"
        return 0
    fi

    candidate=$(find "$dep_parent" -maxdepth 3 -type f -name "$dep_base" -print -quit 2> /dev/null || true)
    if [ -n "$candidate" ] && [ -e "$candidate" ]; then
        echo "$candidate"
        return 0
    fi

    echo "Unable to locate dylib payload for install_name path: $dep" >&2
    return 1
}

bundle_non_system_dylibs()
{
    PREFIX_DIR="$1"
    BINDIR="${PREFIX_DIR}/local/bin"
    LIBDIR="${PREFIX_DIR}/local/lib"

    mkdir -p "$LIBDIR"

    changed=1
    while [ "$changed" -eq 1 ]; do
        changed=0
        scan_targets=("${BINDIR}/mosh-client" "${BINDIR}/mosh-server")
        while IFS= read -r dylib
        do
            scan_targets+=("$dylib")
        done < <(find "$LIBDIR" -maxdepth 1 -type f -name '*.dylib' -print | sort)

        for target in "${scan_targets[@]}"; do
            [ -f "$target" ] || continue

            while IFS= read -r dep
            do
                base=$(basename "$dep")
                dest="${LIBDIR}/${base}"
                dep_source=$(resolve_existing_dylib_path "$dep")

                if [ ! -f "$dest" ]; then
                    cp -Lf "$dep_source" "$dest"
                    chmod u+w "$dest"
                    changed=1
                    continue
                fi

                if ! cmp -s "$dep_source" "$dest"; then
                    echo "Dependency filename collision for ${base}:"
                    echo "  $dep_source"
                    echo "  $dest"
                    return 1
                fi
            done < <(list_non_system_dylibs "$target")
        done
    done

    for prog in "${BINDIR}/mosh-client" "${BINDIR}/mosh-server"; do
        [ -f "$prog" ] || continue
        while IFS= read -r dep
        do
            base=$(basename "$dep")
            install_name_tool -change "$dep" "@executable_path/../lib/${base}" "$prog"
        done < <(list_non_system_dylibs "$prog")
    done

    while IFS= read -r dylib
    do
        base=$(basename "$dylib")
        install_name_tool -id "@loader_path/${base}" "$dylib"
        while IFS= read -r dep
        do
            dep_base=$(basename "$dep")
            install_name_tool -change "$dep" "@loader_path/${dep_base}" "$dylib"
        done < <(list_non_system_dylibs "$dylib")
    done < <(find "$LIBDIR" -maxdepth 1 -type f -name '*.dylib' -print | sort)

    if which -s codesign; then
        while IFS= read -r dylib
        do
            codesign --remove-signature "$dylib" > /dev/null 2>&1 || true
            codesign --force --sign - "$dylib" > /dev/null
        done < <(find "$LIBDIR" -maxdepth 1 -type f -name '*.dylib' -print | sort)

        for prog in "${BINDIR}/mosh-client" "${BINDIR}/mosh-server"; do
            [ -f "$prog" ] || continue
            codesign --remove-signature "$prog" > /dev/null 2>&1 || true
            codesign --force --sign - "$prog" > /dev/null
        done
    fi

    # Verify that no non-system absolute dylib references remain.
    unresolved=""
    scan_targets=("${BINDIR}/mosh-client" "${BINDIR}/mosh-server")
    while IFS= read -r dylib
    do
        scan_targets+=("$dylib")
    done < <(find "$LIBDIR" -maxdepth 1 -type f -name '*.dylib' -print | sort)

    for target in "${scan_targets[@]}"; do
        [ -f "$target" ] || continue
        deps=$(list_non_system_dylibs "$target" || true)
        if [ -n "$deps" ]; then
            unresolved+="$(printf '\n%s:\n%s' "$target" "$deps")"
        fi
    done

    if [ -n "$unresolved" ]; then
        printf 'Failed to rewrite some non-system dylib references:%s\n' "$unresolved"
        return 1
    fi

    echo "Bundled non-system dylibs into ${LIBDIR}."
}

echo "Building into prefix..."


#
# XXX This script abuses Configure's --prefix argument badly.  It uses
# it as a $DESTDIR, but --prefix can also affect paths in generated
# objects.  That is not *currently* a problem in mosh.
#
PREFIX="$(pwd)/prefix"

HOST="arm64-apple-macosx${MACOSX_DEPLOYMENT_TARGET}"
ARCH_TRIPLES="x86_64-apple-macosx arm64-apple-macos"

pushd .. > /dev/null

if [ ! -f configure ];
then
    echo "Running autogen."
    PATH=/opt/homebrew/bin:$PATH ./autogen.sh
fi

PROTOC_BIN=$(resolve_protoc)
echo "Using protoc at ${PROTOC_BIN}"
if which -s pkg-config && pkg-config --exists protobuf; then
    protobuf_prefix=$(pkg-config --variable=prefix protobuf)
    protoc_prefix=$(dirname "$(dirname "$PROTOC_BIN")")
    protobuf_toolchain=$(toolchain_family "$protobuf_prefix")
    protoc_toolchain=$(toolchain_family "$protoc_prefix")
    echo "Using protobuf $(pkg-config --modversion protobuf) from ${protobuf_prefix} (${protobuf_toolchain})"
    if [ "$protobuf_toolchain" != "$protoc_toolchain" ]; then
        echo "Refusing mixed toolchains: protoc is ${protoc_toolchain} (${protoc_prefix}), protobuf pkg-config is ${protobuf_toolchain} (${protobuf_prefix})." >&2
        echo "Set MOSH_DEP_TOOLCHAIN=homebrew or MOSH_DEP_TOOLCHAIN=zerobrew to force one provider." >&2
        exit 1
    fi
fi

#
# Build archs one by one.
#
for triple in $ARCH_TRIPLES; do
    arch=$(echo $triple | cut -d- -f1)
    echo "Building for ${arch}..."
    prefix="${PREFIX}_${arch}"
    rm -rf "${prefix}"
    mkdir "${prefix}"
    if env PATH="$(dirname "$PROTOC_BIN"):$PATH" PROTOC="$PROTOC_BIN" \
           ./configure --prefix="${prefix}/local" --build="${triple}${MACOSX_DEPLOYMENT_TARGET}"\
		   --host="${HOST}" \
		   CC="cc -arch ${arch}" CPP="cc -arch ${arch} -E" CXX="c++ -arch ${arch}" \
		   TINFO_LIBS=-lncurses &&
	    make clean &&
	    make install -j8 V=1 &&
	    rm -f "${prefix}/etc"
    then
	# mosh-client built with Xcode 3.1.2 bus-errors if the binary is stripped.
	# strip "${prefix}/local/bin/mosh-client" "${prefix}/local/bin/mosh-server"
	BUILT_ARCHS="$BUILT_ARCHS $arch"
    fi
done

if [ -z "$BUILT_ARCHS" ]; then
    echo "No architectures built successfully"
    exit 1
fi

echo "Building universal binaries for archs ${BUILT_ARCHS}..."


rm -rf "$PREFIX"
# Copy one architecture to get all files into place.
for arch in $BUILT_ARCHS; do
    cp -Rp "${PREFIX}_${arch}" "${PREFIX}"
    break
done

# Build fat binaries
# XXX will break with spaces in pathname
for prog in local/bin/mosh-client local/bin/mosh-server; do
    archprogs=()
    for arch in $BUILT_ARCHS; do
	archprogs+=("${PREFIX}_${arch}/$prog")
    done
    lipo -create "${archprogs[@]}" -output "${PREFIX}/$prog"
done

perl -wlpi -e 's{#!/usr/bin/env perl}{#!/usr/bin/perl}' "$PREFIX/local/bin/mosh"

if [ "${MOSH_BUNDLE_DYLIBS:-1}" != "0" ]; then
    echo "Bundling non-system dylibs into package prefix..."
    bundle_non_system_dylibs "$PREFIX"
fi

popd > /dev/null

PACKAGE_VERSION=$(cat ../VERSION.stamp)

OUTFILE="$PACKAGE_VERSION.pkg"

rm -f "$OUTFILE"

if which -s pkgbuild; then
    # To replace PackageMaker, you:
    # * make a bare package with the build products
    # * essentially take the Distribution file that PackageMaker generated and
    #   use it as the --distribution input file for productbuild
    echo "Preprocessing package description..."
    PKGID=edu.mit.mosh.mosh.pkg
    for file in Distribution; do
	sed -e "s/@PACKAGE_VERSION@/${PACKAGE_VERSION}/g" ${file}.in > ${file}
    done
    echo "Running pkgbuild/productbuild..."
    mkdir -p Resources/en.lproj
    cp -p copying.rtf Resources/en.lproj/License
    cp -p readme.rtf Resources/en.lproj/Readme
    pkgbuild --root "$PREFIX" --version "${PACKAGE_VERSION}" --identifier $PKGID $PKGID
    productbuild --distribution Distribution \
		 --resources Resources \
		 --package-path . \
		 "$OUTFILE"
    echo "Cleaning up..."
    rm -rf $PKGID
else
    echo "Preprocessing package description..."
    INDIR=mosh-package.pmdoc.in
    OUTDIR=mosh-package.pmdoc
    mkdir -p "$OUTDIR"
    pushd "$INDIR" > /dev/null
    for file in *
    do
	sed -e 's/$PACKAGE_VERSION/'"$PACKAGE_VERSION"'/g' "$file" > "../$OUTDIR/$file"
    done
    popd > /dev/null
    echo "Running PackageMaker..."
    env PATH="/Applications/PackageMaker.app/Contents/MacOS:/Developer/Applications/Utilities/PackageMaker.app/Contents/MacOS:$PATH" PackageMaker -d mosh-package.pmdoc -o "$OUTFILE" -i edu.mit.mosh.mosh.pkg
    echo "Cleaning up..."
    rm -rf "$OUTDIR"
fi


if [ -f "$OUTFILE" ];
then
    echo "Successfully built $OUTFILE with archs ${BUILT_ARCHS}."
else
    echo "There was an error building $OUTFILE."
    false
fi
