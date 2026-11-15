import re
import sys
import zipfile

jar_path, implementation_path, output_path = sys.argv[1:4]

required = set()
with zipfile.ZipFile(jar_path) as archive:
    for name in archive.namelist():
        if name.startswith("org/lwjgl/sdl/") and name.endswith("$Functions.class"):
            data = archive.read(name)
            for match in re.findall(rb"SDL_[A-Za-z0-9_]+", data):
                required.add(match.decode())

implementation = open(implementation_path).read()
implemented = set(re.findall(r"^[A-Za-z_][A-Za-z0-9_ \*]*?\b(SDL_[A-Za-z0-9_]+)\(", implementation, re.MULTILINE))

missing = sorted(required - implemented)
with open(output_path, "w") as output:
    for name in missing:
        output.write(f"__attribute__((visibility(\"default\"))) void *{name}(void) {{ return 0; }}\n")

print(f"Required {len(required)}, implemented {len(required & implemented)}, stubbed {len(missing)}")
unused = sorted(implemented - required)
if unused:
    print("Implemented but not required: " + ", ".join(unused))
