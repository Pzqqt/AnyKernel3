#!/usr/bin/env python3
# encoding: utf-8

import os
import re
import subprocess
import sys
import shutil
import weakref
from concurrent.futures import ProcessPoolExecutor, as_completed
from typing import Set, Dict, Union, Final, Tuple


assert sys.platform == "linux"
for _tool in ("grep", "awk", "modinfo", "modprobe"):
    assert shutil.which(_tool)

__AUTHOR__: Final = "Pzqqt"

try:
    from tqdm import tqdm
    HAS_TQDM = True
except ImportError:
    HAS_TQDM = False
    # noinspection PyUnusedLocal
    def tqdm(*args, **kwargs):
        raise NotImplementedError

class Crc:

    __slots__ = {"_crc", "_hex"}

    @staticmethod
    def crc_to_int(crc: str) -> int:
        if re.match(r'0x[0-9a-fA-F]+', crc):
            return int(crc[2:], 16)
        raise ValueError(crc)

    @staticmethod
    def int_to_crc(num: int) -> str:
        return '0x' + hex(num)[2:].zfill(8)

    def __init__(self, crc: Union[str, int]):
        if isinstance(crc, str):
            self._crc = self.crc_to_int(crc)
        elif isinstance(crc, int):
            if crc < 0 or crc > 0xffffffff:
                raise ValueError("Invalid CRC value: %d" % crc)
            self._crc = crc
        else:
            raise TypeError("Invalid type")
        self._hex = self.int_to_crc(self._crc)

    def to_int(self) -> int:
        return self._crc

    def to_hex(self) -> str:
        return self._hex

    def __eq__(self, other) -> bool:
        return self._crc == other.to_int()

    def __hash__(self) -> int:
        return hash(self._crc)

    __int__ = to_int
    __str__ = to_hex

    def __repr__(self):
        return "Crc(%s)" % self._hex

class KernelModule:

    __slots__ = {"__path", "__name", "__modversions", "__export_modversions", "__cached_depends", "__weakref__"}

    def __init__(self, module_path: str):
        abs_path = os.path.abspath(module_path)
        if not os.path.isfile(abs_path):
            raise Exception("The module file does not exist: %s!" % abs_path)
        self.__path = abs_path

        # get module name
        cp = subprocess.run(
            ["modinfo", "-F", "name", self.__path],
            encoding="utf-8", stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        cp.check_returncode()
        output = cp.stdout.rstrip()
        if not output:
            print("Warning: Module %s has no name defined, the file name will be used instead as the module name."
                  % self.__path)
            # The character '-' seems to be disallowed in module names,
            # so it is replaced with an '_'.
            self.__name = os.path.basename(self.__path).split('.', 1)[0].replace('-', '_')
        else:
            self.__name = output

        # get module symbol versions
        self.__modversions: Dict[str, Crc] = {}
        cp = subprocess.run(["modprobe", self.__path, "--show-modversions"], encoding="utf-8", capture_output=True)
        cp.check_returncode()
        output = cp.stdout.rstrip()
        for line in output.splitlines():
            crc_str, symbol = line.strip().split()
            self.__modversions[symbol] = Crc(crc_str)

        # get module exported symbol versions
        self.__export_modversions: Dict[str, Crc] = {}
        cp = subprocess.run(["modprobe", self.__path, "--show-exports"], encoding="utf-8", capture_output=True)
        output = cp.stdout.rstrip()
        if cp.returncode == 0:
            for line in output.splitlines():
                crc_str, symbol = line.strip().split()
                self.__export_modversions[symbol] = Crc(crc_str)

        self.__cached_depends: Union[None, Tuple[str, ...]] = None

    path = property(lambda self: self.__path)
    name = property(lambda self: self.__name)
    modversions = property(lambda self: self.__modversions.copy())
    export_modversions = property(lambda self: self.__export_modversions.copy())

    @property
    def depends(self) -> Tuple[str, ...]:
        if self.__cached_depends is None:
            cp = subprocess.run(
                ["modinfo", "-F", "depends", self.__path],
                encoding="utf-8", stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            )
            output = cp.stdout.rstrip()
            if cp.returncode != 0 or not output:
                self.__cached_depends = tuple()
            else:
                # The character '-' seems to be disallowed in module names,
                # so it is replaced with an '_'.
                self.__cached_depends = tuple([m.replace('-', '_') for m in output.strip().split(',')])
        return self.__cached_depends

    def __repr__(self) -> str:
        return "KernelModule('%s')" % self.name

class VirtualKernelSymbolInfo:

    __slots__ = {"__source", "__crc", "__used_by"}

    def __init__(self, source: Union[None, KernelModule], crc: Crc, used_by: Set[str]):
        self.__source = source
        self.__crc = crc
        self.__used_by = used_by

    source = property(lambda self: self.__source)
    crc = property(lambda self: self.__crc)
    used_by = property(lambda self: self.__used_by.copy())

    def _add_used_by(self, mod_name: str):
        self.__used_by.add(mod_name)

class VirtualKernel:

    def __init__(self, vmlinux_symvers_file: str, *, ignore_crc_disagree: bool = False, debug: bool = False):
        self.ignore_crc_disagree = ignore_crc_disagree
        self.debug = debug
        self.__symbols: Dict[str, VirtualKernelSymbolInfo] = {}
        # load vmlinux.symvers
        with open(vmlinux_symvers_file, 'r', encoding="utf-8") as f:
            for line_no, line in enumerate(f.readlines(), 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    symbol_name = line.split()[1]
                    self.__symbols[symbol_name] = VirtualKernelSymbolInfo(
                        source=None,
                        crc=Crc(line.split()[0]),
                        used_by=set(),
                    )
                except (IndexError, ValueError, TypeError) as e:
                    raise RuntimeError("Error parsing line %d of %s!" % (line_no, vmlinux_symvers_file)) from e
        self.__loaded_modules: Dict[str, KernelModule] = {}

    symbols = property(lambda self: self.__symbols.copy())
    loaded_modules = property(lambda self: self.__loaded_modules.copy())

    def load_module(self, kernel_module: KernelModule) -> bool:
        if kernel_module.name in self.__loaded_modules.keys():
            if self.debug:
                print("Warning: Module %s has already been loaded" % kernel_module.name)
            return True
        km_modversions = kernel_module.modversions
        km_export_modversions = kernel_module.export_modversions
        if missing_symbols := (km_modversions.keys() - self.__symbols.keys()):
            for symbol in sorted(missing_symbols):
                print("%s: Unknown symbol: %s" % (kernel_module.name, symbol))
            return False
        if disagree_crc_symbols := {
            sym_name
            for sym_name, sym_crc in km_modversions.items()
            if self.__symbols[sym_name].crc != sym_crc
        }:
            for sym_name in sorted(disagree_crc_symbols):
                print("%s: Disagrees about version of symbol %s, %s (%s) vs %s (%s)" % (
                    kernel_module.name, sym_name,
                    self.__symbols[sym_name].crc,
                    self.__symbols[sym_name].source.name if self.__symbols[sym_name].source else "kernel",
                    km_modversions[sym_name], kernel_module.name,
                ))
            if not self.ignore_crc_disagree:
                return False
        if dup_symbols := (km_export_modversions.keys() & self.__symbols.keys()):
            for symbol in sorted(dup_symbols):
                print("%s: Repeated symbol: %s" % (kernel_module.name, symbol))
            return False
        for sym_name, sym_crc in km_export_modversions.items():
            self.__symbols[sym_name] = VirtualKernelSymbolInfo(
                source=weakref.proxy(kernel_module),
                crc=sym_crc,
                used_by=set(),
            )
        for sym_name in km_modversions.keys():
            # noinspection PyProtectedMember
            self.__symbols[sym_name]._add_used_by(kernel_module.name)
        self.__loaded_modules[kernel_module.name] = kernel_module
        if self.debug:
            print("Loaded kernel module %s" % kernel_module.name)
        return True

    def load_modules(self, modules_load_file: str, real_modules_path: str = "") -> bool:
        # load modules.load
        with open(modules_load_file, 'r', encoding="utf-8") as f:
            modules = [m.strip() for m in f.readlines()]

        modules_dir = os.path.abspath(os.path.dirname(modules_load_file))

        # load modules.dep
        modules_dep_dic = {}
        with open(os.path.join(modules_dir, "modules.dep"), 'r', encoding="utf-8") as f:
            for line_no, line in enumerate(f.readlines(), 1):
                line = line.strip()
                if not line:
                    continue
                line_split = line.split()
                module_path = line_split[0]
                if not module_path.endswith(":"):
                    raise RuntimeError(
                        "Error parsing line %d of %s!" % (line_no, os.path.join(modules_dir, "modules.load"))
                    )
                module_path = module_path[:-1]
                module_path = os.path.relpath(module_path, real_modules_path)
                dep_modules = [os.path.relpath(m, real_modules_path) for m in line_split[1:]]
                modules_dep_dic[module_path] = tuple(dep_modules)

        cached_kernel_module = {}
        with ProcessPoolExecutor() as executor:
            futures = {}
            for module in modules:
                module_abs_path = os.path.join(modules_dir, module)
                future = executor.submit(KernelModule, module_abs_path)
                futures[future] = module_abs_path
            completed_futures = as_completed(futures.keys())
            if HAS_TQDM:
                completed_futures = tqdm(completed_futures, desc="Pre-reading modules", total=len(modules))
            for future in completed_futures:
                cached_kernel_module[futures[future]] = future.result()

        # Load modules in order according to their dependencies
        remain_modules = set(modules)
        def _load_module(module_path_: str) -> bool:
            if module_path_ not in remain_modules:
                return True
            for dep_module in reversed(modules_dep_dic[module_path_]):
                if not _load_module(dep_module):
                    return False
            module_abs_path_ = os.path.join(modules_dir, module_path_)
            kernel_module_ = cached_kernel_module.get(module_abs_path_) or KernelModule(module_abs_path_)
            if self.load_module(kernel_module_):
                remain_modules.remove(module_path_)
                return True
            return False

        modules_iter = modules
        if HAS_TQDM:
            modules_iter = tqdm(modules, desc="Loading modules")
        for module in modules_iter:
            if not _load_module(module):
                print("Error: Failed to load %s!" % os.path.join(modules_dir, module))
                print("These kernel modules are still not loaded:")
                for m in sorted(remain_modules):
                    print("-", m)
                return False
        return True

def main(vmlinux_symvers_file: str, *args: str) -> int:
    if not args or len(args) % 2 != 0:
        return 2

    vk = VirtualKernel(vmlinux_symvers_file)

    for i in range(len(args) // 2):
        modules_load_file_, real_modules_path_ = args[i*2], args[i*2+1]
        if not vk.load_modules(modules_load_file_, real_modules_path_):
            return 1

    return 0

if __name__ == "__main__":
    '''
    # Example
    main(
        '/home/pzqqt/working/android_kernel_xiaomi_marble/out/vmlinux.symvers',
        '/mnt/f/OS2.0.6.0.VMRCNXM/vendor_boot_modules/modules.load', "/lib/modules/",
        '/mnt/f/OS2.0.6.0.VMRCNXM/vendor_dlkm_modules/modules.load', "/vendor/lib/modules/",
    )
    '''
    if len(sys.argv) >= 4:
        if (_rc := main(*sys.argv[1:])) != 2:
            sys.exit(_rc)
    print('Usage: %s <vmlinux.symvers file> [<modules.load file> <real modules path>] ...' % sys.argv[0])
    sys.exit(2)
