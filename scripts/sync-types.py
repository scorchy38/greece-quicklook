#!/usr/bin/env python3
"""Writes the file types Greece handles into its Info.plists.

Each module lists its types in its own files, so modules never edit the same list:
  Types/preview/<module>.txt       content types the Quick Look extension previews (one per line, # comments)
  Types/thumbnails/<module>.txt    content types the thumbnail extension draws
  Types/declarations/<module>.plist  an array of UTImportedTypeDeclarations for formats macOS doesn't know

Run after changing any of them:  scripts/sync-types.py        (or --check to verify without writing)
"""
import glob, os, plistlib, sys

repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
check = "--check" in sys.argv

def read_list(kind):
    seen, result = set(), []
    for path in sorted(glob.glob(os.path.join(repo, "Types", kind, "*.txt"))):
        for line in open(path):
            line = line.split("#", 1)[0].strip()
            if line and line not in seen:
                seen.add(line)
                result.append(line)
    return result

def read_declarations():
    seen, result = {}, []
    for path in sorted(glob.glob(os.path.join(repo, "Types", "declarations", "*.plist"))):
        for decl in plistlib.load(open(path, "rb")):
            identifier = decl["UTTypeIdentifier"]
            if identifier in seen:
                sys.exit(f"{identifier} is declared in both {seen[identifier]} and {os.path.basename(path)}")
            seen[identifier] = os.path.basename(path)
            result.append(decl)
    return result

stale = []

def update(plist_path, keypath, value):
    path = os.path.join(repo, plist_path)
    data = plistlib.load(open(path, "rb"))
    node = data
    for key in keypath[:-1]:
        node = node[key]
    if node.get(keypath[-1]) == value:
        return
    stale.append(plist_path)
    if not check:
        node[keypath[-1]] = value
        plistlib.dump(data, open(path, "wb"), sort_keys=False)

attributes = ["NSExtension", "NSExtensionAttributes", "QLSupportedContentTypes"]
update("GreeceQuickLook/Info.plist", attributes, read_list("preview"))
update("GreeceThumbnails/Info.plist", attributes, read_list("thumbnails"))
update("Greece/App/Info.plist", ["UTImportedTypeDeclarations"], read_declarations())

if check and stale:
    sys.exit("Out of date (run scripts/sync-types.py): " + ", ".join(stale))
print("Up to date." if not stale else "Updated " + ", ".join(stale))
