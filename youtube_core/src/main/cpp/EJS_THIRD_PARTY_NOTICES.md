# Local EJS bundle notices

`ejs_bundle.generated.h` is mechanically generated from the already validated
local `yt-decoder-service` runtime. It contains:

- Meriyah, ISC License.
- Astring, MIT License.
- `solver_core.js`, marked SPDX `Unlicense` by its source file.

The bundle has no Node.js file, process, network, module, or VM dependency. It
only exposes `__yourpipeEjs(inputJson)` inside the isolated HarmonyOS JSVM.
