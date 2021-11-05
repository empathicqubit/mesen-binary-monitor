# mesen-binary-monitor

This is a monitor for Mesen, intended to mimic VICE's binary monitor.
It is currently in an alpha state, and some commands are not functional or behave
incorrectly. To use it, start up Mesen as such:

Linux:

```sh
MESEN_REMOTE_HOST=127.0.0.1 MESEN_REMOTE_WAIT=1 MESEN_REMOTE_PORT=9355 MESEN_REMOTE_BASEDIR=/path/to/mesen-binary-monitor mono Mesen.exe /path/to/mesen-binary-monitor/mesen_binary_monitor.lua romfile.nes
```

Windows (CMD):

```sh
set MESEN_REMOTE_HOST=127.0.0.1
set MESEN_REMOTE_WAIT=1
set MESEN_REMOTE_PORT=9355
set MESEN_REMOTE_BASEDIR=/path/to/mesen-binary-monitor
Mesen.exe /path/to/mesen-binary-monitor/mesen_binary_monitor.lua romfile.nes
```

The options:

* `MESEN_REMOTE_HOST`: The host to listen to
* `MESEN_REMOTE_PORT`: The port to listen to
* `MESEN_REMOTE_WAIT`: If set to `1`, pause the emulator immediately and wait
for a connection.
* `MESEN_REMOTE_BASEDIR`: Must always be the base path of the script.