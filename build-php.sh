#!/usr/bin/env bash
# =============================================================================
# build-php.sh - Build patched PHP (php + php-fpm) for RunCloud
#   PHP:    7.2, 7.3, 7.4, 8.0, 8.1
#   Ubuntu: focal (20.04), jammy (22.04), noble (24.04)
#
# Patches (PHP2Shell mitigation - CVE-2026-109618, CVE-2026-109619):
#   - ZSTR_MAX_LEN in Zend/zend_string.h          (PHP 7.0+, CVE-2026-109618)
#   - _exit(1) on zend_mm_safe_error during request startup  (CVE-2026-109618)
#   - RFC1867 callback neutralized (if (0)) in main/rfc1867.c (CVE-2026-109619)
#
# Usage:
#   sudo ./build-php.sh -u focal -p 7.2
#   sudo ./build-php.sh -u 22.04 -p 7.4,8.0,8.1
#   sudo ./build-php.sh -u focal -p all
#   sudo ./build-php.sh                  # interactive menu
# Options:
#   -u, --ubuntu  focal|jammy|noble|20.04|22.04|24.04
#   -p, --php     7.2 ... 8.1 | exact x.y.z | comma list | all
#   -j, --jobs    parallel make jobs (default: nproc)
#   -s, --suffix  version suffix, e.g. co1 -> "PHP 7.4.33-co1" (default: none)
#   -h, --help
# =============================================================================
set -Eeuo pipefail

SUPPORTED_PHP=(7.2 7.3 7.4 8.0 8.1)
SUPPORTED_UBU=(focal jammy noble)

log()  { echo -e "\e[1;32m[+] $*\e[0m"; }
warn() { echo -e "\e[1;33m[!] $*\e[0m"; }
die()  { echo -e "\e[1;31m[x] $*\e[0m" >&2; exit 1; }
usage(){ sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

UBU="" PHP_ARG="" JOBS="$(nproc)" SUFFIX="" SUFFIX_SET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--ubuntu) UBU="$2"; shift 2;;
    -p|--php)    PHP_ARG="$2"; shift 2;;
    -j|--jobs)   JOBS="$2"; shift 2;;
    -s|--suffix) SUFFIX="${2#-}"; SUFFIX_SET=1; shift 2;;
    -h|--help)   usage;;
    *) die "Unknown option: $1";;
  esac
done

[[ $EUID -eq 0 ]] || die "Run with sudo"
[[ "$(uname -m)" == "x86_64" ]] || die "Only x86_64 architecture is supported at this moment (detected: $(uname -m))"

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- interactive selection ----------
if [[ -z "$UBU" ]]; then
  [[ -t 0 ]] || die "Missing -u"
  PS3="Ubuntu release: "; select UBU in "${SUPPORTED_UBU[@]}"; do [[ -n "$UBU" ]] && break; done
fi

case "$UBU" in
  20.04|focal)  UBU=focal;;
  22.04|jammy)  UBU=jammy;;
  24.04|noble)  UBU=noble;;
  *) die "Unsupported Ubuntu: $UBU";;
esac

# Determine compatible versions with $UBU based on the available configure-command files
declare -a COMPAT_PHP=()
declare -a DISPLAY_PHP_MENU=()

for v in "${SUPPORTED_PHP[@]}"; do
  tag=${v/./}
  if [[ -f "$BUILD_DIR/configure-command/configure-php${tag}rc-${UBU}" ]]; then
    COMPAT_PHP+=("$v")
    DISPLAY_PHP_MENU+=("$v")
  else
    DISPLAY_PHP_MENU+=("$v (not available on $UBU)")
  fi
done

ALL_STR=$(IFS=,; echo "${COMPAT_PHP[*]}")
DISPLAY_PHP_MENU+=("all ($ALL_STR)")

if [[ -z "$PHP_ARG" ]]; then
  [[ -t 0 ]] || die "Missing -p"
  PS3="PHP version: "
  select choice in "${DISPLAY_PHP_MENU[@]}"; do
    if [[ -z "$choice" ]]; then
      warn "Invalid option. Please try again."
      continue
    fi
    if [[ "$choice" == *"not available"* ]]; then
      bad_ver=$(cut -d' ' -f1 <<< "$choice")
      warn "PHP $bad_ver is not available for Ubuntu $UBU on RunCloud."
      continue
    fi
    if [[ "$choice" == all* ]]; then
      PHP_ARG="all"
      break
    else
      PHP_ARG="$choice"
      break
    fi
  done
fi

if [[ $SUFFIX_SET -eq 0 && -t 0 ]]; then
  echo "Version suffix (optional). Examples: co1 -> 'PHP 7.4.33-co1'"
  read -rp "Suffix [Enter = none]: " SUFFIX
  SUFFIX="${SUFFIX#-}"
fi
if [[ -n "$SUFFIX" && ! "$SUFFIX" =~ ^[A-Za-z0-9.~+]+$ ]]; then
  die "Invalid suffix '$SUFFIX' (allowed: letters, digits, . ~ +)"
fi

if [[ "$PHP_ARG" == "all" ]]; then
  PHP_LIST=("${COMPAT_PHP[@]}")
else
  IFS=, read -ra RAW_PHP_LIST <<< "$PHP_ARG"
  PHP_LIST=()
  for item in "${RAW_PHP_LIST[@]}"; do
    item="$(echo "$item" | xargs)"
    mm=$(cut -d. -f1-2 <<< "$item")
    if [[ " ${COMPAT_PHP[*]} " != *" $mm "* ]]; then
      die "PHP $item is not available for Ubuntu $UBU on RunCloud. Available versions for $UBU: ${COMPAT_PHP[*]}"
    fi
    PHP_LIST+=("$item")
  done
fi

ROOTFS="$BUILD_DIR/rootfs-$UBU"

# Verify that the configure commands exist for all requested versions
for v in "${PHP_LIST[@]}"; do
  mm=$(cut -d. -f1-2 <<< "$v")
  tag=${mm/./}
  conf_file="$BUILD_DIR/configure-command/configure-php${tag}rc-${UBU}"
  if [[ ! -f "$conf_file" ]]; then
    die "The configuration file was not found: configure-command/configure-php${tag}rc-${UBU} (required for PHP $v on $UBU)."
  fi
done

# ---------- 1. CHROOT ----------
umount_all() {
  for m in dev/pts dev sys proc; do
    mountpoint -q "$ROOTFS/$m" 2>/dev/null && umount -l "$ROOTFS/$m" || true
  done
}
trap umount_all EXIT

if [[ ! -x "$ROOTFS/bin/bash" ]]; then
  log "Creating $UBU rootfs at $ROOTFS"
  mkdir -p "$ROOTFS"
  if [[ "$UBU" == focal && -f "$BUILD_DIR/ubuntu-base-20.04.5-base-amd64.tar.gz" ]]; then
    tar -xzf "$BUILD_DIR/ubuntu-base-20.04.5-base-amd64.tar.gz" -C "$ROOTFS"
  else
    command -v debootstrap >/dev/null || { apt-get update; apt-get install -y debootstrap; }
    debootstrap --variant=minbase --arch=amd64 "$UBU" "$ROOTFS" http://archive.ubuntu.com/ubuntu
  fi
fi

log "Mounting /proc /sys /dev in $ROOTFS"
mountpoint -q "$ROOTFS/proc"    || mount -t proc  proc "$ROOTFS/proc"
mountpoint -q "$ROOTFS/sys"     || mount -t sysfs sys  "$ROOTFS/sys"
mountpoint -q "$ROOTFS/dev"     || mount --bind /dev     "$ROOTFS/dev"
mountpoint -q "$ROOTFS/dev/pts" || mount --bind /dev/pts "$ROOTFS/dev/pts"
for m in proc sys dev; do mountpoint -q "$ROOTFS/$m" || die "mount $m failed"; done
cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

# ---------- 2-5. inner build script ----------
cat > "$ROOTFS/root/inner-build.sh" <<'INNER'
#!/bin/bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
log()  { echo -e "\e[1;34m[chroot] $*\e[0m"; }
warn() { echo -e "\e[1;33m[chroot] $*\e[0m"; }
die()  { echo -e "\e[1;31m[chroot] $*\e[0m" >&2; exit 1; }

: "${PHP_REQ:?}" "${UBU:?}" "${JOBS:?}"
MM=$(cut -d. -f1-2 <<< "$PHP_REQ")          # 7.2
TAG=${MM/./}                                 # 72
VN=$(( ${MM%%.*} * 100 + ${MM##*.} ))        # 702
PREFIX=/RunCloud/Packages/php${TAG}rc
ETC=/etc/php${TAG}rc
STAGE=/stage${TAG}
OUT=/root/php${TAG}rc-${UBU}-patched.tar.gz
ML=/usr/lib/x86_64-linux-gnu

# ---------- 2. dependencies (once per rootfs) ----------
if [[ ! -f /root/.deps-ok ]]; then
  cat > /etc/apt/sources.list <<EOF
deb http://archive.ubuntu.com/ubuntu $UBU main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu $UBU-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu $UBU-security main restricted universe multiverse
EOF
  mkdir -p /etc/apt/sources.list.d.disabled
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -e "$f" ]] && mv -f "$f" /etc/apt/sources.list.d.disabled/ || true
  done
  log "Installing build dependencies"
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates wget xz-utils file perl \
    build-essential autoconf automake libtool bison re2c pkg-config libxml2-dev \
    libssl-dev libgmp-dev libedit-dev zlib1g-dev libsystemd-dev libffi-dev
  # enchant: v1 where available (focal/bionic), else enchant-2
  if apt-cache show libenchant-dev >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends libenchant-dev
  else
    apt-get install -y --no-install-recommends libenchant-2-dev
  fi
  # argon2: keep RunCloud's libargon2-1 if present; fall back to upstream header
  if [[ ! -f /usr/include/argon2.h ]]; then
    apt-get install -y --no-install-recommends libargon2-dev 2>/dev/null \
    || apt-get install -y --no-install-recommends libargon2-0-dev 2>/dev/null \
    || {
      warn "libargon2-dev not installable; fetching argon2.h 20190702"
      apt-get install -y --no-install-recommends libargon2-1 2>/dev/null \
        || apt-get install -y --no-install-recommends libargon2-0
      wget -q -O /usr/include/argon2.h \
        https://raw.githubusercontent.com/P-H-C/phc-winner-argon2/20190702/include/argon2.h
    }
  fi
  [[ -s /usr/include/argon2.h ]] || die "argon2.h missing"
  [[ -e $ML/libargon2.so ]] || ln -sf "$(ls $ML/libargon2.so.* | head -1)" $ML/libargon2.so
  [[ -e /usr/include/gmp.h ]] || ln -sf /usr/include/x86_64-linux-gnu/gmp.h /usr/include/gmp.h
  # compatibility with --with-libdir=lib64
  mkdir -p /usr/lib64
  for so in /usr/lib/x86_64-linux-gnu/*.so* /usr/lib/x86_64-linux-gnu/*.a; do
    [[ -e "$so" ]] && ln -sf "$so" /usr/lib64/ 2>/dev/null || true
  done
  touch /root/.deps-ok
fi

# ---------- OpenSSL selection ----------
SYS_SSL=$(pkg-config --modversion openssl)
SSL_VER=""
if (( VN < 801 )) && [[ $SYS_SSL == 3* ]]; then
  SSL_VER=1.1.1w   # 7.2-8.0 lack OpenSSL 3
fi
if [[ -n "$SSL_VER" ]]; then
  SSL_DIR=/opt/openssl-$SSL_VER
  if [[ ! -f $SSL_DIR/lib/libssl.a ]]; then
    log "Building static OpenSSL $SSL_VER (system has $SYS_SSL)"
    cd /root
    T=openssl-$SSL_VER.tar.gz
    BR=${SSL_VER%?}; GH=OpenSSL_${SSL_VER//./_}
    [[ -s $T ]] || wget -q -O $T "https://www.openssl.org/source/old/$BR/$T" \
      || wget -q -O $T "https://github.com/openssl/openssl/releases/download/$GH/$T"
    rm -rf openssl-$SSL_VER && tar -xzf $T && cd openssl-$SSL_VER
    ./config no-shared -fPIC --prefix=$SSL_DIR --openssldir=/usr/lib/ssl
    make -j"$JOBS"
    make install_sw
    [[ -d $SSL_DIR/lib64 && ! -d $SSL_DIR/lib ]] && ln -s lib64 $SSL_DIR/lib
  fi
  mkdir -p /RunCloud/Packages
  ln -sfn "$SSL_DIR" /RunCloud/Packages/libssl1-rc
  export PKG_CONFIG_PATH=$SSL_DIR/lib/pkgconfig
  export LIBS="-ldl -lpthread"
  log "Using static OpenSSL $SSL_VER linked at /RunCloud/Packages/libssl1-rc"
else
  SSL_DIR=""
  log "Using system OpenSSL $SYS_SSL"
fi

# ---------- 3. source ----------
cd /root
if [[ "$PHP_REQ" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  PHPV=$PHP_REQ
else
  PHPV=$(wget -qO- "https://www.php.net/releases/index.php?json&version=$MM" \
         | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  if [[ -z "$PHPV" ]]; then
    declare -A LAST=([7.2]=7.2.34 [7.3]=7.3.33 [7.4]=7.4.33 [8.0]=8.0.30 [8.1]=8.1.31)
    PHPV=${LAST[$MM]}
  fi
fi
log "PHP $PHPV  ->  $PREFIX  (Ubuntu $UBU)"
T=php-$PHPV.tar.xz
[[ -s $T ]] || wget -q -O $T "https://www.php.net/distributions/$T" \
  || wget -q -O $T "https://museum.php.net/php${MM%%.*}/$T" || die "Download failed"
rm -rf php-$PHPV && tar -xJf $T && cd php-$PHPV

# ---------- 4. patches ----------
log "Patching"
# 4a. ZSTR_MAX_LEN (zend_string only exists on 7.0+)
if (( VN >= 700 )); then
  if ! grep -q 'define ZSTR_MAX_LEN' Zend/zend_string.h; then
    grep -q '#define _ZSTR_HEADER_SIZE' Zend/zend_string.h || die "_ZSTR_HEADER_SIZE not found"
    sed -i '/#define _ZSTR_HEADER_SIZE/a #define ZSTR_MAX_LEN (SIZE_MAX - _ZSTR_HEADER_SIZE)' Zend/zend_string.h
  fi
  grep -q 'define ZSTR_MAX_LEN' Zend/zend_string.h || die "ZSTR_MAX_LEN patch failed"
fi

# 4b. PHP2Shell bailout in zend_mm_safe_error
perl -0pi -e 's/(zend_mm_safe_error\(.*?heap->overflow = 1;\n)/$1\t\tif (PG(during_request_startup)) {\n\t\t\t_exit(1);\n\t\t}\n/s' Zend/zend_alloc.c
grep -q 'during_request_startup' Zend/zend_alloc.c || die "zend_alloc patch failed"
sed -i '0,/#include "zend_alloc.h"/s//#include "zend_alloc.h"\n#include <unistd.h>\n#include "main\/php.h"\n#include "main\/php_globals.h"/' Zend/zend_alloc.c

# 4c. RFC1867 callback neutralization
sed -i -E 's/if \(php_rfc1867_callback != NULL\)/if (0)/g; s/if \(php_rfc1867_callback\)/if (0)/g; s/if \(php_rfc1867_callback != NULL && /if (0 \&\& /g; s/if \(php_rfc1867_callback\(/if (0 \&\& php_rfc1867_callback(/g' main/rfc1867.c
! grep -nE 'if \(php_rfc1867_callback( != NULL|\)|\()' main/rfc1867.c || die "rfc1867 patch incomplete"
N=$(grep -c 'if (0' main/rfc1867.c || true); (( N > 0 )) || die "rfc1867: nothing neutralized"
log "rfc1867 neutralized conditions: $N"

# 4d. Optional version suffix (PHP_EXTRA_VERSION); PHP_VERSION_ID is unchanged
apply_suffix() {
  [[ -n "${SUFFIX:-}" ]] || return 0
  sed -i -E "s/^PHP_EXTRA_VERSION=\"[^\"]*\"/PHP_EXTRA_VERSION=\"-$SUFFIX\"/" configure
  sed -i -E "s/(#define PHP_EXTRA_VERSION )\"[^\"]*\"/\1\"-$SUFFIX\"/; s/(#define PHP_VERSION \")$PHPV[^\"]*\"/\1$PHPV-$SUFFIX\"/" main/php_version.h
  grep -q "PHP_VERSION \"$PHPV-$SUFFIX\"" main/php_version.h || die "version suffix patch failed"
}
log "Version suffix: '${SUFFIX:-}'"
if [[ -n "${SUFFIX:-}" ]]; then
  [[ "$SUFFIX" =~ ^[A-Za-z0-9.~+]+$ ]] || die "Invalid suffix: $SUFFIX"
  apply_suffix
  log "Version string: $PHPV-$SUFFIX"
fi

# ---------- 5. configure ----------
[[ -f /root/configure-cmd ]] || die "/root/configure-cmd not found"
CONF_CMD=$(< /root/configure-cmd)

# Adapt static OpenSSL settings if applicable
if [[ -n "$SSL_DIR" && -d "$SSL_DIR" ]]; then
  mkdir -p /RunCloud/Packages
  ln -sfn "$SSL_DIR" /RunCloud/Packages/libssl1-rc
  if [[ "$CONF_CMD" != *libssl1-rc* ]]; then
    CONF_CMD="${CONF_CMD//--with-openssl=yes/--with-openssl=$SSL_DIR}"
    CONF_CMD="${CONF_CMD//'--with-openssl'/'--with-openssl='$SSL_DIR}"
  fi
fi

export CFLAGS="-O2 -g0 -fPIC -fcommon" CXXFLAGS="-O2 -g0 -fPIC"
if [[ -n "$SSL_DIR" && -d "$SSL_DIR" ]]; then
  export CFLAGS="-I$SSL_DIR/include $CFLAGS"
  export CXXFLAGS="-I$SSL_DIR/include $CXXFLAGS"
  export LDFLAGS="-L$SSL_DIR/lib ${LDFLAGS:-}"
fi
log "Running configure: $CONF_CMD"
eval "$CONF_CMD"
apply_suffix   # configure may regenerate main/php_version.h

log "make -j$JOBS"
make -j"$JOBS"
rm -rf $STAGE
make install INSTALL_ROOT=$STAGE
P=$STAGE$PREFIX
strip --strip-unneeded $P/bin/php $P/sbin/php-fpm
$P/bin/php -v
if [[ -n "${SUFFIX:-}" ]]; then
  GOT=$($P/bin/php -r 'echo PHP_VERSION;')
  [[ "$GOT" == "$PHPV-$SUFFIX" ]] || die "Binary reports '$GOT', expected '$PHPV-$SUFFIX'"
fi
$P/bin/php -m | tr '\n' ' '; echo
tar -czf $OUT -C $STAGE ${PREFIX#/}/bin/php ${PREFIX#/}/sbin/php-fpm
echo "$OUT" > /root/.last-out
log "Done: $OUT"
INNER
chmod +x "$ROOTFS/root/inner-build.sh"

# ---------- run builds ----------
declare -a RESULTS=()
for v in "${PHP_LIST[@]}"; do
  log "===== PHP $v on Ubuntu $UBU ====="
  mm=$(cut -d. -f1-2 <<< "$v")
  tag=${mm/./}
  conf_file="$BUILD_DIR/configure-command/configure-php${tag}rc-${UBU}"
  [[ -f "$conf_file" ]] || die "The configuration file was not found: $conf_file"
  cp "$conf_file" "$ROOTFS/root/configure-cmd"

  chroot "$ROOTFS" /usr/bin/env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin TERM=xterm \
    PHP_REQ="$v" UBU="$UBU" JOBS="$JOBS" SUFFIX="$SUFFIX" /bin/bash /root/inner-build.sh
  OUT_IN=$(cat "$ROOTFS/root/.last-out")
  OUT_HOST="$BUILD_DIR/$(basename "$OUT_IN")"
  cp "$ROOTFS$OUT_IN" "$OUT_HOST"
  chown "${SUDO_USER:-root}": "$OUT_HOST"
  RESULTS+=("$OUT_HOST")
done

# ---------- 6. finalize ----------
umount_all
trap - EXIT
log "Packages:"
for f in "${RESULTS[@]}"; do tar -tzvf "$f"; sha256sum "$f"; done
