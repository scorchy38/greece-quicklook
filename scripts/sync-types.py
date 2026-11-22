#!/usr/bin/env python3
"""Writes the file types Greece handles into its Info.plists.

Each module lists its types in its own files, so modules never edit the same list:
  Types/preview/<module>.txt       content types the Quick Look extension previews (one per line, # comments)
  Types/thumbnails/<module>.txt    content types the thumbnail extension draws
  Types/declarations/<module>.plist  an array of UTImportedTypeDeclarations for formats macOS doesn't know

Run after changing any of them:  scripts/sync-types.py        (or --check to verify without writing)
"""
import glob, json, os, plistlib, sys

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

def read_lists(names):
    seen, result = set(), []
    for name in names:
        path = os.path.join(repo, "Types", "preview", name + ".txt")
        for line in open(path):
            line = line.split("#", 1)[0].strip()
            if line and line not in seen:
                seen.add(line)
                result.append(line)
    return result

# One preview extension per family (Types/families.json): the code family's Info.plist is the
# template; the others are generated next to it under GreeceQuickLook/Families/<Target>/.
families = json.load(open(os.path.join(repo, "Types", "families.json")))["families"]
lists = sorted(os.path.splitext(f)[0] for f in os.listdir(os.path.join(repo, "Types", "preview")) if f.endswith(".txt"))
assigned = [name for family in families for name in family["lists"]]
unassigned = sorted(set(lists) - set(assigned))
if unassigned:
    sys.exit("Types/preview lists without a family in Types/families.json: " + ", ".join(unassigned))
if len(assigned) != len(set(assigned)):
    sys.exit("A type list is assigned to two families in Types/families.json")
claimed = {}
for family in families:
    for type_id in read_lists(family["lists"]):
        if type_id in claimed:
            sys.exit(f"{type_id} is claimed by both {claimed[type_id]} and {family['id']}")
        claimed[type_id] = family["id"]

template_path = "GreeceQuickLook/Info.plist"
for family in families:
    types = read_lists(family["lists"])
    if family["target"] == "GreeceQuickLook":
        update(template_path, attributes, types)
        update(template_path, ["CFBundleDisplayName"], family["name"])
        continue
    plist_path = f"GreeceQuickLook/Families/{family['target']}/Info.plist"
    data = plistlib.load(open(os.path.join(repo, template_path), "rb"))
    data["CFBundleDisplayName"] = family["name"]
    data["NSExtension"]["NSExtensionAttributes"]["QLSupportedContentTypes"] = types
    full = os.path.join(repo, plist_path)
    current = plistlib.load(open(full, "rb")) if os.path.exists(full) else None
    if current != data:
        stale.append(plist_path)
        if not check:
            os.makedirs(os.path.dirname(full), exist_ok=True)
            plistlib.dump(data, open(full, "wb"), sort_keys=False)

update("GreeceThumbnails/Info.plist", attributes, read_list("thumbnails"))
update("Greece/App/Info.plist", ["UTImportedTypeDeclarations"], read_declarations())

if check and stale:
    sys.exit("Out of date (run scripts/sync-types.py): " + ", ".join(stale))
print("Up to date." if not stale else "Updated " + ", ".join(stale))
