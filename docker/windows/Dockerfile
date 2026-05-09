# Before building this image, tag a Windows base image that matches the host OS
#   GitHub Actions windows-2025: docker tag mcr.microsoft.com/windows/servercore:ltsc2025 qemubuild-windows
#   Windows Server 2022 / many Win11 hosts: docker tag mcr.microsoft.com/windows/servercore:ltsc2022 qemubuild-windows
#   Older Win10 hosts: docker tag mcr.microsoft.com/windows/servercore:2004 qemubuild-windows
FROM qemubuild-windows

SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

RUN [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; \
  Invoke-WebRequest -UseBasicParsing -uri "https://github.com/msys2/msys2-installer/releases/download/nightly-x86_64/msys2-base-x86_64-latest.sfx.exe" -OutFile msys2.exe; \
  .\msys2.exe -y -oC:\; \
  Remove-Item msys2.exe ; \
  function msys() { C:\msys64\usr\bin\bash.exe @('-lc') + @Args; } \
  msys ' '; \
  msys 'pacman --noconfirm -Syuu'; \
  msys 'pacman --noconfirm -Syuu'; \
  msys 'pacman --noconfirm -Scc'; \
  msys 'pacman --noconfirm -S git python ninja mingw-w64-ucrt-x86_64-toolchain base-devel mingw-w64-ucrt-x86_64-meson mingw-w64-ucrt-x86_64-ca-certificates mingw-w64-ucrt-x86_64-egl-headers mingw-w64-ucrt-x86_64-gles-headers mingw-w64-ucrt-x86_64-cmake mingw-w64-ucrt-x86_64-python-yaml mingw-w64-ucrt-x86_64-python-pip mingw-w64-ucrt-x86_64-python-setuptools mingw-w64-ucrt-x86_64-python-wheel mingw-w64-ucrt-x86_64-python-virtualenv mingw-w64-ucrt-x86_64-python-distlib && mkdir -p ${cmakeroot}objs/qemu' ; \
  msys 'pacman --noconfirm -Scc'; 

LABEL org.opencontainers.image.source=https://github.com/okuoku/qemubuild