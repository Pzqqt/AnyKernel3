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

import rich

from depmod_regen import main as do_depmod_regen
from simulate_load_kernel_modules import main as do_simulate_load_kernel_modules


VMLINUX_SYMVERS_FILE = '/home/pzqqt/working/android_kernel_xiaomi_marble/out/vmlinux.symvers'
SIGN_ZIP = False
APKSIGNER_JAR = 'apksigner.jar'
SIGN_PRIVATE_KEY = 'your_pk.jks'
SIGN_PRIVATE_KEY_PASSWORD = 'pass:your_pk_password'

assert sys.platform == "linux"
assert shutil.which("7za")
assert shutil.which("hdiffz")
if SIGN_ZIP:
    assert shutil.which("java")

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PACKAGE_NAME_MULTI = "Melt-marble-%s-multi.zip"

def timeit(func):
    @wraps(func)
    def _wrap(*args, **kwargs):
        time_start = time.time()
        r = func(*args, **kwargs)
        print("(Cost: %0.1f seconds)" % (time.time() - time_start))
        return r
    return _wrap

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

def temp_path(*args):
    return os.path.join(tempfile.gettempdir(), *args)

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
    mkdir(os.path.dirname(dst))
    if move:
        shutil.move(src, dst)
    else:
        shutil.copyfile(src, dst)

def remove_path(path):
    if os.path.isdir(path):
        shutil.rmtree(path)
    elif os.path.isfile(path):
        os.remove(path)

def make_zip(*include):

    def _skip_compress(file_name):
        for file_type in ('.7z', '.p'):
            if file_name.endswith(file_type):
                return True
        return False

    zip_path = tempfile.mktemp(".zip")
    try:
        with zipfile.ZipFile(zip_path, "w") as zip_:
            for item in include:
                if os.path.isdir(item):
                    for root, dirs, files in os.walk(item):
                        for f in files:
                            zip_.write(
                                str(os.path.join(root, f)),
                                compress_type=zipfile.ZIP_DEFLATED,
                                compresslevel=0 if _skip_compress(f) else 9,
                            )
                elif os.path.isfile(item):
                    zip_.write(
                        item,
                        arcname=os.path.basename(item) if os.path.isabs(item) else None,
                        compress_type=zipfile.ZIP_DEFLATED,
                        compresslevel=0 if _skip_compress(item) else 9,
                    )
                else:
                    raise Exception("Unknown file: " + item)
    except:
        remove_path(zip_path)
        raise
    return zip_path

def create_hdiff_patch(src: str, dst: str, out_patch: str):
    cp = subprocess.run(["hdiffz", "-c-zstd", "-SD", "-d", src, dst, out_patch])
    cp.check_returncode()

@timeit
def make_7z(path_, output_file, extra_args=""):
    args = ["7za", "a", "-t7z", "-mx=9"]
    if extra_args:
        args.append(extra_args)
    args += ["-bd", os.path.abspath(output_file)]
    if os.path.isdir(path_):
        cwd = path_
        args.append("./*")
    else:
        dirname, basename = os.path.split(path_)
        cwd = dirname
        args.append("./" + basename)
    cp = subprocess.run(args, cwd=cwd)
    cp.check_returncode()

def sign_zip(zip_path):
    # Signing a zip file is just like signing an apk
    try:
        cp = subprocess.run([
            "java", "-jar", APKSIGNER_JAR, "sign", "--ks", SIGN_PRIVATE_KEY,
            "--ks-pass", SIGN_PRIVATE_KEY_PASSWORD, "--min-sdk-version", "32", zip_path
        ])
        cp.check_returncode()
    finally:
        remove_path(zip_path + ".idsig")

def main_multi(build_version):
    image_stock = local_path("Image")
    image_ksu = local_path("Image_ksu")
    image_susfs = local_path("Image_susfs")
    temp_ak_sh = temp_path("anykernel.sh")
    temp_image_7z = temp_path("Image.7z")
    temp_dtb_7z = temp_path("_dtb.7z")
    temp_mods_hos_7z = temp_path("_modules_hyperos.7z")

    assert os.path.exists(image_stock)
    assert os.path.exists(image_ksu)
    have_image_susfs = os.path.exists(image_susfs)

    rich.print("[yellow][1/9][/yellow] [green]Generating SHA1 for image files...[/green]")
    sha1_image_stock = get_sha1(image_stock)
    sha1_image_ksu   = get_sha1(image_ksu)
    print("SHA1 for Image      :", sha1_image_stock)
    print("SHA1 for Image_ksu  :", sha1_image_ksu)
    if have_image_susfs:
        sha1_image_susfs = get_sha1(image_susfs)
        print("SHA1 for Image_susfs:", sha1_image_susfs)
    else:
        sha1_image_susfs = '0' * 40

    rich.print("[yellow][2/9][/yellow] [green]Generating patch file...[/green]")
    remove_path(local_path("bs_patches", "ksu.p"))
    remove_path(local_path("bs_patches", "susfs.p"))
    create_hdiff_patch(image_stock, image_ksu,   local_path("bs_patches", "ksu.p"))
    if have_image_susfs:
        create_hdiff_patch(image_stock, image_susfs, local_path("bs_patches", "susfs.p"))

    rich.print("[yellow][3/9][/yellow] [green]Regenerating module dependency information...[/green]")
    assert do_depmod_regen(local_path("_modules_hyperos", "_vendor_boot_modules"), "/lib/modules/") == 0
    assert do_depmod_regen(local_path("_modules_hyperos", "_vendor_dlkm_modules"), "/vendor/lib/modules/") == 0

    rich.print("[yellow][4/9][/yellow] [green]Simulating loading kernel modules...[/green]")
    assert do_simulate_load_kernel_modules(
        VMLINUX_SYMVERS_FILE,
        local_path("_modules_hyperos", "_vendor_boot_modules", "modules.load.recovery"), "/lib/modules/",
    ) == 0
    assert do_simulate_load_kernel_modules(
        VMLINUX_SYMVERS_FILE,
        local_path("_modules_hyperos", "_vendor_boot_modules", "modules.load"), "/lib/modules/",
        local_path("_modules_hyperos", "_vendor_dlkm_modules", "modules.load"), "/vendor/lib/modules/",
    ) == 0

    try:
        rich.print("[yellow][5/9][/yellow] [green]Compressing Image.7z ...[/green]")
        make_7z(local_path("Image"), temp_image_7z)

        rich.print("[yellow][6/9][/yellow] [green]Compressing _modules_hyperos.7z ...[/green]")
        make_7z(local_path("_modules_hyperos"), temp_mods_hos_7z, extra_args="-mf=off")

        rich.print("[yellow][7/9][/yellow] [green]Compressing _dtb.7z ...[/green]")
        make_7z(local_path("_dtb"), temp_dtb_7z)

        rich.print("[yellow][8/9][/yellow] [green]Making zip package...[/green]")
        with change_dir(BASE_DIR):
            with open("anykernel.sh", "r", encoding='utf-8') as f1:
                with open(temp_ak_sh, "w", encoding='utf-8', newline='\n') as f2:
                    f2.write(
                        f1.read().replace("@SHA1_STOCK@", sha1_image_stock) \
                                 .replace("@SHA1_KSU@",   sha1_image_ksu) \
                                 .replace("@SHA1_SUSFS@", sha1_image_susfs)
                    )
            zip_file = make_zip(
                "META-INF", "tools", "bs_patches", "langs",
                temp_mods_hos_7z, temp_dtb_7z, temp_image_7z, temp_ak_sh,
                "_restore_anykernel.sh", "_rollback_anykernel.sh",
                "LICENSE", "banner",
            )
    finally:
        remove_path(temp_ak_sh)
        remove_path(temp_mods_hos_7z)
        remove_path(temp_dtb_7z)
        remove_path(temp_image_7z)

    rich.print("[yellow][9/9][/yellow] [green]Signing zip package...[/green]")
    if SIGN_ZIP:
        try:
            sign_zip(zip_file)
        except AssertionError:
            remove_path(zip_file)
            raise
    else:
        print("Skipping signing zip package...")

    dst_zip_file = local_path(PACKAGE_NAME_MULTI % build_version)
    file2file(zip_file, dst_zip_file, move=True)

    print(" ")
    rich.print("[green]Done! Output file: %s[/green]" % dst_zip_file)

if __name__ == "__main__":
    if len(sys.argv) == 2:
        main_multi(sys.argv[1])
    else:
        print('Usage: %s <build_version>' % sys.argv[0])
