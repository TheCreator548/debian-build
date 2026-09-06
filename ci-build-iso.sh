#!/usr/bin/env bash
#
# ci-build-iso.sh — Build a custom GNOME-based Ubuntu/Debian live ISO in CI.
#
# Designed to run as a step in a GitHub Actions workflow on an
# `ubuntu-latest` runner (or any Debian/Ubuntu box with sudo + internet).
# It installs Node.js 24, embeds the OS-build logic as a Node script, and
# runs it as root to drive `live-build`.
#
# Usage (locally or in CI):
#   chmod +x ci-build-iso.sh
#   ./ci-build-iso.sh
#
# Configure via environment variables (all optional):
#   DISTRO       ubuntu | debian        (default: ubuntu)
#   CODENAME     release codename       (default: noble / bookworm)
#   OS_NAME      name shown in the OS   (default: novaOS)
#   OUT_DIR      build working dir      (default: ./build)
#
set -euo pipefail

DISTRO="${DISTRO:-ubuntu}"
CODENAME="${CODENAME:-}"
OS_NAME="${OS_NAME:-novaOS}"
OUT_DIR="${OUT_DIR:-$(pwd)/build}"

if [ -z "$CODENAME" ]; then
  if [ "$DISTRO" = "ubuntu" ]; then CODENAME="noble"; else CODENAME="bookworm"; fi
fi

echo "=================================================="
echo " Building: $OS_NAME  ($DISTRO $CODENAME, GNOME)"
echo " Output:   $OUT_DIR"
echo "=================================================="

# ---------- 1. Install Node.js 24 (system-wide, so it's visible under sudo) ----------
echo
echo "=== 1. Installing Node.js 24 ==="
# GitHub-hosted runners ship several Node versions pre-installed under
# /opt/hostedtoolcache, and that path is often ahead of /usr/bin on PATH.
# So even after installing Node 24 system-wide, a plain `node` lookup can
# still resolve to an older cached version. To avoid that, install via
# NodeSource (which places the binary at /usr/bin/node) and then always
# call that exact path explicitly instead of trusting `command -v node`.
NODE_BIN="/usr/bin/node"

if [ -x "$NODE_BIN" ] && "$NODE_BIN" --version | grep -q '^v24\.'; then
  echo "Node 24 already present: $("$NODE_BIN" --version)"
else
  curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi
echo "Using Node: $("$NODE_BIN" --version)"
"$NODE_BIN" --version | grep -q '^v24\.' || { echo "ERROR: Node 24 is required but not active. Found: $("$NODE_BIN" --version 2>&1)"; exit 1; }

# ---------- 2. Install live-build tooling ----------
echo
echo "=== 2. Installing live-build tooling ==="
sudo apt-get update
sudo apt-get install -y live-build live-config live-boot debootstrap syslinux-utils xorriso

# ---------- 3. Write the Node 24 build script ----------
echo
echo "=== 3. Writing build-os.mjs ==="
BUILD_JS="$(mktemp -d)/build-os.mjs"

cat > "$BUILD_JS" << 'NODE_EOF'
#!/usr/bin/env node
/**
 * build-os.mjs — Build a custom Debian/Ubuntu GNOME live ISO with live-build.
 * Invoked by ci-build-iso.sh with Node.js 24. Must run as root.
 */
import { execFileSync } from 'node:child_process';
import { mkdir, writeFile, chmod, copyFile, access } from 'node:fs/promises';
import { constants as FS } from 'node:fs';
import path from 'node:path';

function parseArgs(argv) {
  const opts = { distro: 'ubuntu', codename: null, name: 'novaOS', out: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    if (a === '--distro') opts.distro = next();
    else if (a === '--codename') opts.codename = next();
    else if (a === '--name') opts.name = next();
    else if (a === '--out') opts.out = next();
  }
  if (!opts.codename) opts.codename = opts.distro === 'ubuntu' ? 'noble' : 'bookworm';
  if (!opts.out) opts.out = path.resolve(process.cwd(), `${opts.codename}-custom`);
  else opts.out = path.resolve(process.cwd(), opts.out);
  return opts;
}

function distroProfile(distro) {
  return distro === 'ubuntu'
    ? {
        archiveAreas: 'main restricted universe multiverse',
        mirror: 'http://archive.ubuntu.com/ubuntu',
        securityMirror: 'http://security.ubuntu.com/ubuntu',
        theme: { gtk: 'Yaru-dark', icon: 'Yaru', cursor: 'Yaru' },
        extraPkgs: ['ubuntu-standard', 'yaru-theme-gtk', 'yaru-theme-icon', 'yaru-theme-sound',
          'gnome-shell-extension-dashtodock', 'firefox'],
      }
    : {
        archiveAreas: 'main contrib non-free non-free-firmware',
        mirror: 'http://deb.debian.org/debian',
        securityMirror: 'http://deb.debian.org/debian-security',
        theme: { gtk: 'Adwaita-dark', icon: 'Adwaita', cursor: 'Adwaita' },
        extraPkgs: ['firmware-linux-free', 'gnome-themes-extra'],
      };
}

function run(cmd, args, opts = {}) {
  console.log(`\n$ ${cmd} ${args.join(' ')}`);
  execFileSync(cmd, args, { stdio: 'inherit', ...opts });
}

async function fileExists(p) {
  try { await access(p, FS.F_OK); return true; } catch { return false; }
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const profile = distroProfile(opts.distro);

  if (typeof process.getuid === 'function' && process.getuid() !== 0) {
    throw new Error('This script must run as root (invoke via sudo).');
  }

  console.log('=== Build plan ===');
  console.log(`Distro:   ${opts.distro}`);
  console.log(`Codename: ${opts.codename}`);
  console.log(`OS name:  ${opts.name}`);
  console.log(`Desktop:  GNOME (gnome-core)`);
  console.log(`Workdir:  ${opts.out}`);
  console.log(`Node:     ${process.version}`);

  console.log('\n=== Setting up live-build project ===');
  await mkdir(opts.out, { recursive: true });
  run('lb', [
    'config',
    '--mode', opts.distro,
    '--distribution', opts.codename,
    '--archive-areas', profile.archiveAreas,
    '--mirror-bootstrap', profile.mirror,
    '--mirror-binary', profile.mirror,
    '--mirror-binary-security', profile.securityMirror,
    '--mirror-chroot-security', profile.securityMirror,
    '--binary-images', 'iso-hybrid',
    '--debian-installer', 'none',
    '--iso-application', opts.name,
    '--iso-volume', opts.name.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 16) || 'CUSTOMOS',
    '--linux-flavours', 'generic',
    '--bootappend-live', `boot=live components username=user hostname=${opts.name.toLowerCase().replace(/[^a-z0-9]/g, '-')} locales=en_US.UTF-8`,
  ], { cwd: opts.out });

  console.log('\n=== Writing GNOME package list ===');
  const pkgListDir = path.join(opts.out, 'config', 'package-lists');
  await mkdir(pkgListDir, { recursive: true });
  const packages = [
    '# Desktop — GNOME, always',
    'gnome-core', 'gnome-shell', 'gnome-terminal', 'gnome-control-center',
    'gnome-tweaks', 'nautilus', 'gdm3', '',
    '# Browser',
    'firefox-esr', ...(opts.distro === 'ubuntu' ? ['firefox'] : []), '',
    '# Networking (ethernet/DHCP + NetworkManager GUI applet)',
    'network-manager', 'network-manager-gnome', 'net-tools', 'isc-dhcp-client', 'openssh-client', '',
    '# VirtualBox guest integration',
    'virtualbox-guest-utils', 'virtualbox-guest-x11', '',
    '# Theming',
    ...(opts.distro === 'ubuntu'
      ? ['yaru-theme-gtk', 'yaru-theme-icon', 'yaru-theme-sound', 'gnome-shell-extension-dashtodock']
      : ['gnome-themes-extra']),
    'gnome-shell-extension-appindicator', 'fonts-cantarell', 'fonts-noto-core', '',
    '# Boot splash',
    'plymouth', 'plymouth-themes', '',
    '# Basics',
    'sudo', 'locales', 'software-properties-common',
    ...(opts.distro === 'ubuntu' ? ['ubuntu-standard'] : ['firmware-linux-free']),
  ].join('\n') + '\n';
  await writeFile(path.join(pkgListDir, 'desktop.list.chroot'), packages, 'utf8');

  console.log('\n=== Writing hooks (services, default user, branding) ===');
  const hooksDir = path.join(opts.out, 'config', 'hooks', 'live');
  await mkdir(hooksDir, { recursive: true });

  await writeFile(path.join(hooksDir, '9010-enable-services.hook.chroot'),
`#!/bin/sh
set -e
systemctl enable gdm3
systemctl enable NetworkManager
systemctl enable vboxadd || true
systemctl enable vboxadd-service || true
`, 'utf8');
  await chmod(path.join(hooksDir, '9010-enable-services.hook.chroot'), 0o755);

  await writeFile(path.join(hooksDir, '9020-default-user.hook.chroot'),
`#!/bin/sh
set -e
if ! id -u user >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo,netdev,plugdev user
  echo "user:live" | chpasswd
fi
`, 'utf8');
  await chmod(path.join(hooksDir, '9020-default-user.hook.chroot'), 0o755);

  await writeFile(path.join(hooksDir, '9030-branding.hook.chroot'),
`#!/bin/sh
set -e
if [ -f /etc/os-release-custom ]; then
  cp /etc/os-release /etc/os-release.orig
  cp /etc/os-release-custom /etc/os-release
  rm -f /etc/os-release-custom
fi
dconf update || true
plymouth-set-default-theme -R spinner || true
`, 'utf8');
  await chmod(path.join(hooksDir, '9030-branding.hook.chroot'), 0o755);

  console.log('\n=== Writing branding (os-release, dconf theme defaults) ===');
  const includesEtc = path.join(opts.out, 'config', 'includes.chroot', 'etc');
  await mkdir(path.join(includesEtc, 'dconf', 'db', 'local.d'), { recursive: true });
  await mkdir(path.join(includesEtc, 'dconf', 'profile'), { recursive: true });

  await writeFile(path.join(includesEtc, 'os-release-custom'),
`NAME="${opts.name}"
PRETTY_NAME="${opts.name} 1.0"
ID=${opts.name.toLowerCase().replace(/[^a-z0-9]/g, '')}
ID_LIKE=${opts.distro}
VERSION="1.0"
VERSION_ID="1.0"
`, 'utf8');

  await writeFile(path.join(includesEtc, 'dconf', 'profile', 'user'),
    'user-db:user\nsystem-db:local\n', 'utf8');

  await writeFile(path.join(includesEtc, 'dconf', 'db', 'local.d', '01-look-and-feel'),
`[org/gnome/desktop/interface]
gtk-theme='${profile.theme.gtk}'
icon-theme='${profile.theme.icon}'
cursor-theme='${profile.theme.cursor}'
font-name='Cantarell 11'
color-scheme='prefer-dark'

[org/gnome/shell]
favorite-apps=['firefox${opts.distro === 'ubuntu' ? '' : '-esr'}.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop', 'org.gnome.Settings.desktop']
`, 'utf8');

  console.log('\n=== Building the ISO (this takes a while) ===');
  run('lb', ['clean'], { cwd: opts.out });
  run('lb', ['build'], { cwd: opts.out });

  const isoPath = path.join(opts.out, 'live-image-amd64.hybrid.iso');
  if (!(await fileExists(isoPath))) {
    throw new Error(`Expected ISO not found at ${isoPath} — check the lb build log above.`);
  }
  console.log('\n=== DONE ===');
  console.log(`ISO produced at: ${isoPath}`);
}

main().catch(err => {
  console.error(`\nBuild failed: ${err.message}`);
  process.exit(1);
});
NODE_EOF

echo "Wrote $BUILD_JS"
"$NODE_BIN" --check "$BUILD_JS"

# ---------- 4. Run the build as root ----------
echo
echo "=== 4. Running build-os.mjs as root ==="
sudo "$NODE_BIN" "$BUILD_JS" \
  --distro "$DISTRO" \
  --codename "$CODENAME" \
  --name "$OS_NAME" \
  --out "$OUT_DIR"

# ---------- 5. Stage the ISO for GitHub Actions artifact upload ----------
ISO_SRC="$OUT_DIR/live-image-amd64.hybrid.iso"
ARTIFACT_DIR="$(pwd)/artifacts"
mkdir -p "$ARTIFACT_DIR"
FINAL_ISO="$ARTIFACT_DIR/${OS_NAME}.iso"
sudo cp "$ISO_SRC" "$FINAL_ISO"
sudo chown "$(id -u):$(id -g)" "$FINAL_ISO"

echo
echo "=================================================="
echo " Build complete: $FINAL_ISO"
echo "=================================================="
# If running inside GitHub Actions, expose the path to later steps
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "iso_path=$FINAL_ISO" >> "$GITHUB_OUTPUT"
fi
