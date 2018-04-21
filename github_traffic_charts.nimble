# Package

version       = "0.1.0"
author        = "Federico Ceratto"
description   = "GitHub Traffic chart generator"
license       = "GPLv3"
bin           = @["github_traffic_charts"]

# Dependencies

requires "nim >= 0.18.0", "github_api >= 0.1.0"
task build_deb, "build deb package":
  exec "dpkg-buildpackage -us -uc -b"

task install_deb, "install deb package":
  exec "sudo debi"
