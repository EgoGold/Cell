"""Tiny PE linker shared by Cell's Windows helper programs (no Windows toolchain needed).

Xcode's clang compiles a C file to a COFF object; link() turns that object into a 64-bit Windows
executable that imports only kernel32.dll (other DLLs are reached with LoadLibraryW/GetProcAddress).
build() also embeds the program in CellCore as base64.

Only what these programs need is supported: code, read-only and writable data, zero-filled data,
REL32/ADDR32NB relocations and kernel32 imports. Anything else is reported as an error.
"""
import base64
import hashlib
import os
import struct
import subprocess
import sys
import tempfile

IMAGE_BASE = 0x140000000
SECTION_ALIGN = 0x1000
FILE_ALIGN = 0x200

SCN_CODE, SCN_IDATA, SCN_UDATA = 0x20, 0x40, 0x80
SCN_LNK_INFO, SCN_LNK_REMOVE = 0x200, 0x800
SCN_EXEC, SCN_READ, SCN_WRITE = 0x20000000, 0x40000000, 0x80000000


def align(value, to):
    return (value + to - 1) // to * to


def compile_object(source, path):
    subprocess.run(["clang", "-target", "x86_64-pc-windows-msvc", "-O2", "-c", "-ffreestanding", "-fno-builtin",
                    "-fno-stack-protector", "-mno-stack-arg-probe", "-fno-asynchronous-unwind-tables",
                    "-fno-unwind-tables", "-Wall", "-Werror", source, "-o", path], check=True)
    with open(path, "rb") as handle:
        return handle.read()


def parse(obj):
    machine, count, _, symtab, nsyms, optsize, _ = struct.unpack_from("<HHIIIHH", obj, 0)
    if machine != 0x8664:
        sys.exit("not an x86-64 COFF object")
    strtab = symtab + nsyms * 18

    def long_name(raw):
        if raw.startswith(b"/"):
            offset = int(raw[1:].rstrip(b"\0"))
            end = obj.index(b"\0", strtab + offset)
            return obj[strtab + offset:end].decode()
        return raw.rstrip(b"\0").decode()

    sections = []
    for i in range(count):
        base = 20 + optsize + i * 40
        name, vsize, _, rawsize, rawptr, relptr, _, nrel, _, flags = struct.unpack_from("<8sIIIIIIHHI", obj, base)
        relocs = [struct.unpack_from("<IIH", obj, relptr + r * 10) for r in range(nrel)]
        data = obj[rawptr:rawptr + rawsize] if not flags & SCN_UDATA else b""
        alignment = 1 << (((flags >> 20) & 0xF) - 1) if (flags >> 20) & 0xF else 16
        sections.append({"name": long_name(name), "flags": flags, "data": data,
                         "size": rawsize, "relocs": relocs, "align": alignment})

    symbols = []
    i = 0
    while i < nsyms:
        base = symtab + i * 18
        raw, value, section, _, storage, aux = struct.unpack_from("<8sIhHBB", obj, base)
        if raw[:4] == b"\0\0\0\0":
            offset = struct.unpack_from("<I", raw, 4)[0]
            name = obj[strtab + offset:obj.index(b"\0", strtab + offset)].decode()
        else:
            name = raw.rstrip(b"\0").decode()
        symbols.append({"name": name, "value": value, "section": section, "storage": storage})
        symbols.extend([None] * aux)
        i += 1 + aux
    return sections, symbols


def link(obj, subsystem=2):
    sections, symbols = parse(obj)
    kept = [s for s in sections if s["flags"] & (SCN_CODE | SCN_IDATA | SCN_UDATA)
            and not s["flags"] & (SCN_LNK_INFO | SCN_LNK_REMOVE)]

    def kind(section):
        if section["flags"] & SCN_CODE:
            return ".text"
        if section["flags"] & SCN_UDATA:
            return ".bss"
        return ".data" if section["flags"] & SCN_WRITE else ".rdata"

    imports = sorted({s["name"][len("__imp_"):] for s in symbols
                      if s and s["section"] == 0 and s["name"].startswith("__imp_")})
    undefined = [s["name"] for s in symbols if s and s["section"] == 0 and s["storage"] == 2
                 and not s["name"].startswith("__imp_")]
    if undefined:
        sys.exit(f"undefined symbols: {undefined}")

    # Output sections, in order. Import tables live at the start of .rdata.
    order = [".text", ".rdata", ".data", ".bss"]
    out = {name: {"members": [], "size": 0} for name in order}
    rdata_imports_size = 0
    if imports:
        names = []
        for name in imports:
            entry = struct.pack("<H", 0) + name.encode() + b"\0"
            names.append(entry + (b"\0" if len(entry) % 2 else b""))
        dll = b"kernel32.dll\0"
        thunks = 8 * (len(imports) + 1)
        idt = 20 * 2
        rdata_imports_size = align(idt + 2 * thunks + sum(map(len, names)) + len(dll), 16)
        out[".rdata"]["size"] = rdata_imports_size
    for section in kept:
        target = out[kind(section)]
        target["size"] = align(target["size"], section["align"])
        section["offset"] = target["size"]
        section["out"] = kind(section)
        target["members"].append(section)
        target["size"] += section["size"]

    headers = align(0x40 + 4 + 20 + 240 + 40 * len(order), FILE_ALIGN)
    rva = SECTION_ALIGN
    for name in order:
        out[name]["rva"] = rva
        rva += align(max(out[name]["size"], 1), SECTION_ALIGN)
    image_size = rva

    # Import tables.
    rdata = bytearray(out[".rdata"]["size"])
    iat_rva = iat_size = idt_rva = 0
    slots = {}
    if imports:
        base = out[".rdata"]["rva"]
        idt_rva = base
        ilt_rva = base + 40
        iat_rva = ilt_rva + 8 * (len(imports) + 1)
        iat_size = 8 * (len(imports) + 1)
        cursor = iat_rva + iat_size
        hint_rvas = []
        for name in imports:
            entry = struct.pack("<H", 0) + name.encode() + b"\0"
            entry += b"\0" if len(entry) % 2 else b""
            rdata[cursor - base:cursor - base + len(entry)] = entry
            hint_rvas.append(cursor)
            cursor += len(entry)
        dll_rva = cursor
        rdata[cursor - base:cursor - base + 13] = b"kernel32.dll\0"
        for index, hint in enumerate(hint_rvas):
            struct.pack_into("<Q", rdata, ilt_rva - base + index * 8, hint)
            struct.pack_into("<Q", rdata, iat_rva - base + index * 8, hint)
            slots["__imp_" + imports[index]] = iat_rva + index * 8
        struct.pack_into("<IIIII", rdata, 0, ilt_rva, 0, 0, dll_rva, iat_rva)

    def symbol_rva(index):
        symbol = symbols[index]
        if symbol["section"] > 0:
            section = sections[symbol["section"] - 1]
            if "out" not in section:
                sys.exit(f"symbol {symbol['name']} lives in a discarded section {section['name']}")
            return out[section["out"]]["rva"] + section["offset"] + symbol["value"]
        if symbol["name"] in slots:
            return slots[symbol["name"]]
        sys.exit(f"can't resolve {symbol['name']}")

    images = {".text": bytearray(out[".text"]["size"]), ".rdata": rdata, ".data": bytearray(out[".data"]["size"])}
    for section in kept:
        if section["out"] == ".bss":
            continue
        buffer = images[section["out"]]
        start = section["offset"]
        buffer[start:start + len(section["data"])] = section["data"]
        for address, index, kind_ in section["relocs"]:
            place = start + address
            place_rva = out[section["out"]]["rva"] + place
            target = symbol_rva(index)
            addend = struct.unpack_from("<i", buffer, place)[0]
            if 4 <= kind_ <= 9:            # REL32 .. REL32_5
                value = target + addend - (place_rva + 4 + (kind_ - 4))
                struct.pack_into("<i", buffer, place, value)
            elif kind_ == 3:               # ADDR32NB
                struct.pack_into("<I", buffer, place, target + addend)
            elif kind_ == 1:               # ADDR64: tables of pointers (the image has a fixed base)
                addend64 = struct.unpack_from("<q", buffer, place)[0]
                struct.pack_into("<Q", buffer, place, IMAGE_BASE + target + addend64)
            else:
                sys.exit(f"unsupported relocation type {kind_} in {section['name']}")

    entry = next((s for s in symbols if s and s["name"] == "start" and s["section"] > 0), None)
    if entry is None:
        sys.exit("no entry point `start`")
    entry_rva = symbol_rva(symbols.index(entry))

    # Section table and raw data.
    file_offset = headers
    table = b""
    raw = b""
    characteristics = {".text": SCN_CODE | SCN_EXEC | SCN_READ, ".rdata": SCN_IDATA | SCN_READ,
                       ".data": SCN_IDATA | SCN_READ | SCN_WRITE, ".bss": SCN_UDATA | SCN_READ | SCN_WRITE}
    for name in order:
        size = out[name]["size"]
        data = bytes(images.get(name, b""))
        rawsize = align(len(data), FILE_ALIGN) if data else 0
        table += struct.pack("<8sIIIIIIHHI", name.encode(), max(size, 1), out[name]["rva"], rawsize,
                             file_offset if rawsize else 0, 0, 0, 0, 0, characteristics[name])
        raw += data + b"\0" * (rawsize - len(data))
        file_offset += rawsize

    directories = [(0, 0)] * 16
    directories[1] = (idt_rva, 40) if imports else (0, 0)
    directories[12] = (iat_rva, iat_size)
    optional = struct.pack("<HBBIIIIIQIIHHHHHHIIIIHHQQQQII", 0x20B, 14, 0,
                           align(out[".text"]["size"], FILE_ALIGN),
                           align(out[".rdata"]["size"] + out[".data"]["size"], FILE_ALIGN),
                           align(out[".bss"]["size"], FILE_ALIGN),
                           entry_rva, out[".text"]["rva"], IMAGE_BASE, SECTION_ALIGN, FILE_ALIGN,
                           6, 0, 0, 0, 6, 0, 0, image_size, headers, 0,
                           subsystem,              # 2 = Windows GUI (no console window), 3 = console
                           0x8100,                 # NX compatible, terminal-server aware; fixed base
                           0x100000, 0x1000, 0x100000, 0x1000, 0, 16)
    optional += b"".join(struct.pack("<II", *d) for d in directories)
    coff = struct.pack("<HHIIIHH", 0x8664, len(order), 0, 0, 0, len(optional), 0x0023)
    dos = bytearray(0x40)
    dos[0:2] = b"MZ"
    struct.pack_into("<I", dos, 0x3C, 0x40)
    header = bytes(dos) + b"PE\0\0" + coff + optional + table
    return header + b"\0" * (headers - len(header)) + raw



def build(source, exe, swift, swift_type, generator, subsystem=2):
    with tempfile.TemporaryDirectory() as temp:
        image = link(compile_object(source, os.path.join(temp, "program.obj")), subsystem)
    with open(exe, "wb") as handle:
        handle.write(image)
    digest = hashlib.sha256(image).hexdigest()
    encoded = base64.b64encode(image).decode()
    lines = [encoded[i:i + 100] for i in range(0, len(encoded), 100)]
    text = (f"// Generated by {generator} from {os.path.basename(source)}. Do not edit.\n"
            "import Foundation\n\n"
            f"extension {swift_type} {{\n"
            f"    static let sha256 = \"{digest}\"\n"
            f"    static let size = {len(image)}\n"
            "    static let base64 = \"\"\"\n" + "\n".join(f"        {line}" for line in lines) + "\n        \"\"\"\n}\n")
    with open(swift, "w") as handle:
        handle.write(text)
    print(f"{exe}: {len(image)} bytes, sha256 {digest}")
    return image
