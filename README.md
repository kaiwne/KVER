## KVER - Kaiwne's Void Extended Repository

> [!NOTE]
> How to use?
> 
> Type in the terminal
> ```shell
> printf "repository=https://github.com/kaiwne/KVER/releases/latest/download" | sudo tee /etc/xbps.d/kver.conf
> sudo xbps-install -S
> ```

## List Packages
| Name           | Source                                           | Auto-update |
|----------------|--------------------------------------------------|-------------|
| brave-origin   | https://github.com/brave/brave-browser           | ✅          |
| fcitx5-lotus   | https://github.com/LotusInputMethod/fcitx5-lotus | ✅          |
| helium-browser | https://github.com/imputnet/helium-linux         | ✅          |
| mangowc        | https://github.com/mangowm/mango                 | ✅          |
| scenefx        | https://github.com/wlrfx/scenefx                 | ✅          |
| scenefx-devel  | https://github.com/wlrfx/scenefx                 | ✅          |

## TODO
- [x] Build, update packages once a new version is released via GitHub Actions
