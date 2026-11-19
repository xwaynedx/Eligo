import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

PRIVATE = "testTabbedPrivateButtonOpensItsBrowserWhenAnotherRowIsHighlighted"
SHIFT = "testShiftEnterOnFocusedPrivateButtonUsesTheHighlightedBrowser"
REOPEN = "testReopenedForegroundPanelStartsAtChooserAndTabsToCopy"
NORMAL = "testTabToNormalRowHighlightsAndActivatesThatBrowser"


def make_host(root):
    platform = subprocess.check_output(["xcrun", "--show-sdk-platform-path"], text=True).strip()
    developer = Path(platform) / "Developer"
    frameworks = developer / "Library/Frameworks"
    app = root / "TabTestHost.app"
    contents = app / "Contents"
    binary = contents / "MacOS/TabTestHost"
    binary.parent.mkdir(parents=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": binary.name, "CFBundleIdentifier": "io.github.xwaynedx.eligo.tabtest",
        "CFBundleName": "Tab Test Host", "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "LSUIElement": True,
    }))
    subprocess.run([
        "xcrun", "clang", "-fobjc-arc", str(Path(__file__).with_name("TabTestHost.m")),
        "-F", str(frameworks), "-framework", "AppKit", "-framework", "XCTest",
        *[f"-Wl,-rpath,{p}" for p in (frameworks, developer / "Library/PrivateFrameworks", developer / "usr/lib")],
        "-o", str(binary),
    ], check=True)
    subprocess.run(["codesign", "--sign", "-", str(app)], check=True)
    return app


def matching(lines, prefix):
    return [dict(field.split("=", 1) for field in line.split()[1:]) for line in lines if line.startswith(prefix + " ")]


def run_host(app, bundle, expected_mode=None):
    methods = [REOPEN] if expected_mode is None else [NORMAL, PRIVATE, SHIFT, REOPEN]
    label = expected_mode or "local"
    environment = {**os.environ, "ELIGO_TAB_PANEL": "production", "ELIGO_TAB_TEST_BUNDLE": str(bundle),
                   "ELIGO_TAB_METHODS": ",".join(methods)}
    # 直接启动宿主，超时时 subprocess.run 会终止并回收当前这一个子进程。
    started = subprocess.run([app / "Contents/MacOS/TabTestHost"], env=environment,
                             capture_output=True, text=True, timeout=90)
    lines = (started.stdout + "\n" + started.stderr).splitlines()
    print(f"::group::{label}", *lines, "::endgroup::", sep="\n", flush=True)
    completed = matching(lines, "ELIGO_HOST_TEST")
    ok = started.returncode == 0 and [row["method"] for row in completed] == methods
    ok = ok and all(row["executed"] == "1" and row["skipped"] == "0" and row["failures"] == "0"
                    and row["passed"] == "true" for row in completed)
    if expected_mode is not None:
        private = matching(lines, "ELIGO_PRIVATE")
        expected_keys = {(direction, key) for direction in ("false", "true") for key in ("36", "76", "49")}
        ok = ok and len(private) == 6 and {(r["backwards"], r["key"]) for r in private} == expected_keys
        ok = ok and all(r["fullAccess"] == expected_mode for r in completed)
        ok = ok and all(r["fullAccess"] == expected_mode and r["visible"] == r["keyWindow"] == r["active"] == "true"
                        and r["deliveries"] == "1" and r["targets"] == "com.google.Chrome/privateBrowsing" for r in private)
        rejected = matching(lines, "ELIGO_SHIFT_SAFARI")
        ok = ok and len(rejected) == 2 and {r["key"] for r in rejected} == {"36", "76"}
        ok = ok and all(r["fullAccess"] == expected_mode and r["deliveries"] == "0"
                        and r["visible"] == r["keyWindow"] == r["active"] == r["privateFocused"] == "true"
                        for r in rejected)
    details = [line for line in lines if line.startswith(("ELIGO_HOST_TEST ", "ELIGO_PRIVATE ", "ELIGO_SHIFT_SAFARI ", "ELIGO_HOST_ASSERT "))]
    notice = "notice" if ok else "error"
    message = "%0A".join(line.replace("%", "%25") for line in (details or lines[-4:]))
    print(f"::{notice} title=AppKit fullAccess {label}::{message}", flush=True)
    return ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--hosted-both-modes", action="store_true")
    group.add_argument("--local-reopen", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="eligo-keyboard-") as temp:
        app = make_host(Path(temp))
        try:
            if args.local_reopen:
                return run_host(app, args.bundle.resolve())
            pref = "AppleKeyboardUIMode"
            old = subprocess.run(["defaults", "read", "-g", pref], capture_output=True, text=True)
            original = int(old.stdout.strip()) if old.returncode == 0 else 0
            try:
                passed = []
                for enabled, mode in [(False, original & ~2), (True, original | 2)]:
                    subprocess.run(["defaults", "write", "-g", pref, "-int", str(mode)], check=True)
                    passed.append(run_host(app, args.bundle.resolve(), str(enabled).lower()))
                return all(passed)
            finally:
                restore = ["write", "-g", pref, "-int", str(original)] if old.returncode == 0 else ["delete", "-g", pref]
                subprocess.run(["defaults", *restore], check=True)
        finally:
            lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            subprocess.run([lsregister, "-u", str(app)], check=False)


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
