"""Insert classes.dex into an apk (zip) that has no dex yet.

Usage: python adddex.py <apk> <classes.dex>

The bundled JBR distribution does not include the `jar` helper, so this
tiny script does what `jar uf` would: copy the apk, append the dex entry
with STORED... no, DEFLATE compression (apksigner accepts both).
"""
import shutil
import sys
import zipfile


def main() -> int:
    apk, dex = sys.argv[1], sys.argv[2]
    tmp = apk + ".tmp"
    with zipfile.ZipFile(apk, "r") as src, zipfile.ZipFile(
        tmp, "w", zipfile.ZIP_DEFLATED
    ) as dst:
        for item in src.infolist():
            if item.filename == "classes.dex":
                continue
            data = src.read(item.filename)
            info = zipfile.ZipInfo(item.filename, date_time=item.date_time)
            info.compress_type = item.compress_type
            info.external_attr = item.external_attr
            dst.writestr(info, data)
        dst.write(dex, "classes.dex", compress_type=zipfile.ZIP_DEFLATED)
    shutil.move(tmp, apk)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
