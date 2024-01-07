#!/usr/bin/env python3
# encoding: utf-8

import os
import subprocess
import sys
import shutil
import tempfile


FAKE_MOD_VERSION = "1.1"

assert sys.platform == "linux"
assert subprocess.getstatusoutput("which depmod")[0] == 0

def main(modules_dir: str, real_modules_path: str) -> int:
    assert os.path.isdir(modules_dir)
    if not real_modules_path.endswith('/'):
        real_modules_path += '/'
    tmp_base_dir = tempfile.mkdtemp(prefix="_modules_")
    print("- Copying module files...")
    tmp_modules_dir = os.path.join(tmp_base_dir, "lib", "modules", FAKE_MOD_VERSION)
    os.makedirs(tmp_modules_dir)
    try:
        for file in os.listdir(modules_dir):
            if file.endswith(".ko"):
                shutil.copy(os.path.join(modules_dir, file), tmp_modules_dir)

        print("- Running depmod...")
        rc_, text_ = subprocess.getstatusoutput("depmod -b %s %s" % (tmp_base_dir, FAKE_MOD_VERSION))
        print(text_)
        if rc_ != 0:
            return rc_

        for file in ("modules.alias", "modules.softdep"):
            shutil.copyfile(os.path.join(tmp_modules_dir, file), os.path.join(modules_dir, file))
            print("- Output: " + file)
        with open(os.path.join(tmp_modules_dir, "modules.dep"), 'r', encoding="utf-8") as f1:
            with open(os.path.join(modules_dir, "modules.dep"), 'w', encoding="utf-8") as f2:
                for line in f1.readlines():
                    f2.write(real_modules_path + line.replace(' ', ' ' + real_modules_path))
            print("- Output: modules.dep")

        print("- Done!")
        return 0
    finally:
        shutil.rmtree(tmp_base_dir)

if __name__ == "__main__":
    if len(sys.argv) == 3:
        sys.exit(main(sys.argv[1], sys.argv[2]))
    print('Usage: %s <modules_dir> <real_modules_path>' % sys.argv[0])
    sys.exit(2)
