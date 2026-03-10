#!/bin/sh
#
# remaster_tc.sh - D-Secure Edition (DIRECT MOUNT STRATEGY)
#
# ROOT CAUSE: tce-load is too slow (2-3 min for 127 packages via CDROM in VM).
# FIX: Pre-extract ALL .tcz files directly into the squashfs initramfs.
#      Zero tce-load calls at boot. Everything is already installed.
#      Boot sequence: GRUB -> splash -> login -> startx -> dashboard
#      Total time to dashboard: < 30 seconds.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$SCRIPT_DIR/tc_remaster"
EXT_DIR="$SCRIPT_DIR/tc_extensions"
BASE_DIR="$SCRIPT_DIR/tc_base"
ISO_ROOT="$SCRIPT_DIR/iso_root"
APP_DIR="$SCRIPT_DIR/app_bin"

echo "=== Remastering Tiny Core Linux (D-Secure Edition) ==="

# 0. Cleanup
rm -rf "$ISO_ROOT/isolinux" "$ISO_ROOT/cde"
mkdir -p "$ISO_ROOT/boot"

# 2. Unpack base
echo "[2/4] Unpacking corepure64.gz and modules64.gz..."
# Use rm -rf instead of mv to avoid 'Identifier removed' fakeroot issues
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
zcat "$BASE_DIR/corepure64.gz" | cpio -i -H newc -d 2>/dev/null
zcat "$BASE_DIR/modules64.gz" | cpio -i -H newc -d 2>/dev/null

# Fix kernel modules dependency list
KVER=$(ls lib/modules | head -n 1)
echo "Detected Kernel Version: $KVER"
if [ -n "$KVER" ]; then
    echo "Running depmod for $KVER..."
    # Ensure the directory exists and has modules
    mkdir -p "lib/modules/$KVER/kernel"
    depmod -a -b . "$KVER"
fi

# Extract ALL extensions into the rootfs (The "Direct Mount" Fix)
echo "Pre-extracting extensions into initramfs..."
for ext in "$EXT_DIR"/*.tcz; do
    fname=$(basename "$ext")
    # Skip massive unnecessary extensions to reduce ISO size (~35MB savings)
    # KEPT: firmware-iwlwifi, wireless-*, and wpa_supplicant for network functionality
    case "$fname" in
        python3.9.tcz|librsvg.tcz|alsa-modules-*.tcz|tcl8.6.tcz|tk8.6.tcz|libvpx113.tcz|adwaita-icon-theme.tcz)
            echo "  Skipping bloat: $fname"
            continue
            ;;
    esac

    echo "  Extracting: $fname"
    if [ ! -s "$ext" ]; then
        echo "  WARNING: Skipping empty extension $ext"
        continue
    fi
    unsquashfs -f -d "$WORK_DIR" "$ext" || {
        echo "  WARNING: Failed to extract $ext correctly! Trying fallback..."
        unsquashfs -i -f -d "$WORK_DIR" "$ext" || true
    }
done

# Compatibility: Create symlink for Ubuntu-style library paths
# Tiny Core uses /usr/local/lib, but Ubuntu-built binaries expect /lib/x86_64-linux-gnu
echo "Creating library compatibility symlinks..."
mkdir -p "$WORK_DIR/lib/x86_64-linux-gnu" "$WORK_DIR/usr/lib/x86_64-linux-gnu"
for lib in "$WORK_DIR/usr/local/lib"/*; do
    [ -e "$lib" ] || continue
    fname=$(basename "$lib")
    ln -sf "/usr/local/lib/$fname" "$WORK_DIR/lib/x86_64-linux-gnu/$fname"
    ln -sf "/usr/local/lib/$fname" "$WORK_DIR/usr/lib/x86_64-linux-gnu/$fname"
done

if [ ! -L "$WORK_DIR/lib64" ] && [ ! -d "$WORK_DIR/lib64" ]; then
    ln -s lib "$WORK_DIR/lib64"
fi

# Fallback: Copy missing libraries directly from host if they are not in TCZ
echo "Copying host specific libraries as fallback..."
for lib in \
    libwoff2dec.so.1.0.2 \
    libwoff2common.so.1.0.2 \
; do
    if [ ! -f "$WORK_DIR/usr/local/lib/$lib" ]; then
        cp "/lib/x86_64-linux-gnu/$lib" "$WORK_DIR/usr/local/lib/" 2>/dev/null || \
        cp "/usr/lib/x86_64-linux-gnu/$lib" "$WORK_DIR/usr/local/lib/" 2>/dev/null || true
    fi
done

# Fix for missing libudev versions which Xorg/App might want
for libdir in "$WORK_DIR/usr/local/lib" "$WORK_DIR/usr/lib"; do
    if [ -f "$libdir/libudev.so.1" ] && [ ! -f "$libdir/libudev.so.0" ]; then
        ln -sf libudev.so.1 "$libdir/libudev.so.0"
    elif [ -f "$libdir/libudev.so" ] && [ ! -f "$libdir/libudev.so.1" ]; then
        ln -sf libudev.so "$libdir/libudev.so.1"
    fi
done

# Pre-installation complete. Run ldconfig in the WORK_DIR to fix library cache
echo "Running ldconfig in rootfs..."
ldconfig -r "$WORK_DIR" 2>/dev/null || true

# Back to WORK_DIR for rest of script
cd "$WORK_DIR"

# 3. Install tiny_splash
echo "Compiling tiny_splash..."
gcc -static -O3 "$SCRIPT_DIR/tiny_splash.c" -o "$SCRIPT_DIR/tiny_splash" || {
    echo "ERROR: Compilation of tiny_splash failed!"
    exit 1
}
cp "$SCRIPT_DIR"/splash_*.raw "$WORK_DIR/" 2>/dev/null || true
cp "$SCRIPT_DIR/tiny_splash" "$WORK_DIR/sbin/tiny_splash"
chmod +x "$WORK_DIR/sbin/tiny_splash"

# Start splash as first thing in rcS
if [ -f etc/init.d/rcS ]; then
    sed -i '/tiny_splash/d' etc/init.d/rcS
    sed -i '1a /sbin/tiny_splash &' etc/init.d/rcS
    
    # Keep verbose logging disabled
    # sed -i 's|> /dev/null 2>&1||g' etc/init.d/rcS
    # sed -i 's|2>/dev/null||g' etc/init.d/rcS
    
    # Ensure system dbus is running before anything else (guard against duplicates)
    grep -q "dbus start" etc/init.d/rcS 2>/dev/null || echo "sudo /usr/local/etc/init.d/dbus start" >> etc/init.d/rcS
    
    # Load input drivers early (guard against duplicates)
    grep -q "modprobe i8042" etc/init.d/rcS 2>/dev/null || echo "modprobe i8042 || true" >> etc/init.d/rcS
    grep -q "modprobe atkbd" etc/init.d/rcS 2>/dev/null || echo "modprobe atkbd || true" >> etc/init.d/rcS
    grep -q "modprobe psmouse" etc/init.d/rcS 2>/dev/null || echo "modprobe psmouse || true" >> etc/init.d/rcS
    grep -q "modprobe hid-generic" etc/init.d/rcS 2>/dev/null || echo "modprobe hid-generic || true" >> etc/init.d/rcS
    grep -q "modprobe usbhid" etc/init.d/rcS 2>/dev/null || echo "modprobe usbhid || true" >> etc/init.d/rcS
    grep -q "modprobe evdev" etc/init.d/rcS 2>/dev/null || echo "modprobe evdev || true" >> etc/init.d/rcS
fi

# 4. Configure Autostart
echo "[3/4] Configuring Autostart Logic..."
sed -i 's|tty1::respawn:/sbin/getty.*|tty1::once:/bin/login -f tc </dev/tty1 >/dev/tty1 2>\&1|' "$WORK_DIR/etc/inittab"
> "$WORK_DIR/etc/motd"

mkdir -p "$WORK_DIR/home/tc" "$WORK_DIR/etc/skel"
mkdir -p "$WORK_DIR/etc/sysconfig"
echo "Xorg" > "$WORK_DIR/etc/sysconfig/Xserver"
echo "flwm" > "$WORK_DIR/etc/sysconfig/desktop"
echo "tc" > "$WORK_DIR/etc/sysconfig/tcuser"

# Silence tc-config wait prompt
if [ -f "$WORK_DIR/etc/init.d/tc-config" ]; then
    sed -i 's|read ans||g' "$WORK_DIR/etc/init.d/tc-config"
fi

# ============================================================
# Xorg Setup & Permissions
# ============================================================
echo "Configuring Xorg Permissions and Fallback..."

# Find the real Xorg binary if it moved during extraction
XORG_BIN=$(find "$WORK_DIR/usr/local" -name Xorg -type f -executable | head -n 1)
if [ -n "$XORG_BIN" ]; then
    chmod 4755 "$XORG_BIN" || true
fi

# Allow anybody to run X
mkdir -p "$WORK_DIR/etc/X11"
echo "allowed_users=anybody" > "$WORK_DIR/etc/X11/Xwrapper.config"
echo "needs_root_rights=yes" >> "$WORK_DIR/etc/X11/Xwrapper.config"



# CRITICAL: udev rules for tc user graphics/input
mkdir -p "$WORK_DIR/etc/udev/rules.d"
cat > "$WORK_DIR/etc/udev/rules.d/99-dsecure.rules" << 'UDEV_EOF'
KERNEL=="console", MODE="0666"
KERNEL=="fb0", MODE="0666"
KERNEL=="tty[0-9]*", MODE="0666"
KERNEL=="event*", MODE="0666"
KERNEL=="mouse*", MODE="0666"
KERNEL=="uinput", MODE="0666"
UDEV_EOF

# Xorg config: modesetting (primary for UEFI) + fbdev (fallback)
mkdir -p "$WORK_DIR/etc/X11"
cat > "$WORK_DIR/etc/X11/xorg.conf" << 'XORG_EOF'
Section "ServerFlags"
    Option "AutoAddDevices" "true"
    Option "AllowEmptyInput" "true"
    Option "DontVTSwitch" "true"
EndSection

Section "Device"
    Identifier  "Video0"
    Driver      "modesetting"
EndSection

Section "Device"
    Identifier  "Video1"
    Driver      "fbdev"
    Option      "fbdev" "/dev/fb0"
EndSection

Section "Screen"
    Identifier  "Screen0"
    Device      "Video0"
    DefaultDepth 24
EndSection

Section "Screen"
    Identifier  "Screen1"
    Device      "Video1"
    DefaultDepth 24
EndSection

Section "ServerLayout"
    Identifier  "Layout0"
    Screen      0 "Screen0"
    Screen      1 "Screen1"
EndSection
XORG_EOF

# Set Openbox as default desktop
echo "openbox" > "$WORK_DIR/etc/sysconfig/desktop"
echo "Xorg" > "$WORK_DIR/etc/sysconfig/Xserver"

# ============================================================
# .xsession — The real X startup (native TC way)
# ============================================================
echo "Creating .xsession..."
cat > "$WORK_DIR/home/tc/.xsession" << 'XESS_EOF'
#!/bin/sh
# Set environment
export DISPLAY=:0
export XDG_RUNTIME_DIR=/tmp/runtime-tc
mkdir -p $XDG_RUNTIME_DIR && chmod 700 $XDG_RUNTIME_DIR

# Start Window Manager
openbox &

# Wait for WM
sleep 1

# Detect screen size (for logging only, we will use % for sizing)
SCREEN_GEOM=$(xdotool getdisplaygeometry 2>/dev/null || echo "1024 768")
echo "[BOOT] Current Resolution: $SCREEN_GEOM" > /dev/ttyS0

# Dashboard Environment
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_SANDBOX=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export GDK_BACKEND=x11
export LIBGL_ALWAYS_SOFTWARE=1
export NO_AT_BRIDGE=1

# Launch the app
if [ -f /opt/d-secure-ui/app ]; then
    echo "[BOOT] Launching Dashboard..." > /dev/ttyS0
    # Start resizing watchdog (Force 100% size)
    (
        WID=""
        for i in $(seq 1 50); do
            # Search for the window by title (case insensitive)
            WID=$(xdotool search --name ".*[Dd]-[Ss]ecure.*" 2>/dev/null | head -n 1)
            [ -z "$WID" ] && WID=$(xdotool search --name ".*[Ee]raser.*" 2>/dev/null | head -n 1)
            
            if [ -n "$WID" ]; then
                echo "[BOOT] Resizing Dashboard (WID: $WID) to 100%..." > /dev/ttyS0
                # Move to top-left and stretch to 100% of the screen
                xdotool windowmove "$WID" 0 0
                xdotool windowsize "$WID" 100% 100%
                xdotool windowactivate "$WID" 2>/dev/null || true
                break
            fi
            sleep 0.2
        done
    ) &
    
    dbus-run-session /opt/d-secure-ui/app > /tmp/dashboard.log 2>&1
else
    echo "[ERROR] Dashboard not found!" > /dev/ttyS0
    aterm &
fi
XESS_EOF
chmod +x "$WORK_DIR/home/tc/.xsession"
chown 1001:50 "$WORK_DIR/home/tc/.xsession"

# ============================================================
# .profile — Auto-login, auto-startx
# ============================================================

# Create Openbox config to force maximization and remove decorations (Kiosk Mode)
echo "Configuring Openbox Kiosk Mode..."
mkdir -p "$WORK_DIR/home/tc/.config/openbox"
cat > "$WORK_DIR/home/tc/.config/openbox/rc.xml" << 'OB_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <applications>
    <application name="*">
      <decor>no</decor>
      <maximized>yes</maximized>
      <fullscreen>yes</fullscreen>
    </application>
  </applications>
  <keyboard>
    <keybind key="A-F4"><action name="Close"/></keybind>
  </keyboard>
</openbox_config>
OB_EOF
chown -R 1001:50 "$WORK_DIR/home/tc/.config"

# Prepare the startup logic in .profile
cat > "$WORK_DIR/home/tc/.profile" << 'PROFILE_EOF'
#!/bin/sh
export PATH=/usr/local/bin:/usr/local/sbin:/bin:/sbin:/usr/bin:/usr/sbin
export HOME=/home/tc
export USER=tc

# Ensure we only run this once on boot
case "$(tty)" in
    /dev/tty1|/dev/vc/1|/dev/ttyS0)
        [ -f /tmp/.boot_done ] && return
        touch /tmp/.boot_done
        
        echo "[BOOT] Dashboard Init (PID: $$) on $(tty)" | sudo tee /dev/ttyS0
        
        # Load Input Drivers
        sudo modprobe i8042 atkbd psmouse hid-generic usbhid evdev 2>/dev/null || true
        sudo udevadm trigger 2>/dev/null || true
        sudo udevadm settle --timeout=3 2>/dev/null || true
        sudo chown tc:staff /dev/fb0 /dev/tty1 /dev/input/event* 2>/dev/null || true

        # Start Networking
        echo "[BOOT] Initializing Network..." | sudo tee /dev/ttyS0
        sudo ifconfig lo up 2>/dev/null || true
        for i in $(ls /sys/class/net/ 2>/dev/null | grep -v lo); do
            sudo ifconfig "$i" up 2>/dev/null || true
            sudo udhcpc -b -i "$i" -t 5 -T 2 >/dev/null 2>&1 &
        done
        
        # Native Tiny Core X Startup
        echo "[BOOT] Starting X Session..." | sudo tee /dev/ttyS0
        touch /tmp/splash.stop
        startx
        ;;
esac
PROFILE_EOF

echo "Installing Tauri Dashboard..."
mkdir -p "$WORK_DIR/opt/d-secure-ui"
TAURI_SOURCE="$APP_DIR/app"
if [ -f "$TAURI_SOURCE" ]; then
    cp "$TAURI_SOURCE" "$WORK_DIR/opt/d-secure-ui/app"
    chmod +x "$WORK_DIR/opt/d-secure-ui/app"
    
    # Also copy assets if they exist
    DIST_SOURCE="$APP_DIR/dist"
    if [ -d "$DIST_SOURCE" ]; then
        cp -r "$DIST_SOURCE/." "$WORK_DIR/opt/d-secure-ui/"
    fi
    
    # Bundle host GLIBC 2.39 and WebKit/GTK libraries for compatibility
    echo "  Bundling host libraries (GLIBC + WebKit + GTK)..."
    PRIVATE_LIBS_DIR="$WORK_DIR/opt/d-secure-ui/.libs_private"
    mkdir -p "$PRIVATE_LIBS_DIR"
    
    # Base system libs + Tauri requirements + ALL transitive dependencies
    # Base system libs + Tauri requirements + ALL transitive dependencies
    LIBS="libc.so.6 libm.so.6 libresolv.so.2 librt.so.1 libdl.so.2 libpthread.so.0 libgcc_s.so.1 libstdc++.so.6 ld-linux-x86-64.so.2 libatomic.so.1 libwebpdemux.so.2 libwebkit2gtk-4.1.so.0 libsoup-3.0.so.0 libjavascriptcoregtk-4.1.so.0 libgtk-3.so.0 libgdk-3.so.0 libpangocairo-1.0.so.0 libpango-1.0.so.0 libharfbuzz.so.0 libatk-1.0.so.0 libcairo.so.2 libgdk_pixbuf-2.0.so.0 libgio-2.0.so.0 libgobject-2.0.so.0 libglib-2.0.so.0 libEGL.so.1 libEGL_mesa.so.0 libGLX.so.0 libGLX_mesa.so.0 libGL.so.1 libglapi.so.0 libgbm.so.1 libGLESv2.so.2 libepoxy.so.0 libgudev-1.0.so.0 libdrm.so.2 libjpeg.so.8 libpng16.so.16 libsystemd.so.0 libsecret-1.so.0 libenchant-2.so.2 libhyphen.so.0 libmanette-0.2.so.0 libseccomp.so.2 libgstreamer-1.0.so.0 libgstbase-1.0.so.0 libgstapp-1.0.so.0 libgstvideo-1.0.so.0 libgstaudio-1.0.so.0 libgstgl-1.0.so.0 libgstpbutils-1.0.so.0 libgstfft-1.0.so.0 libgsttag-1.0.so.0 libgstallocators-1.0.so.0 libicudata.so.74 libicui18n.so.74 libicuuc.so.74 libxml2.so.2 libxslt.so.1 libsqlite3.so.0 liblcms2.so.2 libgcrypt.so.20 libgpg-error.so.0 libtasn1.so.6 libwebp.so.7 libwebpmux.so.3 libharfbuzz-icu.so.0 liborc-0.4.so.0 libunwind.so.8 libdw.so.1 libelf.so.1 libbrotlidec.so.1 libbrotlicommon.so.1 libpsl.so.5 libnghttp2.so.14 libgssapi_krb5.so.2 libkrb5.so.3 libk5crypto.so.3 libkrb5support.so.0 libkeyutils.so.1 libunistring.so.5 libidn2.so.0 libmount.so.1 libblkid.so.1 libcap.so.2 liblz4.so.1 liblzma.so.5 libzstd.so.1 libselinux.so.1 libpcre2-8.so.0 libGLdispatch.so.0 libffi.so.8 libevdev.so.2 libatspi.so.0 libdbus-1.so.3 libcairo-gobject.so.2 libbz2.so.1.0 libthai.so.0 libdatrie.so.1 libbsd.so.0 libmd.so.0 libX11-xcb.so.1 libsharpyuv.so.0 libpangoft2-1.0.so.0 libatk-bridge-2.0.so.0 libwayland-server.so.0 libwayland-client.so.0 libwayland-egl.so.1 libwayland-cursor.so.0 libgraphite2.so.3 libwoff2common.so.1.0.2 libcom_err.so.2 libdbus-glib-1.so.2 libXau.so.6 libXdmcp.so.6 libxcb-glx.so.0 libxcb-dri2.so.0 libxcb-dri3.so.0 libxcb-present.so.0 libxcb-sync.so.1 libxshmfence.so.1 libXfixes.so.3 libXdamage.so.1 libXxf86vm.so.1 libXcursor.so.1 libXinerama.so.1 libXcomposite.so.1 libXi.so.6"
    
    copy_lib() {
        lib_name=$1
        for path in "/lib/x86_64-linux-gnu" "/usr/lib/x86_64-linux-gnu" "/usr/local/lib" "/lib64" "/lib"; do
            if [ ! -d "$path" ]; then continue; fi
            # Try exact match first
            if [ -e "$path/$lib_name" ]; then
                cp -L --update=none "$path/$lib_name" "$PRIVATE_LIBS_DIR/$lib_name"
                return 0
            fi
            # Fallback to prefix match
            MATCH=$(find "$path" -maxdepth 1 -name "$lib_name*" \( -type f -o -type l \) | head -n 1)
            if [ -n "$MATCH" ]; then
                cp -L --update=none "$MATCH" "$PRIVATE_LIBS_DIR/$lib_name"
                return 0
            fi
        done
        return 1
    }

    for lib in $LIBS; do
        copy_lib "$lib" || echo "  WARNING: Could not find $lib"
    done

    # 1. SCAN DEEP DEPENDENCIES (Recursive)
    echo "  Scanning app and all bundled libs for deep dependencies..."
    ldd "$TAURI_SOURCE" 2>/dev/null | grep "=> /" | awk '{print $3}' | while read -r libpath; do
        if [ -f "$libpath" ]; then
            cp -L --update=none "$libpath" "$PRIVATE_LIBS_DIR/"
        fi
    done
    
    # Also explicitly gather libgallium which is a dlopen dependency of mesa
    GALLIUM=$(find /usr/lib/x86_64-linux-gnu -name "libgallium-*.so" | head -n 1)
    if [ -n "$GALLIUM" ]; then
        cp -L --update=none "$GALLIUM" "$PRIVATE_LIBS_DIR/"
    fi

    NEW_FOUND=1
    while [ $NEW_FOUND -eq 1 ]; do
        NEW_FOUND=0
        for lib in "$PRIVATE_LIBS_DIR"/*.so*; do
            [ -f "$lib" ] || continue
            # Read dependencies of this library
            deps=$(ldd "$lib" 2>/dev/null | grep "=> /" | awk '{print $3}' || true)
            for libpath in $deps; do
                if [ -f "$libpath" ]; then
                    libname=$(basename "$libpath")
                    if [ ! -f "$PRIVATE_LIBS_DIR/$libname" ]; then
                        cp -L --update=none "$libpath" "$PRIVATE_LIBS_DIR/"
                        NEW_FOUND=1
                    fi
                fi
            done
        done
    done

    # 2. BUNDLE WEBKIT HELPER PROCESSES
    echo "  Bundling WebKit helper processes..."
    WEBKIT_PROC_DIR="$WORK_DIR/opt/d-secure-ui/webkit_runtime"
    mkdir -p "$WEBKIT_PROC_DIR"
    # Find WebKit processes on host (Ubuntu path is usually /usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/)
    HOST_WEBKIT_DIR=$(find /usr/lib/x86_64-linux-gnu -name "webkit2gtk-4.*" -type d | head -n 1)
    if [ -d "$HOST_WEBKIT_DIR" ]; then
        cp -r "$HOST_WEBKIT_DIR/"* "$WEBKIT_PROC_DIR/"
        # Fix dependencies for the processes too
        for proc in "$WEBKIT_PROC_DIR"/*; do
            [ -f "$proc" ] && [ -x "$proc" ] || continue
            ldd "$proc" 2>/dev/null | grep "=> /" | awk '{print $3}' | while read -r libpath; do
                [ -f "$libpath" ] && cp -L --update=none "$libpath" "$PRIVATE_LIBS_DIR/"
            done
        done
        
        # CRITICAL: Wrap ELF WebKit processes so they use the bundled ld-linux.
        echo "  Compiling static C wrapper..."
        
        cat > "$WORK_DIR/opt/d-secure-ui/webkit_wrapper.c" << 'WRAPEOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>

int main(int argc, char *argv[]) {
    char *orig_name = argv[0];
    char real_path[1024];
    snprintf(real_path, sizeof(real_path), "%s.real", orig_name);
    
    char *loader = "/opt/d-secure-ui/.libs_private/ld-linux-x86-64.so.2";
    char *libs = "/opt/d-secure-ui/.libs_private:/usr/local/lib:/usr/lib:/lib";
    
    char **new_argv = malloc((argc + 4) * sizeof(char *));
    new_argv[0] = loader;
    new_argv[1] = "--library-path";
    new_argv[2] = libs;
    new_argv[3] = real_path;
    
    for (int i = 1; i < argc; i++) {
        new_argv[i + 3] = argv[i];
    }
    new_argv[argc + 3] = NULL;
    
    // Set the specific GTK environment variables needed for the bundled libs
    setenv("LD_LIBRARY_PATH", libs, 1);
    setenv("DISPLAY", ":0", 1);
    
    // Force X11 EGL platform and debug logging
    setenv("EGL_PLATFORM", "x11", 1);
    setenv("EGL_LOG_LEVEL", "debug", 1);
    setenv("LIBGL_DEBUG", "verbose", 1);
    setenv("MESA_DEBUG", "1", 1);
    
    setenv("GDK_PIXBUF_MODULE_FILE", "/usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/2.10.0/loaders.cache", 1);
    setenv("GTK_IM_MODULE_FILE", "/usr/lib/x86_64-linux-gnu/gtk-3.0/3.0.0/immodules.cache", 1);
    setenv("LIBGL_DRIVERS_PATH", "/usr/lib/x86_64-linux-gnu/dri", 1);
    setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
    setenv("G_MESSAGES_DEBUG", "all", 0);
    setenv("WEBKIT_DEBUG", "all", 0);
    setenv("WEBKIT_DISABLE_COMPOSITING_MODE", "1", 1);
    setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1", 1);
    setenv("WEBKIT_DISABLE_SANDBOX", "1", 1);
    setenv("GDK_BACKEND", "x11", 1);
    setenv("XDG_DATA_DIRS", "/usr/share:/usr/local/share", 1);
    setenv("GSETTINGS_SCHEMA_DIR", "/usr/share/glib-2.0/schemas", 1);
    setenv("FONTCONFIG_PATH", "/etc/fonts", 1);
    
    execv(loader, new_argv);
    
    perror("execv failed");
    return 1;
}
WRAPEOF
        # Compile it statically using host gcc
        gcc -static -O3 "$WORK_DIR/opt/d-secure-ui/webkit_wrapper.c" -o "$WORK_DIR/opt/d-secure-ui/webkit_wrapper_static"
        
        echo "  Wrapping main app and WebKit processes..."
        # Wrap main app
        mv "$WORK_DIR/opt/d-secure-ui/app" "$WORK_DIR/opt/d-secure-ui/app.real"
        cp "$WORK_DIR/opt/d-secure-ui/webkit_wrapper_static" "$WORK_DIR/opt/d-secure-ui/app"
        chmod +x "$WORK_DIR/opt/d-secure-ui/app"

        for proc in "$WEBKIT_PROC_DIR"/*; do
            [ -f "$proc" ] && [ -x "$proc" ] || continue
            procname=$(basename "$proc")
            # Only wrap ELF executables, skip .so shared libraries
            file "$proc" | grep -q "ELF.*executable" || continue
            echo "    Wrapping: $procname"
            if [ ! -f "${proc}.real" ]; then
                mv "$proc" "${proc}.real"
            fi
            cp "$WORK_DIR/opt/d-secure-ui/webkit_wrapper_static" "$proc"
            chmod +x "$proc"
        done
    fi

    # 3. BUNDLE GTK AND GDK-PIXBUF MODULES (Needed for gtk_init)
    echo "  Bundling GTK and GDK-Pixbuf modules..."
    # gdk-pixbuf
    if [ -d /usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0 ]; then
        mkdir -p "$WORK_DIR/usr/lib/x86_64-linux-gnu"
        rm -f "$WORK_DIR/usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0" # Remove any conflicting symlink
        cp -r /usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0 "$WORK_DIR/usr/lib/x86_64-linux-gnu/"
        # Find dependencies of the loaders
        find "$WORK_DIR/usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0" -name "*.so" -type f | while read -r proc; do
            ldd "$proc" 2>/dev/null | grep "=> /" | awk '{print $3}' | while read -r libpath; do
                [ -f "$libpath" ] && cp -L --update=none "$libpath" "$PRIVATE_LIBS_DIR/"
            done
        done
    fi
    # gtk-3.0
    if [ -d /usr/lib/x86_64-linux-gnu/gtk-3.0 ]; then
        mkdir -p "$WORK_DIR/usr/lib/x86_64-linux-gnu"
        rm -f "$WORK_DIR/usr/lib/x86_64-linux-gnu/gtk-3.0" # Remove any conflicting symlink
        cp -r /usr/lib/x86_64-linux-gnu/gtk-3.0 "$WORK_DIR/usr/lib/x86_64-linux-gnu/"
        # Find dependencies of the immodules
        find "$WORK_DIR/usr/lib/x86_64-linux-gnu/gtk-3.0" -name "*.so" -type f | while read -r proc; do
            ldd "$proc" 2>/dev/null | grep "=> /" | awk '{print $3}' | while read -r libpath; do
                [ -f "$libpath" ] && cp -L --update=none "$libpath" "$PRIVATE_LIBS_DIR/"
            done
        done
    fi
    # librsvg (SVG support for icons is required by many GTK themes)
    cp -L --update=none /usr/lib/x86_64-linux-gnu/librsvg-2.so* "$PRIVATE_LIBS_DIR/" 2>/dev/null || true
    
    # Bundle Mesa DRI software rasterizer drivers for EGL/GLX fallback
    echo "  Bundling DRI software rasterizers..."
    mkdir -p "$WORK_DIR/usr/lib/x86_64-linux-gnu/dri"
    # Use -L to resolve symlinks (swrast_dri.so -> libdril_dri.so)
    cp -L /usr/lib/x86_64-linux-gnu/dri/swrast_dri.so "$WORK_DIR/usr/lib/x86_64-linux-gnu/dri/" 2>/dev/null || true
    cp -L /usr/lib/x86_64-linux-gnu/dri/kms_swrast_dri.so "$WORK_DIR/usr/lib/x86_64-linux-gnu/dri/" 2>/dev/null || true
    cp -L /usr/lib/x86_64-linux-gnu/dri/libdril_dri.so "$WORK_DIR/usr/lib/x86_64-linux-gnu/dri/" 2>/dev/null || true
    
    # Bundle glvnd configs for EGL dispatching
    echo "  Bundling glvnd configs..."
    mkdir -p "$WORK_DIR/usr/share/glvnd/egl_vendor.d"
    cp -r /usr/share/glvnd/egl_vendor.d/* "$WORK_DIR/usr/share/glvnd/egl_vendor.d/" 2>/dev/null || true
    
    # Bundle a basic GTK theme and icon theme
    mkdir -p "$WORK_DIR/usr/share/themes" "$WORK_DIR/usr/share/icons"
    cp -r /usr/share/themes/Default "$WORK_DIR/usr/share/themes/" 2>/dev/null || true
    cp -r /usr/share/icons/hicolor "$WORK_DIR/usr/share/icons/" 2>/dev/null || true
    
    # 4. BUNDLE GSETTINGS SCHEMAS
    echo "  Bundling GSettings schemas..."
    SCHEMA_DIR="$WORK_DIR/usr/share/glib-2.0/schemas"
    mkdir -p "$SCHEMA_DIR"
    cp -r /usr/share/glib-2.0/schemas/*.xml "$SCHEMA_DIR/" 2>/dev/null || true
    cp /usr/share/glib-2.0/schemas/gschemas.compiled "$SCHEMA_DIR/" 2>/dev/null || true
    # Compile schemas using host tool directly into target
    glib-compile-schemas "$SCHEMA_DIR/" 2>/dev/null || true
    
    # 4. CREATE WEBKIT SYMLINK AT DEFAULT PATH
    echo "  Creating WebKit symlink at default path..."
    WEBKIT_DEFAULT_DIR="$WORK_DIR/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1"
    mkdir -p "$(dirname "$WEBKIT_DEFAULT_DIR")"
    ln -sfn /opt/d-secure-ui/webkit_runtime "$WEBKIT_DEFAULT_DIR"
    
    # 5. BUNDLE FONTCONFIG
    echo "  Bundling fontconfig..."
    mkdir -p "$WORK_DIR/etc/fonts"
    cp -r /etc/fonts/* "$WORK_DIR/etc/fonts/" 2>/dev/null || true
    mkdir -p "$WORK_DIR/usr/share/fonts"
    cp -r /usr/share/fonts/truetype "$WORK_DIR/usr/share/fonts/" 2>/dev/null || true
    # Generate font cache
    chroot "$WORK_DIR" fc-cache -f 2>/dev/null || true

    # 6. CREATE LAUNCHER WRAPPER (Critical: uses bundled ld-linux to bypass TC's old GLIBC)
    echo "  Creating launcher wrapper (bundled dynamic linker)..."
    cat > "$WORK_DIR/opt/d-secure-ui/launch.sh" << 'LAUNCH_EOF'
#!/bin/sh
DIR="$(cd "$(dirname "$0")" && pwd)"
export LD_LIBRARY_PATH="$DIR/.libs_private:/usr/local/lib:/usr/lib:/lib"
export WEBKIT_EXEC_PATH="$DIR/webkit_runtime"
export WEBKIT_INJECTED_BUNDLE_PATH="$DIR/webkit_runtime/injected-bundle"
export GSETTINGS_SCHEMA_DIR="/usr/share/glib-2.0/schemas"
export XDG_DATA_DIRS="/usr/share:/usr/local/share"
export NO_AT_BRIDGE=1
export GTK_A11Y=none
export FONTCONFIG_PATH="/etc/fonts"
export GDK_SCALE=1
export GDK_DPI_SCALE=1
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_SANDBOX=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export LIBGL_DRIVERS_PATH="/usr/lib/x86_64-linux-gnu/dri"
export GDK_BACKEND=x11
export LIBGL_ALWAYS_SOFTWARE=1
exec "$DIR/.libs_private/ld-linux-x86-64.so.2" --library-path "$LD_LIBRARY_PATH" "$DIR/app" "$@"
LAUNCH_EOF
    chmod +x "$WORK_DIR/opt/d-secure-ui/launch.sh"
else
    echo "WARNING: Tauri binary not found!"
fi
chown -R 1001:50 "$WORK_DIR/opt/d-secure-ui"

# ============================================================
# Install Python Dashboard (Fallback)
# ============================================================
echo "Installing Python Dashboard..."
mkdir -p "$WORK_DIR/opt/react_python"
if [ -f "$SCRIPT_DIR/dashboard.py" ]; then
    cp "$SCRIPT_DIR/dashboard.py" "$WORK_DIR/opt/react_python/react_launcher.py"
    chmod +x "$WORK_DIR/opt/react_python/react_launcher.py"
fi
chown -R 1001:50 "$WORK_DIR/opt/react_python"

# Repack
echo "[4/4] Repacking..."
chmod +x "$WORK_DIR/home/tc/.profile"
chown -R 1001:50 "$WORK_DIR/home/tc"
cp -p "$WORK_DIR/home/tc/.profile" "$WORK_DIR/etc/skel/"
cp -p "$WORK_DIR/home/tc/.xsession" "$WORK_DIR/etc/skel/"
echo "tc ALL=(ALL) NOPASSWD: ALL" >> "$WORK_DIR/etc/sudoers"

find . | cpio -o -H newc 2>/dev/null | gzip -1 > "$ISO_ROOT/boot/core_custom.gz"
cp "$BASE_DIR/vmlinuz64" "$ISO_ROOT/boot/vmlinuz64"
cp "$BASE_DIR/modules64.gz" "$ISO_ROOT/boot/modules64.gz"

echo "Remaster complete!"