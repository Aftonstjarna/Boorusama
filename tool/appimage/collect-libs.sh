#!/usr/bin/env bash
# Build an aarch64 library set for BooruFlow's libmpv.
#
# Two modes:
#   MODE=minimal (default)  closure of the 14 SONAMEs the headset reported missing.
#                           Keeps the existing libmpv. Small.
#   MODE=full               closure of the suite's own libmpv, including a
#                           replacement libmpv. Large (~167 MiB); fallback only.
#
# Why Debian trixie and not the MPV Flatpak:
#   The Flatpak ships libmpv.so.2 but belongs to a different ABI family
#   (libplacebo.so.387, libcdio.so.21, libluajit) and needs glibc 2.44.
#   The libmpv on the headset wants libplacebo.so.349 / libcdio.so.19 =
#   Debian trixie. One suite, max GLIBC_2.39 here, no mixing.
#
# usage: MODE=minimal collect-libs.sh [output-dir]
set -euo pipefail

suite=${SUITE:-trixie}
mode=full
case "$mode" in minimal|full) ;; *) echo "MODE must be minimal or full" >&2; exit 2 ;; esac
if [ "$mode" = minimal ]; then
  out=${1:-dist/boorusama-libs-aarch64}
else
  out=${1:-dist/boorusama-libs-aarch64}
fi
out=$(realpath -m "$out")
case "$out" in
  */boorusama-libs*) ;;
  *) echo "refusing to write to $out (name must contain boorusama-libs)" >&2; exit 2 ;;
esac
image=${IMAGE:-docker.io/library/debian:${suite}-slim}

rm -rf "$out"; mkdir -p "$out/lib"

echo "==> mode=$mode suite=$suite"
podman run --rm -i --arch=arm64 -v "$out:/out:Z" \
  -e "MODE=$mode" "$image" bash -eu -s <<'INNER'
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends binutils python3 >/dev/null

  pkg=""
  for p in libmpv2 libmpv1; do
    if apt-cache show "$p" >/dev/null 2>&1; then pkg=$p; break; fi
  done
  [ -n "$pkg" ] || { echo "no libmpv package in this suite" >&2; exit 1; }

  apt-get install -y -qq --no-install-recommends --download-only "$pkg" >/dev/null
  # Some NEEDED libraries come from packages preinstalled in the image, so
  # --download-only never fetches them. Resolve their package and fetch it too.
  for so in libacl.so.1 libbz2.so.1.0 libcrypto.so.3 libffi.so.8 libgmp.so.10 \
            libhogweed.so.6 liblz4.so.1 liblzma.so.5 libncursesw.so.6 libnettle.so.8 \
            libssl.so.3 libtinfo.so.6 libudev.so.1 libz.so.1 libzstd.so.1 \
            libbsd.so.0 libmd.so.0 libcap.so.2 libxxhash.so.0 libdb-5.3.so; do
    f=$(find /usr/lib /lib -name "$so" 2>/dev/null | head -1)
    [ -n "$f" ] || continue
    p=$(dpkg -S "$(readlink -f "$f")" 2>/dev/null | cut -d: -f1) || continue
    [ -n "$p" ] && apt-get install -y -qq --no-install-recommends --reinstall \
      --download-only "$p" >/dev/null 2>&1 || true
  done
  mkdir -p /stage
  for d in /var/cache/apt/archives/*.deb; do dpkg-deb -x "$d" /stage; done

  python3 - <<"PY"
import os, re, subprocess, sys

stage, out = "/stage", "/out/lib"
mode = os.environ["MODE"]

# Resolved by the host: glibc, loader, compiler runtime, GPU stack, core X11,
# and the font/GLib stack that GTK and SteamOS already provide.
DENY = re.compile(r"""^(
  ld-linux.*|libc\.so.*|libm\.so.*|libmvec.*|libpthread.*|libdl.*|librt.*|
  libresolv.*|libutil\.so.*|libgcc_s.*|libstdc\+\+.*|
  libvulkan.*|libGL.*|libEGL.*|libGLX.*|libOpenGL.*|libgbm.*|libdrm.*|
  libX11\.so.*|libX11-xcb.*|libXext\.so.*|libXrender.*|libXau\.so.*|
  libXdmcp.*|libXfixes.*|libXrandr.*|libXi\.so.*|libXcursor.*|libxcb.*|
  libharfbuzz.*|libfreetype.*|libfontconfig.*|libfribidi.*|
  libglib-.*|libgobject-.*|libgio-.*|libgmodule-.*|libpango.*|libcairo.*|
  libgdk.*|libgtk.*|libatk.*|libepoxy.*|libicu.*|libsmbclient.*|
  libasound\.so.*|libpulse\.so.*|libpulsecommon.*|libpipewire.*|
  libwayland.*
)$""", re.X)

# Exactly what the headset's ldd reported as "not found".
MISSING = [
  "libplacebo.so.349", "libcdio_paranoia.so.2", "libcdio_cdda.so.2",
  "libcdio.so.19", "libdvdnav.so.4", "libmujs.so.3", "liblua5.2.so.0",
  "libuchardet.so.0", "libsndio.so.7", "libdisplay-info.so.2",
  "libjpeg.so.62", "libsixel.so.1", "libXss.so.1", "libXpresent.so.1",
]

index = {}
for root, _, files in os.walk(stage):
    for f in files:
        index.setdefault(f, os.path.join(root, f))

def needed(p):
    s = subprocess.run(["readelf", "-d", p], capture_output=True, text=True).stdout
    return re.findall(r"\(NEEDED\).*?\[(.*?)\]", s)

def glibc(p):
    s = subprocess.run(["readelf", "--version-info", p], capture_output=True, text=True).stdout
    v = re.findall(r"GLIBC_([0-9.]+)", s)
    return max(v, key=lambda x: [int(i) for i in x.split(".")]) if v else None

def soname(p):
    s = subprocess.run(["readelf", "-d", p], capture_output=True, text=True).stdout
    m = re.search(r"\(SONAME\).*?\[(.*?)\]", s)
    return m.group(1) if m else None

if mode == "minimal":
    queue = list(MISSING)
else:
    mpvs = sorted(n for n in index if n.startswith("libmpv.so."))
    if not mpvs:
        sys.exit("libmpv not found in unpacked packages")
    seed = os.path.realpath(index[sorted(mpvs, key=lambda n: [int(x) for x in n.split(".")[2:]])[-1]])
    queue = [soname(seed) or "libmpv.so.2"]

seen, missing, host = {}, [], set()
while queue:
    n = queue.pop(0)
    if n in seen:
        continue
    if DENY.match(n):
        host.add(n)
        continue
    p = index.get(n)
    if not p:
        missing.append(n)
        continue
    real = os.path.realpath(p)
    seen[n] = real
    for d in needed(real):
        if d not in seen:
            queue.append(d)

rows, total = [], 0
for n, p in sorted(seen.items()):
    size = os.path.getsize(p)
    total += size
    rows.append((n, glibc(p) or "-", size))
    subprocess.run(["cp", "-L", p, os.path.join(out, n)], check=True)

for n, g, s in rows:
    print(f"{n:38s} glibc<={g:6s} {s//1024:6d}K")
print(f"\n{len(rows)} libs, {total/1048576:.1f} MiB", file=sys.stderr)
if missing:
    print("not found in this suite (investigate):", file=sys.stderr)
    for m in sorted(set(missing)): print("  " + m, file=sys.stderr)
if host:
    print("left to the host (verify SteamOS has them):", file=sys.stderr)
    for h in sorted(host): print("  " + h, file=sys.stderr)
PY
INNER

echo "==> bundle"
ls -1 "$out/lib" | wc -l | awk '{print "  libs: "$1}'
du -sh "$out/lib"

cat > "$out/install.sh" <<'EOF'
#!/bin/sh
# Run on the Steam Frame from the unpacked bundle directory.
set -eu
APP=${APP:-$HOME/Applications/boorusama}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$APP/lib.bak"
for f in "$APP"/lib/*.so*; do
  [ -e "$f" ] && cp -an "$f" "$APP/lib.bak/" 2>/dev/null || true
done
cp -av "$here"/lib/. "$APP/lib/"
echo "installed; verify with ./check.sh"
EOF
chmod +x "$out/install.sh"

cat > "$out/check.sh" <<'EOF'
#!/bin/sh
# Run on the Steam Frame.
set -u
APP=${APP:-$HOME/Applications/boorusama}
export LD_LIBRARY_PATH="$APP/lib"
echo "== libmpv"; ldd "$APP/lib/libmpv.so.2" 2>&1 | grep -E 'not found|version' || echo "  all resolved"
echo "== app";    ldd "$APP/boorusama"        2>&1 | grep -E 'not found|version' || echo "  all resolved"
echo "== launch"; "$APP/boorusama" --version 2>&1 | head -5 || true
EOF
chmod +x "$out/check.sh"

echo
echo "bundle: $out"
echo "ship:   tar czf $out.tar.gz -C $(dirname "$out") $(basename "$out")"
