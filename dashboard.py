import tkinter as tk
from tkinter import ttk, messagebox, simpledialog, Listbox, Scrollbar
import subprocess
import sys
import os
import threading
import time
import re
import traceback

# --- Global Crash Handler ---
def handle_exception(exc_type, exc_value, exc_traceback):
    with open("/tmp/dashboard_crash.log", "w") as f:
        traceback.print_exception(exc_type, exc_value, exc_traceback, file=f)
    sys.__excepthook__(exc_type, exc_value, exc_traceback)

sys.excepthook = handle_exception

# --- Helper Functions ---

def run_cmd(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True).strip()
    except subprocess.CalledProcessError as e:
        return e.output.strip()
    except Exception as e:
        return str(e)

def run_sudo(cmd):
    return run_cmd(f"sudo {cmd}")

def get_interfaces():
    try:
        all_ifaces = os.listdir('/sys/class/net')
        wired = [i for i in all_ifaces if i.startswith('e') or i.startswith('en')]
        wireless = [i for i in all_ifaces if i.startswith('w') or i.startswith('wl')]
        w_iface = wired[0] if wired else "eth0"
        wifi_iface = wireless[0] if wireless else None
        return w_iface, wifi_iface
    except:
        return "eth0", None

WIRED_IFACE, WIFI_IFACE = get_interfaces()

# Shared data for thread-safe UI updates
monitor_data = {
    "net_connected": False,
    "net_ip": "No IP",
    "storage_used": 0,
    "storage_desc": "Checking...",
    "peripherals": "Checking..."
}

# --- Dashboard Application ---

# Font names that always exist in Tk
FONT_DEFAULT = "TkDefaultFont"
FONT_FIXED = "TkFixedFont"

class DashboardApp(tk.Tk):
    def __init__(self):
        super().__init__()
        
        # Window & Theme
        self.title("System Dashboard")
        self.attributes('-fullscreen', True)
        self.configure(bg='#1e272e')
        
        # Geometry Force
        sw, sh = self.winfo_screenwidth(), self.winfo_screenheight()
        self.geometry(f"{sw}x{sh}+0+0")
        self.config(cursor="arrow")
        
        # Styles
        style = ttk.Style()
        style.theme_use('clam')
        style.configure("TFrame", background='#1e272e')
        style.configure("Sidebar.TFrame", background='#0c1013')
        style.configure("Card.TFrame", background='#2f3640', relief="flat")
        
        style.configure("TLabel", background='#2f3640', foreground='white')
        
        # Main Layout
        self.columnconfigure(1, weight=1)
        self.rowconfigure(0, weight=1)
        
        # --- Sidebar ---
        sidebar = ttk.Frame(self, style="Sidebar.TFrame", width=250)
        sidebar.grid(row=0, column=0, sticky="ns")
        sidebar.pack_propagate(False)
        
        lbl_title = tk.Label(sidebar, text="DASHBOARD", bg='#0c1013', fg='#0abde3', font=(FONT_DEFAULT, 18, "bold"))
        lbl_title.pack(pady=40)
        
        self.sidebar_net = tk.Label(sidebar, text="Network: ...", bg='#0c1013', fg='#bdc3c7')
        self.sidebar_net.pack(pady=10)
        
        btn_exit = tk.Button(sidebar, text="Power / Exit", command=self.show_shutdown_menu,
                             bg='#e74c3c', fg='white', relief='flat', cursor='hand2')
        btn_exit.pack(side="bottom", fill="x", padx=20, pady=20)
        
        # --- Content Area ---
        content = ttk.Frame(self, style="TFrame")
        content.grid(row=0, column=1, sticky="nsew", padx=40, pady=40)
        
        tk.Label(content, text="System Overview", bg='#1e272e', fg='white', font=(FONT_DEFAULT, 22, "bold")).pack(anchor="w", pady=(0, 30))
        
        # Grid for Modules
        self.modules_frame = ttk.Frame(content, style="TFrame")
        self.modules_frame.pack(fill="both", expand=True)
        
        # Create Cards
        self.create_network_card(0, 0)
        self.create_storage_card(0, 1)
        self.create_wifi_card(1, 0)
        self.create_misc_card(1, 1)
        
        # Start Monitor Thread
        self.running = True
        threading.Thread(target=self.monitor_loop, daemon=True).start()
        
        # Start UI Update Loop (Thread-safe)
        self.after(500, self.update_ui_loop)
        
        self.focus_force()
        self.bind("<Escape>", lambda e: self.destroy())
        
        # Force update to render GUI
        self.update()
        
        # Force update to render GUI
        self.update()
        
        # FAILSAFE: Don't block on wait_visibility as it might hang on some X servers
        # Instead, just wait a secure amount of time then kill splash
        self.after(1000, self.kill_splash_screen)

    # --- KILL SPLASH SCREEN AFTER UI LOAD ---
    def kill_splash_screen(self):
        print("Stopping splash screen...")
        # 1. Signal the renderer to wipe and exit
        try:
            with open("/tmp/splash.stop", "w") as f:
                f.write("stop")
            # Permission check - ensure everyone can see it
            os.chmod("/tmp/splash.stop", 0o666)
        except:
            pass

        # 2. Short wait for renderer to see file and wipe
        self.after(300, self._force_cleanup_splash)

    def _force_cleanup_splash(self):
        # Failsafe: Force kill if it's still running
        run_sudo("pkill -TERM tiny_splash")
        # Ensure we cover any terminal artifacts
        self.update_idletasks()

    def show_shutdown_menu(self):
        menu = tk.Toplevel(self)
        menu.title("Power Options")
        # Modal-like behavior
        menu.transient(self)
        menu.grab_set()
        
        # Center the menu
        mw, mh = 400, 300
        sw, sh = self.winfo_screenwidth(), self.winfo_screenheight()
        menu.geometry(f"{mw}x{mh}+{(sw-mw)//2}+{(sh-mh)//2}")
        menu.configure(bg='#2f3640')
        menu.overrideredirect(True) # No window borders

        tk.Label(menu, text="Power Options", bg='#2f3640', fg='white', font=(FONT_DEFAULT, 16, "bold")).pack(pady=20)

        btns_spec = [
            ("Shutdown", "#e74c3c", lambda: self.safe_power_action("poweroff")),
            ("Reboot", "#f39c12", lambda: self.safe_power_action("reboot")),
            ("Exit to Shell", "#7f8c8d", self.destroy),
            ("Cancel", "#34495e", menu.destroy)
        ]

        for text, color, cmd in btns_spec:
            tk.Button(menu, text=text, command=cmd, bg=color, fg='white',
                      relief='flat', width=20, pady=5).pack(pady=5)

    def safe_power_action(self, action):
        # 1. Hide the main window immediately
        self.withdraw()
        # 2. Start the splash renderer to cover the screen (persistent mode)
        run_sudo("/sbin/tiny_splash shutdown &")
        # 3. Trigger system action
        run_sudo(action)

    def create_card(self, row, col, title):
        card = ttk.Frame(self.modules_frame, style="Card.TFrame", padding=20)
        card.grid(row=row, column=col, sticky="nsew", padx=10, pady=10)
        self.modules_frame.columnconfigure(col, weight=1)
        self.modules_frame.rowconfigure(row, weight=1)
        
        tk.Label(card, text=title, bg='#2f3640', fg='#48dbfb', font=(FONT_DEFAULT, 14, "bold")).pack(anchor="w", pady=(0, 15))
        return card

    def create_network_card(self, r, c):
        card = self.create_card(r, c, "LAN Status")
        
        self.lbl_net_status = tk.Label(card, text="Checking...", bg='#2f3640', fg='white')
        self.lbl_net_status.pack(anchor="w")
        
        self.lbl_ip = tk.Label(card, text="IP: --", bg='#2f3640', fg='#8395a7')
        self.lbl_ip.pack(anchor="w", pady=5)
        
        self.lbl_details = tk.Label(card, text=f"({WIRED_IFACE})", bg='#2f3640', fg='#57606f')
        self.lbl_details.pack(anchor="w")
        
        tk.Button(card, text="Renew DHCP (Debug)", command=self.renew_dhcp,
                  bg='#6c5ce7', fg='white', relief='flat').pack(anchor="w", pady=10)

    def create_storage_card(self, r, c):
        card = self.create_card(r, c, "Storage Usage (/)")
        self.progress_storage = ttk.Progressbar(card, orient="horizontal", mode="determinate")
        self.progress_storage.pack(fill="x", pady=10)
        self.lbl_storage = tk.Label(card, text="Calculating...", bg='#2f3640', fg='white')
        self.lbl_storage.pack(anchor="w")

    def create_wifi_card(self, r, c):
        card = self.create_card(r, c, "Wi-Fi Networks")
        
        list_frame = tk.Frame(card, bg='#2f3640')
        list_frame.pack(fill="both", expand=True)
        
        self.wifi_list = Listbox(list_frame, bg='#1e272e', fg='white', borderwidth=0, highlightthickness=0, font=(FONT_FIXED,))
        self.wifi_list.pack(side="left", fill="both", expand=True)
        
        scrollbar = Scrollbar(list_frame, orient="vertical", command=self.wifi_list.yview)
        scrollbar.pack(side="right", fill="y")
        self.wifi_list.config(yscrollcommand=scrollbar.set)
        
        btn_frame = tk.Frame(card, bg='#2f3640')
        btn_frame.pack(fill="x", pady=(10, 0))
        
        tk.Button(btn_frame, text="Scan", command=self.scan_wifi,
                  bg='#0984e3', fg='white', relief='flat').pack(side="left", padx=5)
        tk.Button(btn_frame, text="Connect", command=self.connect_wifi_selected,
                  bg='#00b894', fg='white', relief='flat').pack(side="left", padx=5)

    def create_misc_card(self, r, c):
        card = self.create_card(r, c, "Tools & Checks")
        
        tk.Button(card, text="Test Connectivity (keva.agency)", command=self.check_url,
                  bg='#f39c12', fg='white', relief='flat').pack(fill="x", pady=10)
        
        self.lbl_url_status = tk.Label(card, text="", bg='#2f3640', fg='white')
        self.lbl_url_status.pack(pady=5)
        
        self.lbl_periph = tk.Label(card, text="...", bg='#2f3640', fg='#95a5a6')
        self.lbl_periph.pack(anchor="w", pady=10)
        
    def update_ui_loop(self):
        if not self.running: return
        
        # Pull data from shared monitor_data dict
        net_text = "Connected" if monitor_data["net_connected"] else "Disconnected"
        net_color = "#1dd1a1" if monitor_data["net_connected"] else "#ff6b6b"
        
        self.lbl_net_status.config(text=f"● {net_text}", fg=net_color)
        self.lbl_ip.config(text=f"IP: {monitor_data['net_ip']}")
        self.sidebar_net.config(text=f"Net: {net_text}", fg=net_color)
        
        self.progress_storage['value'] = monitor_data["storage_used"]
        self.lbl_storage.config(text=monitor_data["storage_desc"])
        self.lbl_periph.config(text=monitor_data["peripherals"])
        
        # Re-schedule
        self.after(2000, self.update_ui_loop)

    def monitor_loop(self):
        while self.running:
            try:
                self.gather_network_info()
                self.gather_storage_info()
                self.gather_peripheral_info()
            except Exception as e:
                print(f"Monitor error: {e}")
            time.sleep(2)

    def gather_network_info(self):
        connected = False
        try:
            subprocess.check_call(["ping", "-c", "1", "-W", "1", "8.8.8.8"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            connected = True
        except:
            connected = False
            
        # Busybox compatible IP extraction (sed instead of grep -P)
        ip = run_cmd(f"ip -4 addr show {WIRED_IFACE} | sed -n 's/.*inet \\([0-9.]*\\).*/\\1/p'")
        if not ip and WIFI_IFACE:
            ip = run_cmd(f"ip -4 addr show {WIFI_IFACE} | sed -n 's/.*inet \\([0-9.]*\\).*/\\1/p'")
        
        monitor_data["net_connected"] = connected
        monitor_data["net_ip"] = ip if ip else "No IP"

    def gather_storage_info(self):
        try:
            output = run_cmd("df / | tail -n 1")
            parts = output.split()
            if len(parts) >= 5:
                used_str = parts[4].replace('%', '')
                used_p = int(used_str)
                avail = parts[3]
                monitor_data["storage_used"] = used_p
                monitor_data["storage_desc"] = f"Used: {used_p}%  (Avail: {int(avail)//1024} MB)"
        except:
            pass

    def gather_peripheral_info(self):
        devices = run_cmd("cat /proc/bus/input/devices")
        has_kbd = "Handlers=kbd" in devices or "Keyboard" in devices
        has_mouse = "Handlers=mouse" in devices or "Mouse" in devices
        monitor_data["peripherals"] = f"Keyboard: {'YES' if has_kbd else 'NO'} | Mouse: {'YES' if has_mouse else 'NO'}"

    def renew_dhcp(self):
        def _task():
            try:
                run_sudo(f"ifconfig {WIRED_IFACE} up")
                cmd = f"sudo udhcpc -f -n -i {WIRED_IFACE}" # Foreground, run once
                output = run_cmd(cmd)
                messagebox.showinfo("DHCP Result", f"Command: {cmd}\n\nOutput:\n{output}")
                self.gather_network_info()
            except Exception as e:
                messagebox.showerror("DHCP Error", str(e))
        threading.Thread(target=_task).start()

    def load_wifi_drivers_debug(self):
        def _task():
            cmd = "tce-load -i /cde/optional/wireless-6.6.8-tinycore64.tcz 2>&1"
            out = run_cmd(cmd)
            lsmod = run_cmd("lsmod | grep cfg80211")
            
            msg = f"Extension Load Output:\n{out}\n\nModule Check (cfg80211):\n{lsmod}"
            if not lsmod:
                msg += "\n\nWARNING: Wi-Fi drivers NOT loaded!"
            else:
                msg += "\n\nSUCCESS: Wi-Fi stack is active."
            
            messagebox.showinfo("Wi-Fi Debug", msg)
            if lsmod: self.scan_wifi()
            
        threading.Thread(target=_task).start()

    def scan_wifi(self):
        self.wifi_list.delete(0, tk.END)
        # Refresh interface check
        global WIFI_IFACE
        _, WIFI_IFACE = get_interfaces()
        
        if not WIFI_IFACE:
            self.wifi_list.insert(tk.END, "No Wi-Fi Adapter found.")
            if messagebox.askyesno("No Wi-Fi", "No adapter found.\nTry loading drivers manually?"):
                self.load_wifi_drivers_debug()
            return

        self.wifi_list.insert(tk.END, "Scanning...")
        self.update()
        
        def _scan():
            run_sudo(f"ifconfig {WIFI_IFACE} up")
            output = run_sudo(f"iwlist {WIFI_IFACE} scan")
            
            # Use after to update UI
            self.after(0, lambda: self._update_wifi_list(output))
            
        threading.Thread(target=_scan).start()
    
    def _update_wifi_list(self, scan_output):
        self.wifi_list.delete(0, tk.END)
        networks = []
        for line in scan_output.split('\n'):
            line = line.strip()
            if "ESSID:" in line:
                ssid = line.split(':')[1].strip('"')
                if ssid: networks.append(ssid)
                    
        if not networks:
             networks = ["No networks found"]
        
        networks = list(set(networks))
        for net in networks:
            self.wifi_list.insert(tk.END, net)

    def connect_wifi_selected(self):
        if not hasattr(self, 'wifi_list'): return
        selection = self.wifi_list.curselection()
        if not selection:
            messagebox.showwarning("Wi-Fi", "Select a network first.")
            return
            
        ssid = self.wifi_list.get(selection[0])
        if "No networks" in ssid or "Scanning" in ssid: return
        
        pwd = simpledialog.askstring("Wi-Fi", f"Enter Password for {ssid}:", show='*')
        if not pwd: return
        
        def _connect():
            if not WIFI_IFACE: return
            conf = f"""ctrl_interface=/var/run/wpa_supplicant\nnetwork={{\n ssid="{ssid}"\n psk="{pwd}"\n}}"""
            with open("/tmp/wpa_custom.conf", "w") as f:
                f.write(conf)
            
            run_sudo("pkill wpa_supplicant")
            run_sudo("pkill udhcpc")
            run_sudo(f"wpa_supplicant -B -i {WIFI_IFACE} -c /tmp/wpa_custom.conf")
            time.sleep(2)
            run_sudo(f"udhcpc -b -i {WIFI_IFACE}")
            messagebox.showinfo("Wi-Fi", f"Connecting to {ssid}...")
            
        threading.Thread(target=_connect).start()

    def check_url(self):
        def _check():
            try:
                cmd = "curl -I -s -o /dev/null -w '%{http_code}' https://keva.agency"
                code = run_cmd(cmd)
                if code == "200" or code == "301" or code == "302":
                    res = f"SUCCESS (Code: {code})"
                    color = "#1dd1a1"
                else:
                    res = f"FAILED (Code: {code})"
                    color = "#ff6b6b"
            except Exception as e:
                res = f"ERROR: {e}"
                color = "#ff6b6b"
            
            self.lbl_url_status.config(text=res, fg=color)
            messagebox.showinfo("Result", f"Connectivity Check for keva.agency:\n{res}")
            
        self.lbl_url_status.config(text="Checking...", fg="white")
        threading.Thread(target=_check).start()

if __name__ == "__main__":
    try:
        app = DashboardApp()
        app.mainloop()
    except Exception as e:
        # CRASH TRAP: Show error visually so user can see what went wrong
        err_msg = traceback.format_exc()
        with open("/tmp/dashboard_fatal.log", "w") as f:
            f.write(err_msg)
        print(f"DASHBOARD FATAL ERROR:\n{err_msg}")
        os.system("sudo pkill -9 tiny_splash")
        os.system("sudo killall -9 tiny_splash")
        # Try to show a visible error window
        try:
            root = tk.Tk()
            root.title("Dashboard Error")
            root.configure(bg='#1e272e')
            root.geometry("800x400")
            tk.Label(root, text="Dashboard Failed to Start", bg='#1e272e', fg='#e74c3c', font=('TkDefaultFont', 16, 'bold')).pack(pady=20)
            txt = tk.Text(root, bg='#2f3640', fg='white', wrap='word')
            txt.insert('1.0', err_msg)
            txt.pack(fill='both', expand=True, padx=20, pady=10)
            root.mainloop()
        except:
            pass
