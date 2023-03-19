import os
import re
import shutil
import subprocess
import shlex
import logging
import string
from string import Template
import sys

import riscof.utils as utils
import riscof.constants as constants
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()

class minimax(pluginTemplate):
    __model__ = "minimax"
    __version__ = "1.0.0"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

        if (config := kwargs.get('config')) is None:
            print("Please enter input file paths in configuration.")
            raise SystemExit(1)

        self.dut_exe = os.path.join(config.get('PATH', ""), "minimax")
        self.num_jobs = str(config.get('jobs', os.cpu_count()))
        self.pluginpath=os.path.abspath(config['pluginpath'])
        self.isa_spec = os.path.abspath(config['ispec'])
        self.platform_spec = os.path.abspath(config['pspec'])
        if 'target_run' in config and config['target_run']=='0':
            self.target_run = False
        else:
            self.target_run = True


    def initialise(self, suite, work_dir, archtest_env):
       self.work_dir = work_dir
       self.suite_dir = suite
       self.timeout = None  # timeout via MAXTICKS, not wall clock

       cross_compile='riscv32-corev-elf-'

       rom_len = 0x200000
       microcode_base = 0x1ff000

       self.compile_cmd = (
         f'{cross_compile}gcc '
         '-march={0} -mabi=ilp32 '
         '-static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -g '
         f'-T{self.pluginpath}/env/link.ld '
         f'-I{self.pluginpath}/env '
         f'-I{archtest_env} '
         ' {2} -o {3}.elf {4}'
       )
       self.objcopy_cmd = cross_compile+'objcopy -O binary {0}.elf {0}.bin'
       self.hexgen_cmd = (
               f"{work_dir}/../../asm/bin2hex "
               f"--microcode={work_dir}/../../asm/microcode.hex "
               f"--microcode-base={microcode_base} "
               f"--size={rom_len} "
               "{0}.bin {0}.hex"
       )
       self.simcmd = (
            "verilator --binary -o test-harness --top minimax_tb "
            "-GROM_FILENAME='\"{0}.hex\"' "
            f"-GROM_SIZE={rom_len} "
            f"-GMICROCODE_BASE={microcode_base} "
            "-GOUTPUT_FILENAME='\"{1}\"' "
            "-GMAXTICKS=3000000 "
            "-GTRACE=1 "
            + work_dir + "/../minimax_tb.v "
            + work_dir + "/../../rtl/minimax.v && "
            'obj_dir/test-harness'
       )

    def build(self, isa_yaml, platform_yaml):
      ispec = utils.load_yaml(isa_yaml)['hart0']
      self.xlen = 32
      self.isa = 'rv32'
      if "I" in ispec["ISA"]:
          self.isa += 'i'
      if "M" in ispec["ISA"]:
          self.isa += 'm'
      if "C" in ispec["ISA"]:
          self.isa += 'c'
      if "Zbkb" in ispec["ISA"]:
          self.isa += 'zbkb'

    def runTests(self, testList):
      if os.path.exists(self.work_dir+ "/Makefile." + self.name[:-1]):
            os.remove(self.work_dir+ "/Makefile." + self.name[:-1])

      make = utils.makeUtil(makefilePath=os.path.join(self.work_dir, "Makefile." + self.name[:-1]))
      make.makeCommand = 'make -k VERILATOR=/usr/bin/verilator -j' + self.num_jobs

      for testname in testList:
          testentry = testList[testname]
          test = testentry['test_path']
          test_dir = testentry['work_dir']
          filename = 'minimax-{0}'.format(test.rsplit('/',1)[1][:-2])

          sig_file = os.path.join(test_dir, self.name[:-1] + ".signature")
          compile_macros= ' -D' + " -D".join(testentry['macros'])
          compile_cmd = self.compile_cmd.format(testentry['isa'].lower(), self.xlen, test, filename, compile_macros)

          objcopy_cmd = self.objcopy_cmd.format(filename)
          hexgen_cmd = self.hexgen_cmd.format(filename)

          if self.target_run:
            simcmd = self.simcmd.format(filename, sig_file)
          else:
            simcmd = 'echo "NO RUN"'

          make.add_target(
            f'+@cd {test_dir} && \\\n'
                          f'{compile_cmd} && \\\n'
                          f'{objcopy_cmd} && \\\n'
                          f'{hexgen_cmd} && \\\n'
                          f'{simcmd} > sim.log')

      make.execute_all(self.work_dir, timeout=self.timeout)
