#!/usr/bin/env python3
"""Fetch the platform headers needed to build health_shim.cpp outside an
Android tree, then print the include roots (one "ROOTS=" line).

- HIDL/libutils/liblog headers come from the AOSP VNDK v34 snapshot, and the
  generated android.hardware.health@2.0 headers (dropped from v34) from v30.
  Only the headers actually included are downloaded, into ./inc.
- libc++ headers come from the NDK, copied to ./inc_cxx with the ABI namespace
  switched from std::__ndk1 to the platform's std::__1, so that the shim's
  IHealth::getService(const std::string&, bool) symbol matches the one the
  Motorola blob imports.
"""
import base64, json, os, re, shutil, subprocess, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
INC = os.path.join(HERE, "inc")
INC_CXX = os.path.join(HERE, "inc_cxx")
NDK = os.environ.get("ANDROID_NDK_HOME",
                     os.path.expanduser("~/android-toolchain/android-sdk/ndk/27.2.12479018"))
TOOLCHAIN = NDK + "/toolchains/llvm/prebuilt/linux-x86_64"
CLANG = TOOLCHAIN + "/bin/clang++"
SNAPSHOT = "https://android.googlesource.com/platform/prebuilts/vndk/%s/+/refs/heads/main/arm64/include/"
VERSIONS = ("v34", "v30")


def gitiles(url):
    return urllib.request.urlopen(url).read()


def load_index(v):
    path = os.path.join(INC, "index_%s.txt" % v)
    if not os.path.exists(path):
        os.makedirs(INC, exist_ok=True)
        tree = json.loads(gitiles(SNAPSHOT % v + "?format=JSON&recursive=1")[4:])
        open(path, "w").write("\n".join(e["name"] for e in tree["entries"] if e["type"] == "blob"))
    return open(path).read().split("\n")


def prepare_libcxx():
    if os.path.exists(INC_CXX):
        return
    shutil.copytree(TOOLCHAIN + "/sysroot/usr/include/c++/v1", INC_CXX)
    site = os.path.join(INC_CXX, "__config_site")
    s = open(site).read().replace("_LIBCPP_ABI_NAMESPACE __ndk1", "_LIBCPP_ABI_NAMESPACE __1")
    open(site, "w").write(s)


def rank(path):
    for i, prefix in enumerate(["generated-headers", "system", "frameworks", "hardware", "external"]):
        if path.startswith(prefix):
            return i
    return 9


def main():
    prepare_libcxx()
    indexes = {v: load_index(v) for v in VERSIONS}
    roots = []
    for _ in range(400):
        cmd = [CLANG, "--target=aarch64-linux-android30", "-std=c++17", "-fsyntax-only",
               "-nostdinc++", "-isystem", INC_CXX, "-D__ANDROID_VNDK__", "-Wno-everything"]
        cmd += sum((["-I", os.path.join(INC, r)] for r in roots), [])
        p = subprocess.run(cmd + [os.path.join(HERE, "health_shim.cpp")], capture_output=True, text=True)
        m = re.search(r"fatal error: '([^']+)' file not found", p.stderr)
        if not m:
            if p.returncode:
                sys.exit(p.stderr[-3000:])
            print("ROOTS=" + " ".join(roots))
            return
        name = m.group(1)
        for v in VERSIONS:
            cands = [e for e in indexes[v] if e == name or e.endswith("/" + name)]
            if cands:
                break
        else:
            sys.exit("header not found in snapshots: " + name)
        best = sorted(cands, key=lambda c: (rank(c), len(c)))[0]
        dst = os.path.join(INC, best)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        open(dst, "wb").write(base64.b64decode(gitiles(SNAPSHOT % v + best + "?format=TEXT")))
        root = best[: len(best) - len(name)].rstrip("/")
        if root not in roots:
            roots.append(root)
        print("fetched " + best, file=sys.stderr)
    sys.exit("too many headers")


if __name__ == "__main__":
    main()
