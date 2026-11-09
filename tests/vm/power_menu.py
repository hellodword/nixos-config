"""Drive the real Rofi session menu through a VM's keyboard."""
from datetime import timedelta
import re


KEY_DELAY = timedelta(milliseconds=150)
# Fractional bounds in the upright framebuffer, shared with Rofi launchers.
REGION = (0.25, 0.04, 0.5, 0.92)


def ready(machine, visible, prompt, choices=(), *, typed=None, unique=False):
    """Match the input row and the list below it in the same central panel."""
    # Before typing, the entry can show a placeholder. Its counter and the
    # adjacent options establish readiness; after typing, require the full input.
    entry = r".*?" if typed is None else re.escape(typed) + r"[\[\]|]?"
    counter = r"(\d+)\s*/\s*\d+"
    heading = re.compile(r"^" + re.escape(prompt) + r":?\s*" + entry
                         + r"\s*" + counter + r"\s*\|?$", re.I)

    def panel(lines):
        for index, line in enumerate(lines):
            match = heading.fullmatch(line["text"])
            if match is None or (unique and match[1] != "1"):
                continue
            if typed is not None:
                return True
            if choices and int(match[1]) != len(choices):
                continue
            # The selected row can have inverted text contrast. Initial menu
            # readiness uses the following rows; after filtering, the complete
            # input and unique result count identify the candidate to activate.
            expected = choices[1:] if len(choices) > 1 else choices
            rows = lines[index + 1:index + 1 + (len(choices) or 2)]
            if not rows:
                continue
            previous = line
            adjacent = []
            for position, row in enumerate(rows):
                # The first visible option may follow one selected row that
                # OCR could not read. Do not rely on the input caret's height.
                gap = 6 if position == 0 else 3
                if row["center"] - previous["center"] > gap * max(row["height"], previous["height"]):
                    break
                adjacent.append(row)
                previous = row
            # Use adjacent options; text below the panel can belong to a
            # notification or the application behind the menu.
            labels = [" ".join(word["text"] for word in row["words"] if re.search(r"\w", word["text"]))
                      for row in adjacent]
            if not choices and len(labels) >= 2:
                return True
            # The first (selected) option may or may not be readable.
            for start in (0, 1) if len(choices) > 1 else (0,):
                candidates = labels[start:start + len(expected)]
                if expected and len(candidates) == len(expected) and all(
                    re.fullmatch(choice, label, re.I)
                    for choice, label in zip(expected, candidates)
                ):
                    return True
        return False

    # The filtered entry and its counter are separate text islands across a
    # wide row. Sparse segmentation finds both without choosing a background
    # application's paragraph as the main block. A block pass also reads the
    # compact counter beside the border in a portrait menu.
    return visible(machine, prompt + ": " + (typed or ""), timeout=30, region=REGION,
                   layout="sparse" if typed is not None else "block",
                   fallback_layout="block" if typed is not None else None, check=panel, consecutive=2)


def open_action(machine, user, visible, action, *, shortcut=False):
    user(machine, "fcitx5-remote -c")
    # Clear bar tooltips before driving the menu with the keyboard.
    machine.move_pointer(90, 90, 100, 100)
    if shortcut:
        machine.send_key("meta_l-shift-p", delay=KEY_DELAY)
    else:
        user(machine, "systemd-run --user --collect --unit=power-menu-fixture desktop-power")
    ready(machine, visible, "Session", ("Log out", "Reboot", "Power off"))
    machine.send_chars(action, delay=KEY_DELAY)
    ready(machine, visible, "Session", typed=action, unique=True)
    machine.send_key("ret", delay=KEY_DELAY)


def blocked(machine, user, visible, action, label, *, shortcut=False):
    with machine.input_lock:
        open_action(machine, user, visible, action, shortcut=shortcut)
        try:
            visible(machine, re.escape(action) + r"\s+is waiting for:.*" + re.escape(label),
                    timeout=30, region=REGION, layout="block")
        except Exception:
            # These guests contain only synthetic workloads. Retain process
            # identity when a real application's guard fails, including wrappers.
            print(machine.execute("ps -u 1000 -o pid,ppid,ruid,euid,comm,args")[1])
            raise
        machine.screenshot(machine.name + "-power-block-" + re.sub(r"\W+", "-", label))
        user(machine, "systemctl --user is-active graphical-session.target")
        machine.send_key("esc", delay=KEY_DELAY)
        machine.wait_until_fails(r"pgrep -u 1000 -f '^([^ ]*/)?\.?rofi(-wrapped)?( |$)'", timeout=15)


def confirm(machine, user, visible, action, *, shortcut=False):
    with machine.input_lock:
        open_action(machine, user, visible, action, shortcut=shortcut)
        ready(machine, visible, action, ("Cancel", re.escape(action)))
        machine.stop_activity()
        machine.send_key("down", delay=KEY_DELAY)
        machine.send_key("ret", delay=KEY_DELAY)
