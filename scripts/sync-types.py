#!/usr/bin/env python3
"""Writes the file types Greece handles into its Info.plists, and keeps their localizations in step.

Each module lists its types in its own files, so modules never edit the same list:
  Types/preview/<module>.txt       content types the Quick Look extension previews (one per line, # comments)
  Types/thumbnails/<module>.txt    content types the thumbnail extension draws
  Types/declarations/<module>.plist  an array of UTImportedTypeDeclarations for formats macOS doesn't know

Localization (the String Catalogs hold the translations; this script keeps their keys in step):
  - Every extension's Info.plist declares Greece's languages (CFBundleLocalizations) and allows mixed
    localizations, so GreeceKit.framework inside it speaks the user's language.
  - Each extension's display name ("Code & Text", "Greece Thumbnails") is translated in its own
    InfoPlist.xcstrings: GreeceQuickLook/Families/<Target>/InfoPlist.xcstrings, GreeceThumbnails/InfoPlist.xcstrings.
  - Finder's Kind for each declared type (UTTypeDescription) is translated in Greece/App/InfoPlist.xcstrings,
    keyed by the English description, which is how Launch Services looks it up.
  New keys are added in English only (the tests then ask for translations); keys nothing uses any more
  are removed; a changed English name marks its translations for review. Translations are never touched.

Run after changing any of them:  scripts/sync-types.py        (or --check to verify without writing)
"""
import glob, json, os, plistlib, re, sys

repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
check = "--check" in sys.argv

# Greece's languages: English plus the 16 the app and its previews are translated into
# (GreeceKitTests/LocalizationTests.swift lists the same).
LANGUAGES = ["en", "de", "fr", "es", "it", "pt-BR", "nl", "sv", "pl", "tr", "el", "ru", "uk", "ja", "ko", "zh-Hans", "zh-Hant"]

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

def localized(data):
    """An extension's Info.plist with Greece's languages declared, top-level keys in order."""
    data = dict(data)
    data["CFBundleLocalizations"] = LANGUAGES
    data["CFBundleAllowMixedLocalizations"] = True
    return {key: data[key] for key in sorted(data)}

def write_plist(plist_path, data):
    full = os.path.join(repo, plist_path)
    current = plistlib.load(open(full, "rb")) if os.path.exists(full) else None
    # Same keys in the same order: plistlib compares dicts regardless of order, the file doesn't.
    if current == data and list(current) == list(data):
        return
    stale.append(plist_path)
    if not check:
        os.makedirs(os.path.dirname(full), exist_ok=True)
        plistlib.dump(data, open(full, "wb"), sort_keys=False)

def update(plist_path, keypath, value, transform=None):
    data = plistlib.load(open(os.path.join(repo, plist_path), "rb"))
    node = data
    for key in keypath[:-1]:
        node = node[key]
    node[keypath[-1]] = value
    write_plist(plist_path, transform(data) if transform else data)

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

# MARK: - String Catalogs

def catalog_text(catalog):
    # Xcode's own formatting, so editing a catalog in Xcode and running this script agree byte for byte.
    return json.dumps(catalog, indent=2, separators=(",", " : "), ensure_ascii=False, sort_keys=True) + "\n"

# Info.plist keys (CFBundleName, NSHumanReadableCopyright…) that Xcode may add to an InfoPlist catalog
# on its own; this script leaves them alone.
plist_key = re.compile(r"^(CF|NS|LS|UI|UT|QL)[A-Za-z]+$")

def sync_catalog(path, managed, comments, keep_unmanaged_plist_keys=True):
    """Keeps an InfoPlist.xcstrings in step: `managed` maps each key to its English value.

    A key that is itself the English text (a type description) gets no "en" localization; a plist key
    (CFBundleDisplayName) carries its English value, and translations of a changed value go to review.
    """
    full = os.path.join(repo, path)
    catalog = json.load(open(full)) if os.path.exists(full) else {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
    strings = catalog.setdefault("strings", {})
    for key in list(strings):
        if key not in managed and not (keep_unmanaged_plist_keys and plist_key.match(key)):
            del strings[key]
    for key, english in managed.items():
        entry = strings.setdefault(key, {})
        entry["comment"] = comments[key]
        entry["extractionState"] = "manual"
        localizations = entry.setdefault("localizations", {})
        if key != english:
            unit = localizations.setdefault("en", {}).setdefault("stringUnit", {"state": "translated", "value": english})
            if unit.get("value") != english:
                unit["value"] = english
                unit["state"] = "translated"
                for language, localization in localizations.items():
                    if language != "en" and "stringUnit" in localization:
                        localization["stringUnit"]["state"] = "needs_review"
        if not localizations:
            del entry["localizations"]
    text = catalog_text(catalog)
    if os.path.exists(full) and open(full).read() == text:
        return
    stale.append(path)
    if not check:
        os.makedirs(os.path.dirname(full), exist_ok=True)
        open(full, "w").write(text)

def display_name_catalog(path, name, what):
    sync_catalog(path, {"CFBundleDisplayName": name},
                 {"CFBundleDisplayName": f"The name of Greece’s {what} extension, shown in System Settings › Extensions › Quick Look and in Greece’s Preview Kinds"})

# MARK: - Preview families

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
template = localized(plistlib.load(open(os.path.join(repo, template_path), "rb")))
for family in families:
    types = read_lists(family["lists"])
    data = plistlib.loads(plistlib.dumps(template, sort_keys=False))  # a deep copy of the template
    data["CFBundleDisplayName"] = family["name"]
    data["NSExtension"]["NSExtensionAttributes"]["QLSupportedContentTypes"] = types
    if family["target"] == "GreeceQuickLook":
        write_plist(template_path, data)
    else:
        write_plist(f"GreeceQuickLook/Families/{family['target']}/Info.plist", data)
    # Every family's display name is translated in its own catalog, next to its plist.
    display_name_catalog(f"GreeceQuickLook/Families/{family['target']}/InfoPlist.xcstrings", family["name"], f"“{family['name']}” preview")

# MARK: - Thumbnails

update("GreeceThumbnails/Info.plist", attributes, read_list("thumbnails"), transform=localized)
thumbnails_name = plistlib.load(open(os.path.join(repo, "GreeceThumbnails/Info.plist"), "rb"))["CFBundleDisplayName"]
display_name_catalog("GreeceThumbnails/InfoPlist.xcstrings", thumbnails_name, "Finder thumbnail")

# MARK: - Type declarations

declarations = read_declarations()
update("Greece/App/Info.plist", ["UTImportedTypeDeclarations"], declarations)
examples = {}
for decl in declarations:
    extensions = decl.get("UTTypeTagSpecification", {}).get("public.filename-extension", [])
    shown = ["." + e for e in ([extensions] if isinstance(extensions, str) else extensions)] or [decl["UTTypeIdentifier"]]
    examples.setdefault(decl["UTTypeDescription"], []).extend(shown)
sync_catalog("Greece/App/InfoPlist.xcstrings", {description: description for description in examples},
             {description: "Finder’s Kind for " + ", ".join(shown[:6]) for description, shown in examples.items()})

if check and stale:
    sys.exit("Out of date (run scripts/sync-types.py): " + ", ".join(stale))
print("Up to date." if not stale else "Updated " + ", ".join(stale))
