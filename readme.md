# AstraClient

AstraClient is the public client identity for this project.

Created/maintained by Mateuzkl.


## Protocol Features

Read the feature guide before changing `g_game.enableFeature` or `g_game.disableFeature`:

- English: `docs/protocol-features-8.60.md`
- PT-BR: `docs/protocol-features-8.60.pt-BR.md`

## Game Assets

Download the protocol 8.60 asset package:

**[Download 860.rar](https://github.com/Mateuzkl/AstraClient/raw/refs/heads/main/data/things/860.rar)**

The archive contains:

```text
860/Tibia.dat
860/Tibia.otfi
860/Tibia.spr
```

Extract it inside `data/things/`. The final files must be located under `data/things/860/`.

SHA-256: `1857FA472F2BC28EF2E62A8B889C3D80380B7A7287B28EA4AAD10C6793537B19`

## Build

### Windows

Install vcpkg:

```powershell
git clone https://github.com/microsoft/vcpkg.git
cd vcpkg
.\bootstrap-vcpkg.bat
.\vcpkg.exe integrate install
```

Open the Visual Studio solution in `vc17`, select the desired backend and platform, then build the `AstraClient` project.

### Linux

```bash
sudo apt update
sudo apt install git curl build-essential cmake gcc g++ pkg-config autoconf libtool libglew-dev -y
git clone https://github.com/microsoft/vcpkg.git ~/vcpkg
~/vcpkg/bootstrap-vcpkg.sh
~/vcpkg/vcpkg install
mkdir build
cd build
cmake -DCMAKE_TOOLCHAIN_FILE=~/vcpkg/scripts/buildsystems/vcpkg.cmake ..
cmake --build . --config Release
```

## Credits

See `CREDITS.md` for upstream and license-related credits.
