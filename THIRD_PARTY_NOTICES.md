# Third-party notices

Nano Cortex Editor for Mac is MIT-licensed (see `LICENSE`). It builds on the work below.

## Protocol knowledge

The Bluetooth protocol layer in `NanoCore` (message layouts, the effect model catalogue in `Models.swift`, the
parameter scaling) was ported from two community editors. No code is copied verbatim; the Swift port follows their
behaviour, and both projects are MIT-licensed.

- **nano-cortex-editor** by Dominik Schmidt (DrD85), MIT: <https://github.com/DrD85/nano-cortex-editor>
- **nano-cortex-web-editor** by choldy, MIT: <https://github.com/choldy/nano-cortex-web-editor>

Everything beyond them (capture transfer, preset delete, footswitch and expression assignments, preset tempo, device
settings) was decoded from our own recordings; see `docs/PROTOCOL-NOTES.md`.

> MIT License. Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
> associated documentation files (the "Software"), to deal in the Software without restriction, including without
> limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
> Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of
> the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
> NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
> EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
> ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
> DEALINGS IN THE SOFTWARE.

## IBM Plex Sans

The app bundles IBM Plex Sans (Regular, Medium, SemiBold, Bold) in `App/Resources/Fonts`.

Copyright © 2017 IBM Corp. with Reserved Font Name "Plex". Licensed under the SIL Open Font License, Version 1.1.
The full licence text ships next to the fonts in `App/Resources/Fonts/OFL.txt` (and inside the app bundle);
it is also available at <https://openfontlicense.org>.

## Sparkle

The app embeds [Sparkle](https://sparkle-project.org) 2.10.0 (`Sparkle.framework`) for update notifications and
installs. Sparkle is MIT-licensed (© 2006-2013 Andy Matuschak, © 2009-2013 Elgato Systems GmbH, © 2011-2014 Kornel
Lesiński, © 2015-2017 Mayur Pawashe, © 2014 C.W. Betts, © 2014 Petroules Corporation, © 2014 Big Nerd Ranch) and
includes bsdiff/bspatch (© 2003-2005 Colin Percival, BSD 2-clause), sais-lite (© 2008-2010 Yuta Mori, MIT), an Ed25519
implementation (© 2015 Orson Peters, zlib) and SUSignatureVerifier (© 2011 Mark Hamlin, BSD 2-clause). The full text of these
licences is in `App/Resources/Sparkle-LICENSE.txt`, copied verbatim from Sparkle 2.10.0 and shipped inside the app
bundle (`Contents/Resources/Sparkle-LICENSE.txt`).

## Trademarks

Neural DSP and Nano Cortex are trademarks of Neural DSP Technologies Oy; this project is not affiliated with or
endorsed by Neural DSP. Quad Cortex, Neural Capture and Cortex Cloud are also Neural DSP trademarks. They are used
here only to say which device and service the app works with. The app ships no Neural DSP logos or artwork.
