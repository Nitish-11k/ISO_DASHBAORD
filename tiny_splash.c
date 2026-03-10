#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <string.h>
#include <signal.h>
#include <linux/vt.h>
#include <linux/kd.h>
#include <linux/fb.h>
#include <errno.h>

#define LOG_PATH "/tmp/splash.log"

static volatile int g_stop = 0;
struct fb_var_screeninfo vinfo;
struct fb_fix_screeninfo finfo;
long screensize = 0;
unsigned char *fbp = NULL;

void log_msg(const char *msg) {
    FILE *f = fopen(LOG_PATH, "a");
    if (f) {
        fprintf(f, "[splash] %s\n", msg);
        fclose(f);
    }
    // Also log to serial console for debugging
    FILE *s = fopen("/dev/ttyS0", "w");
    if (s) {
        fprintf(s, "[SPLASH] %s\n", msg);
        fclose(s);
    }
    printf("[SPLASH] %s\n", msg);
}

void log_error(const char *msg, int err) {
    FILE *f = fopen(LOG_PATH, "a");
    if (f) {
        fprintf(f, "[splash] ERROR: %s (errno: %d, %s)\n", msg, err, strerror(err));
        fclose(f);
    }
    FILE *s = fopen("/dev/ttyS0", "w");
    if (s) {
        fprintf(s, "[SPLASH-ERROR] %s (errno: %d)\n", msg, err);
        fclose(s);
    }
    fprintf(stderr, "[SPLASH-ERROR] %s (errno: %d)\n", msg, err);
}

static void signal_handler(int sig) {
    g_stop = 1;
}

static void fill_color(unsigned int r, unsigned int g, unsigned int b) {
    if (!fbp) return;
    for (unsigned int y = 0; y < vinfo.yres; y++) {
        for (unsigned int x = 0; x < vinfo.xres; x++) {
            long location = (x + vinfo.xoffset) * (vinfo.bits_per_pixel / 8) +
                           (y + vinfo.yoffset) * finfo.line_length;
            
            if (vinfo.bits_per_pixel == 32) {
                unsigned char *pixel = &fbp[location];
                pixel[vinfo.red.offset / 8] = r;
                pixel[vinfo.green.offset / 8] = g;
                pixel[vinfo.blue.offset / 8] = b;
                pixel[vinfo.transp.offset / 8] = 0xFF;
            } else if (vinfo.bits_per_pixel == 16) {
                unsigned short *pixel = (unsigned short *)&fbp[location];
                *pixel = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
            }
        }
    }
}

int main(int argc, char *argv[]) {
    remove(LOG_PATH);
    log_msg("Starting robust splash (static v2)...");

    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);

    int fb_fd = -1;
    for (int i = 0; i < 500; i++) { // Wait up to 5s, but check every 10ms
        fb_fd = open("/dev/fb0", O_RDWR);
        if (fb_fd >= 0) break;
        usleep(1000); // 1ms poll
    }

    if (fb_fd < 0) {
        log_error("Failed to open /dev/fb0", errno);
        return 1;
    }

    if (ioctl(fb_fd, FBIOGET_FSCREENINFO, &finfo) < 0 ||
        ioctl(fb_fd, FBIOGET_VSCREENINFO, &vinfo) < 0) {
        log_error("Error reading FB info", errno);
        close(fb_fd);
        return 1;
    }

    screensize = finfo.smem_len;
    if (screensize == 0) screensize = vinfo.xres * vinfo.yres * (vinfo.bits_per_pixel / 8);

    fbp = (unsigned char *)mmap(0, screensize, PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd, 0);
    if (fbp == MAP_FAILED) {
        log_error("mmap failed", errno);
        close(fb_fd);
        return 1;
    }

    char setup_msg[256];
    sprintf(setup_msg, "Detect: %dx%d, %dbpp, LL:%d, R:%d G:%d B:%d", 
            vinfo.xres, vinfo.yres, vinfo.bits_per_pixel, finfo.line_length,
            vinfo.red.offset, vinfo.green.offset, vinfo.blue.offset);
    log_msg(setup_msg);

    int tty_fd = open("/dev/tty0", O_RDWR);
    if (tty_fd >= 0) ioctl(tty_fd, KDSETMODE, KD_GRAPHICS);

    // Initial clear to ultra-dark blue
    fill_color(3, 10, 33);

    #define MAX_FRAMES 100
    unsigned char *frames[MAX_FRAMES];
    int loaded_count = 0;
    // We assume input frames are ALWAYS 24bpp (BGR) 1024x768
    long frame_input_size = 1024 * 768 * 3; 

    for (int i = 0; i < MAX_FRAMES; i++) {
        char path[128];
        sprintf(path, "./splash_%d.raw", i);
        int fd = open(path, O_RDONLY);
        if (fd < 0) {
            sprintf(path, "/splash_%d.raw", i);
            fd = open(path, O_RDONLY);
        }
        
        if (fd >= 0) {
            frames[i] = malloc(frame_input_size);
            if (read(fd, frames[i], frame_input_size) == frame_input_size) {
                loaded_count++;
            } else {
                free(frames[i]);
                frames[i] = NULL;
                close(fd);
                break;
            }
            close(fd);
        } else {
            break;
        }
    }

    // Log detected mode to console
    char mode_msg[128];
    sprintf(mode_msg, "DETECTED FB: %dx%d @ %dbpp, line_length=%d", vinfo.xres, vinfo.yres, vinfo.bits_per_pixel, finfo.line_length);
    log_msg(mode_msg);

    int persistent = (argc > 1);
    int safety_timeout = 75; 

    while (!g_stop) {
        if (!persistent && access("/tmp/splash.stop", F_OK) == 0) break;
        if (safety_timeout-- <= 0) break; 

        for (int i = 0; i < loaded_count && !g_stop; i++) {
            if (!frames[i]) continue;
            
            for (unsigned int y = 0; y < vinfo.yres && y < 768; y++) {
                unsigned char *src_line = &frames[i][y * 1024 * 3];
                unsigned char *dst_line = fbp + (y + vinfo.yoffset) * finfo.line_length;

                for (unsigned int x = 0; x < vinfo.xres && x < 1024; x++) {
                    unsigned char sb = src_line[x * 3 + 0];
                    unsigned char sg = src_line[x * 3 + 1];
                    unsigned char sr = src_line[x * 3 + 2];
                    
                    long pix_offset = (x + vinfo.xoffset) * (vinfo.bits_per_pixel / 8);
                    unsigned char *pixel_ptr = dst_line + pix_offset;

                    if (vinfo.bits_per_pixel == 32 || vinfo.bits_per_pixel == 24) {
                        // Assemble 32-bit pixel based on offsets
                        unsigned int val = (sr << vinfo.red.offset) | 
                                           (sg << vinfo.green.offset) | 
                                           (sb << vinfo.blue.offset);
                        
                        if (vinfo.bits_per_pixel == 32) {
                            *(unsigned int *)pixel_ptr = val;
                        } else {
                            // 24-bit manual write (rare but possible)
                            pixel_ptr[0] = (val >> 0) & 0xFF;
                            pixel_ptr[1] = (val >> 8) & 0xFF;
                            pixel_ptr[2] = (val >> 16) & 0xFF;
                        }
                    } else if (vinfo.bits_per_pixel == 16) {
                        unsigned short val = ((sr >> (8 - vinfo.red.length)) << vinfo.red.offset) |
                                             ((sg >> (8 - vinfo.green.length)) << vinfo.green.offset) |
                                             ((sb >> (8 - vinfo.blue.length)) << vinfo.blue.offset);
                        *(unsigned short *)pixel_ptr = val;
                    }
                }
            }
            usleep(100000);
            if (!persistent && access("/tmp/splash.stop", F_OK) == 0) goto done;
        }
        if (loaded_count == 0) usleep(500000);
    }

done:
    fill_color(3, 10, 33);
    if (tty_fd >= 0) {
        ioctl(tty_fd, KDSETMODE, KD_TEXT);
        close(tty_fd);
    }
    munmap(fbp, screensize);
    close(fb_fd);
    return 0;
}
