// Front end of the ESP32-S3 Linux build of fastfetch: it replaces src/flashfetch.c, the
// project's own minimal front end, which also has its layout fixed at build time.
//
// The detection and printing code is fastfetch's. What is left out is the command line parser,
// the JSON configuration and yyjson: that is about 300 KB of the 433 KB of code of the full
// binary, and the board needs the code in one piece of RAM (NOMMU), at most 256 KB of it, to
// still find that piece after it has been running for a while. The layout below is for the
// 41 x 20 character console on the round AMOLED: the small Tux on top, then one line per item.
#include "fastfetch.h"

#include "common/init.h"
#include "logo/logo.h"
#include "modules/modules.h"

#define MODULE_OPTION(name)                                               \
    [[gnu::cleanup(ffDestroy##name##Options)]] FF##name##Options options; \
    ffInit##name##Options(&options);

int main(void) {
    ffInitInstance();

    instance.config.display.sizeNdigits = 1;     // 4.4 MiB
    instance.config.display.freqNdigits = 3;     // 0.240 GHz (the clock is 240 MHz)

    ffStrbufSetStatic(&instance.config.logo.source, "linux");
    instance.config.logo.type = FF_LOGO_TYPE_SMALL;
    instance.config.logo.position = FF_LOGO_POSITION_TOP;

    ffStart();
    ffLogoPrint();

    {
        MODULE_OPTION(Title)
        ffPrintTitle(&options);
    }
    {
        MODULE_OPTION(OS)
        ffPrintOS(&options);
    }
    {
        MODULE_OPTION(Host)
        ffStrbufSetStatic(&options.moduleArgs.key, "HW");
        ffPrintHost(&options);
    }
    {
        MODULE_OPTION(Kernel)
        ffStrbufSetStatic(&options.moduleArgs.outputFormat, "{release}");
        ffPrintKernel(&options);
    }
    {
        MODULE_OPTION(Uptime)
        ffPrintUptime(&options);
    }
    {
        MODULE_OPTION(CPU)
        options.showPeCoreCount = false;
        ffPrintCPU(&options);
    }
    {
        MODULE_OPTION(Memory)
        ffPrintMemory(&options);
    }
    {
        MODULE_OPTION(Disk)
        ffStrbufSetStatic(&options.folders, "/home");
        ffStrbufSetStatic(&options.moduleArgs.key, "Disk");
        ffStrbufSetStatic(&options.moduleArgs.outputFormat, "{size-used} / {size-total} ({size-percentage})");
        ffPrintDisk(&options);
    }
    {
        MODULE_OPTION(LocalIp)
        ffStrbufSetStatic(&options.moduleArgs.key, "IP");
        ffPrintLocalIp(&options);
    }
    {
        MODULE_OPTION(Break)
        ffPrintBreak(&options);
    }
    {
        MODULE_OPTION(Colors)
        ffPrintColors(&options);
    }

    ffLogoPrintRemaining();
    ffFinish();
    ffDestroyInstance();
    return 0;
}
