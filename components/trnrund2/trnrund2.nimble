# Package
version = "0.1.0"
author = "Alex Lachance"
description = "Daemon that runs TRNRun simulations for one client over stdin and stdout"
license = "MIT"
srcDir = "src"
bin = @["trnrund2"]
binDir = "build"

# Dependencies
requires "nim >= 2.2.12"
