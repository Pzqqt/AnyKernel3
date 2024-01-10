#!/usr/bin/env python3
# encoding: utf-8

import os
import sys
import hashlib
import shutil
import subprocess
import tempfile
import time
import zipfile
from functools import wraps
from contextlib import contextmanager

import bsdiff4

from depmod_regen import main as do_depmod_regen


assert sys.platform == "linux"
assert subprocess.getstatusoutput("which 7za")[0] == 0

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PACKAGE_NAME_MULTI = "Melt-Kernel-marble-%s-multi.zip"

def timeit(func):
    @wraps(func)
    def _wrap(*args, **kwargs):
        time_start = time.time()
        r = func(*args, **kwargs)
        print("(Cost: %0.1f seconds)" % (time.time() - time_start))
        return r
    return _wrap

bsdiff4_file_diff = timeit(bsdiff4.file_diff)

@contextmanager
def change_dir(dir_path):
    cwd = os.getcwd()
    try:
        os.chdir(dir_path)
        yield None
    finally:
        os.chdir(cwd)

def local_path(*args):
    return os.path.join(BASE_DIR, *args)

def get_sha1(file_path):
    with open(file_path, "rb") as f:
        return hashlib.sha1(f.read()).hexdigest()

def mkdir(path):
    if os.path.exists(path):
        if os.path.isdir(path):
            return
        raise Exception("The path %s already exists and is not a directory!" % path)
    os.makedirs(path)

def file2file(src, dst, move=False):
    mkdir(os.path.split(dst)[0])
    if move:
        shutil.move(src, dst)
    else:
        shutil.copyfile(src, dst)

def remove_path(path):
    if os.path.isdir(path):
        shutil.rmtree(path)
    elif os.path.isfile(path):
        os.remove(path)

def make_zip(*include, exclude=()):

    def _skip_compress(file_name):
        for file_type in ('.7z', '.p'):
            if file_name.endswith(file_type):
                return True
        return False

    zip_path = tempfile.mktemp(".zip")
    try:
        with zipfile.ZipFile(zip_path, "w") as zip_:
            for item in include:
                if isinstance(item, (list, tuple)):
                    if len(item) != 2:
                        raise Exception("Unknown param: %s" % item)
                    item, arc_name = item[:2]
                    if os.path.isdir(item):
                        raise Exception("`arcname` cannot be defined for directory: %s" % item)
                elif isinstance(item, str):
                    arc_name = None
                else:
                    raise Exception("Unknown param: %s" % item)
                if os.path.isdir(item):
                    for root, dirs, files in os.walk(item):
                        for f in files:
                            if f not in exclude:
                                zip_.write(
                                    os.path.join(root, f),
                                    compress_type=zipfile.ZIP_DEFLATED,
                                    compresslevel=0 if _skip_compress(f) else 9,
                                )
                elif os.path.isfile(item):
                    zip_.write(
                        item,
                        arcname=arc_name,
                        compress_type=zipfile.ZIP_DEFLATED,
                        compresslevel=0 if _skip_compress(item) else 9,
                    )
                else:
                    raise Exception("Unknown file: " + item)
    except:
        remove_path(zip_path)
        raise
    return zip_path

def make_7z(dir_, output_file):
    with change_dir(dir_):
        rc, text = subprocess.getstatusoutput("7za a -t7z -bd %s ./*" % os.path.abspath(output_file))
    print(text)
    assert rc == 0

def main_multi(build_version):
    image_stock = local_path("Image")
    image_ksu = local_path("Image_ksu")

    assert os.path.exists(image_stock)
    assert os.path.exists(image_ksu)

    sha1_image_stock = get_sha1(image_stock)
    sha1_image_ksu = get_sha1(image_ksu)

    remove_path(local_path("bs_patches", "ksu.p"))
    print("Generating patch file...")
    bsdiff4_file_diff(image_stock, image_ksu, local_path("bs_patches", "ksu.p"))

    print("Regenerating module dependency information...")
    for d in ("_modules_miui", "_modules_hyperos"):
        assert do_depmod_regen(local_path(d, "_vendor_boot_modules"), "/lib/modules/") == 0
        assert do_depmod_regen(local_path(d, "_vendor_dlkm_modules"), "/vendor/lib/modules/") == 0

    file2file(local_path("anykernel.sh"), local_path("anykernel.sh.BAK"), move=True)
    try:
        print("Compressing _modules_miui.7z ...")
        make_7z(local_path("_modules_miui"), local_path("_modules_miui.7z"))
        print("Compressing _modules_hyperos.7z ...")
        make_7z(local_path("_modules_hyperos"), local_path("_modules_hyperos.7z"))
        with change_dir(BASE_DIR):
            with open("anykernel.sh.BAK", "r", encoding='utf-8') as f1:
                with open("anykernel.sh", "w", encoding='utf-8', newline='\n') as f2:
                    f2.write(
                        f1.read().replace("@SHA1_STOCK@", sha1_image_stock).replace("@SHA1_KSU@", sha1_image_ksu)
                    )
            print("Making zip package...")
            zip_file = make_zip(
                "META-INF", "tools", "_modules_miui.7z", "_modules_hyperos.7z", "bs_patches",
                "anykernel.sh", "_restore_anykernel.sh", "Image", "LICENSE", "banner",
            )
    finally:
        remove_path(local_path("anykernel.sh"))
        remove_path(local_path("_modules_miui.7z"))
        remove_path(local_path("_modules_hyperos.7z"))
        file2file(local_path("anykernel.sh.BAK"), local_path("anykernel.sh"), move=True)
    dst_zip_file = local_path(PACKAGE_NAME_MULTI % build_version)
    file2file(zip_file, dst_zip_file, move=True)
    print("\nDone! Output file:", dst_zip_file)

if __name__ == "__main__":
    if len(sys.argv) == 2:
        main_multi(sys.argv[1])
    else:
        print('Usage: %s [-s] build_version' % sys.argv[0])
