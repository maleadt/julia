# RISC-V (Linux)

Julia has experimental support for 64-bit RISC-V (RV64) processors running
Linux. This file provides general guidelines for compilation, in addition to
instructions for specific devices.

A list of [known issues](https://github.com/JuliaLang/julia/labels/system:riscv)
for RISC-V is available. If you encounter difficulties, please create an issue
including the output from `cat /proc/cpuinfo`.


## Compiling Julia

For now, Julia will need to be compiled entirely from source, i.e., including
all of its dependencies. This can be accomplished with the following
`Make.user`:

```make
USE_BINARYBUILDER := 0
```

Additionally, it is required to indicate what architecture, and optionally which
CPU to build for. This can be done by setting the `MARCH` and `MCPU` variables
in `Make.user`

The `MARCH` variable needs to be set to a RISC-V ISA string, which can be found by
looking at the documentation of your device, or by inspecting `/proc/cpuinfo`. Only
use flags that your compiler supports, e.g., run `gcc -march=help` to see a list of
supported flags. A common value is `rv64gc`, which is a good starting point.

The `MCPU` variable is optional, and can be used to further optimize the
generated code for a specific CPU. If you are unsure, it is recommended to leave
it unset. You can find a list of supported values by running `gcc --target-help`.

For example, if you are using a StarFive VisionFive2, which contains a JH7110
processor based on the SiFive U74, you can set these flags as follows:

```make
MARCH := rv64gc_zba_zbb
MCPU := sifive-u74
```

This build will take a long time, so be prepared to wait.
