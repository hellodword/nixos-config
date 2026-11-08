"""Drive the real Rofi session menu through a VM's keyboard."""
from datetime import timedelta
import re


KEY_DELAY = timedelta(milliseconds=150)
# Fractional bounds in the upright framebuffer, shared with Rofi launchers.
REGION = (0.15, 0.1, 0.7, 0.8)


def open_action(machine, user, visible, action, *, shortcut=False):
    user(machine, "fcitx5-remote -c")
    # Clear bar tooltips before driving the menu with the keyboard.
    machine.move_pointer(90, 90, 100, 100)
    if shortcut:
        machine.send_key("meta_l-shift-p", delay=KEY_DELAY)
    else:
        user(machine, "systemd-run --user --collect --unit=power-menu-fixture desktop-power")
    visible(machine, r"Session", timeout=30, region=REGION)
    machine.send_chars(action, delay=KEY_DELAY)
    visible(machine, re.escape(action), timeout=30, region=REGION)
    machine.send_key("ret", delay=KEY_DELAY)


def blocked(machine, user, visible, action, label, *, shortcut=False):
    open_action(machine, user, visible, action, shortcut=shortcut)
    try:
        visible(machine, re.escape(action) + r" is waiting for:", timeout=30, region=REGION)
    except Exception:
        # These guests contain only synthetic workloads. Retain process
        # identity when a real application's guard fails, including wrappers.
        print(machine.execute("ps -u 1000 -o pid,ppid,ruid,euid,comm,args")[1])
        raise
    visible(machine, re.escape(label), timeout=30, region=REGION)
    machine.screenshot(machine.name + "-power-block-" + re.sub(r"\W+", "-", label))
    user(machine, "systemctl --user is-active graphical-session.target")
    machine.send_key("esc", delay=KEY_DELAY)
    machine.wait_until_fails(r"pgrep -u 1000 -f '^([^ ]*/)?\.?rofi(-wrapped)?( |$)'", timeout=15)


def confirm(machine, user, visible, action, *, shortcut=False):
    open_action(machine, user, visible, action, shortcut=shortcut)
    # The action becomes the prompt only in the confirmation dialog. Its
    # heading stays readable regardless of the selected row's theme colours.
    visible(machine, re.escape(action) + r":", timeout=30, region=REGION)
    machine.send_key("down", delay=KEY_DELAY)
    machine.send_key("ret", delay=KEY_DELAY)
