#include <stdio.h>
#include <sys/mount.h>
#include <stdlib.h>
#include <unistd.h>


int main()
{
    printf("Mounting rootfs\n");
    mount("proc", "/proc", "proc", 0, NULL);
    while (mount("/dev/mmcblk0p1", "/usr", "ext2", 0, 0));

    char *argv[] = { "sh", NULL };
    char *envp[] = {
        "PATH=/usr/bin",
        "TSLIB_CALIBFILE=/usr/etc/pointercal",
        "TSLIB_CONFFILE=/usr/etc/ts.conf",
        "TSLIB_TSDEVICE=/dev/input/event0",
        "TSLIB_CONSOLEDEVICE=none",
        NULL
    };
    execve("/usr/bin/sh", argv, envp);
}
