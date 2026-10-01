"""Verify physical Mach-O closure; this is not a build/source attestation."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import sys
import tempfile


CAPTURE_SPEC = importlib.util.spec_from_file_location(
    "symphony_bounded_process", Path(__file__).resolve().with_name("bounded_process.py")
)
CAPTURE = importlib.util.module_from_spec(CAPTURE_SPEC)
CAPTURE_SPEC.loader.exec_module(CAPTURE)


PROFILE = "macos-arm64-26.0-sdk26.5"
MINIMUM = (26, 0, 0)
SDK = (26, 5, 0)
DYLD = "/usr/lib/dyld"
SYSTEM_LIB = "/usr/lib/libSystem.B.dylib"
MAX_ARTIFACT = 256 * 1024 * 1024
MAX_COMMAND_BYTES = 1024 * 1024
MAX_COMMANDS = 4096
MAX_TOOL_OUTPUT = 8 * 1024 * 1024
TOOL_TIMEOUT = 30
COPY_CHUNK = 1024 * 1024
RECEIPT_CLOSE_NOTE = "Private receipt staging file close also failed."
RECEIPT_CLEANUP_NOTE = "Private receipt staging directory cleanup also failed."
RECEIPT_PUBLISHED_NOTE = "Complete receipt publication preceded cleanup failure."
HEADER_SIZE = 32
ARM64 = 0x0100000C
MH_MAGIC_64 = 0xFEEDFACF
MH_EXECUTE = 2
PLATFORM_MACOS = 1
VM_PROT_READ = 0x01
VM_PROT_WRITE = 0x02
VM_PROT_EXECUTE = 0x04
VM_PROT_ALL = VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE
SG_HIGHVM = 0x01
UINT64_MAX = (1 << 64) - 1

# Apple's SDK mach-o/loader.h defines these command numbers and layouts.
COMMANDS = {
    0x19: "LC_SEGMENT_64", 0x2: "LC_SYMTAB", 0xB: "LC_DYSYMTAB",
    0xC: "LC_LOAD_DYLIB", 0xE: "LC_LOAD_DYLINKER", 0x1B: "LC_UUID",
    0x1D: "LC_CODE_SIGNATURE", 0x80000022: "LC_DYLD_INFO_ONLY",
    0x26: "LC_FUNCTION_STARTS", 0x80000028: "LC_MAIN",
    0x29: "LC_DATA_IN_CODE", 0x2A: "LC_SOURCE_VERSION",
    0x32: "LC_BUILD_VERSION", 0x80000033: "LC_DYLD_EXPORTS_TRIE",
    0x80000034: "LC_DYLD_CHAINED_FIXUPS",
}
LINKEDIT = {
    "LC_CODE_SIGNATURE", "LC_FUNCTION_STARTS", "LC_DATA_IN_CODE",
    "LC_DYLD_EXPORTS_TRIE", "LC_DYLD_CHAINED_FIXUPS",
}
FIXED_SIZES = {
    "LC_SYMTAB": 24, "LC_DYSYMTAB": 80, "LC_UUID": 24,
    "LC_DYLD_INFO_ONLY": 48, "LC_MAIN": 24, "LC_SOURCE_VERSION": 16,
} | {name: 16 for name in LINKEDIT}
REQUIRED = {
    "LC_LOAD_DYLINKER", "LC_BUILD_VERSION", "LC_MAIN", "LC_SYMTAB",
    "LC_DYSYMTAB", "LC_UUID",
}


class Rejected(Exception):
    def __init__(self, code, detail, remedy):
        super().__init__(detail)
        self.diagnostic = {"code": code, "detail": detail, "remedy": remedy}


class Arguments(argparse.ArgumentParser):
    def error(self, message):
        raise Rejected("arguments", message, "Run check_release.py --help for the fixed profile and artifact argument.")


def reject(code, detail, *, cleanup_notes=()):
    error = Rejected(code, detail, "Rebuild for the declared release profile; do not edit the receipt.")
    if cleanup_notes:
        error.diagnostic["cleanup_notes"] = list(cleanup_notes)
    raise error


def digest(data):
    return hashlib.sha256(data).hexdigest()


def version(value):
    return (value >> 16, (value >> 8) & 255, value & 255)


def version_text(value):
    return ".".join(str(part) for part in value[:2]) + (f".{value[2]}" if value[2] else "")


def require_range(offset, size, total):
    if offset > total or size > total - offset:
        reject("malformed", "A referenced file range is truncated.")


def ascii_name(value, label):
    try:
        return value.decode("ascii")
    except UnicodeDecodeError:
        reject("malformed", f"The {label} is not ASCII.")


def command_name(block, start):
    offset = struct.unpack_from("<I", block, 8)[0]
    if offset != start or b"\0" not in block[offset:]:
        reject("malformed", "A load-command name has an invalid offset or terminator.")
    name, padding = block[offset:].split(b"\0", 1)
    if any(padding):
        reject("malformed", "A load-command name has nonzero trailing bytes.")
    return ascii_name(name, "load-command name")


def check_dependencies(dependencies):
    """Adding dependencies cannot repair rejection; only libSystem is allowed."""
    for dependency in dependencies:
        if dependency != SYSTEM_LIB:
            reject("dependency", f"Foreign or relative dylib import: {dependency}")


def check_segment(block, total):
    if len(block) < 72:
        reject("malformed", "A segment command is truncated.")
    values = struct.unpack_from("<II16sQQQQiiII", block)
    name = values[2].rstrip(b"\0")
    segment = ascii_name(name, "segment name")
    vmaddr, vmsize = values[3], values[4]
    fileoff, filesize, sections = values[5], values[6], values[9]
    maximum, initial = values[7], values[8]
    if len(block) != 72 + sections * 80:
        reject("malformed", "A segment's section count disagrees with its size.")
    # SDK mach/vm_prot.h defines ordinary segment access; VM API modifiers are excluded.
    if (maximum | initial) & ~VM_PROT_ALL:
        reject("permissions", f"Segment {segment} has unsupported permission bits.")
    if initial & ~maximum:
        reject("permissions", f"Segment {segment} initial permissions exceed its maximum.")
    if segment == "__TEXT" and not initial & VM_PROT_EXECUTE:
        reject("permissions", "The __TEXT segment must initially permit execution.")
    if filesize > vmsize or vmaddr > UINT64_MAX - vmsize:
        reject("mapping", f"Segment {segment} has an invalid virtual extent.")
    # SDK SG_HIGHVM places file bytes above low zero-fill (normally used by core stacks).
    backed_start = vmaddr + (vmsize - filesize if values[10] & SG_HIGHVM else 0)
    require_range(fileoff, filesize, total)
    for offset in range(72, len(block), 80):
        section = struct.unpack_from("<16s16sQQIIIIIIII", block, offset)
        if section[1].rstrip(b"\0") != name:
            reject("malformed", "A section disagrees with its containing segment.")
        section_type = section[8] & 255
        # Zero-fill sections have memory size but no file payload.
        if section_type not in {1, 0xC, 0x12}:
            require_range(section[4], section[3], total)
        require_range(section[6], section[7] * 8, total)
    return {"name": segment, "fileoff": fileoff, "filesize": filesize,
            "vmaddr": vmaddr, "backed_start": backed_start, "initial": initial}


def check_shape(name, block, total):
    expected = FIXED_SIZES.get(name)
    if expected is not None and len(block) != expected:
        reject("malformed", f"Wrong command size: {name}")
    if name in LINKEDIT:
        offset, size = struct.unpack_from("<II", block, 8)
        require_range(offset, size, total)
    if name == "LC_SYMTAB":
        symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", block, 8)
        require_range(symoff, nsyms * 16, total)
        require_range(stroff, strsize, total)
    if name == "LC_DYSYMTAB":
        fields = struct.unpack_from("<18I", block, 8)
        for index, item_size in ((6, 8), (8, 56), (10, 4), (12, 4), (14, 8), (16, 8)):
            require_range(fields[index], fields[index + 1] * item_size, total)
    if name == "LC_DYLD_INFO_ONLY":
        fields = struct.unpack_from("<10I", block, 8)
        for index in range(0, len(fields), 2):
            require_range(fields[index], fields[index + 1], total)
    if name == "LC_MAIN":
        entryoff = struct.unpack_from("<Q", block, 8)[0]
        if entryoff >= total:
            reject("malformed", "The entry point is outside the file.")


def parse_macho(data):
    """Decode checked load-command framing; unknown shapes fail closed."""
    if len(data) < HEADER_SIZE:
        reject("malformed", "The Mach-O header is missing or truncated.")
    magic, cpu, subtype, kind, count, size, flags, reserved = struct.unpack_from("<8I", data)
    if (magic, cpu, subtype, kind, reserved) != (MH_MAGIC_64, ARM64, 0, MH_EXECUTE, 0):
        reject("architecture", "Expected a thin arm64 Mach-O executable.")
    if not 0 < count <= MAX_COMMANDS or size > MAX_COMMAND_BYTES:
        reject("malformed", "The load-command count or size exceeds the profile bound.")
    require_range(HEADER_SIZE, size, len(data))
    end = HEADER_SIZE + size
    offset = HEADER_SIZE
    commands, dependencies, segments = [], [], []
    singletons = set()
    build = None
    loader = None
    entry = None
    for _ in range(count):
        if offset + 8 > end:
            reject("malformed", "A load-command header is truncated.")
        command, length = struct.unpack_from("<II", data, offset)
        if length < 8 or length % 8 or offset + length > end:
            reject("malformed", "A load-command size is invalid or truncated.")
        name = COMMANDS.get(command)
        if name is None:
            reject("command", f"Unapproved load command: 0x{command:08x}")
        block = data[offset:offset + length]
        commands.append({"name": name, "size": length})
        if name not in {"LC_SEGMENT_64", "LC_LOAD_DYLIB"}:
            if name in singletons:
                reject("malformed", f"Duplicate load command: {name}")
            singletons.add(name)
        check_shape(name, block, len(data))
        if name == "LC_SEGMENT_64":
            segments.append(check_segment(block, len(data)))
        if name == "LC_MAIN":
            entry = struct.unpack_from("<Q", block, 8)[0]
        if name == "LC_LOAD_DYLIB":
            if length < 32:
                reject("malformed", "A dylib command is truncated.")
            dependencies.append(command_name(block, 24))
        if name == "LC_LOAD_DYLINKER":
            if length < 16:
                reject("malformed", "A loader command is truncated.")
            loader = command_name(block, 12)
        if name == "LC_BUILD_VERSION":
            if length < 24:
                reject("malformed", "The build-version command is truncated.")
            platform, minimum, sdk, tools = struct.unpack_from("<4I", block, 8)
            if length != 24 + tools * 8:
                reject("malformed", "The build-tool count disagrees with its size.")
            build = {"platform": platform, "minimum": version(minimum), "sdk": version(sdk)}
        offset += length
    if offset != end or not REQUIRED <= singletons:
        reject("malformed", "Load commands are missing or leave unparsed bytes.")
    segment_names = [segment["name"] for segment in segments]
    if len(segment_names) != len(set(segment_names)) or not {"__TEXT", "__LINKEDIT"} <= set(segment_names):
        reject("malformed", "Executable segments are missing or duplicated.")
    # Dyld uses __TEXT.vmaddr + entryoff; that address must map the same file byte.
    text = next(segment for segment in segments if segment["name"] == "__TEXT")
    if entry > UINT64_MAX - text["vmaddr"]:
        reject("entrypoint", "LC_MAIN's virtual address overflows the address space.")
    entry_address = text["vmaddr"] + entry
    if not any(segment["initial"] & VM_PROT_EXECUTE and
               segment["fileoff"] <= entry < segment["fileoff"] + segment["filesize"]
               and entry_address == segment["backed_start"] + entry - segment["fileoff"]
               for segment in segments):
        reject("entrypoint", "LC_MAIN must map its file byte in an initially executable segment.")
    if loader != DYLD:
        reject("loader", "The executable does not use the approved system loader.")
    if build != {"platform": PLATFORM_MACOS, "minimum": MINIMUM, "sdk": SDK}:
        reject("deployment", f"Wrong deployment metadata: {build}")
    check_dependencies(dependencies)
    return {"architecture": "arm64", "minimum": version_text(MINIMUM),
            "sdk": version_text(SDK), "loader": loader,
            "dependencies": dependencies, "commands": commands}


def tool_output(argv, base):
    try:
        result = CAPTURE.run(argv, timeout=TOOL_TIMEOUT,
                             stdout_limit=MAX_TOOL_OUTPUT, stderr_limit=MAX_TOOL_OUTPUT,
                             env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
    except subprocess.TimeoutExpired as error:
        reject("tool", f"Inspection timed out: {argv[0]}", cleanup_notes=CAPTURE.cleanup_notes(error))
    except CAPTURE.OutputLimit as error:
        reject("tool", f"Inspection output exceeds the bound: {argv[0]}", cleanup_notes=CAPTURE.cleanup_notes(error))
    if result.returncode or result.stderr:
        reject("tool", f"Inspection failed or warned: {argv[0]} (exit {result.returncode})")
    try:
        text = result.stdout.decode("utf-8")
    except UnicodeDecodeError:
        reject("tool", f"Inspection output is not UTF-8: {argv[0]}")
    return text, {"argv": [str(item).replace(str(base), "<snapshot>") for item in argv],
                  "stdout_sha256": digest(result.stdout)}


def inspect_tools(path, parsed):
    observations = []
    for argv, expected in ((["/usr/bin/file", "-b", str(path)], "Mach-O 64-bit executable arm64"),
                           (["/usr/bin/lipo", "-archs", str(path)], "arm64")):
        text, evidence = tool_output(argv, path.parent)
        if text.strip() != expected:
            reject("tool", f"Architecture inspection disagrees: {argv[0]}")
        observations.append(evidence)
    text, evidence = tool_output(["/usr/bin/otool", "-l", str(path)], path.parent)
    pattern = r"Load command (\d+)\n\s+cmd (LC_[A-Z0-9_]+)\n\s+cmdsize (\d+)\n"
    observed = re.findall(pattern, text)
    expected = [(str(index), item["name"], str(item["size"]))
                for index, item in enumerate(parsed["commands"])]
    if observed != expected or text.count("Load command ") != len(expected):
        reject("tool", "otool load-command framing disagrees with the inspected bytes.")
    for field, value in (("minos", parsed["minimum"]), ("sdk", parsed["sdk"])):
        if re.findall(rf"^\s+{field} (\S+)\s*$", text, re.MULTILINE) != [value]:
            reject("tool", f"otool deployment metadata disagrees: {field}")
    observations.append(evidence)
    text, evidence = tool_output(["/usr/bin/otool", "-L", str(path)], path.parent)
    lines = text.splitlines()
    if not lines or lines[0] != f"{path}:":
        reject("tool", "otool dependency output has an invalid header.")
    dependencies = []
    for line in lines[1:]:
        match = re.fullmatch(r"\s+(.+) \(compatibility version \d+\.\d+\.\d+, current version \d+\.\d+\.\d+\)", line)
        if match is None:
            reject("tool", "otool dependency output has an unknown shape.")
        dependencies.append(match.group(1))
    if dependencies != parsed["dependencies"]:
        reject("tool", "otool dependencies disagree with the inspected bytes.")
    observations.append(evidence)
    return observations


def file_identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def snapshot(source, target):
    # Every inspector reads the same private copy; its hash identifies the evidence.
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as input_file, target.open("xb") as output:
        before = os.fstat(input_file.fileno())
        if not stat.S_ISREG(before.st_mode) or not before.st_mode & 0o111:
            reject("artifact", "The artifact must be a regular executable file, not a symlink.")
        if not 0 < before.st_size <= MAX_ARTIFACT:
            reject("artifact", "The artifact is empty or exceeds the profile size bound.")
        remaining = before.st_size
        while remaining:
            block = input_file.read(min(remaining, COPY_CHUNK))
            if not block:
                reject("artifact", "The artifact changed while its snapshot was copied.")
            output.write(block)
            remaining -= len(block)
        if input_file.read(1) or file_identity(before) != file_identity(os.fstat(input_file.fileno())):
            reject("artifact", "The artifact changed while its snapshot was copied.")
    return before.st_size


def verify(artifact):
    receipt = {"schema": 1, "profile": PROFILE, "gate": "physical-binary-closure",
               "artifact": {"path": str(artifact.absolute())}, "status": "rejected"}
    try:
        if sys.platform != "darwin":
            reject("platform", "This gate runs on macOS and accepts only the declared macOS profile.")
        with tempfile.TemporaryDirectory(prefix="symphony-release-") as temporary:
            path = Path(temporary) / "artifact"
            size = snapshot(artifact, path)
            data = path.read_bytes()
            receipt["artifact"].update({"sha256": digest(data), "size": size})
            parsed = parse_macho(data)
            observations = inspect_tools(path, parsed)
            if digest(path.read_bytes()) != receipt["artifact"]["sha256"]:
                reject("artifact", "The inspected snapshot changed.")
            receipt.update({"status": "accepted", "binary": parsed, "observations": observations})
    except Rejected as error:
        receipt["diagnostic"] = error.diagnostic
    except OSError as error:
        receipt["diagnostic"] = {"code": "io", "detail": f"Artifact/inspection I/O failed: {error}",
                                 "remedy": "Provide a readable physical executable and the selected Apple inspection tools."}
        notes = CAPTURE.cleanup_notes(error)
        if notes:
            receipt["diagnostic"]["cleanup_notes"] = list(notes)
    return receipt


def publish_receipt(path, rendered):
    # A same-parent hard link publishes complete bytes atomically without replacement.
    temporary = tempfile.TemporaryDirectory(prefix=".symphony-receipt-", dir=path.parent)
    stream = None
    try:
        staged = Path(temporary.name) / "receipt.json"
        stream = staged.open("x", encoding="utf-8")
        stream.write(rendered)
        stream.close()
        stream = None
        os.link(staged, path, follow_symlinks=False)
    except BaseException as error:
        operations = [(temporary.cleanup, RECEIPT_CLEANUP_NOTE)]
        if stream is not None:
            operations.insert(0, (stream.close, RECEIPT_CLOSE_NOTE))
        for release, note in operations:
            try:
                release()
            except BaseException:
                try:
                    error.add_note(note)
                except BaseException:
                    pass
        raise
    try:
        temporary.cleanup()
    except BaseException as error:
        try:
            error.add_note(RECEIPT_PUBLISHED_NOTE)
        except BaseException:
            pass
        raise


def main():
    parser = Arguments(description=__doc__)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--profile", choices=[PROFILE], default=PROFILE)
    parser.add_argument("--receipt", type=Path, help="exclusively create a new structured JSON receipt")
    try:
        arguments = parser.parse_args()
    except Rejected as error:
        print(json.dumps({"schema": 1, "profile": PROFILE, "gate": "physical-binary-closure",
                          "status": "rejected", "diagnostic": error.diagnostic}, sort_keys=True))
        return 2
    receipt = verify(arguments.artifact)
    rendered = json.dumps(receipt, indent=2, sort_keys=True) + "\n"
    if arguments.receipt is not None:
        try:
            publish_receipt(arguments.receipt, rendered)
        except OSError as error:
            receipt["status"] = "rejected"
            receipt["diagnostic"] = {"code": "receipt", "detail": f"Cannot finalize receipt {arguments.receipt}: {error}",
                                     "remedy": "Check parent permissions and free space. Use a new name if the receipt already exists."}
            notes = [note for note in getattr(error, "__notes__", ())
                     if type(note) is str and note in {RECEIPT_CLOSE_NOTE, RECEIPT_CLEANUP_NOTE, RECEIPT_PUBLISHED_NOTE}]
            if notes:
                receipt["diagnostic"]["cleanup_notes"] = notes
            if RECEIPT_PUBLISHED_NOTE in notes:
                receipt["receipt_publication"] = {"status": "published", "path": str(arguments.receipt)}
            rendered = json.dumps(receipt, indent=2, sort_keys=True) + "\n"
    print(rendered, end="")
    return 0 if receipt["status"] == "accepted" else 1


if __name__ == "__main__":
    raise SystemExit(main())
