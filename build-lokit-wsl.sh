#!/usr/bin/env bash
#
# LibreOffice core -> Android arm64 (LOKit) yerel derleme — WSL2 / Ubuntu
#
# Colab'da öğrendiğimiz tüm düzeltmeler + Play için zorunlu 16 KB sayfa hizalaması.
# i5-13420H (12 iş parçacığı) üzerinde tahmini süre: 1,5-2,5 saat.
#
# Kullanım (WSL içinde):
#   bash build-lokit-wsl.sh            # baştan derle
#   bash build-lokit-wsl.sh --relink   # sadece yeniden linkle (hızlı)
#
set -euo pipefail

LO_BRANCH="libreoffice-24-8"
NDK_VER="r26d"
WORK="$HOME/lo-build"
NDK="$WORK/android-ndk"
SDK="$WORK/android-sdk"
SRC="$WORK/libreoffice"
OUT="$WORK/out"
JOBS="$(nproc)"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"

# Play Store şartı: 64-bit cihazlarda 16 KB bellek sayfası desteği (1 Kasım 2025'ten beri)
ALIGN_FLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"

say() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

# WSL, Windows'un PATH'ini miras alır. İçinde Git Bash'in mingw64 klasörü varsa
# LibreOffice configure "WSL'den Windows'a çapraz derleme" moduna geçip
# strawberry-perl-portable istiyor (configure.ac:323). Windows yollarını at:
# hem bu tuzağı kapatır hem de her komutta .exe aranmasını önleyip derlemeyi hızlandırır.
PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vi 'mingw' | grep -v '^/mnt/' | paste -sd: -)"
export PATH
unset WSL_DISTRO_NAME WSL_INTEROP WSLENV 2>/dev/null || true

# --- 1. Bağımlılıklar --------------------------------------------------------
# Ubuntu'nun otomatik güncelleme servisi (unattended-upgrades) açılışta dpkg
# kilidini tutuyor; beklemezsek apt hata verip derleme daha başlamadan düşüyor.
wait_apt() {
  local i=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do
    [ $i -eq 0 ] && echo "  apt kilidi meşgul, bekleniyor…"
    i=$((i+1))
    [ $i -gt 60 ] && { echo "  5 dakika geçti, yine de deneniyor"; break; }
    sleep 5
  done
}

setup_deps() {
  say "Bağımlılıklar kuruluyor (sudo parolası isteyebilir)"
  wait_apt
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    git build-essential autoconf automake libtool pkg-config \
    bison flex zip unzip ccache gperf nasm ant openjdk-17-jdk-headless \
    xsltproc libxslt1-dev libxml2-dev libxml2-utils python3-dev \
    libfontconfig1-dev libfreetype6-dev libcairo2-dev \
    libcurl4-openssl-dev libnss3-dev zlib1g-dev curl psmisc > /dev/null

  # LibreOffice GCC 12+ istiyor (Ubuntu 22.04'te varsayılan 11)
  if ! gcc --version | grep -qE "gcc.* 1[2-9]\."; then
    wait_apt
    sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test > /dev/null 2>&1 || true
    wait_apt
    sudo apt-get update -qq
    wait_apt
    sudo apt-get install -y -qq gcc-12 g++-12 > /dev/null
    sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 100 \
         --slave /usr/bin/g++ g++ /usr/bin/g++-12
  fi
  gcc --version | head -1

  ccache -M 25G
}

# --- 2. NDK + SDK ------------------------------------------------------------
setup_ndk() {
  mkdir -p "$WORK"
  if [ ! -d "$NDK" ]; then
    say "Android NDK $NDK_VER indiriliyor"
    curl -sLo /tmp/ndk.zip \
      "https://dl.google.com/android/repository/android-ndk-${NDK_VER}-linux.zip"
    unzip -q /tmp/ndk.zip -d "$WORK"
    mv "$WORK/android-ndk-${NDK_VER}" "$NDK"
    rm /tmp/ndk.zip
  fi
  if [ ! -d "$SDK" ]; then
    say "Android SDK komut satırı araçları indiriliyor"
    mkdir -p "$SDK/cmdline-tools"
    curl -sLo /tmp/tools.zip \
      "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
    unzip -q /tmp/tools.zip -d "$SDK/cmdline-tools"
    mv "$SDK/cmdline-tools/cmdline-tools" "$SDK/cmdline-tools/latest"
    rm /tmp/tools.zip
    # sdkmanager JAVA_HOME olmadan sessizce ölüyor; çıktıyı da yutmayalım.
    export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
    export PATH="$JAVA_HOME/bin:$PATH"
    yes | "$SDK/cmdline-tools/latest/bin/sdkmanager" --licenses 2>&1 | tail -1
    "$SDK/cmdline-tools/latest/bin/sdkmanager" \
      "platforms;android-34" "build-tools;34.0.0" 2>&1 | tail -1
    [ -d "$SDK/platforms/android-34" ] || { echo "HATA: SDK platformu kurulamadı"; exit 1; }
  fi
}

# --- 3. Kaynak ---------------------------------------------------------------
setup_source() {
  if [ ! -d "$SRC" ]; then
    say "LibreOffice $LO_BRANCH klonlanıyor (~1,5 GB)"
    git clone --depth 1 --branch "$LO_BRANCH" \
      https://git.libreoffice.org/core "$SRC"
  fi
}

# --- 4. Yapılandırma ---------------------------------------------------------
configure() {
  say "Yapılandırılıyor (16 KB hizalama etkin)"
  cd "$SRC"

  # NOT: --with-extra-cflags LO 24.8'de yok (configure 'unrecognized option' verip düşüyor).
  # Android hedefi zaten PIC üretiyor, gerek de yok.
  # DİKKAT: --with-distro İLK satırda olmalı, sonra gelen --host onu ezer.
  # Ters sırada distro dosyası 32-bit ARM dayatıyor.
  cat > autogen.input <<EOF
--with-distro=LibreOfficeAndroid
--build=x86_64-unknown-linux-gnu
--host=aarch64-linux-android
--with-android-ndk=$NDK
--with-android-sdk=$SDK
--enable-release-build
--with-android-api-level=24
--disable-debug
--disable-dbgutil
--disable-nss
--without-help
--without-myspell-dicts
--with-galleries=no
--with-theme=colibre
--enable-mergelibs
--enable-ccache
EOF

  # Not: LDFLAGS burada yalnızca ara adımlar için ayarlanıyor. Asıl Android
  # bağlama komutu bunu OKUMUYOR — 16 KB bayrağı patch_nss() içinde doğrudan
  # Makefile.shared'a yazılıyor.
  export LDFLAGS="${ALIGN_FLAGS}"
  ./autogen.sh

  say "Hedef mimari doğrulaması"
  grep -m1 -A1 'checking host system type' config.log
}

# --- 5. Makefile yamaları ----------------------------------------------------
patch_nss() {
  say "Android bağlama adımı yamalanıyor (NSS + 16 KB hizalama)"
  cd "$SRC"

  # İki değişiklik de aynı dosyada:
  #
  # 1) NSPR, NDK 26 ile derlenmiyor (stat64 uyumsuzluğu) -> --disable-nss ile
  #    kapattık. Ancak Android paketleme NSS'i koşulsuz bekliyor; NSSLIBS boşalt.
  #
  # 2) 16 KB hizalama bayrağı DOĞRUDAN bağlama komutuna girmek zorunda.
  #    Ortam LDFLAGS'i buraya ULAŞMIYOR: aşağıdaki kural kendi $(CXX) satırını
  #    kuruyor ve LDFLAGS'e hiç bakmıyor. Bayrağı yalnızca dışarıdan verirsek
  #    derleme sorunsuz biter ama .so 4 KB hizalı çıkar ve Play reddeder.
  python3 - "$ALIGN_FLAGS" <<'PY'
import re, os, sys
align = sys.argv[1]
p = "android/Bootstrap/Makefile.shared"
s = open(p).read()
if not os.path.exists(p + ".orig"):
    open(p + ".orig", "w").write(s)

s = re.sub(r'NSSLIBS\s*[:+]?=(?:[^\n\\]*\\\n)*[^\n]*', 'NSSLIBS =', s, count=1)
print("  Makefile.shared: NSSLIBS bosaltildi")

old = "$(CXX) -Wl,--build-id=sha1"
if align in s:
    print("  Makefile.shared: hizalama bayragi zaten ekli")
elif old in s:
    s = s.replace(old, "$(CXX) " + align + " -Wl,--build-id=sha1", 1)
    print("  Makefile.shared: 16 KB hizalama bayragi baglama komutuna eklendi")
else:
    sys.exit("  HATA: baglama satiri bulunamadi, Makefile.shared degismis olabilir")

open(p, "w").write(s)
PY

  # Bağlayıcı bayraklarını üreten script'ten de NSS'i çıkar
  python3 - <<'PY'
import re, os
p = "bin/lo-all-static-libs"
s = open(p).read()
if not os.path.exists(p + ".orig"):
    open(p + ".orig", "w").write(s)
for lib in ['freebl3','nspr4','nss3','nssckbi','nssdbm3','nssutil3',
            'plc4','plds4','smime3','softokn3','sqlite3','ssl3']:
    s = re.sub(r'-l' + lib + r'\b', '', s)
s = re.sub(r'-L\S*nss\S*', '', s)
open(p, "w").write(s)
print("  lo-all-static-libs: NSS bayraklari kaldirildi")
PY

}

# Bağlayıcının aradığı boş arşiv.
# DİKKAT: bunu derlemeden önce bir kez oluşturmak YETMİYOR. xmlsec tarball'ı
# derleme sırasında açılınca .libs klasörü sıfırlanıyor ve arşiv siliniyor;
# derleme saatlerce sürüp en son bağlama adımında "No rule to make target"
# ile düşüyor. Bu yüzden bağlamadan hemen önce tekrar oluşturuyoruz.
make_nss_stub() {
  local A="$SRC/workdir/UnpackedTarball/xmlsec/src/nss/.libs"
  mkdir -p "$A"
  "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar" rcs "$A/libxmlsec1-nss.a"
}

# --- 6. Derleme --------------------------------------------------------------
build() {
  say "Derleniyor ($JOBS iş parçacığı) — LO 24.8'de hedef adı 'build'"
  cd "$SRC"
  set -o pipefail
  make_nss_stub

  # xmlsec derleme ortasında açılırsa yer tutucu silinir; o durumda arşivi
  # yeniden yaratıp bir kez daha deniyoruz. İkinci geçiş yalnızca bağlama
  # yaptığı için dakikalar sürer, baştan derleme değildir.
  if ! make -j"$JOBS" build 2>&1 | tee "$WORK/build.log" | tail -40; then
    if grep -q "libxmlsec1-nss.a" "$WORK/build.log"; then
      say "xmlsec yer tutucusu silinmiş — yeniden oluşturulup bağlama tekrarlanıyor"
      make_nss_stub
      make -j"$JOBS" build 2>&1 | tee -a "$WORK/build.log" | tail -20
    else
      return 1
    fi
  fi
}

# --- 7. Çıktı toplama + hizalama doğrulama -----------------------------------
collect() {
  say "Çıktılar toplanıyor"
  local JNI="$OUT/jniLibs/arm64-v8a"
  local ASSETS="$OUT/assets"
  rm -rf "$OUT"; mkdir -p "$JNI" "$ASSETS/share" "$ASSETS/program"

  cp "$SRC/android/obj/local/arm64-v8a/liblo-native-code.so" "$JNI/"
  cp "$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" \
     "$JNI/" 2>/dev/null || true
  "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" "$JNI"/*.so

  cp -r "$SRC/instdir/share/." "$ASSETS/share/"
  cp "$SRC/instdir/program/"*.rdb "$ASSETS/program/" 2>/dev/null || true
  cp -r "$SRC/instdir/program/services" "$ASSETS/program/" 2>/dev/null || true
  cp -r "$SRC/instdir/program/resource" "$ASSETS/program/" 2>/dev/null || true
  cp "$SRC/instdir/program/"*rc "$ASSETS/program/" 2>/dev/null || true

  say "16 KB hizalama doğrulaması (0x4000 olmalı)"
  local READELF="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
  local ok=1
  for f in "$JNI"/*.so; do
    a=$("$READELF" -l "$f" | grep -m1 " LOAD " | awk '{print $NF}')
    if [ "$a" = "0x4000" ]; then
      printf "  \033[32m✓\033[0m %-28s %s\n" "$(basename "$f")" "$a"
    else
      printf "  \033[31m✗\033[0m %-28s %s  (Play REDDEDER)\n" "$(basename "$f")" "$a"
      ok=0
    fi
  done

  echo
  du -sh "$JNI" "$ASSETS"
  echo
  if [ "$ok" = "1" ]; then
    say "TAMAM — çıktılar: $OUT"
    echo "  Windows'a kopyalamak icin:"
    echo "    cp -r $OUT/jniLibs/arm64-v8a/*.so /mnt/c/dev/lo-android-engine/engine/src/main/jniLibs/arm64-v8a/"
    echo "    cp -r $OUT/assets/* /mnt/c/dev/lo-android-engine/engine/src/main/assets/"
  else
    say "UYARI: hizalama tutmadi — patch_nss() Makefile.shared'a bayragi yazamamis olabilir"
  fi
}

# --- Akış --------------------------------------------------------------------
if [ "${1:-}" = "--relink" ]; then
  say "Yalnızca yeniden linkleme"
  cd "$SRC"
  patch_nss          # idempotent; hizalama bayrağının yerinde olduğunu garanti eder
  rm -f android/obj/local/arm64-v8a/liblo-native-code.so
  build
  collect
else
  setup_deps
  setup_ndk
  setup_source
  configure
  patch_nss
  build
  collect
fi
