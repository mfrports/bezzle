# Bezzle for Windows

Bezzle on Windows, native: Swift with WinUI 3 (Erik, 2026-11-06), doing everything the Mac app
does. Nothing here is part of the Mac app's build.

## How it is put together

- **The design's model and its drawing** are the Mac app's own Swift, as the web core shares them
  (`Web/`): `Bezzle/Model`, the renderer, and the stand-ins for what they take from Core Graphics,
  Core Text and the rest (`Web/Sources/BezzleCore/Platform`). Where the web core asks the page
  (CanvasKit) to draw, set text and run path operations, the Windows app asks Skia directly, so
  designs draw and measure on Windows as they do in the browser, which matches the Mac.
- **The window, canvas and panels** are WinUI 3, through Swift bindings that swift-winrt
  generates from the Windows App SDK's metadata.

## Building

Windows builds on Windows: Swift cannot target Windows from macOS, and CrossOver cannot run WinUI 3
(its Windows App SDK needs system calls Wine lacks). On this Mac that is the Bezzle test VM:

```sh
Windows/VM/make-vm.sh        # once: Windows 11 for Arm in UTM, installed unattended (~30 min)
scp …/Windows/VM/provision.ps1, then run it in the VM: Visual Studio Build Tools, Swift, Git, CMake…
Windows/VM/sync.sh           # the working tree's build inputs to C:\src\Bezzle in the VM
Windows/VM/win               # a PowerShell in the VM, or `win <command>`
```

In the VM, in `C:\src\Bezzle\Windows`:

```powershell
.\winrt.ps1                  # WinUI bindings into Packages\, and the Windows App Runtime
.\skia.ps1                   # Skia into Packages\skia
.\avif.ps1                   # libavif and libaom into Packages\avif, for AVIF (a few minutes)
swift build
```

Without `Packages\avif`, Bezzle builds all the same but neither reads nor writes AVIF, as a Mac whose
Image I/O cannot write it leaves the format out. Run `.\avif.ps1` before the first `swift build`; when
it comes after one, touch `Package.swift`, since SwiftPM may keep its earlier reading of the manifest.

Remove Background runs the Mac's subject matte, BiRefNet_HR, exported to ONNX, with ONNX Runtime:
at 2,048 or at 1,024 pixels, on the graphics card through DirectML or on the processor, by what
the PC can afford (`Sources/BezzleCore/Host/MatteWays.swift`; what each way asks is in
`Scripts/subject-matte/README.md` › For Windows):

```powershell
.\onnx.ps1                   # ONNX Runtime 1.24.4 with DirectML, and DirectML 1.15.4, into Packages\onnxruntime
```

The model itself is made on a Mac and is too large for git: `Scripts/subject-matte/make.sh`, then
`make-onnx.sh`, write its three files to `Scripts/subject-matte/build/onnx`, the graphs of the two
sizes (`BiRefNet-2048.onnx`, `BiRefNet-1024.onnx`) and the weights both read (`BiRefNet.weights`,
269 MB), and `Windows/VM/send-matte.sh [C:\src\<folder>]` sends them into the VM's
`Packages\subject-matte`. A graph looks for the weights beside itself, so the three go together.
`onnx.ps1` says whether they are the model measured (their SHA-256 are pinned there), `build.ps1`
links them into `.build\Bezzle\Bezzle.resources` and puts ONNX Runtime and DirectML beside
Bezzle.exe, and the installer takes only the model measured. Without the headers, Bezzle builds
without Remove Background; without the model, it leaves Remove Background out of the inspector,
its menu and the welcome tour. (`Packages\subject-matte\BiRefNet.onnx`, a single file of 275 MB,
is the model of Bezzle 1.6 and before; nothing reads it any more.)

`.\build.ps1` builds and lays out the app in `.build\Bezzle`. Most PCs have Intel or AMD processors
(x64), and the Arm VM builds for them too: Swift cross-compiles (`swift build --arch x86_64`, with
`BEZZLE_ARCH=x64` telling `Package.swift` to link the x64 libraries), into `.build\x64`:

```powershell
.\skia.ps1 -Arch x64 -Jobs 2  # Skia into Packages\skia\out\x64 (about 40 minutes with two jobs)
.\avif.ps1 -Arch x64          # libavif and libaom into Packages\avif\out\x64
.\build.ps1 -Arch x64         # the app in .build\x64\Bezzle
```

The x64 app carries Swift's and Visual C++'s runtimes beside `Bezzle.exe` (`runtime.ps1`, from the
merge module Swift's installer leaves and from Visual Studio's redistributable files, only the DLLs
something asks for), since the Swift on an Arm machine's path is Arm's; `-Runtime` does the same for
an Arm build. Its Windows App Runtime bootstrapper is the x64 one of the same Windows App SDK
release. Windows 11 on Arm runs the x64 app by emulation, with the x64 Windows App Runtime that the
Arm runtime installer winrt.ps1 runs puts there beside the Arm one (and x86's).

A release build is of the app alone, `.\build.ps1 -Configuration release -Product Bezzle` (either
architecture): bezzle-share imports the core `@testable`, which a release build refuses.

See `VM/make-vm.sh` for what the VM is and where its key, password and disks live.

## Working in the VM

The VM is `bezzle@192.168.77.10`, reached by SSH with the key `~/.ssh/bezzle-windows-vm`; its
account's password is in `~/.ssh/bezzle-windows-vm.password` (never print either). `VM/autounattend.xml`
is a template with a placeholder, not the password.

- **Starting it:** UTM has to be running and showing, never hidden: hidden (⌘H, `open -j`, System
  Events' `visible`), it takes the order to start, fails without a word on the VM's window, and the
  VM stays stopped while the order times out (2026-11-10). UTM comes to the front as it is
  launched, even with `open -g`, so note the app in front and give the front back at once:
  `front=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true')`,
  then, if `pgrep -x UTM` finds none, `open -g -a UTM; sleep 6; osascript -e "tell application \"$front\" to activate"`,
  then `osascript -e 'tell application "UTM" to start virtual machine "Bezzle Windows"'`. SSH answers
  within half a minute. `utmctl start` prints error -10004 whether the VM starts or not, so ask
  `utmctl list` for its state. If a start timed out, quit UTM and begin again.
- **Commands:** `VM/win '<PowerShell>'` runs over SSH (session 0: no windows, no package installs);
  `VM/desktop [--detach] '<PowerShell>'` runs in the signed-in desktop, where windows appear. A
  program's output over SSH arrives only when it exits. Send a file with non-ASCII text as base64 and
  write it with `[IO.File]::WriteAllBytes` (the console's code page mangles it otherwise), then compare
  `Get-FileHash` with `md5` here. `scp` with `VM/win`'s options fetches results.
- **Sources:** `VM/sync.sh` puts the working tree's build inputs into `C:\src\Bezzle`, the Vectorize
  and shader engines (`Packages\Vectorizer`, `Packages\Shaders`) among them, making the files the web
  core changes a line of first (`Web/prepare.sh`), since the VM keeps what was sent before. Packages
  are built once there (`winrt.ps1`, `skia.ps1`, `avif.ps1`, `onnx.ps1`) and kept. A second working
  copy (a parallel agent's, the release's `C:\src\bezzle-release`) is a folder of its own with a
  junction to `C:\src\Bezzle\Windows\Packages`: `VM/sync.sh 'C:\src\<folder>'` syncs into one and
  makes the junction.
- **Building:** `.\build.ps1` lays out `.build\Bezzle`, which the launchers in `C:\bezzle\*.cmd` run;
  a bare `swift build` does not update it. With several builds at once the VM (8 cores, 12 GB) runs
  out of breath: build with `-j 2` (`swift build -j 2`, `build.ps1 -Jobs 2`).
- **The desktop is one, so it is taken in turn:**
  `until mkdir /private/tmp/claude-501/bezzle-vm-desktop.lock 2>/dev/null; do sleep 30; done; echo <who> > /private/tmp/claude-501/bezzle-vm-desktop.lock/owner`,
  one round of launching, trying and quitting (under about 20 minutes), then
  `rm -rf /private/tmp/claude-501/bezzle-vm-desktop.lock`. Others test without the desktop meanwhile:
  `bezzle-render`, or the AI server over HTTP with the app started minimized.
- **Trying the app:** `VM/input.ps1` (in the VM at `C:\bezzle\input.ps1`) moves the mouse and presses
  keys as real input, which WinUI needs. Every `VM/desktop` call briefly brings its own PowerShell to
  the front, so Bezzle loses focus for a moment and the first input of a call only activates its
  window: begin a call with a harmless click inside Bezzle (the empty part of the inspector), and send
  keys in the same call as that click. Paths go into file dialogs through `Set-Clipboard` and Ctrl+V.
  `VM/desktop --detach '<script>'` with `VM/win 'Start-Sleep <s>'` as a timer catches a gesture midway.
- **Seeing it:** `VM/screenshot [out.png]` photographs the VM's screen from inside it, so it works while
  this Mac's screen is locked; `VM/cursor.ps1` draws the pointer, which screenshots leave out. Copies
  running for an agent use `BEZZLE_NO_MCP=1`, so the AI server's port stays the main session's.
- **Debugging:** `BEZZLE_TRACE` writes `Trace.say` to `%TEMP%\bezzle-trace.log`. Copies started through
  `VM/desktop` run elevated, so `Get-Process` over SSH cannot see their path: look through `VM/desktop`.
  For a crash, set `HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\Bezzle.exe`,
  reproduce it, read the dump with `lldb -b -o "bt 40" --core <dmp> <exe>` in the VM, and remove the
  key. A folder holding macOS `._.` files is removed with `cmd /c del \\?\C:\<folder>\._.` first.
- **A first install, as someone new would:** make a local standard user, sign it in automatically
  (its password as the LSA secret `DefaultPassword`, `DefaultUserName` in Winlogon), restart, run the
  installer in its session through a scheduled task whose principal is that user, launched with
  `conhost.exe --headless powershell …` (a new user's consoles otherwise open in Windows Terminal,
  which covers the screen), and photograph the screen from inside. Afterwards restore the automatic
  sign-in with the real password from `~/.ssh/bezzle-windows-vm.password` and remove the user and its
  profile. Done this way before 1.5 (2026-11-08): the installer registered Windows App Runtime 1.7
  for a new user without administrator rights.
- **What the VM cannot show:** a graphics card (it has no Direct3D 12, so DirectML and its speed are
  untested, and shader fills are drawn by WARP there; `Scripts/subject-matte/README.md` › Measuring
  a graphics card says how Remove Background is measured on a real one), a real x64 PC, Smart App
  Control, and Windows in German, French or Italian.

## The app

It looks like the Mac app: `DESIGN.md` has the Mac's numbers, and `Sources/Bezzle/` builds the same
window from them (Theme, Glyphs, Bar, ToolRail, LayersPanel, Inspector, Rulers, DesignCanvas,
HomeView). Designs live in Documents › Bezzle and are saved 600 ms after each change, as on the Mac;
designs shared through a synced folder (`sharing/people` in the package) are saved as the Mac saves
them (Host/Collaborating.swift). In a folder OneDrive, Google Drive, iCloud Drive or the like keep
in step, only the computer that changes a design writes in it (`SharedSession.changedHere`,
`WindowsCore.save(closing:)`, `persist(force:)`, `writesWhenClosed`), a design away for a moment
is retried for 20 s before it is written again where it was (`WindowsCore.Away`), and copies the
service made beside it ("Poster 2", "Poster (1)") are taken back in and sent to the Recycle Bin
(`FolderCopy.foldCopies`, the shared `FolderShare.fold`): the Mac's rules, `README.md` › The Mac
app › Designs in synced folders. Since 2026-11-16, as there, it writes in such a design only names
of its own: pictures and named versions from the relay wait beside it in
`%LOCALAPPDATA%\Bezzle\Arrivals` (`WindowsCore.arrivals`, the shared `FolderShare.Arrivals`) until
the folder brings them or a change made here takes them in, what a service that keeps each file
apart kept twice inside it is taken back in (`FolderShare.foldCopiesInside`, from `foldCopies`), and
a link to a design already in the designs folder opens it (`acceptLink`,
`FolderShare.design(sharedAs:among:)`). Checked headless in the VM: `bezzle-share <fonts> drive
<design.bezzle> <out>` with `BEZZLE_SYNCED_FOLDER` naming its folder.

A design opens as on the Mac (`README.md` › The Mac app › Opening a design): its tab shows at once,
covered by the window's paper with Bezzle's mark pressed into it (`Sources/Bezzle/OpeningCover.swift`),
and the design is opened on the window's thread once the cover is on screen (`Tabs.open`); the
cover lifts a frame after the canvas is laid out and drawn, or 1.6 s after the design was opened.
The mark's pictures are the shared drawing (`Bezzle/Model/OpeningMarkPaint.swift`, by Skia through
`Host/OpeningPictures.swift`), its name Gelasio's letters, and its moves the shared numbers as the
compositor's key frames (`Host/OpeningPlan.swift`, checked against the Mac's by `Windows/Tests`),
all handed over as the cover shows, so it goes on while the window's thread opens the design
(filmed so in the VM on 2026-11-16: the sheets struck and the name set while the thread was away
for 840 ms). The window lays it over the page in front, under the bar (`BezzleApp.showCover`).
What differs from the Mac: the window takes its new size at once, so the first design too comes
through without the mark when it is open within the grace; the ink runs into the deepest sheet
behind a straight edge, where the Mac's is soft; and the bar's controls come with the design's page,
a moment before the paper lifts. Windows' "Animation effects" off, the mark only fades. To try it:
`BEZZLE_OPEN_AT=2:<design>` opens from home, `BEZZLE_OPEN_SLOW=<s>` holds the design back,
`BEZZLE_SLOW=6` plays the cover six times slower, `BEZZLE_NO_COVER=1` opens as before to compare,
`BEZZLE_APPEARANCE=dark`, `BEZZLE_REDUCE_MOTION=1`, and with `BEZZLE_TRACE` each step is traced,
and every time the window's thread was away for more than 40 ms. Measured in the VM on 2026-11-16
(a debug build, `OpeningTests`' designs): before, a design of 3 layers was drawn
72 ms after it was asked for, and one of 4,860 layers with 60 photos 825 ms, the window meanwhile
grown round home as it was, held still; after, the cover shows in 7 ms, its pictures drawn and its
moves handed over in 6 more, the small design comes through without the mark at 81 to 93 ms, and
the large one is drawn by 862 to 869 ms under its mark, which lifts at 970 ms.

To try it in the VM without anyone at it: `VM/desktop` runs a command in its signed-in session,
and `VM/input.ps1` there moves the mouse and presses keys (real input, as WinUI needs). With
`BEZZLE_TRACE` set, the app writes what `Trace.say` reports to `%TEMP%\bezzle-trace.log`.
`bezzle-render` draws a design's artboards to PNG files (`BEZZLE_TWICE`, `BEZZLE_FIRST` and
`BEZZLE_HOST_TRACE` for drawing twice, after other designs, and tracing what is missing). Given a
file from Adobe XD, Figma, Sketch or Photoshop instead, it brings it in first, as the app does
(into the out folder, or `BEZZLE_IMPORT_TO`), says what came across, and draws the new design.
Given a web page's address (`https://…` or `file:///…`), it brings the page in as Import from a
Website does (`BEZZLE_WEB_WIDTHS=1440,390`, `BEZZLE_WEB_BANNERS` keeps cookie banners,
`BEZZLE_WEB_SCALE` the pixels to a CSS pixel). WebView2 refuses SSH's session 0, so run it in the
signed-in session (a scheduled task); its window is cloaked and never in front.
`BEZZLE_TEXTS=<file>` writes instead how the core measures the design's texts and probe texts in
every family the open fonts stand in for (lines, baselines, widths, fitted frames;
`Host/TextReport.swift`), to compare with Text Kit on the Mac; `BEZZLE_INK=<file>` where letters
are drawn against their baselines.

Web pages are read in WebView2, the Edge engine Windows 11 has (`CBezzleHost/webview.cpp`, its
SDK fetched by `winrt.ps1` into `Packages\webview2`), by the Mac's own page reader
(`Bezzle/Import/WebPageReader.js` and `WebPageAwake.js`, built into the core) and the Mac's
converter (`WebImporter.swift`, `WebPage.swift`, `CSSValues.swift`, linked); `Import/WebCapture.swift`
is the Mac's WebCapture with WebKit's calls asked of the DevTools protocol instead. As on the Mac,
home's From a Website… button, the Bezzle menu's Import from a Website… (Ctrl+Alt+Shift+I), a
link dropped on home and the AI tool `import_website` bring one in (`WebImportSheet.swift`), into
a new design or, with Into, beside the artboards of the design in front.
`BEZZLE_LIBRARY` gives a test copy a designs folder of its own.

Shader fills, a website's WebGL kept live, draw as on the Mac: at any size, in tiles, at the
film's moment (`Renderer.Options.time`). The engine is the Mac's (`Packages/Shaders`, a package
the manifest depends on, which `sync.sh` and the release send into the VM): the same GLSL upgrade,
glslang and SPIRV-Cross, the same working out of every draw, with HLSL and Direct3D 11 in place of
MSL and Metal, on the graphics card or with WARP on the processor where there is none (as in the
VM). The fill is drawn by the Mac's own `ShaderPainting` (`Host/ShaderPainting.swift` links to it),
which `Host/ShaderPictures.swift` lets speak to the engine in the core's types; the browser viewer
keeps its stand-in (`Web/WebShaderPainting.swift`), which Windows leaves out. Nothing is fetched for
it: Direct3D and its compiler, d3dcompiler_47, come with Windows. The two platforms draw the same
frames to within a level or two (`Packages/Shaders/README.md` › Agreement;
`VM/shader-agreement.sh` compares them), and `swift test -j 2` in `Packages\Shaders` runs the Mac's
engine tests here. The VM has no graphics card, so it has only ever drawn them with WARP.
Direct3D draws a fill's draws onto its canvas and no more yet: a fill with passes into textures,
steps that build on the frames before, depth, stencil, instances or textures of numbers
(`ShaderFill.beyondPlain`, which the Mac draws since 2026-11-14) is refused by name and shows its
picture, in the design and in a film (`Packages/Shaders/README.md` › What WebGL does that this
does not).

Every web view keeps what pages store in Bezzle's own WebView2 profile, `%LOCALAPPDATA%\Bezzle\Web
Pages`, apart from Edge's, as the Mac keeps a data store of its own: a sign-in made in Bezzle's
browser holds for the pages imported after it and from one launch to the next, and the pictures
fetched for a page go with its cookies (`Network.getAllCookies`). `BEZZLE_WEB_PROFILE` gives a test
copy a profile of its own. Bezzle's browser is the Mac's (`Import/WebBrowser.swift`, after the Mac's
of the same name; the window is `Sources/Bezzle/BrowserWindow.swift`, with the Mac's bar): the
sheet's Open the Page… shows it, to sign in and click through to the screen wanted, Import brings
the page in as it shows it, and Pages lists the site's pages to bring several in together. WebView2
wants a view in a window to live on that window's thread, so the browser's one web view lives on
the app's own (`bz_web_host_here`, `bz_web_open_shown` in `CBezzleHost/webview.cpp`), asked from
other threads as page reads are. It is laid over the browser's window under the bar in a window of
its own that the browser's owns, moved with it, or, while a page is read at its full size or an
assistant browses, kept out of sight in a cloaked window (`bz_web_place`). Not a child window of
the browser's: WinUI sends a child window in its window none of the pointer or keys, though it
shows (measured 2026-11-13 with a page that notes its events). Nothing in the window can lie over
the page, so while the list of pages is open the page waits out of sight and a picture of it holds
its place. Its hands (`WebPageHands.js`) and the recorder of a page's WebGL (`WebPageGL.js`) are
the Mac's, built into the core, and every page read gets the recorder too; what it works out
without asking a browser (the pages offered, what new artboards are called and where they go, which
cookies go with a picture) is the Mac's own `Bezzle/Import/WebPages.swift`, linked. The AI server's
`browse` drives it, and `import_website` takes `shown`, `urls`, `design` and `name` as on the Mac. A
WebGL canvas comes in with what it draws kept as the layer's shader fill (`WebGLScene.swift`, linked),
its picture as the poster, when the Mac's `ShaderPainting.settled` says Windows can draw it again:
a page that draws through framebuffers or needs its depth test comes in as a picture here, where
the Mac keeps it live.

To try the browser, sign in on a page of your own, never with a real site's password: a local page
with a form that sets a cookie, served in the VM (any small server on 127.0.0.1), run in the
signed-in session, as WebView2 refuses SSH's session 0.

Remove Background is the Mac's (`Host/CutoutMaker.swift`, `CutoutHand.swift`, `Cutouts.swift`,
`SubjectMatte.swift`, `MatteWays.swift`, copies of the Mac's CutoutMaker, CutoutTool, CutoutOperations,
SubjectMatte and SubjectModel):
the same model, the same edges and colours, the same outlines, and cutouts named as the Mac names
them, so a design shared between the two finds the other's. What differs is how the subject is
found: the Mac asks Apple's Vision, which Windows lacks; here the matte's own regions are the parts a
click keeps or drops, so subjects that touch are one part. A photo in wider colours than sRGB's
(an iPhone's Display P3, Adobe RGB) is cut out in its own, as on the Mac: the cutout carries the
photo's profile and keeps its numbers, and only the model sees it in sRGB. Checked against the Mac
on 2026-11-14 with photos made for it, patches of known colours in each: a P3 PNG's cutout has
the photo's profile byte for byte, the patches' very numbers, and wherever the subject is solid
not one colour value other than the Mac's cutout by the same matte; a JPEG's differs only as the
two read JPEGs (as much for an sRGB JPEG). Grey and CMYK photos are cut out in sRGB, as on the
Mac, and so are those whose light goes past white (`ownColors` in `CBezzleHost/host.cpp`).
`bezzle-render <fonts> cutout <out>` cuts
the photos `BEZZLE_PHOTOS` names out as Bezzle does and says the way each took, how long the
model and the matte took and what memory the tool held (`BEZZLE_MATTE_MODEL`,
`BEZZLE_MATTE_DEVICE=cpu` or `gpu`, `BEZZLE_MATTE_ROUTE` for one way alone, `BEZZLE_MATTE_MACHINE`
for another PC's ways, `BEZZLE_MATTE_LEFT` for those of a PC with so many gigabytes left,
`BEZZLE_MATTE_LEAN=1` for the processor's lean way, `BEZZLE_PICKS`, `BEZZLE_MATTE_RAW` for the
matte's floats). The app says the same of each matte in its trace (`BEZZLE_TRACE`), which is how a
graphics card is measured on a real PC (`Scripts/subject-matte/README.md` › Measuring a graphics
card). Which way a PC takes, what it remembers of the ways
and what cutouts are called ask Windows nothing (`Host/MatteWays.swift`, `CutoutCells.swift`), so
their tests run on a Mac too: `swift test --package-path Windows/Tests`.

Vectorize is the Mac's: its engine is the Mac's own package, `Packages/Vectorizer` (Foundation alone,
always built optimized, a dependency of the core here, which `VM/sync.sh` and the release send into
the VM beside `Windows`), and the group made of a tracing is the shared model's
(`Bezzle/Model/Vectorizing.swift`: the settings, which layers may be traced, how a layer is read, the
group in the picture's place with its id, the picture remembered while the design is open and
given back where the group lies). `Host/Vectors.swift` is the Mac's VectorOperations on the core's
statics, `Host/VectorHand.swift` its VectorTool (the pencil across a picture that takes a while,
then its pass with the outlines behind it), `Sources/Bezzle/VectorCard.swift` its Vector card (the
dial is Detail; colours, outlines, Detail, Picture held to see the picture, × back to the
picture). What differs is only how the layer is read: Skia draws it where the Mac's Core Graphics
does, and the reveal draws the layer again each frame where the Mac keeps its picture. A dial's
drag shows quick tracings as previews (`preview`, not part of the drag: `endGesture` sets them
aside, `aroundVectorPreview`) and changes the design once, after it is let go. Vectorize is in the
canvas's right-click menu (and Back to Picture), a chip in the inspector, and the AI tool
`vectorize`. `bezzle-render <fonts> vectorize <out>` traces the pictures `BEZZLE_PICTURES` names
as they are, an SVG each to compare with the Mac's `vectorize-cli trace`, and as a layer Bezzle
reads and makes a group of, listed in `<name>-layers.txt` as the Mac's ParityTests (`vectorizing`)
lists it (`BEZZLE_VECTOR_FRAME=w,h`, `BEZZLE_VECTOR_TURN` for a turned ellipse, `BEZZLE_DETAIL`,
`BEZZLE_COLORS`, `BEZZLE_SMOOTHING`). Measured so on 2026-11-13: from the same pixels the engine
writes the Mac's SVG byte for byte (the engine's eight samples and VectorTests' two pictures; a
JPEG differs as Windows decodes it otherwise); Skia reads a layer at its picture's own pixels as
Core Graphics does, so its group is the Mac's layer for layer, and where the picture is drawn to
other pixels (stretched, or cut by a turned ellipse) its outlines move by hundredths of a point.
The engine's own tests run here too: a package of `Sources/Vectorizer` and `Tests` alone (its
`vectorize-cli` needs Image I/O), `swift test`.

Animate, the fourth mode (the bar's switch, Alt+A), is the Mac's (`README.md` › Animate). The film
is in the design and shared already (`Bezzle/Model/Motion.swift`, `Film.swift`); what the timeline
reads of it and where the camera looks to show layers are shared too (`Model/FilmKeys.swift`). The
Mac's store functions are ported in `Host/Animating.swift` (`WindowsCore.FilmDesk`, one for each
design's `DesignSession.film`), its canvas tool in `Host/MotionHand.swift` and its timeline's hand in
`Host/FilmHand.swift`, their marks and menus as data for `Sources/Bezzle/FilmView.swift`,
`FilmTimelineView.swift` and `AnimatePanel.swift`. Where the Mac makes two changes in one gesture
(the camera flown somewhere, the scene turned on its pad) they are one change here, since a gesture
on Windows makes each change again from where it began. Alt held while a layer is moved lifts it
nearer or lowers it (the shared DepthPushing, Control on the Mac). A shape's Draw and Shape
(`README.md` › Animate, Shapes) are the Mac's too: its points are moved in the film, and added and
taken away there (a click on the outline, Delete), with the shared pen through
`Host/FilmPoints.swift`, the Mac's FilmPoints, which the canvas hand takes in hand with a double
click and the Pose card's Edit Points, and puts down as `Host/FilmPointRules.swift` says. Where a
click would add a point the pen's pale point shows on the outline; the pointer stays the arrow,
where the Mac's is its pen with a plus. The Pose card's From… chip gives the shape another's
outline at the playhead (`FilmDesk.takeShape` in `Host/FilmPoints.swift`, the Mac's
`DocumentStore.takeShape`); a shape pointed at in its menu lights in the layers list, where the Mac
outlines it on the canvas, as the film's canvas hand draws only what its own pointer is on.
The Draw move's chip draws its line part of the way with `Host/DrawnLine.swift`, as WinUI cannot
cut a curve short. Both rule files ask Windows nothing, so `swift test --package-path Windows/Tests`
checks them on a Mac (with Xcode's developer directory, whose Swift has the testing macros). The film is drawn as the Mac draws it:
each piece is a picture the Mac's own `FilmPictures` (linked into `Sources/BezzleCore/Film/`) draws
once, laid into the frame through the camera's 3×3 map by Skia (`bz_film_frame` in host.cpp) where
the Mac's graphics card does it, and only for what shows of the artboard; a part is drawn sharper
where the camera is close once the film rests (`Host/FilmStage.swift`).

Scrubbing and playing keep pace as the Mac's do (`README.md` › Animate, Keeping it quick), each
lesson where it applies to a stage put together on the processor. What is placed at every frame
is found once (`Node.filmLayers`). A piece whose insides move (a moving shader) is drawn again at
every moment, so only as far as it shows through the frame and as sharp as it shows there
(`FilmStage.seenPart`, the Mac's). No sharper part is drawn while the film moves from one frame to
the next or a hand is on the design: the Mac draws its parts away from the main thread, Windows
draws on it, so they come with a frame asked for once the playhead has rested an eighth of a
second (`FilmStage.owesParts`, `FilmView.sharpen`). Skia lays the frame out in bands, a thread
each, for every processor but one (`bz_film_frame`; `BEZZLE_FILM_BANDS=1` lays it out in one, to
compare: the same picture, but for a pixel or two in ten thousand that come out one step of 255
off where the camera tilts). The playhead tells of itself apart from the film (`DesignSession.listenToPlayhead`,
`FilmDesk.moved`), so a step of a scrub moves the timeline's playhead and makes none of its lines
again, the header is painted only where it changed, and the marks on the canvas that are as they
were stay (`FilmView.lay`; the way, its beads and the home outline are kept in `MotionHand` until
the design changes). The Animate cards show `FilmDesk.panelTime`, the playhead caught up with
thirty times a second at most, and each number, bead and summary puts itself right in place
(`Inspector.filmFollowers`): making the cards again, as every other change does, took longer than
a frame.

The timeline is looked at closer as on the Mac (`README.md` › Animate, The timeline looked at
closer). Which part of the film shows is `FilmDesk.window`, the shared `FilmWindow`: the viewer's
own and never saved, nil for the whole film; another artboard's film is seen whole first, and a
film that gets shorter is not looked at past its end. Over the lines or the ruler, the wheel with
Ctrl held looks closer about the moment under the pointer, as it zooms the canvas, and so do two
fingers pinched on a touchpad (told as the wheel with Ctrl said to be held while no key is down);
turned sideways, or with Shift, it moves a film looked at closer along and stops at the film's
ends; up and down stays the lines' own scrolling (`FilmTimelineView.wheel`, `FilmHand.zoom`,
`scroll`). Back to the whole film: looking from further off stops there, and two clicks on the
stroke under the lines, which shows which part is in sight, go there at once (`showWhole`). The
playhead stays in sight: `seek` brings the part along (not under a hand on the playhead), and a
film playing out of it turns the page, the playhead an eighth in. `FilmDesk.looked` tells of
another part showing apart from everything else, and only then are the lines made again, once
(`FilmTimelineView.owesLines`): once a page while a film plays and never at every frame, and a
step of a scrub still moves the playhead alone. Keys, bands and the film's end are moved by the
moment under the pointer, not by how far it has gone, and what is dragged past either end of the
part shown waits there while the sheet creeps along under it, a step with every frame
(`FilmHand.creep`, which the hand asks the view for through `creeping`). The ruler thins out and
fills in as the Mac's and makes only the strokes in sight. That, the stroke under the lines, what
a turn of the wheel does and how fast the sheet creeps are numbers in and numbers out
(`Host/FilmSheet.swift`), so `Windows/Tests` checks them too. The card grows and shrinks with its
lines on the Mac's spring (`Motion.spring`), its shadow stretched along and drawn anew once it
rests; at once under a hand on the sheet and while the film plays. Lines do not glide to their
places, nor the seconds when the scale changes: either would make every line again at each frame.

How a layer looks is keyed in the shared model (`README.md` › Animate, Looks), so the stage, the
movie and the AI server's pictures of a film show keyed fills, borders, corners and shadows by
themselves, and the timeline lists a line for each look that has keys. A key on such a line is
that look's alone, as on the Mac: picked, dragged, paced and deleted without the layer's other
keys of that moment (`FilmKeyRef.look`, `FilmDesk.tracks(of:)`). Two clicks on the line and Add Key
Here set or take that look's key (`FilmDesk.toggleLookKeys`), the bead that holds a pose keys the
looks that have keys too, and a key for what the design no longer has (a fill turned off) is
faint. Windows has no cards at the playhead, beads or corner dots yet, so a look cannot be keyed
by hand there; the AI server keys looks and reads them back as the Mac's does (`animate` with
`look` and `which`, `get_animation`'s `looks`: `MCP/MCPAnimateLooks.swift`, the Mac's file). For a
test run, `look=fill:ff0000` (or `border:`, `width:`, `corners:`, `shadow:`)
keys what is picked at the playhead through the shared `Node.poseLooks`, and `open=Card 2` opens
a layer's lines. Looked at in the VM on 2026-11-14, the colours being what the shared model's
rule gives, worked out apart from it: a fill keyed red at 1 s and blue at 4 s shows #4e46d4 on
the stage at 2.5 s, and playing goes through purple; keyed red at 1 s and blue at 5 s, come to
evenly, it is #8c53a2 at 3 s in the AI server's `render` and in the frame of a movie saved from
the same copy.

To measure, as on the Mac: `BEZZLE_ANIMATE=3` and
`BEZZLE_FILM='6:scrub=0,10,8;16:pick=Card 1;17:scrub=0,10,8;27:pick=camera;28:scrub=0,10,8;38:pick=;39:start;41:watch=8'`
(`Sources/Bezzle/AnimateHooks.swift` has the steps) drag the playhead through a copy's film and
back with every frame of the screen, and `BEZZLE_SCRUB_OUT=<file>` takes what each scrub or watch
found: steps a second, the gaps between them, how busy the main thread was, the pictures and
parts drawn, and where the time went (`Host/Probe.swift`, since the VM has no profiler to ask).
`zoom=4`, `along=-200`, `whole` and `timeline` look at the timeline closer, move it along, show the
whole film again and write which part shows, without a wheel or a touchpad.
Measure the release build, in the desktop session, the copy started with a library of its own.
Without the app, `bezzle-render` lays the first film out as the canvas does and says what a scrub
costs the stage alone: `BEZZLE_STAGE_AT=0;1.5;4` (frames written at these moments, and beside each
the frame as a scrub passing shows it, `-moving`, where they differ), `BEZZLE_STAGE_SCRUB=0,10,60`
(from, to, steps), `BEZZLE_STAGE_SIZE=1600,900`, `BEZZLE_STAGE_PICK=<names;…>` and
`BEZZLE_STAGE_ZOOM=5` (that many times closer than the artboard fitted, where parts are needed).

Save as Movie and the AI
server's `export` with format mp4 write H.264 in an .mp4 through Media Foundation's sink writer
(`Host/FilmMovie.swift`, FilmExport's reel ported, and `CBezzleHost/movie.cpp`): High profile, a
key frame every second, BT.709 and sRGB said, what says how it is read put before the pictures
once the file is whole. Windows' encoder keeps to H.264's levels, up to 5.2, and refuses a movie
that asks for more (0xC00D36B4 as the writer's input is set): no more than 172 frames a second at
any size, and no more than 2 073 600 macroblocks a second, which is 144 frames a second at 2560 by
1440 and 64 at 3840 by 2160 (`Host/FilmRates.swift`, with what was tried in the VM). A movie asked
for with more is made with the most its size takes; the Mac's, whose encoder asks for no level,
goes to 240. The AI server's
`get_animation` and `animate` are the Mac's (`MCP/MCPAnimate.swift`), `render` takes `time` and
`frames`, and its `animate` prompt is there. `bezzle-render` draws a design's films at moments and
saves them as movies, headless: `BEZZLE_FILM_AT=0;0.5;1.5` (seconds) and
`BEZZLE_FILM_MOVIE=2,60` (scale, frames a second), into the out folder.

3D is the Mac's (`README.md` › 3D), all of it from the shared model. Several layers lying together
turn as one body from the 3D card too: its pad, its drag, its X, Y and Z, Lay Flat and its switch
go through the shared `turnInDepth` and `layFlat` (`turning` in `Host/LookEditing.swift`), and the
card reads the body's lead. For a group the card has the switch Layers keep their depth
(`Node.keepsDepth`). An artboard is looked at from the side with Alt, the Mac's Control: Alt
dragged from beside the layers turns the look (Shift in fives), a click there with Alt, Escape
with nothing picked or the word by the artboard's top right corner looks from the front again.
`Host/Looking.swift` has it: the looks are the open design's own (`WindowsCore.sceneLooks`, one of
the values a tab keeps), handed to `doc.looks` whenever the design is set, so undo, redo and a
gesture made again leave them alone, and gone when the design is seen as a prototype, inspected
or animated. `WindowsCore.LookHand` is the Mac's LookTool for the canvas, which draws its posts
and its word. Windows draws the part of an artboard in sight, including what reaches off the page
(`WindowsCore.drawn`, `picture(of:part:scale:)`). Whatever leaves the canvas reads `doc.front`.
The AI server's `turn_layers` and `keepsDepth` are the Mac's.
`bezzle-render <fonts> depth <out>` tries all of it without a window (`Host/DepthCheck.swift`: the
card's changes, turning from a side, a group that keeps depth picked, drawn and played, the look
with its posts and word, and the AI server), and `BEZZLE_LOOK=-45,0` (degrees across, down) draws
a design's artboards as the canvas shows them from there. `VM/depth-agreement.sh` compares
Windows with the Mac's renderer: `VM/DepthTruthTests.swift`, a test the script copies into
BezzleTests for the run, writes two designs and the Mac's pictures of them from the front, from
two sides and as films, `bezzle-render` draws the same in the VM, and `VM/depth-compare.py` says
how far each pair is apart. Measured so on 2026-11-14 at two pixels to the point: a group that
keeps depth, a body and an artboard seen from the side differ from the Mac as the same scenes
do from the front and with the group as one card, on edges alone (a mean of 0.01 to 0.11 of 255
a channel, 0.03% to 0.37% of the channels further apart than 8), and an artboard that does not
clip reaches as far off the page on both.

Files from other apps are brought in by the Mac's own importers (`Bezzle/Import`, linked into
`Sources/BezzleCore/Import` beside the Windows stand-ins for what they take from AppKit, Image I/O
and Core Text); home's Bring In… button, the Bezzle menu, files dropped on home and a file given
on the command line all bring one in.

## Shipping it

Bezzle for Windows is a download from bezzle.ch beside the Mac's, unsigned (Erik, 2026-11-07: no
Store, no paid certificate), so Windows asks once, for the installer someone downloads, whether to
run an app from an unknown publisher (More info, then Run anyway).

- **The installer** (`Installer/`) is made with Inno Setup 6, pinned with its SHA-256 like everything
  `Installer/fetch.ps1` fetches (Inno Setup, WinSparkle, Microsoft's Windows App Runtime installer).
  `Installer/make-installer.ps1 -Version 1.4.2 -Build 20261108.1200 [-Arch x64]` takes the app
  `build.ps1 release` laid out, puts the Swift runtime and the C++ runtime beside Bezzle.exe (whatever
  it needs that Windows has not), strips Bezzle.exe's debugging information (kept beside the
  installer as `Bezzle-<v>-<arch>.pdb.exe` for reading crashes), writes its icon and version into it,
  and compiles `Installer/Bezzle.iss`, Remove Background with it: the subject matte measured (it
  refuses any other) and ONNX Runtime and DirectML for its architecture, which take the installer
  from about 99 MiB to about 490 MiB. It refuses an app without the welcome tour's two pictures (its
  lake photo and its logo to trace), which are painted on the Mac (`Resources/make-welcome-photo.sh`,
  run by `VM/sync.sh` and by the release) and laid into `Bezzle.resources` by `build.ps1`: up to 1.7
  the release left the photo out. It installs for the person alone, with no administrator, into
  `%LOCALAPPDATA%\Programs\Bezzle`: a Start menu entry, an entry in Settings › Apps to remove it, the
  `bezzle:` links, Open in Bezzle on a `.bezzle` folder in Explorer, and the Windows App Runtime 1.7
  when it is missing (Microsoft's own installer, run quietly, per user). `-Name 'Bezzle Test'` makes a
  copy that installs beside Bezzle's own (`%LOCALAPPDATA%\Programs\Bezzle Test`).
- **Updates** come through WinSparkle, as the Mac's through Sparkle, from
  https://bezzle.ch/updates/windows/appcast.xml, signed with the Mac's EdDSA key. Only an installed copy
  has them: `-Feed` and `-PublicKey` put WinSparkle.dll beside Bezzle.exe and the feed and key into its
  resources (`Sources/Bezzle/Updates.swift` loads it when it is there). An update runs the new installer
  with `/SILENT /UPDATE=1` from the feed, and Bezzle opens again. WinSparkle has no deltas: each
  update downloads the whole installer, subject matte and all.
- **About Bezzle** (the Bezzle menu) lists what Bezzle is made with; the licences are in
  `Credits/licenses`, which `build.ps1` and the installer put beside Bezzle.exe.
- **A release** is `Scripts/release-windows.sh` on the Mac (a dry run unless given `--publish`): it
  builds the pushed commit in the VM (`C:\src\bezzle-release`), makes the installers for x64 and Arm64,
  signs them and writes the feed; with `--publish` it attaches them to the GitHub release
  `windows-v<version>` of mfrports/bezzle-web, commits the feed there, waits for bezzle.ch to serve
  both and tags the commit. Building takes 30 to 50 minutes an architecture, so a dry run keeps its
  installers (`~/Library/Caches/bezzle-release/windows-made`, the last commit's only), and `--publish`
  of the same commit sends those out without building again, once it has checked they are whole and
  were made for that version, feed, key and open fonts (`--rebuild` builds anew). Its header says
  what it needs; `CLAUDE.md` › Releases has the order, the Mac's release first, at the same version
  and with the same notes.
