@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem ============================================================================
rem  compile.bat - build Prism Launcher (Windows/MSVC) into a runnable EXE
rem
rem  What it does:
rem    1. Checks that Git, CMake, curl and a Visual Studio C++ toolchain exist
rem    2. Checks out the required git submodules (cmake/vcpkg, libnbtplusplus)
rem    3. Sets up Ninja   (downloaded to .\tools\ninja  if missing)
rem    4. Sets up a real Python 3 - used for aqtinstall. Tries (in order):
rem       COMPILE_PYTHON, an existing "py" launcher or python.exe, a winget
rem       install of Python 3.12, and finally a standalone Python build fetched
rem       from GitHub (astral-sh/python-build-standalone, SHA-256 verified).
rem    5. Sets up Qt 6    (downloaded with aqtinstall to .\tools\Qt if missing)
rem    6. Sets up a JDK   (Temurin 17 from GitHub to .\tools\jdk if missing -
rem       needed to compile the two Java jar subprojects; SHA-256 verified)
rem    7. Configures with the official windows_msvc preset + x64-windows vcpkg triplets
rem       (the updater target is enabled so the NSIS installer can include it:
rem        Launcher_BUILD_ARTIFACT=PrismLauncherX)
rem    8. Builds "Release" and installs into .\install
rem       (Qt DLLs/plugins are bundled by the install step -> runnable EXE)
rem    9. Zips .\install into PrismLauncherX-<version>.zip with 7-Zip
rem   10. Builds the NSIS installer (PrismLauncherX-Setup-<version>.exe)
rem       - fetches the NScurl plugin (needed for the Visual Studio Runtime
rem         download section) into .\NSISPlugins if missing
rem
rem  Result:  .\install\PrismLauncher.exe
rem           .\PrismLauncherX-<version>.zip
rem           .\PrismLauncherX-Setup-<version>.exe
rem
rem  Optional environment overrides:
rem     COMPILE_BUILD_TYPE       Build configuration      (default: Release)
rem     COMPILE_QT_VERSION       Qt version to use        (default: 6.11.2)
rem     COMPILE_PYTHON           Path to a python.exe     (skips python setup)
rem     COMPILE_QT_DIR           Path to an existing Qt   (skips Qt download,
rem                              e.g. a Qt dir containing lib\cmake\Qt6\Qt6Config.cmake)
rem     COMPILE_JAVA_HOME        Path to an existing JDK  (skips JDK download; its
rem                              javac must still support -source 7, i.e. JDK <= 19)
rem     COMPILE_RELEASE_VERSION  Version used in artifact names (default: derived
rem                              from CMakeLists.txt + current git branch)
rem     COMPILE_UPDATER_REPO     GitHub repo the in-app updater checks
rem                              (default: https://github.com/PrismLauncher/PrismLauncher)
rem     COMPILE_ARTIFACT_NAME    Asset prefix the updater looks for
rem                              (default: PrismLauncherX)
rem     COMPILE_YES=1            Skip all confirmation prompts
rem ============================================================================

set "SCRIPT_DIR=%~dp0"
cd /d "%SCRIPT_DIR%"

rem ---------------------------------------------------------- configuration ----
set "BUILD_TYPE=Release"
set "QT_VERSION=6.11.2"
set "QT_ARCH=win64_msvc2022_64"
set "QT_MODULES=qtimageformats qtnetworkauth"
set "VCPKG_TRIPLET=x64-windows"
set "NINJA_VERSION=v1.12.1"
set "TOOLS_DIR=%SCRIPT_DIR%tools"
set "NINJA_DIR=%TOOLS_DIR%\ninja"
set "QT_INSTALL_DIR=%TOOLS_DIR%\Qt"
set "JDK_DIR=%TOOLS_DIR%\jdk"
set "ARTIFACT_NAME=PrismLauncherX"
set "UPDATER_GITHUB_REPO=https://github.com/PrismLauncher/PrismLauncher"
rem aqt strips the leading "win64_" from the arch when choosing the install
rem folder name (win64_msvc2022_64 is installed into .../6.11.2/msvc2022_64).
set "QT_FOLDER=%QT_ARCH:win64_=%"

if not "%COMPILE_BUILD_TYPE%"==""  set "BUILD_TYPE=%COMPILE_BUILD_TYPE%"
if not "%COMPILE_QT_VERSION%"==""  set "QT_VERSION=%COMPILE_QT_VERSION%"
if not "%COMPILE_ARTIFACT_NAME%"==""  set "ARTIFACT_NAME=%COMPILE_ARTIFACT_NAME%"
if not "%COMPILE_UPDATER_REPO%"==""  set "UPDATER_GITHUB_REPO=%COMPILE_UPDATER_REPO%"

echo ============================================================================
echo  Prism Launcher X - compile.bat
echo ============================================================================
echo  Build type : %BUILD_TYPE%
echo  Qt         : %QT_VERSION% ^(%QT_ARCH%^)
echo  vcpkg      : %VCPKG_TRIPLET% triplets
echo  Artifact   : %ARTIFACT_NAME%
echo.

rem -------------------------------------------------- check basic tooling ----
where cmake >nul 2>&1 || goto :fail_no_cmake
where git   >nul 2>&1 || goto :fail_no_git
where curl  >nul 2>&1 || goto :fail_no_curl

set "NEEDS_CONFIRM=0"

set "VCPKG_TOOLCHAIN=%SCRIPT_DIR%cmake\vcpkg\scripts\buildsystems\vcpkg.cmake"
if not exist "%VCPKG_TOOLCHAIN%" set "NEEDS_CONFIRM=1"

if exist "%NINJA_DIR%\ninja.exe" (set "NEEDS_NINJA=0") else (set "NEEDS_NINJA=1")
if "!NEEDS_NINJA!"=="1" set "NEEDS_CONFIRM=1"

set "NEEDS_PYTHON=1"
if not "%COMPILE_PYTHON%"=="" if exist "%COMPILE_PYTHON%" set "NEEDS_PYTHON=0"
if "!NEEDS_PYTHON!"=="1" (
    py -3 -c "import sys" >nul 2>&1        && set "NEEDS_PYTHON=0"
)
if "!NEEDS_PYTHON!"=="1" (
    python -c "import sys" >nul 2>&1       && set "NEEDS_PYTHON=0"
)
if "!NEEDS_PYTHON!"=="1" if exist "%TOOLS_DIR%\python\python\python.exe" set "NEEDS_PYTHON=0"
if "!NEEDS_PYTHON!"=="1" set "NEEDS_CONFIRM=1"

set "NEEDS_QT=1"
if not "%COMPILE_QT_DIR%"=="" if exist "%COMPILE_QT_DIR%\lib\cmake\Qt6" set "NEEDS_QT=0"
if "!NEEDS_QT!"=="1" if exist "%QT_INSTALL_DIR%\%QT_VERSION%\%QT_FOLDER%\lib\cmake\Qt6" set "NEEDS_QT=0"
if "!NEEDS_QT!"=="1" if exist "C:\Qt\%QT_VERSION%\%QT_FOLDER%\lib\cmake\Qt6" set "NEEDS_QT=0"
if "!NEEDS_QT!"=="1" set "NEEDS_CONFIRM=1"

set "JAVA_HOME_JDK="
set "NEEDS_JAVA=1"
if not "%COMPILE_JAVA_HOME%"=="" if exist "%COMPILE_JAVA_HOME%\bin\javac.exe" set "JAVA_HOME_JDK=%COMPILE_JAVA_HOME%"
if not defined JAVA_HOME_JDK if exist "%JDK_DIR%\bin\javac.exe" set "JAVA_HOME_JDK=%JDK_DIR%"
if not defined JAVA_HOME_JDK if defined JAVA_HOME (
    call :javac_ok "%JAVA_HOME%\bin\javac.exe" && set "JAVA_HOME_JDK=%JAVA_HOME%"
)
if not defined JAVA_HOME_JDK (
    for /d %%d in ("%ProgramFiles%\Eclipse Adoptium\jdk-17*" "%ProgramFiles%\Microsoft\jdk-17*" "%ProgramFiles(x86)%\Eclipse Adoptium\jdk-17*") do (
        if exist "%%~d\bin\javac.exe" if not defined JAVA_HOME_JDK (
            call :javac_ok "%%~d\bin\javac.exe" && set "JAVA_HOME_JDK=%%~d"
        )
    )
)
if not defined JAVA_HOME_JDK (
    set "JAVAC_PATH="
    for /f "delims=" %%p in ('where javac 2^>nul') do if not defined JAVAC_PATH set "JAVAC_PATH=%%p"
    if defined JAVAC_PATH (
        call :javac_ok "!JAVAC_PATH!" && set "JAVA_HOME_JDK=use_path"
    )
)
if defined JAVA_HOME_JDK set "NEEDS_JAVA=0"
if "!NEEDS_JAVA!"=="1" set "NEEDS_CONFIRM=1"

if "!NEEDS_CONFIRM!"=="1" (
    echo ^> This build needs to download several large components
    echo   ^(vcpkg submodule ~1-2 GB, Qt ~1 GB, additional tools^). This can take a
    echo   long time on first run and will use significant disk space.
    if not defined COMPILE_YES (
        set /p "GO=Proceed with downloads? [y/N] "
        if /i not "!GO!"=="y" (
            echo Aborted.
            exit /b 1
        )
    )
)
echo.

rem ------------------------------------------------------ [1/10] submodules ----
if not exist "%VCPKG_TOOLCHAIN%" (
    echo [1/10] Initializing git submodules ^(cmake/vcpkg, libnbtplusplus^)...
    git submodule update --init --recursive
    if errorlevel 1 goto :fail_submodules
) else (
    echo [1/10] Git submodules already present.
)
if not exist "%VCPKG_TOOLCHAIN%" goto :fail_submodules
echo.

rem --------------------------------------------------------- [2/10] Ninja -----
if not exist "%NINJA_DIR%\ninja.exe" (
    echo [2/10] Downloading Ninja %NINJA_VERSION%...
    if not exist "%TOOLS_DIR%" mkdir "%TOOLS_DIR%"
    curl -L --fail --silent --show-error -o "%TOOLS_DIR%\ninja.zip" ^
        "https://github.com/ninja-build/ninja/releases/download/%NINJA_VERSION%/ninja-win.zip"
    if errorlevel 1 goto :fail_ninja
    if not exist "%NINJA_DIR%" mkdir "%NINJA_DIR%"
    tar -xf "%TOOLS_DIR%\ninja.zip" -C "%NINJA_DIR%"
    if errorlevel 1 goto :fail_ninja
    del "%TOOLS_DIR%\ninja.zip"
) else (
    echo [2/10] Ninja already present.
)
set "PATH=%NINJA_DIR%;%PATH%"
ninja --version >nul 2>&1 || goto :fail_ninja
echo.

rem ------------------------------------------------- [3/10] Visual Studio ----
set "VS_INSTALL="
set "VSWhere=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "%VSWhere%" (
    for /f "usebackq delims=" %%i in (`"%VSWhere%" -latest -products * -property installationPath`) do set "VS_INSTALL=%%i"
)
if not defined VS_INSTALL if exist "%ProgramFiles%\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" set "VS_INSTALL=%ProgramFiles%\Microsoft Visual Studio\2022\Community"
if not defined VS_INSTALL goto :fail_no_vs
set "VCVARS=%VS_INSTALL%\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" goto :fail_no_vs

echo [3/10] Entering Visual Studio developer environment...
call "%VCVARS%" >nul
where cl >nul 2>&1 || goto :fail_no_cpp
echo         MSVC toolchain ready.
echo.

rem ------------------------------------------------------- [4/10] Python -----
call :setup_python
if errorlevel 1 goto :fail_no_python
echo.

rem ---------------------------------------------------------- [5/10] Qt ------
call :setup_qt
if errorlevel 1 goto :fail_no_qt
echo.

rem ------------------------------------------------------- [6/10] JDK --------
call :setup_java
if errorlevel 1 goto :fail_no_java
echo.

rem --------------------------------------------------- [7/10] Configure ------
echo [7/10] Configuring with preset "windows_msvc"...
set "VCPKG_DISABLE_METRICS=1"
set "Qt6_DIR=%QT6_DIR%"
call :ensure_vcpkg_python
if errorlevel 1 goto :fail_configure
cmake --preset windows_msvc ^
    -D Qt6_DIR="%QT6_DIR%" ^
    -D VCPKG_HOST_TRIPLET=%VCPKG_TRIPLET% ^
    -D VCPKG_TARGET_TRIPLET=%VCPKG_TRIPLET% ^
    -D Launcher_BUILD_ARTIFACT=%ARTIFACT_NAME% ^
    -D Launcher_UPDATER_GITHUB_REPO=%UPDATER_GITHUB_REPO%
if errorlevel 1 goto :fail_configure
echo.

rem ----------------------------------------------------- [8/10] Build --------
echo [8/10] Building "%BUILD_TYPE%" and installing to .\install...
cmake --build --preset windows_msvc --config %BUILD_TYPE%
if errorlevel 1 goto :fail_build

cmake --install build --config %BUILD_TYPE%
if errorlevel 1 goto :fail_install

echo.
rem --------------------------------------------------- [9/10] Zip ------------
echo [9/10] Packing .\install into a 7-Zip archive...
call :pack_zip
if errorlevel 1 goto :fail_zip

echo.
rem -------------------------------------------------- [10/10] Installer ------
echo [10/10] Building the NSIS installer...
call :pack_installer
if errorlevel 1 goto :fail_installer

echo.
echo ============================================================================
echo  BUILD SUCCEEDED
echo.
echo  Runnable launcher:
echo      "%SCRIPT_DIR%install\PrismLauncher.exe"
echo.
echo  Release artifacts:
echo      "%SCRIPT_DIR%%ZIP_NAME%"
echo      "%SCRIPT_DIR%%SETUP_NAME%"
echo.
echo  Tip: .\install is a complete bundle (EXE + Qt DLLs + plugins) and can be
echo       moved anywhere or run directly.
echo ============================================================================
endlocal
exit /b 0

rem ============================================================================
rem  subroutines
rem ============================================================================

:setup_python
    set "PYTHON_EXE="
    if not "%COMPILE_PYTHON%"=="" if exist "%COMPILE_PYTHON%" set "PYTHON_EXE=%COMPILE_PYTHON%"
    if not defined PYTHON_EXE (
        py -3 -c "import sys" >nul 2>&1 && set "PYTHON_EXE=py -3"
    )
    if not defined PYTHON_EXE (
        python -c "import sys" >nul 2>&1 && set "PYTHON_EXE=python"
    )
    if not defined PYTHON_EXE (
        rem Standalone Python left over from a previous run
        if exist "%TOOLS_DIR%\python\python\python.exe" set "PYTHON_EXE=%TOOLS_DIR%\python\python\python.exe"
    )
    if not defined PYTHON_EXE (
        echo [4/10] No usable Python found - trying winget install...
        winget install --id Python.Python.3.12 --exact --scope user --silent ^
            --source winget --accept-package-agreements --accept-source-agreements >nul
        if exist "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" set "PYTHON_EXE=%LOCALAPPDATA%\Programs\Python\Python312\python.exe"
    )
    if not defined PYTHON_EXE (
        echo [4/10] winget route unavailable - fetching a standalone Python 3.13 from GitHub...
        call :fetch_standalone_python
        if errorlevel 1 exit /b 1
        set "PYTHON_EXE=%TOOLS_DIR%\python\python\python.exe"
    )
    "%PYTHON_EXE%" -c "import sys; assert sys.version_info >= (3, 9)" >nul 2>&1 || exit /b 1
    "%PYTHON_EXE%" -m pip --version >nul 2>&1 || "%PYTHON_EXE%" -m ensurepip --upgrade >nul
    echo [4/10] Python ready: %PYTHON_EXE%
exit /b 0

:fetch_standalone_python
    rem Standalone CPython build from https://github.com/astral-sh/python-build-standalone
    rem (hosted on GitHub, which avoids TLS interception problems some networks have
    rem  with python.org/PyPI). SHA-256 is verified against the value published in
    rem  the GitHub release metadata.
    set "PY_TAG=20260901"
    set "PY_FILE=cpython-3.13.15+%PY_TAG%-x86_64-pc-windows-msvc-install_only.tar.gz"
    set "PY_SHA256=9bcc038a0bf180612ed56dec93d4977d035e80b8d9320ef51a38c287baf134b7"
    set "PY_TARBALL=%TOOLS_DIR%\%PY_FILE%"
    if not exist "%TOOLS_DIR%" mkdir "%TOOLS_DIR%"
    echo         Downloading Python 3.13.15 standalone from GitHub...
    curl -L --fail --silent --show-error -o "%PY_TARBALL%" ^
        "https://github.com/astral-sh/python-build-standalone/releases/download/%PY_TAG%/%PY_FILE%"
    if errorlevel 1 exit /b 1
    echo         Verifying SHA-256...
    set "GOT="
    for /f "tokens=1" %%h in ('certutil -hashfile "%PY_TARBALL%" SHA256 ^| findstr /R "^[0-9a-f]*$"') do set "GOT=%%h"
    if not defined GOT exit /b 1
    if /i not "!GOT!"=="%PY_SHA256%" (
        echo         Hash mismatch: expected %PY_SHA256% but got !GOT! - refusing to use the download.
        exit /b 1
    )
    echo         Extracting...
    if not exist "%TOOLS_DIR%\python" mkdir "%TOOLS_DIR%\python"
    tar -xf "%PY_TARBALL%" -C "%TOOLS_DIR%\python"
    if errorlevel 1 exit /b 1
    del "%PY_TARBALL%"
    if not exist "%TOOLS_DIR%\python\python\python.exe" exit /b 1
exit /b 0

:ensure_vcpkg_python
    rem vcpkg fetches an embeddable CPython (to drive meson etc.) and python.org
    rem is TLS-intercepted on some networks. Pre-seed the archive; SHA-512 is
    rem verified here and vcpkg re-validates the hash itself before use.
    set "VPY=%SCRIPT_DIR%cmake\vcpkg\downloads\python-3.14.2-embed-amd64.zip"
    if exist "%VPY%" exit /b 0
    echo         Pre-seeding vcpkg embedded Python 3.14.2 from python.org...
    curl -k -sS -L --max-time 300 -o "%VPY%" "https://www.python.org/ftp/python/3.14.2/python-3.14.2-embed-amd64.zip"
    if errorlevel 1 exit /b 1
    set "VPY_HASH="
    for /f "usebackq delims=" %%l in (`powershell -NoProfile -Command "(Get-FileHash -Algorithm SHA512 -LiteralPath '%VPY%').Hash.ToLower()"`) do set "VPY_HASH=%%l"
    if /i not "%VPY_HASH%"=="d72d4f036c4dd563c4ac15c7162bf63406d3fd83a44877300ff87e4168f211d66b8209fdd3ad39ea549b8bc46c092b4ecab3b24b0da2f8950e0e5642828e99f2" (
        echo         SHA-512 mismatch for the vcpkg Python seed - refusing to continue.
        exit /b 1
    )
    echo         vcpkg Python seed ready.
exit /b 0

:setup_qt
    set "QT6_DIR="
    if not "%COMPILE_QT_DIR%"=="" if exist "%COMPILE_QT_DIR%\lib\cmake\Qt6" (
        set "QT6_DIR=%COMPILE_QT_DIR%"
    )
    if not defined QT6_DIR if exist "%QT_INSTALL_DIR%\%QT_VERSION%\%QT_FOLDER%\lib\cmake\Qt6" (
        set "QT6_DIR=%QT_INSTALL_DIR%\%QT_VERSION%\%QT_FOLDER%"
    )
    if not defined QT6_DIR if exist "C:\Qt\%QT_VERSION%\%QT_FOLDER%\lib\cmake\Qt6" (
        set "QT6_DIR=C:\Qt\%QT_VERSION%\%QT_FOLDER%"
    )
    if not defined QT6_DIR (
        echo [5/10] Installing Qt %QT_VERSION% with aqtinstall...
        echo         Installing aqtinstall...
        rem Pin the same aqtinstall revision Prism's CI uses (handles the Qt 6.11+
        rem  win64_* repo-folder layout that the PyPI release gets wrong).
        rem --trusted-host: some networks TLS-inspect PyPI with an untrusted root; harmless elsewhere
        "%PYTHON_EXE%" -m pip install --disable-pip-version-check ^
            --trusted-host pypi.org --trusted-host files.pythonhosted.org ^
            "git+https://github.com/miurahr/aqtinstall.git@16db45a70b5905ad596941b223469bc86a56901e"
        if errorlevel 1 exit /b 1
        echo         Downloading and installing Qt ^(this is the big one^)...
        "%PYTHON_EXE%" -m aqt install-qt windows desktop %QT_VERSION% %QT_ARCH% ^
            -b https://download.qt.io/ ^
            --outputdir "%QT_INSTALL_DIR%" -m %QT_MODULES%
        if errorlevel 1 exit /b 1
        set "QT6_DIR=%QT_INSTALL_DIR%\%QT_VERSION%\%QT_FOLDER%"
    )
    if not exist "%QT6_DIR%\lib\cmake\Qt6" (
        echo         Qt installation incomplete: missing Qt6Config.cmake under %QT6_DIR%
        exit /b 1
    )
    echo [5/10] Qt ready: %QT6_DIR%
exit /b 0

:setup_java
    if "%JAVA_HOME_JDK%"=="use_path" (
        echo [6/10] JDK ready: javac from PATH
        exit /b 0
    )
    if defined JAVA_HOME_JDK (
        set "JAVA_HOME=%JAVA_HOME_JDK%"
        set "PATH=%JAVA_HOME_JDK%\bin;%PATH%"
        echo [6/10] JDK ready: %JAVA_HOME_JDK%
        exit /b 0
    )
    rem Temurin 17 (same major as CI) - needed because the jar subprojects are
    rem compiled with -source 7, which javac >= 20 no longer accepts.
    echo [6/10] Fetching Temurin JDK 17 from GitHub...
    set "JDK_URL=https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20.1+1/OpenJDK17U-jdk_x64_windows_hotspot_17.0.20.1_1.zip"
    set "JDK_ZIP=%TOOLS_DIR%\temurin-jdk17.zip"
    set "JDK_SHA256=e53a79c3c3d86865bd7e787903884331068e71321714ffd44f145785affc7cb0"
    if not exist "%TOOLS_DIR%" mkdir "%TOOLS_DIR%"
    curl -L --fail --silent --show-error -o "%JDK_ZIP%" "%JDK_URL%"
    if errorlevel 1 exit /b 1
    set "JGOT="
    for /f "tokens=1" %%h in ('certutil -hashfile "%JDK_ZIP%" SHA256 ^| findstr /R "^[0-9a-f]*$"') do set "JGOT=%%h"
    if not defined JGOT exit /b 1
    if /i not "!JGOT!"=="%JDK_SHA256%" (
        echo         SHA-256 mismatch for the JDK download - refusing to continue.
        exit /b 1
    )
    if exist "%JDK_DIR%" rmdir /s /q "%JDK_DIR%"
    mkdir "%JDK_DIR%"
    tar -xf "%JDK_ZIP%" -C "%JDK_DIR%" --strip-components 1
    if errorlevel 1 exit /b 1
    del "%JDK_ZIP%"
    if not exist "%JDK_DIR%\bin\javac.exe" exit /b 1
    set "JAVA_HOME=%JDK_DIR%"
    set "PATH=%JDK_DIR%\bin;%PATH%"
    echo         JDK ready: %JDK_DIR%
exit /b 0

:javac_ok
    rem Usage: call :javac_ok "path\to\javac.exe"
    rem Succeeds only if that javac can still compile with -source 7 (major < 20).
    if not exist "%~1" exit /b 1
    "%~1" --version >"%TEMP%\prism_javac_ver.txt" 2>nul
    if errorlevel 1 exit /b 1
    set "JV="
    set /p JV=<"%TEMP%\prism_javac_ver.txt"
    del "%TEMP%\prism_javac_ver.txt" >nul 2>&1
    for /f "tokens=2" %%v in ("%JV%") do for /f "delims=." %%m in ("%%v") do if %%m LSS 20 exit /b 0
exit /b 1

:derive_version
    rem Mirrors BuildConfig::printableVersionString():
    rem   MAJOR.MINOR.PATCH from CMakeLists.txt, plus "-channel" when the build
    rem   is not a tagged release (channel = current git branch).
    rem COMPILE_RELEASE_VERSION overrides everything.
    if not "%COMPILE_RELEASE_VERSION%"=="" (
        set "VERSION=%COMPILE_RELEASE_VERSION%"
        exit /b 0
    )
    set "VMAJ="
    set "VMIN="
    set "VPATCH="
    for /f "tokens=2 delims=) " %%a in ('findstr /c:"set(Launcher_VERSION_MAJOR " CMakeLists.txt') do set "VMAJ=%%a"
    for /f "tokens=2 delims=) " %%a in ('findstr /c:"set(Launcher_VERSION_MINOR " CMakeLists.txt') do set "VMIN=%%a"
    for /f "tokens=2 delims=) " %%a in ('findstr /c:"set(Launcher_VERSION_PATCH " CMakeLists.txt') do set "VPATCH=%%a"
    if not defined VMAJ exit /b 1
    if not defined VMIN exit /b 1
    if not defined VPATCH exit /b 1
    set "VERSION=%VMAJ%.%VMIN%.%VPATCH%"
    set "CHANNEL="
    for /f "delims=" %%b in ('git rev-parse --abbrev-ref HEAD 2^>nul') do set "CHANNEL=%%b"
    if not "%CHANNEL%"=="" if not "%CHANNEL%"=="stable" set "VERSION=%VERSION%-%CHANNEL%"
exit /b 0

:pack_zip
    rem Uses 7-Zip to create PrismLauncherX-<version>.zip from .\install.
    set "SEVENZIP="
    if exist "C:\Program Files\7-Zip\7z.exe" set "SEVENZIP=C:\Program Files\7-Zip\7z.exe"
    if not defined SEVENZIP if exist "C:\Program Files (x86)\7-Zip\7z.exe" set "SEVENZIP=C:\Program Files (x86)\7-Zip\7z.exe"
    if not defined SEVENZIP (
        for /f "delims=" %%s in ('where 7z 2^>nul') do if not defined SEVENZIP set "SEVENZIP=%%s"
    )
    if not defined SEVENZIP (
        echo ERROR: 7-Zip not found. Install it from https://www.7-zip.org and re-run.
        exit /b 1
    )
    call :derive_version
    if errorlevel 1 (
        echo ERROR: could not derive the version for the archive name.
        exit /b 1
    )
    set "ZIP_NAME=%ARTIFACT_NAME%-%VERSION%.zip"
    echo         Creating "%ZIP_NAME%"...
    if exist "%SCRIPT_DIR%%ZIP_NAME%" del "%SCRIPT_DIR%%ZIP_NAME%"
    rem zip the *contents* of .\install so the EXE sits at the archive root
    pushd "%SCRIPT_DIR%install"
    "%SEVENZIP%" a -tzip -mx9 -y "%SCRIPT_DIR%%ZIP_NAME%" * >nul
    set "ZIP_RC=!errorlevel!"
    popd
    if not "!ZIP_RC!"=="0" (
        echo ERROR: 7-Zip failed with exit code !ZIP_RC!.
        exit /b 1
    )
    if not exist "%SCRIPT_DIR%%ZIP_NAME%" (
        echo ERROR: zip archive was not created.
        exit /b 1
    )
    for %%f in ("%SCRIPT_DIR%%ZIP_NAME%") do echo         Done: %%~nxf (%%~zf bytes)
exit /b 0

:pack_installer
    rem Builds the NSIS installer from the CMake-generated win_install.nsi.
    rem Mirrors the official recipe:
    rem   - NScurl plugin (SHA-256 verified) enables the "Visual Studio Runtime"
    rem     section that downloads the MSVC redistributable at install time.
    rem   - makensis runs with -NOCD from inside .\install so all relative paths
    rem     (File "prismlauncher.exe", MUI_ICON ../program_info/..., etc.) resolve
    rem     correctly.
    set "MAKENSIS="
    if exist "C:\Program Files (x86)\NSIS\makensis.exe" set "MAKENSIS=C:\Program Files (x86)\NSIS\makensis.exe"
    if not defined MAKENSIS if exist "C:\Program Files\NSIS\makensis.exe" set "MAKENSIS=C:\Program Files\NSIS\makensis.exe"
    if not defined MAKENSIS (
        for /f "delims=" %%m in ('where makensis 2^>nul') do if not defined MAKENSIS set "MAKENSIS=%%m"
    )
    if not defined MAKENSIS (
        echo ERROR: NSIS not found. Install it from https://nsis.sourceforge.io and re-run.
        exit /b 1
    )
    if not exist "%SCRIPT_DIR%build\program_info\win_install.nsi" (
        echo ERROR: build\program_info\win_install.nsi not found. Configure and build first.
        exit /b 1
    )

    rem ---- NScurl plugin (only needed for the optional MSVC redist section) ----
    set "NSCURL_VER=v24.9.26.122"
    set "NSCURL_SHA256=AEE6C4BE3CB6455858E9C1EE4B3AFE0DB9960FA03FE99CCDEDC28390D57CCBB0"
    if exist "%SCRIPT_DIR%NSISPlugins\NScurl\Plugins\" goto :nscurl_present
    echo         Fetching NScurl plugin %NSCURL_VER%...
    if not exist "%SCRIPT_DIR%NSISPlugins" mkdir "%SCRIPT_DIR%NSISPlugins"
    curl -L --fail --silent --show-error -o "%SCRIPT_DIR%NSISPlugins\NScurl.zip" ^
        "https://github.com/negrutiu/nsis-nscurl/releases/download/%NSCURL_VER%/NScurl.zip"
    if errorlevel 1 goto :nscurl_download_failed
    if not exist "%SCRIPT_DIR%NSISPlugins\NScurl.zip" goto :nscurl_download_failed
    set "NSCURL_HASH="
    for /f "tokens=1" %%h in ('certutil -hashfile "%SCRIPT_DIR%NSISPlugins\NScurl.zip" SHA256 ^| findstr /R "^[0-9a-f]*$"') do set "NSCURL_HASH=%%h"
    if /i not "!NSCURL_HASH!"=="%NSCURL_SHA256%" goto :nscurl_hash_bad
    powershell -NoProfile -Command "Expand-Archive -LiteralPath '%SCRIPT_DIR%NSISPlugins\NScurl.zip' -DestinationPath '%SCRIPT_DIR%NSISPlugins\NScurl' -Force" >nul
    if errorlevel 1 goto :nscurl_extract_failed
    goto :nscurl_cleanup
:nscurl_present
    echo         NScurl plugin already present.
    goto :nscurl_done
:nscurl_download_failed
    echo         WARNING: NScurl download failed - installer will lack the VS Runtime section.
    goto :nscurl_cleanup
:nscurl_hash_bad
    echo         WARNING: NScurl hash mismatch - skipping plugin (installer will lack the VS Runtime section).
    goto :nscurl_cleanup
:nscurl_extract_failed
    echo         WARNING: NScurl extract failed - installer will lack the VS Runtime section.
:nscurl_cleanup
    if exist "%SCRIPT_DIR%NSISPlugins\NScurl.zip" del "%SCRIPT_DIR%NSISPlugins\NScurl.zip" >nul 2>&1
:nscurl_done

    rem ---- makensis ----
    echo         Running makensis (this can take a minute)...
    pushd "%SCRIPT_DIR%install"
    "%MAKENSIS%" -NOCD "%SCRIPT_DIR%build\program_info\win_install.nsi"
    set "NSIS_RC=!errorlevel!"
    popd
    if not "!NSIS_RC!"=="0" (
        echo ERROR: NSIS build failed with exit code !NSIS_RC!. Check the output above.
        exit /b 1
    )
    if not exist "%SCRIPT_DIR%PrismLauncher-Setup.exe" (
        echo ERROR: NSIS finished but PrismLauncher-Setup.exe was not produced.
        exit /b 1
    )
    if "%VERSION%"=="" call :derive_version
    set "SETUP_NAME=%ARTIFACT_NAME%-Setup-%VERSION%.exe"
    move /y "%SCRIPT_DIR%PrismLauncher-Setup.exe" "%SCRIPT_DIR%%SETUP_NAME%" >nul
    for %%f in ("%SCRIPT_DIR%%SETUP_NAME%") do echo         Done: %%~nxf (%%~zf bytes)
exit /b 0

rem ============================================================================
rem  error handlers
rem ============================================================================

:fail_no_cmake
    echo ERROR: cmake was not found. Install CMake ^>= 3.28 ^(https://cmake.org^) and try again.
    goto :fail

:fail_no_git
    echo ERROR: git was not found. Install Git for Windows ^(https://git-scm.com^) and try again.
    goto :fail

:fail_no_curl
    echo ERROR: curl was not found.
    goto :fail

:fail_no_vs
    echo ERROR: Visual Studio 2022 was not found.
    echo Install "Visual Studio Community 2022" with the "Desktop development with C++" workload.
    goto :fail

:fail_no_cpp
    echo ERROR: the MSVC C++ compiler ^(cl.exe^) is not available.
    echo In the Visual Studio Installer, add the "Desktop development with C++" workload.
    goto :fail

:fail_no_python
    echo ERROR: could not set up Python. Install Python 3 ^(https://python.org^) or pass COMPILE_PYTHON=path\to\python.exe
    goto :fail

:fail_no_qt
    echo ERROR: could not set up Qt. Install Qt %QT_VERSION% or pass COMPILE_QT_DIR=path\containing\Qt6Config.cmake
    goto :fail

:fail_no_java
    echo ERROR: could not set up a JDK. Install Temurin JDK 17 ^(https://adoptium.net^) or pass COMPILE_JAVA_HOME=path\to\jdk
    goto :fail

:fail_ninja
    echo ERROR: could not set up Ninja. Download ninja-win.zip manually and extract ninja.exe into %NINJA_DIR%
    goto :fail

:fail_submodules
    echo ERROR: git submodules could not be initialized ^(cmake/vcpkg is required^).
    echo Check your network connection and git credentials, then re-run this script.
    goto :fail

:fail_configure
    echo ERROR: CMake configure step failed. Scroll up for the error output.
    goto :fail

:fail_build
    echo ERROR: compilation failed. Scroll up for the error output.
    goto :fail

:fail_install
    echo ERROR: the install step failed. Scroll up for the error output.
    goto :fail

:fail_zip
    echo ERROR: creating the 7-Zip archive failed. Scroll up for the error output.
    goto :fail

:fail_installer
    echo ERROR: building the NSIS installer failed. Scroll up for the error output.
    goto :fail

:fail
    endlocal
    exit /b 1
