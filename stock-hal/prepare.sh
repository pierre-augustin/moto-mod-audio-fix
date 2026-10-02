#!/bin/sh
# Download beckham's stock (Motorola) audio HAL and its libraries from the
# LineageOS proprietary repo (TheMuppets, lineage-20 branch, before the HAL was
# dropped) and prepare them to run next to the CAF HAL, the same way nash does.
#
# Libraries that also exist in CAF form on the device are renamed with
# same-length names, edited in place (no ELF restructuring):
#   audio.primary.sdm660.so -> audio.primary.sdm66m.so  (ro.hardware.audio.primary=sdm66m)
#   libtinyalsa.so          -> libtinymoto.so
#   libaudioroute.so        -> libaudiormoto.so
# Nothing proprietary is stored in this repo. Output: stock-hal/out/
set -e
cd "$(dirname "$0")"
BASE=https://raw.githubusercontent.com/TheMuppets/proprietary_vendor_motorola_beckham/lineage-20/proprietary/vendor/lib
mkdir -p orig out

while read -r sum path; do
    f=$(basename "$path")
    [ -f "orig/$f" ] || curl -sfL -o "orig/$f" "$BASE/$path"
    echo "$sum  orig/$f" | sha256sum -c --quiet - || { echo "checksum mismatch: $f" >&2; exit 1; }
done <<'EOF'
08ceb14066e5243b4e30f4c556a2a610fddfc4da2f279748ac6368b4c31f79a3 hw/audio.primary.sdm660.so
18d0d6d6330ec9f8b55e41cca5ec0231d685e837aa76a40b3379d91e32d3a70a libtinyalsa.so
89b025f8103f3171c5b68a40bcea348ca90d88294cf733fbbc74c51c31fdb691 libaudioroute.so
55173bc7dcb0411ccd2665656c01db6f55c9c413d455e654798c1606c81555f7 libmotaudioutils.so
acc8927933e8153f8ad76b07a52c38a6dc4141e4ea29cb7c25ccf903cd2ff7be libunshorten.so
0374ef235d9c9aac8b295dbd85cbca87bb0ece94956c3ae174c8c8ab6604d6b7 libtinycompress_vendor.so
EOF

python3 - <<'PY'
renames = [(b"libtinyalsa.so\0", b"libtinymoto.so\0"),
           (b"libaudioroute.so\0", b"libaudiormoto.so\0"),
           (b"audio.primary.sdm660.so\0", b"audio.primary.sdm66m.so\0")]
files = {"audio.primary.sdm660.so": "audio.primary.sdm66m.so",
         "libtinyalsa.so": "libtinymoto.so",
         "libaudioroute.so": "libaudiormoto.so",
         "libmotaudioutils.so": "libmotaudioutils.so",
         "libunshorten.so": "libunshorten.so",
         "libtinycompress_vendor.so": "libtinycompress_vendor.so"}
for src, dst in files.items():
    data = open("orig/" + src, "rb").read()
    size = len(data)
    for old, new in renames:
        data = data.replace(old, new)
    assert len(data) == size
    open("out/" + dst, "wb").write(data)
PY

# Same bytes as the files validated on the device.
(cd out && sha256sum -c --quiet -) <<'EOF'
4e163d2f50e7ee653d13b48f7ebcbe2b6b813c0e4d155917c54d798a5ac2c669  audio.primary.sdm66m.so
48ab094d863d59168ce56658b67de3c54cc85466cc182352b7a095b0703ee02f  libtinymoto.so
8c3fa4002b1e5342e2745790ad83502ded988dbac5406a81c2e5fe805f97485d  libaudiormoto.so
55173bc7dcb0411ccd2665656c01db6f55c9c413d455e654798c1606c81555f7  libmotaudioutils.so
acc8927933e8153f8ad76b07a52c38a6dc4141e4ea29cb7c25ccf903cd2ff7be  libunshorten.so
0374ef235d9c9aac8b295dbd85cbca87bb0ece94956c3ae174c8c8ab6604d6b7  libtinycompress_vendor.so
EOF
echo "OK: stock-hal/out/"
