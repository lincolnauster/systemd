#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later

set -ex

info() { echo -e "\033[33;1m$1\033[0m"; }
fatal() { echo >&2 -e "\033[31;1m$1\033[0m"; exit 1; }
success() { echo >&2 -e "\033[32;1m$1\033[0m"; }

ARGS=(
    "--optimization=0"
    "--optimization=s"
    "--optimization=3 -Db_lto=true -Ddns-over-tls=false"
    "--optimization=3 -Db_lto=false"
    "--optimization=3 -Ddns-over-tls=openssl"
    "--optimization=3 -Dfexecve=true -Dstandalone-binaries=true -Dstatic-libsystemd=true -Dstatic-libudev=true"
    "-Db_ndebug=true"
)
PACKAGES=(
    cryptsetup-bin
    expect
    fdisk
    gettext
    iputils-ping
    isc-dhcp-client
    itstool
    kbd
    libblkid-dev
    libbpf-dev
    libcap-dev
    libcurl4-gnutls-dev
    libfdisk-dev
    libfido2-dev
    libgpg-error-dev
    liblz4-dev
    liblzma-dev
    libmicrohttpd-dev
    libmount-dev
    libp11-kit-dev
    libpwquality-dev
    libqrencode-dev
    libssl-dev
    libtss2-dev
    libxkbcommon-dev
    libxtables-dev
    libzstd-dev
    mount
    net-tools
    perl
    python3-evdev
    python3-jinja2
    python3-lxml
    python3-pip
    python3-pyparsing
    python3-setuptools
    quota
    strace
    unifont
    util-linux
    zstd
)
COMPILER="${COMPILER:?}"
COMPILER_VERSION="${COMPILER_VERSION:?}"
LINKER="${LINKER:?}"
CRYPTOLIB="${CRYPTOLIB:?}"
RELEASE="$(lsb_release -cs)"

bash -c "echo 'deb-src http://archive.ubuntu.com/ubuntu/ $RELEASE main restricted universe multiverse' >>/etc/apt/sources.list"

# Note: As we use postfixed clang/gcc binaries, we need to override $AR
#       as well, otherwise meson falls back to ar from binutils which
#       doesn't work with LTO
if [[ "$COMPILER" == clang ]]; then
    CC="clang-$COMPILER_VERSION"
    CXX="clang++-$COMPILER_VERSION"
    AR="llvm-ar-$COMPILER_VERSION"

    # ATTOW llvm-11 got into focal-updates, which conflicts with llvm-11
    # provided by the apt.llvm.org repositories. Let's use the system
    # llvm package if available in such cases to avoid that.
    if ! apt show --quiet "llvm-$COMPILER_VERSION" &>/dev/null; then
        # Latest LLVM stack deb packages provided by https://apt.llvm.org/
        # Following snippet was partly borrowed from https://apt.llvm.org/llvm.sh
        wget -O - https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --yes --dearmor --output /usr/share/keyrings/apt-llvm-org.gpg
        printf "deb [signed-by=/usr/share/keyrings/apt-llvm-org.gpg] http://apt.llvm.org/%s/   llvm-toolchain-%s-%s  main\n" \
		"$RELEASE" "$RELEASE" "$COMPILER_VERSION" >/etc/apt/sources.list.d/llvm-toolchain.list
        PACKAGES+=("clang-$COMPILER_VERSION" "lldb-$COMPILER_VERSION" "lld-$COMPILER_VERSION" "clangd-$COMPILER_VERSION")
    fi
elif [[ "$COMPILER" == gcc ]]; then
    CC="gcc-$COMPILER_VERSION"
    CXX="g++-$COMPILER_VERSION"
    AR="gcc-ar-$COMPILER_VERSION"
    # Latest gcc stack deb packages provided by
    # https://launchpad.net/~ubuntu-toolchain-r/+archive/ubuntu/test
    add-apt-repository -y ppa:ubuntu-toolchain-r/test
    PACKAGES+=("gcc-$COMPILER_VERSION")
else
    fatal "Unknown compiler: $COMPILER"
fi

# PPA with some newer build dependencies (like zstd)
add-apt-repository -y ppa:upstream-systemd-ci/systemd-ci
apt-get -y update
apt-get -y build-dep systemd
apt-get -y install "${PACKAGES[@]}"
# Install more or less recent meson and ninja with pip, since the distro versions don't
# always support all the features we need (like --optimization=). Since the build-dep
# command above installs the distro versions, let's install the pip ones just
# locally and add the local bin directory to the $PATH.
pip3 install --user -r .github/workflows/requirements.txt --require-hashes
export PATH="$HOME/.local/bin:$PATH"

$CC --version
meson --version
ninja --version

for args in "${ARGS[@]}"; do
    SECONDS=0

    info "Checking build with $args"
    # shellcheck disable=SC2086
    if ! AR="$AR" \
         CC="$CC" CC_LD="$LINKER" CFLAGS="-Werror" \
         CXX="$CXX" CXX_LD="$LINKER" CXXFLAGS="-Werror" \
         meson -Dtests=unsafe -Dslow-tests=true -Dfuzz-tests=true --werror \
               -Dcryptolib="${CRYPTOLIB:?}" $args build; then

        fatal "meson failed with $args"
    fi

    if ! meson compile -C build; then
        fatal "'meson compile' failed with $args"
    fi

    git clean -dxf

    success "Build with $args passed in $SECONDS seconds"
done
