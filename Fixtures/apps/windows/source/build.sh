#!/bin/zsh
# Rebuilds the Windows fixtures with Homebrew LLVM (clang, lld-link, llvm-rc, llvm-dlltool) and OpenSSL.
#   Fixtures/apps/windows/source/build.sh <work-dir>
set -e
SRC=${0:A:h}
OUT=${SRC:h}
WORK=${1:?work directory}
LLVM=/opt/homebrew/opt/llvm/bin
mkdir -p $WORK

# hello.exe: x64 GUI program, kernel32 import, delay-loaded user32, icon, manifest, version info, PDB record.
python3 -I $SRC/fixtures.py icon $WORK/hello.ico
cp $SRC/hello.rc $SRC/hello.manifest $WORK/
$LLVM/llvm-rc -no-preprocess -I $WORK /FO $WORK/hello.res $WORK/hello.rc
printf 'LIBRARY kernel32.dll\nEXPORTS\n  ExitProcess\n  GetTickCount\n' > $WORK/kernel32.def
printf 'LIBRARY user32.dll\nEXPORTS\n  MessageBoxW\n' > $WORK/user32.def
$LLVM/llvm-dlltool -m i386:x86-64 -d $WORK/kernel32.def -l $WORK/kernel32.lib
$LLVM/llvm-dlltool -m i386:x86-64 -d $WORK/user32.def -l $WORK/user32.lib
$LLVM/clang --target=x86_64-pc-windows-msvc -O2 -ffreestanding -fno-stack-protector -c $SRC/hello.c -o $WORK/hello.obj
/opt/homebrew/bin/lld-link /nologo /entry:entry /subsystem:windows,6.1 /nodefaultlib /dynamicbase /nxcompat /highentropyva \
  /Brepro /debug /pdb:$WORK/hello.pdb /pdbaltpath:hello.pdb /delayload:user32.dll \
  /out:$WORK/hello.exe $WORK/hello.obj $WORK/hello.res $WORK/kernel32.lib $WORK/user32.lib

# greece.dll: ARM64 library with two named exports and one by ordinal only.
$LLVM/clang --target=aarch64-pc-windows-msvc -O2 -ffreestanding -fno-stack-protector -c $SRC/greece.c -o $WORK/greece.obj
/opt/homebrew/bin/lld-link /nologo /dll /machine:arm64 /entry:DllMain /nodefaultlib /def:$SRC/greece.def \
  /out:$WORK/greece.dll $WORK/greece.obj

# hello-signed.exe: hello.exe with a self-signed test signature in Authenticode's layout.
# (OpenSSL signs the SpcIndirectDataContent; the fixture tests parsing and the file digest, not Windows trust.)
python3 -I $SRC/fixtures.py digest $WORK/hello.exe $WORK/padded.exe $WORK/spc.der
openssl req -x509 -newkey rsa:2048 -nodes -keyout $WORK/key.pem -out $WORK/cert.pem -days 3650 \
  -subj "/CN=Greece Test Signer/O=Greece Fixtures" 2>/dev/null
openssl cms -sign -binary -nodetach -nosmimecap -md sha256 -econtent_type 1.3.6.1.4.1.311.2.1.4 \
  -in $WORK/spc.der -signer $WORK/cert.pem -inkey $WORK/key.pem -outform DER -out $WORK/cms.der
python3 -I $SRC/fixtures.py attach $WORK/padded.exe $WORK/cms.der $WORK/hello-signed.exe

cp $WORK/hello.exe $WORK/greece.dll $WORK/hello-signed.exe $OUT/
ls -l $OUT/*.exe $OUT/*.dll
