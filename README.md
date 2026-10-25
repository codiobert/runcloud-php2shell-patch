# RunCloud PHP2Shell Patch

This project builds patched PHP binaries (`php` and `php-fpm`) for RunCloud environments on Ubuntu, targeting the security issues associated with the **PHP2Shell** attack vector (**CVE-2026-109618** and **CVE-2026-109619**).

It was created as a community-driven solution because **RunCloud does not provide these security patches officially** for PHP versions that have reached end-of-life (EOL). The goal is to harden production servers without altering the native package layout or breaking existing extensions.

> [!WARNING]
> This project is independent, community-maintained, and not officially supported by RunCloud or The PHP Group. Use it at your own responsibility.

---

## Overview

The build script compiles a PHP binary with the following mitigations applied directly to the corresponding upstream sources:

- protection against the integer overflow condition behind **CVE-2026-109618**
- immediate termination during request startup when memory corruption is detected
- disabling the `multipart/form-data` upload callbacks that drive `session.upload_progress`, neutralizing the **CVE-2026-109619** attack path
- optional version suffixes for easy identification and auditing of patched binaries

The script preserves the standard RunCloud layout and only replaces the base executables while keeping the ABI and extension compatibility intact.

---

## What is patched

| # | File | Change | Purpose | Related CVE | Versions |
|---|------|--------|---------|-------------|----------|
| 1 | `Zend/zend_string.h` | Adds `#define ZSTR_MAX_LEN (SIZE_MAX - _ZSTR_HEADER_SIZE)` | Defines the maximum string length needed to detect integer overflow conditions. | CVE-2026-109618 | 7.2 – 8.1 |
| 2 | `Zend/zend_alloc.c` (inside `zend_mm_safe_error`) | Adds `if (PG(during_request_startup)) { _exit(1); }` after `heap->overflow = 1;` and required includes | If memory corruption occurs during request startup, the worker exits immediately instead of continuing in an inconsistent state. | CVE-2026-109618 | 7.2 – 8.1 |
| 3 | `main/rfc1867.c` | Converts all `if (php_rfc1867_callback ...)` checks to `if (0)` / `if (0 && ...)` | Disables the `multipart/form-data` upload callbacks completely, including `session.upload_progress`, neutralizing the hijacking/execution vector. | CVE-2026-109619 | 7.2 – 8.1 |
| 4 | `main/php_version.h` and `configure` | Adds an optional version suffix (`-s co1` produces `7.4.33-co1`) | Allows patched binaries to be identified and audited without changing `PHP_VERSION_ID`. | Audit only | 7.2 – 8.1 |

Notes:

- `main/SAPI.c` is intentionally left untouched. In PHP 7.2, the request structure (`sapi_request_info`) does not include `post_data_length`.
- If patch 1, 2, or 3 is not applied correctly, the script aborts and does not generate a package.
- Patch 4 is validated at the end by reading the compiled binary version.
- Side effect: the PHP upload progress feature (`session.upload_progress`) stops working because the callbacks it depends on are disabled.

---

## Supported RunCloud combinations

Because RunCloud only offers certain PHP versions for each Ubuntu release, the script validates and only allows officially supported combinations.

| PHP version | Focal (20.04) | Jammy (22.04) | Noble (24.04) | Notes / OpenSSL |
|:---:|:---:|:---:|:---:|---|
| **PHP 7.2** | ✅ Available | ❌ Not available | ❌ Not available | OpenSSL 1.1.1 (system) |
| **PHP 7.3** | ✅ Available | ❌ Not available | ❌ Not available | OpenSSL 1.1.1 (system) |
| **PHP 7.4** | ✅ Available | ✅ Available | ❌ Not available | Focal: system 1.1.1 / Jammy: static OpenSSL 1.1.1w (`libssl1-rc`) |
| **PHP 8.0** | ✅ Available | ✅ Available | ❌ Not available | Focal: system 1.1.1 / Jammy: static OpenSSL 1.1.1w (`libssl1-rc`) |
| **PHP 8.1** | ✅ Available | ✅ Available | ✅ Available | Focal: system / Jammy and Noble: OpenSSL 3 (system) |

> [!NOTE]
> * **PHP 5.6, 7.0, and 7.1 are excluded** because RunCloud no longer supports them on Ubuntu 20.04 (Focal) and later.
> * In the interactive menu (`./build-php.sh`), unsupported PHP versions for the selected Ubuntu release are disabled automatically. If you pass `-p all`, the script only compiles versions that are valid for the chosen Ubuntu distribution.

### Packaging and environment details

- **Supported architecture**: `x86_64` (AMD64)
- **Ubuntu releases**: `focal` (20.04), `jammy` (22.04), `noble` (24.04)
- **Target installation path**: `/RunCloud/Packages/phpXXrc` with config under `/etc/phpXXrc`, preserving the native RunCloud structure
- **Generated package**: `phpXXrc-<ubuntu>-patched.tar.gz`, containing only the executables `bin/php` and `sbin/php-fpm`
- **Extension compatibility**: because only the base executables are replaced while keeping the same prefix and ABI, dynamic extensions from RunCloud such as `pdo_mysql`, `redis`, `imagick`, `opcache`, etc. continue to work normally
- **Official configure command files** (`configure-command/`):
  The build process reads the exact `./configure` command from text files under `configure-command/` following this naming pattern:
  ```text
  configure-command/configure-php<TAG>rc-<ubuntu>
  # Example: configure-command/configure-php74rc-focal
  ```
  If the matching file does not exist for the requested PHP version and Ubuntu release, the script aborts before starting. You can obtain the exact command from a RunCloud server with:
  ```bash
  /RunCloud/Packages/phpXXrc/bin/php -i | grep '^Configure Command' | sed "s/^Configure Command => //; s/' '\.\/configure'/'\.\/configure'/"
  ```

---

## Requirements

### Where the build can run

The script uses `debootstrap` and isolated `chroot` environments with `/proc`, `/sys`, and `/dev` mounted. It can run in the following environments:

- **Windows with WSL2**: Ubuntu distribution under **WSL2**
  *(WSL1 is not supported because the required mount and chroot operations are unavailable)*
- **Native Ubuntu**: Any 64-bit Ubuntu system
- **Virtual machines**: VirtualBox, VMware, Proxmox, Hyper-V, or KVM with Ubuntu installed
- **VPS / cloud servers**: Any Ubuntu-based VM such as Hetzner, DigitalOcean, AWS EC2, Linode, or OVH
- **Docker containers**: An Ubuntu container started with privileges (`docker run --privileged -it ubuntu:22.04 bash`)

### System requirements

1. **Architecture**: `x86_64` (AMD64). ARM64 is not supported at the moment.
2. **Privileges**: root access via `sudo` is required for mount and chroot management.
3. **Disk space**: approximately 2–5 GB free per Ubuntu version you intend to build, to hold the rootfs and compiled sources.
4. **Internet access**: required to download the minimal base images via `debootstrap` and the PHP/OpenSSL source tarballs.

---

## Quick start

```bash
# Interactive mode: prompts for Ubuntu version, PHP version, and optional suffix
sudo ./build-php.sh

# Examples with arguments:
sudo ./build-php.sh -u focal -p 7.2
sudo ./build-php.sh -u jammy -p 7.4 -s co1
sudo ./build-php.sh -u noble -p 8.1 -j 4
sudo ./build-php.sh -u focal -p all
```

### Available options

- `-u, --ubuntu`: Ubuntu release (`focal`, `jammy`, `noble`, `20.04`, `22.04`, `24.04`)
- `-p, --php`: PHP version (`7.2`, `7.3`, `7.4`, `8.0`, `8.1`, exact version string `x.y.z`, comma-separated list such as `7.2,7.4`, or `all`)
- `-s, --suffix`: optional version suffix, e.g. `co1` will display `PHP 7.4.33-co1`
- `-j, --jobs`: number of parallel jobs for `make` (default: `nproc`)
- `-h, --help`: show help

---

## Deploying on a RunCloud server

Once the package `phpXXrc-<ubuntu>-patched.tar.gz` is generated, copy it to your RunCloud server and follow these steps:

```bash
# Example for PHP 7.4 (php74rc)
TAG="74"
PACKAGE="php74rc-focal-patched.tar.gz"

# 1. Stop the corresponding FPM service
sudo systemctl stop php${TAG}rc-fpm

# 2. Back up the current binaries
sudo cp -p /RunCloud/Packages/php${TAG}rc/bin/php /RunCloud/Packages/php${TAG}rc/bin/php.bak
sudo cp -p /RunCloud/Packages/php${TAG}rc/sbin/php-fpm /RunCloud/Packages/php${TAG}rc/sbin/php-fpm.bak

# 3. Extract the patched package over the installed binaries
sudo tar -xzf "$PACKAGE" -C /

# 4. Verify the version and modules
/RunCloud/Packages/php${TAG}rc/bin/php -v
/RunCloud/Packages/php${TAG}rc/bin/php -m

# 5. Start the service again
sudo systemctl start php${TAG}rc-fpm
sudo systemctl status php${TAG}rc-fpm
```

Rollback steps:

```bash
sudo systemctl stop php${TAG}rc-fpm
sudo mv /RunCloud/Packages/php${TAG}rc/bin/php.bak /RunCloud/Packages/php${TAG}rc/bin/php
sudo mv /RunCloud/Packages/php${TAG}rc/sbin/php-fpm.bak /RunCloud/Packages/php${TAG}rc/sbin/php-fpm
sudo systemctl start php${TAG}rc-fpm
```

---

## How to verify the patch is active

### 1. Visual verification of the binary

If you compiled with the `-s` option, for example `-s co1`, the following command should show the patched suffix:

```bash
/RunCloud/Packages/php74rc/bin/php -v
```

Expected output example:

```text
PHP 7.4.33-co1 (cli)
```

This confirms that the installed binary is the freshly built patched version.

### 2. Static binary check (fast and reliable)

Patch 3 neutralizes the callbacks for `session.upload_progress` by making the conditionals evaluate to `if (0)` in `main/rfc1867.c`. You can verify this in assembly without even starting a web server:

```bash
PHP_BIN="/RunCloud/Packages/php74rc/bin/php"
CB_ADDR=$(nm -D "$PHP_BIN" | awk '/php_rfc1867_callback/{print $1}' | sed 's/^0*//')

# Check whether rfc1867_post_handler reads that address
objdump -d --no-show-raw-insn "$PHP_BIN" | grep -A 250 '<rfc1867_post_handler>:' | grep "$CB_ADDR"
```

- **Patched binary**: no output is returned; the compiler optimized away the unreachable code path.
- **Original unpatched binary**: multiple assembly instructions (`mov`, `cmp`, etc.) read and check the callback address.

### 3. Functional HTTP verification for CVE-2026-109619

If you want to verify real behavior over HTTP, note that PHP defaults to `session.upload_progress.cleanup = 1`, which removes upload-progress data as soon as the upload completes.

To perform a functional test:

1. Temporarily disable cleanup of uploaded-progress data:
   - **Option A (recommended, no restart needed)**: create a `.user.ini` file in the same directory as the script with:
     ```ini
     session.upload_progress.enabled = 1
     session.upload_progress.cleanup = 0
     ```
   - **Option B**: set `session.upload_progress.cleanup = Off` in `/etc/phpXXrc/php.ini` or the relevant FPM pool, then restart FPM.

2. Create a test script (`test-upload.php`) on the server:
   ```php
   <?php
   session_start();
   echo "--- INI DIRECTIVES ---\n";
   echo "session.upload_progress.enabled: " . var_export(ini_get('session.upload_progress.enabled'), true) . "\n";
   echo "session.upload_progress.cleanup: " . var_export(ini_get('session.upload_progress.cleanup'), true) . "\n\n";

   echo "--- SESSION ---\n";
   print_r($_SESSION);

   echo "\n--- FILES ---\n";
   print_r($_FILES);
   ```

3. Generate a sample file and send a POST request:
   ```bash
   # Generate ~8 MB of test data
   head -c 8M </dev/urandom > /tmp/test-file.bin

   # Upload a multipart request; the upload-progress field must come before the file field
   curl -F "PHP_SESSION_UPLOAD_PROGRESS=test1234" \
        -F "file=@/tmp/test-file.bin" \
        https://yourdomain.com/test-upload.php
   ```

Expected results:

- **Unpatched vulnerable PHP**: `cleanup: '0'` and `$_SESSION` contains upload-progress metadata.
- **Patched PHP**: `$_SESSION` remains empty (`Array()`) even while `upload_progress.enabled` and `upload_progress.cleanup` are enabled.

This demonstrates that the upload callbacks have been neutralized in the engine.

> Remove the `.user.ini` file or restore `cleanup = On` after the test.

---

## Tested combinations

| Combination | Status |
|-------------|--------|
| **PHP 7.2 / Focal** | ✅ Built and verified |
| **PHP 7.3 / Focal** | ✅ Built and verified |
| **PHP 7.4 / Focal** | ✅ Built and verified |
| **PHP 8.0 / Focal** | ✅ Built and verified |
| **PHP 8.1 / Focal** | ✅ Built and verified |
| **PHP 7.4 / Jammy** | ✅ Ready with static OpenSSL 1.1.1w (`libssl1-rc`) |
| **PHP 8.0 / Jammy** | ✅ Ready with static OpenSSL 1.1.1w (`libssl1-rc`) |
| **PHP 8.1 / Jammy** | ✅ Built and verified |
| **PHP 8.1 / Noble** | ✅ Built and verified |

---

## Disclaimer

> [!WARNING]
> * **OpenSSL EOL**: the OpenSSL 1.1.1w binary embedded in older builds is no longer officially supported and may not receive security updates.
> * **PHP EOL**: PHP 7.2 – 8.1 is outside the official support window. These patches mitigate the specific PHP2Shell issue, but they do not fix all other known or future vulnerabilities in those versions.
> * **Independence**: this project is a community tool and is not sponsored, backed, or officially associated with RunCloud or The PHP Group.

