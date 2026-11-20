# What is left

Everything known to be missing, unfinished or unchecked, by area. Each item says where it lives
and when it was found. A session that leaves a gap adds it here; one that closes a gap takes the
item out in the same commit. Larger lists of their own stay where they are and are linked from
here, such as `Web/README.md` › Not done in the prototype.

Items marked *(from notes)* were carried over from session notes and not checked again when this
file was made (2026-11-14): look before starting on one.

## Animate

### Mac and shared

- **Shape keys that go with the design** (2026-11-14: a layer resized, rounded or flipped in the
  design takes its Shape keys along, `BezzleDocument.followOutlines`; 2026-11-15: rounded and
  squared again, exactly; a new copy of a component made at another size grows its keys; a key
  set for the old size while someone else resizes the shape grows with it once the two meet). Left:
  that key is put right by a Mac that had it when the resize came; if every such Mac closes the
  design before the resize reaches it and never opens it again, the others keep it unscaled. Two
  live copies were never tried in a room for it, only the model's merge, the store with a second
  Mac in memory, and a synced folder opened again. A copy shown as another variant whose layer
  has another size keeps the keys its layer had, unscaled: the layer is another one there, with
  no layer before it for `followOutlines` to go by (`Components.switched`). A key made on a
  rounded rectangle itself, or one grown with it while it was rounded, is none the square could
  have made: squared again, each corner goes as the place on the curve nearest it went, and a
  little of the reshaping is lost as before.
- **Outlines with other points** (2026-11-14: points added and taken away at the playhead, and
  From… in the Pose card's Shape row gives a shape another's outline; 2026-11-15: the key keeps
  the other's own points). Where a key either side has the same runs and would go into it point
  by point otherwise than they lie along each other, the outline taken still has points more (a
  square given a circle has eight). Points taken in hand between two keys are the outline as it
  is then, with the points the stretch gives both. From… takes the other's outline as the design
  places and turns it, in depth too (2026-11-15), not as the film poses either at the playhead
  (Move, Turn, Scale, Tilt, Swing); under a turn in depth a curve is carried by its handles, so a
  strong perspective takes it only nearly. It offers only shapes on the film's own artboard: others
  would need the menu grouped by artboard (`ShapeFromChip` in `AnimateInspector.swift`) and their
  outline placed from another artboard's eye. Its menu and the hover preview were never looked at
  in a running window; adding and deleting points is driven through canvas events in tests only.
- **Outline keys in Bezzle 1.7:** it shows the design at such a key and keeps the key whole. Where
  the design's outline gets more points while such a key keeps its old count of noughts (points
  added in 1.7, or one person keying while another edits the design's points), 1.7 shows the
  stretch to that key bent; this Bezzle reads the key right and rewrites it at its next change.
- **The camera's focus** (2026-11-14: Focus and Blur on the Camera card, Focus the Camera Here,
  `Bezzle/Model/FilmFocus.swift`; `README.md` › Animate › The camera's focus has the numbers).
  The stage shows it through a lens of eight bits, so a wide blurred gradient can band on the
  stage where the movie does not. Under a quick scrub the lens shows the last frame made, a
  frame behind the handles, and one sharp frame can show before the first lens frame. While
  playing on the 75 Hz screen the lens made 72 frames a second.
- **The lens's cost:** about a millisecond for every plane blurred by itself. Never measured on a
  screen of two pixels to the point; the composer alone took 20 to 22 ms a frame there for
  fifteen lifted cards at 2880×1800. A cheaper blur for planes the camera faces has another
  edge than the ramp's (up to 9.7 of 255 apart), so it needs a cross-fade to the ramp or a blur
  of our own.
- **The camera's focus, as chosen and not built:** the camera's blur is as wide as a layer's own
  Blur of the same amount but not the same shape along an edge (up to 4 % of tone). No shapes
  of light in the blur, no pointing at the canvas to focus (a card does it), and the pad dots
  only the line along which the sheet is sharp. The German, French and Italian words (Fokus and
  Unschärfe, Mise au point and Flou, Messa a fuoco and Sfocatura) were not read by a native
  speaker. Pictures made with `BEZZLE_SNAPSHOT_LAYERS` do not show the lens: photograph the
  window. Seen in a running window once, in German.
- **The camera's focus in Bezzle 1.7:** it keeps both tracks through the file and through
  sharing, counts their keys for the film's length and shows the film without the blur. Its
  Remove Motion on the camera leaves them; clearing the whole artboard's motion takes them.
- **Looks keyed in Animate** (2026-11-14: fill and text colour, gradient colours and their
  places, border colour and width, a rectangle's corners, shadows; `Bezzle/Model/LookMotion.swift`).
  Not keyed: picture and shader fills, on and off, adding and taking away, dashes, a border's
  side, a shadow inside or outside, blend, smooth corners, a gradient's line, ends and count of
  colours.
- **Keyed looks, as chosen:** a keyed colour is a colour of its own, so it cannot be a named
  colour or a variable and does not turn with a dark artboard (only the keys the app gave follow
  the design). A rectangle whose Shape has keys keeps the design's corners: its Corners keys wait
  and show faint, the card and the corner dots are not offered, the AI server refuses; rounding
  it over time takes a Shape key with rounder corners. Hover previews of presets and styles do
  not show on the film, and no ready-made move changes a look. A rectangle's corner dots show
  only for one picked rectangle drawn as a piece of its own and at least 48 points each way.
  A look change made in Animate that no key holds (dashes taken off by a weight's preset, a fill
  turned off) changes the design for the whole film, as before, and the card of that look says
  "Changed in the design" for five seconds in place of its summary (the first card there is,
  where the change took its own away). A change that keys something drops the rest without a
  word: a dashed border given another weight keeps its dashes.
- **Keyed looks, unchecked:** photographed in German at one window size before the marquee, the
  outline keys and the gentle tones were on main; gradient colours, the beads, the corner dots
  and the marquee over a look's line are driven by tests only, and so is the card's "Changed in
  the design", never seen in a window (in German, French or Italian it may be cut short at the
  card's width). Scrub speed was measured on 1.7's
  base only (120 steps a second, longest gap 11.1 ms, 49 layers of which 7 change look), not
  since the movie's sixteen-bit pictures; a movie with keyed looks was made in a test only.
  Restacking or removing fills while another person keys them was tested through the model's
  merge, never with two copies in a live room.
- **Look keys in Bezzle 1.7:** kept, and the design's look shown. A whole-layer retime there
  leaves them at their old moments, Remove Motion takes them, and a layer with only look keys
  has no line.
- **The timeline looked at closer** (2026-11-14): the pinch, two fingers moving it along, the
  double tap and the creep under a drag were driven by tests and by made events in a test copy,
  never felt on a trackpad (the creep's pace, the four times of the double tap, the catch at the
  whole film). A pinch over the canvas while the timeline listens was checked in `FilmZoomTests`
  only. The Bounce number and the Spring chip were photographed in German at one window size.
- **Gentle tones in a movie** (2026-11-14: kept in sixteen bits until the one cut to the movie's
  steps, and HEVC with ten bits beside H.264). Still cut twice, with eight bits: a layer turned
  in depth inside a piece (`Depth.swift`), and a piece holding Plus Lighter, Plus Darker, Color
  Dodge, Color Burn, Hue, Saturation, Color or Luminosity, or a background blur made lighter or
  darker. Core Graphics casts a shadow's mask with eight bits even then. Such pieces take twice
  the memory in a movie. Not built: grain in the design, the only remedy once a video site packs
  a movie again with eight bits (tried with x264 standing in for a site, never with a real one).
- **HEVC with ten bits, unchecked:** read back with AVFoundation, ffmpeg and headless Chrome, but
  not opened in QuickTime Player's window, Safari, iOS, Windows, Firefox or VLC; "This Mac cannot
  save a movie of this kind" was never seen for real.
- **Bands outside movies** (measured 2026-11-14, not changed): shadows and blurs in an exported
  PNG are plain eight bits, a JPEG wipes out the dither Core Graphics gives gradients, and what
  the stage shows on screen was not measured beyond its pieces being eight bits.
- **The marquee over keys** (2026-11-14: a drag from the timeline's bare sheet picks the keys it
  touches; the ruler and the playhead's own line move the playhead). Escape is read from the
  keyboard's state (`FilmHand.escapeOnKeyboard`), because the app hears no key while SwiftUI
  follows a press: driven by tests with a stand-in for the key, never with a real key, never in
  the sandboxed release build. Never felt: drawn once in a background copy by made presses; the 3
  points before it begins, the 4 within which it catches a bead and the 4 that take the
  playhead's line were not tried with a pointer.
- **The marquee, not built:** it begins only on bare sheet: where every line's bar runs the
  film's length and the card shows no spare line, there is none to begin on. Shift is read as
  the press comes.
- **Escape under every drag, the lines scrolled under a marquee, copying keys** (2026-11-15,
  `README.md` › Animate): driven by tests only, never felt. Not tried: Escape with a real key
  under a key, a band, the playhead or the film's end; the pace the lines scroll at; whether
  SwiftUI's drag goes on, and tells points down the lines, while the card's `ScrollPosition`
  scrolls them under a pointer at rest (the hand counts on it); the Edit menu's items in a
  running window (checked through `validateMenuItem` only). The scrub was not measured again
  since the hand asks the keyboard for Escape sixty times a second under every drag, not only
  under a marquee.
- **Copying keys, as chosen:** Option held as a bead or a band is pressed takes copies, so held
  before the press it no longer only steps finer (held once the press is under way it still
  does). Keys copied stay until other keys or layers are copied in Bezzle; copying in another
  app leaves them, and they never reach the pasteboard, another app or the AI server. Paste in
  Animate never pastes layers. Duplicate puts the copies half a second after the last key
  picked. A camera's keys go onto the camera of whichever film is on the desk.
- **Driving a copy:** `press=` replaces `acceptsFirstMouse` on the kind of view under the point
  while the press lasts (Debug only).
- **Unchecked:** a movie saved from the sandboxed build onto another disk, where it is copied into
  place instead of renamed. (Checked 2026-11-14 with a sandboxed copy of the Debug build and
  `BEZZLE_FILM` › `movie=`: a new movie through the save panel, one replacing another, and a place
  the sandbox refuses, which is said and leaves nothing behind. The save panel brings the copy to
  the front, so `movie=ask` is for when Erik is not at the Mac.)

### Windows

Brought up on 2026-11-14 (`Windows/README.md` › Animate): scrubbing and playing keep pace (in
the VM, a film of 35 pieces: 11 steps a second before, 44 now; with the camera picked 7 before,
28 now; playing 31 frames a second before, 43 now), the timeline looked at closer, a spring's
bounce, Shape keys that go with the design, points added and taken away, From…, Tilt and Swing
of several layers as one body, a look's key that is that look's alone, and the AI server keying
outlines and looks. What is left:

- **A look cannot be keyed by hand:** no look cards at the playhead, no beads and no corner dots
  (the AI server can key looks). To build: `LookCards.swift` reads `WindowsCore.looks(ids)` and
  changes through `WindowsCore.change`/`preview` in `Host/LookEditing.swift`; read through
  `Node.looked(at:)`, route through `Node.poseLooks`, add to `Inspector.showAnimate()`;
  `FilmDesk.poseLook` shows the call.
- **Shape keys and others' changes:** `Host/Collaborating.swift` › `showChangesFromOthers` does not
  call `followOutlines(merging:)` yet, nor `Editing`'s undo `BezzleDocument.step(from:to:onto:)`
  (2026-11-15, Mac: `DocumentStore.showChangesFromOthers`, `init(opening:)` and `record`), so on
  Windows a key set for the old size while someone else resized the shape stays unscaled until a
  Mac that had it puts it right.
- **The timeline has no marquee over keys,** and bare sheet dragged still moves the playhead
  there. The shared `FilmMarquee` (`Bezzle/Model/FilmKeys.swift`) is tested and there to use.
- **No Escape under a drag on the timeline, and keys cannot be copied** (the Mac has both since
  2026-11-15). What pastes keys is the Mac's store (`Bezzle/Store/AnimateClipboard.swift`:
  `place`, `taken`, `pasteTargets`), to move into `Bezzle/Model` for Windows to share.
- **Several picked have no handles as one body on the canvas:** `MotionHand` grows, turns and
  tips one layer only (the Pose card and the AI server pose bodies). The shared `FilmBody` and
  `BezzleDocument.poseBody` (`Bezzle/Model/FilmBody.swift`, tested in `FilmBodyTests`) and
  `poseInDepth` are there to use, as the Mac's `MotionTool.body` and its `bodyScale`, `bodyTurn`
  and `bodyDepth` drags use them.
- **A layer dragged inside a group turned in depth lags the pointer** (keeping depth or one
  card), and one the design lifts goes a little too far under a tilted camera:
  `MotionHand.travel` lays the pointer's way across the sheet at the layer's Lift. It should
  cast the pointer onto the plane the layer moves along, as the Mac's `MotionTool.travel` does
  since 2026-11-15: `scene.board.filmMovePlane(of:at:pieces:)` once as a move or a bead's drag
  begins, then `plane.travel(from:to:)` at each step (`Bezzle/Model/FilmMovePlane.swift`,
  shared and tested in `FilmMovePlaneTests`).
- **A movie's gentle tones** are still rounded twice (pieces and the frame in eight bits, then
  NV12), and there is no ten bit choice; the AI server's `codec` is the Mac's alone. What it
  takes is in e652531's report: `bz_film_frame` composing in sixteen bits, the stand-in pictures
  carrying depth, P010 and an HEVC Main 10 encoder where the PC has one, measured with
  `FilmBandingTests` and `TEST_RUNNER_ANIMATE_BANDING_MOVIE`.
- **The camera's focus is not drawn:** Windows keeps the keys, shows Focus and Blur as lines in
  its timeline through shared code, and plays such a film sharp all over. To build:
  `Host/FilmStage.swift` (`filmPiece`) and `Host/FilmMovie.swift` draw `FilmPlacement.soft`
  (blur by `across·x + down·y + level` frame points, pieces in one plane, `FilmSoft.matches`,
  laid together and blurred once; `bz_film_piece` has one `blur` only, so a first step is
  `soft.blur(at:)` at the piece's middle, and a ramp takes more in Skia); `FilmDesk` gets
  `focusCamera(on:)` as `DocumentStore.focusCamera` does it (`Node.focus(on:at:pieces:)`,
  `FilmCamera.usualBlur`, `Node.filmHasDepth`); `AnimatePanel.swift` gets rows for Focus and
  Blur after Swing, a Focus the Camera Here card under Fly the Camera Here and
  `FilmLens.sharpLine` on the pad; `MCPAnimate.swift` gets `focusOn` and the descriptions, and
  would give its one-key warning for `cameraBlur`. Nothing of the camera's focus was built or
  run in the VM; See the Whole Artboard there leaves focus and blur alone, as on the Mac.
- **A movie's frames a second:** 172 at most, fewer for large frames (144 at 2560×1440, 64 at
  3840×2160): H.264's levels as Media Foundation's encoder keeps them; the Mac goes to 240.
- **A movie's frames lie one frame late** in the file as AVFoundation reads it (the first at
  1/30 s in a 30 fps movie). Older than 2026-11-14; cause not looked into, not checked in a
  Windows player.
- **What Windows gives an app no way to do:** two fingers turned on the camera (a Windows
  touchpad tells an app of no such gesture), taps of feedback on a touchpad.
- **Different from the Mac:** no sharper parts while the film plays (pictures are drawn on the
  main thread only; they come once the film rests); the Spring chip is not a dial (the number
  sets the bounce); the timeline's seconds and lines do not glide when the scale changes or a
  line opens; no two-finger double tap on the timeline, the stroke under the lines cannot be
  dragged, no tick at the whole film; with a shape's points in hand the pointer stays the arrow
  (the Mac shows the pen with a plus), and a shape pointed at in From…'s menu lights in the
  layers list only.
- **Never tried on a real touchpad** (the VM has none): the pinch on the camera, the canvas and
  the timeline, and whether the lines' ScrollViewer swallows a pinch or a sideways pan. The
  timeline card's height on its spring was built but not looked at in the VM.
- **Unchecked:** a film with outline keys or look keys made on the Mac opened in the VM (ones
  made on Windows through the shared calls play); a shader input key's bounce in the AI
  server's `get_animation` (no shader fill could be made in the VM); the x64 build, which 1.8's
  release made and nobody ran (the VM is an Arm one, where the Arm64 release build was launched
  once, as far as its home window).
- **The stage** is put together on the processor and was measured in the VM only, never on a
  real PC.

## Shaders

- **Kept live since 2026-11-14 on the Mac:** canvases that draw through framebuffers (blur chains,
  feedback), with depth and stencil tests, culling, masks, scissor, instances, several outputs,
  textures of numbers, uniform blocks and a blend constant. Checked with pages of our own that
  imitate the calls of three.js, PixiJS, regl and ogl, never with the real libraries or a real
  website, and never looked at in a running window.
- **Not recorded on import** (the canvas stays a picture and the report says why): cube maps as
  targets, `gl_FragDepth`, sampled depth textures, 3D, array, multisampled and integer targets,
  `clearBuffer` of one of several outputs, `copyTexImage2D`, a blit from the canvas, transform
  feedback, pages driven by `readPixels`, compressed textures, WebGL 1 `gl_FragColor` to several
  outputs. A page that uploads its buffers anew every frame (PixiJS batches) is kept still.
  Uniforms counted per frame run as slowly as the reading web view drew.
- **Video textures** are the frame at capture only ("Videos in WebGL drawings, as still
  pictures"); playing one needs the video's file kept in the design, decoding per film frame and
  a mapping of film time to video time.
- **What a fill keeps:** kept state over 12 MB, or unreadable, makes the canvas a picture; the
  contents of targets and textures of numbers live as base64 in the design's JSON (keeping them
  as files would be a format change). A 1.7 that saves such a design again drops the `scene` key
  and keeps the picture.
- **In a film:** a fill that builds on its frames is drawn in steps; a far jump forward draws
  every step between once, and steps stop at 36,000.
- **Direct3D draws none of it:** passes into textures, depth and stencil, culling, colour masks,
  scissor, polygon offset, instances, several outputs and textures of numbers are refused by
  name and such fills show their picture on Windows. It needs targets with formats, several
  outputs, depth-stencil and rasterizer states, write masks, instanced draws, mipmaps of targets
  and float read-back in `ShaderDirect3D.h/.cpp` and `Direct3D/Renderer.swift`, mirroring
  Metal's `run`, `targets(of:)` and `Timelines`; then `TargetsTests`, `StateTests` and the 17
  Agreement frames are turned on (`drawsPasses` in `Tests/ShadersTests/Support.swift`). On
  Windows a web import keeps such a canvas as a picture; that path is compiled, never run in
  the app.
- **The browser viewer** shows the picture for such a fill (`beyondPlain`); drawing it needs
  framebuffer passes, steps with kept state, a depth and stencil context, instancing, textures
  of numbers and per-draw clocks in `site/shaders.mjs`.
- **For Erik:** the glow layer of the web page design Erik imported on 2026-11-13 was recorded before the recorder was
  fixed (2026-11-13); importing it again gives the fixed recording.

## Vectorize

Worked on 2026-11-14 (`Packages/Vectorizer/README.md` has the measures): colours that run become
gradient fills, thin lines come out evenly thick, small text keeps most of its pieces, textured
pictures make fewer shapes. What is still open:

- **Thin lines:** a line a pixel thick in a picture that wavers comes out about a fifth too thick
  (1.15 to 1.25); its two edges are found each on its own.
- **Textured pictures** still make more shapes than vectorizer.ai's where long thin lines along
  edges break up (243 to their 193, 113 to 87), and nothing is taken away in pictures traced at a
  smaller size than their own (129 to 105).
- **Gradients:** colours that run round a point, along a bend or outward in ovals stay bands of
  flat colour; so does a faint run in a noisy picture. The Vector card's colours
  (`Tracing.palette`) list a run's bands, not its gradient. In a JPEG the edge of a shape beside
  a run keeps a notch here and there, and the ground of the gradients sample comes out in two
  halves.
- **10 point text** loses strokes and gaps thinner than a pixel (6 of 140 pieces, 10 of 46
  counters closed, 14 letters run together); a dot on the corner of four pixels reads up to three
  times too large.
- **Large pictures:** one of more than about 1.6 megapixels is read with one sample to a pixel
  and its outlines may lie 0.6 px off (0.2 in a small picture); a circle there is not always
  known for an ellipse.
- **Time:** last measured on a calm Mac for the state of c03f41f's content; the three later
  commits only on a busy one. A photograph's time has not been measured since 2026-11-10.
- **Never looked at in a window** with the new engine, on the Mac or Windows.
- **Windows:** the vectorize tool's description in `Windows/Sources/BezzleCore/MCP/MCPDefinitions.swift`
  still says every layer is flat in colour; gradient layers were not built or looked at in the
  VM (they come through the shared `Bezzle/Model/Vectorizing.swift`, round ones with
  `Gradient.across`).

## Remove Background on Windows

- DirectML is not measured on real hardware (speed, memory, integrated graphics at 2,048 pixels),
  so the card's measures in `MatteWays` are guesses. It takes a real PC and the first version
  after 1.7: `Scripts/subject-matte/README.md` › Measuring a graphics card.
- Not run on a real x64 processor: under emulation in the VM it cuts out correctly (2026-11-14),
  which says nothing of its speed.
- No PC of 4 or 8 GB has run it: in the VM the light size holds 1.7 GB, and 1.2 GB the lean way,
  taken with less than 2.2 GB left (`BEZZLE_MATTE_LEFT` tries the choice, not real pressure).
- The new ways (2026-11-14) ran through `bezzle-render`, not the app: the line the app writes to
  its trace after each matte was not read from an app's own trace file, and their times were not
  taken in a quiet VM.

## 3D scenes

Built 2026-11-14 on the Mac (`README.md` › 3D): several layers turned as one body, an artboard
looked at from the side, groups that keep their layers' depth. None of it was seen in a real
window, only in tests and in pictures the renderer made. What that left:

- **For Erik, looking from the side:** it moves the eye and leaves the page where it is, so every
  tool stays true while looking (`DepthLook`); a true orbit that tilts the page is not built. Say
  if the page itself should turn.
- **Looking from the side, not seen in a window** (only in tests and pictures the renderer made):
  View › Look from the Side and its place in the zoom menu (tests drive the store and find the
  item in the menu bar), in German, French and Italian too; the posts hidden behind nearer layers,
  and how long working that out takes on a large artboard while the look is dragged round (32
  places up each post, each asked of every layer standing higher than the post's foot where both
  show; worked out again at each step of the drag); the word over a carousel in the line above
  its slide numbers. A post is hidden where the frame of a layer pinned by its corners would be,
  not where its corners are pinned.
- **One body:** a body posed by keys is rigid at each key and only nearly so between them (its
  angles ease one by one). A body's lead can change between turns when a group's fitted frame
  outgrows it, and angles are kept to hundredths of a degree, so a body facing several ways
  drifts by thousandths of a point over many turns.
- **One body on Animate's canvas** (2026-11-15, `FilmBody`): several picked that lie apart (on
  the artboard and in a group) have no handles and are only moved together. Grown one way, each
  layer grows along its own sides, so one that does not run with the lead's keeps its angles
  rather than being stretched askew. The handles lie in the plane of the lead's face, so layers
  standing far off it can show outside them; a group or a shape whose points are keyed, leading
  a body inside a group drawn as one card while standing off that group itself, shows them as if
  it lay in it. Driven by tests only, never seen in a running window.
- **Animate, dragging in a group turned in depth** (2026-11-15, `Node.filmMovePlane`): the layer
  stays under the pointer in tests, within a point; never felt in a running window. A layer that
  is itself tipped is cast onto the plane of its middle, so a point of it taken hold of away from
  the middle drifts a little off the pointer; lifted with Control during the drag, it goes on
  across along the plane it began on.
- **Groups that keep depth, different or not built:** in SVG, one split by layers beside it goes
  out as several parts under its name (`Group`, `Group_2`), its turned layers as pictures, so an
  editor sees no one group there; one whose layers stand in an order its own does not give them
  (a layer beside it joining two of them into one body) goes out whole in its own order where
  nothing comes between, which can differ from the canvas. Windows' and the browser's SVG
  (`SVGWriter` and `Depth.swift` are shared) were not built with it, and no SVG with such
  pictures was opened in another program. One with keys of its own is one card in its film,
  while a click in Animate (`filmChain`, through `Prototype.chain`) orders its layers among what
  lies beside it as the design does. Seen exactly edge on, hits and bounds take layers standing
  off it as lying in it. A background blur lying directly in a group makes it one card, which
  CSS does not do.
- **Groups that keep depth, unchecked:** the switch, the outline and the handles in a window, and
  Layers Keep Their Depth in a group's right-click menu (tested on the menu's entries only); the
  tiles' redraw around such groups on a live canvas (it rests on `Renderer.reach` and its test);
  a 1.7 copy in a live room beside the new `keepsDepth` entry. Bezzle 1.7 opening and saving such
  a design writes it back without the flag.
- **For Erik, web import:** a page's 3D comes in depth only where it is seen from the artboard's
  own eye (`README.md` › 3D, From a web page). Real pages set a perspective of their own on a box
  (1000px, say), so nearly all of them come in flat as before, with a note. Pinning such a layer
  by its corners (`Transform3D.corners`, as a Photoshop mockup's screen is) would show it exactly
  as the page does, though not in depth. Say if it should.
- **Web import, not built:** a turned box that does not keep depth holding something turned in it
  through a perspective of the box's own (drawn flat, noted); a part photographed inside a turned
  box keeps the box from being one group (each of its layers then stands on its own, true to the
  page); a background that can only be photographed is photographed as the page shows it, turned,
  and turned again with its box, as a box turned flat in the page already is; a face the page
  hides from behind and that faces the eye is shown, and stays shown when turned away later, as
  the design cannot hide a face only from behind. Nearer over further is the design's
  (`DepthOrder`), not CSS's splitting of planes, so faces crossing each other may differ.
- **Web import, unchecked:** only test pages read in WebKit, no real site with 3D; a page taller
  than its window, whose artboard's eye is twice the page's height away, so a perspective would
  have to be that far to be the artboard's.
- **Films of groups that keep depth** (order at rest and keys measured in the group, fixed
  2026-11-14 in the shared model): Windows was not built or run with the fix, nor with
  2026-11-15's shared changes: `DepthOrder.nearness` (a face in a body's plane, its middle as high
  as another's there, belongs to the body), `Prototype.chain` ordering across a group's border,
  the posts (`posts(of:)`, `shownParts`); run `Windows/VM/depth-agreement.sh` again with a fresh
  out folder, since the Mac's "Resting" and "Turning" frames changed. Untested: a layer pinned by
  its corners lying in a turned group that keeps depth.
- **Windows** has all three since 2026-11-14 (the card and the AI server turn bodies, the group's
  switch, the look from the side with Alt; `Windows/README.md` › The app), measured against the
  Mac's renderer (`Windows/VM/depth-agreement.sh`) and seen in the app's window. Left there:
  Escape does not let go of what is picked in
  Design, so it looks from the front only with nothing picked; a look from the side cannot be
  begun in a read-only design or while looking back at versions; with no tiles, an artboard
  looked at from the side is drawn whole at every step of the drag (not measured on a large
  one); the 3D card's numbers follow a turn from a side only when the drag ends. Not there since
  the Mac has them (2026-11-15): Look from the Side in the menus, and Layers Keep Their Depth in
  a group's right-click menu; the posts are drawn whole over everything, where the Mac hides them
  behind nearer layers (`BezzleDocument.shownParts`, shared, asked by the Mac's `LookTool`), and
  the word may sit over a carousel's slide numbers (`WindowsCore.LookHand.wordRect`). The shared
  posts now stand under each layer of a group that keeps depth, down to the page, there too.
- **Windows, not checked:** the switch and captions in German, French and Italian in the window;
  a deck's artboard looked at from the side; the x64 build run; a film of a group that keeps depth
  playing in the window (only at rest there).
- **Windows, web import in depth:** not built or run there. The reader and the converter are the
  Mac's (`WebPageReader.js`, `WebPage.swift`, `WebImporter.swift`, linked), so the next Windows
  build reads a page's depth too; whether WebView2 hands over the same matrices and typed
  transforms WebKit does is not known.
- **Not looked at on the Mac:** whether the 3D card's row cuts "Layers keep their depth" (Windows
  uses a wrapping row).

## The welcome tour

- **Windows releases 1.5 to 1.7 shipped the tour without its photo** (grey boxes in Photo editing,
  Masks, Adaptive layout and Gradients and pictures; seen in the release's build folder and with
  the render tool, not in an installed copy). `Scripts/release-windows.sh` paints the tour's
  pictures since e9046e7 and the installer refuses an app without them; the next Windows release
  is the first real run of that.
- **Unchecked on the Mac:** Space playing the postcard's film by a pressed key (the hook sends key
  down only; the code path and the `start` hook were run), and Vectorize's pencil pass over the
  badge in a photograph.
- **For Erik:** three handwritten notes of older lessons end in exclamation marks ("Go on, move
  one!", "into the sky!", "your turn!"). Left as they were.

## The browser viewer

Worked through on 2026-11-14 (`Web/README.md` › What the prototype left out, and what is drawn
now, with the numbers): plus darker, blurs along a ramp, shader fills in the design, the live
room's hands and presence, four languages, the icon library in the core, and memory let go.

- **Published with 1.8** (2026-11-14, bezzle.ch/app, from the app's commit cf196be). Checked
  before the push with the published page in a headless Chromium against a relay on this Mac: a
  design with a film, 3D depth and an outline key draws and plays, in English and German, with
  nothing in the console; after the deploy the live files were compared byte for byte. Not
  tried: a design shared by a real Mac through the live relay opened at bezzle.ch/app, in
  Safari or Firefox, or on a phone.
- **Shader fills** beyond plain draws (passes into textures, steps building on frames before,
  depth, stencil, instances, textures of numbers; `beyondPlain`), and every shader fill where
  there is no WebGL, show their picture, in the design and in a film; drawing them needs
  framebuffer passes, steps with kept state, a depth and stencil context, instancing, textures
  of numbers and per-draw clocks in `site/shaders.mjs`. A moving shader's frame is read back
  from the graphics card each moment (about 3 ms at 840×600). Cube maps, matrix attributes,
  `#version 300 es` programs and antialias off are written there, but no test design has them.
- **The live room** does not show a layer moving while it is dragged (it moves when the drag
  ends), the glow of what was just changed, the light where others look, pictures on their way,
  or following someone's view. Tested with the words two real Mac rooms said (`LiveTruthTests`)
  and stand-ins on a local relay; never tried by hand with a Mac in the room.
- **Words:** `Web/site/index.html`, the sample viewer for this Mac, is in English alone.
- **Text widths:** at sizes that are not whole every face is up to a 64th of the size narrower
  (FreeType takes sizes in 64ths; 0.10 pt on a word of 230 pt), and the system font's heavier
  weights are up to 0.2 pt wider on a word at 96 pt (whole-unit advances at a weight between the
  font's own). Both inside CanvasKit; measured with Apple's fonts, while the published page sets
  open stand-ins.
- **A film without WebGL** plays at 5 to 12 frames a second on the processor.
- **A film's sharpness while playing:** a piece's whole picture is capped at 4,096 pixels a side
  and 16 megapixels; past that it is sharp only when the film rests.
- **A film's gentle tones:** the page draws each piece of a film with eight bits, where the Mac's
  movie keeps pieces finer and cuts once: up to 2 levels of 255.
- **A film's focus:** a film whose camera blurs plays sharp all over in the viewer
  (`Web/Sources/BezzleCore/Film/WebFilm.swift` reads a piece's `map`, `opacity` and `blur`,
  not `FilmPlacement.soft`).
- **Not set beside the Mac in the viewer:** 3D bodies and the look from the side, groups that
  keep depth, Shape keys with other outlines, and looks keyed in a film (drawn through the
  shared `FilmPictures.subject` and `piece.changes`; the core compiles with them).
- **The icon library** is read by the core (`bz.icons`), but no page uses it and `publish.sh`
  does not copy `Icons.deflate`; placing an icon would be editing, which the viewer leaves out
  at Erik's wish.
- **Unchecked:** the film with the open fonts the published page uses (compared with Apple's
  only), in Safari and Firefox, on a phone, a WebGL context lost mid-film.
- **Windows, not checked after these commits:** the build (`Platform`, `Web` and `Bezzle/Model`
  files changed, additively); whether it keeps texts as the page did before `HostTexts`; and
  its host's `pathOp`, which hands on Skia's Simplify and Op results as they come (even-odd,
  contours either way round) and strokes at Skia's default precision, so Lucide icons whose
  lines enclose something and combined shapes with holes may fill in, as they did in the page
  before `wound` (the cure could move into `Platform/CGPath.swift`).
- `Web/README.md` › Not done lists what the viewer still does not draw or do.

## The website

bezzle.ch as of 2026-11-15 (bezzle-web b351ca1, deployed): the docs, What's New and the home page
say what 1.8 has, and the story has twelve chapters, with Vectorize and Animate among them and
the window's switch showing four modes. The docs play the Vectorize and Animate scenes, the
comparison pages have rows for Animation, 3D and Vectorize (Figma's and Sketch's sides as their
own sites had them in November 2026), `/docs/index.html` no longer puts React's error 418 in the
console, and `scripts/shelter-logo.mjs` runs with Node 26. Its source is `~/Sites/bezzle-web`;
this is what was left there.

- **The story's ten older captures show three modes.** The pictures a visitor without motion
  sees (`public/img/app/<locale>/`) were taken before Animate; only `vectorize` and `animate` are
  new. Those two were captured apart with `capture/story/` in `AppStore/screenshots-src` (kept
  from that session and not run from this folder since; its header says what it needs beside
  it). Left: all twelve taken afresh through `capture/capture.py`, and words for the two
  chapters in `captions.py`.
- **Not measured:** the two new scenes drawn flat on a phone (`lib/flat.js`; the memory Safari
  holds, with Playwright's WebKit at an iPhone's size and 3× as the site's README says), and
  Lighthouse on the live site (on the local preview server, which sends files uncompressed, the
  home page's performance was 82 before the two chapters and 81 after, the other three 100).
- **For Erik, the two new captures:** the window's three buttons are grey in them, since a test
  copy never comes to the front (four of the ten older captures are grey too, six coloured).
  The copies ran with a relay address nothing answers at (`http://127.0.0.1:9`) instead of none,
  so that Share… shows as in the other captures; the designs were made from the screenshots'
  poster and have no `sharing` folder.
- **Two older worktrees** in `~/Sites/bezzle-web/.claude/worktrees` (`agent-a510f38f3edf95d18`,
  `agent-a9ce4579b9ab95071`, both at 72c6d36 and last written on 2026-11-08) hold changes that
  were never committed: 8 and 39 of their files differ from main's. Another session's, so left
  as they were; look before removing them.

## Moving about

Made quick on 2026-11-15 (`README.md` › The Mac app › Moving about quickly has the numbers and
the rules). What that left:

- **Never felt:** measured with made scroll and pinch events in a copy in the background, on a
  copy of one of Erik's largest designs, never with a hand on a trackpad. Released in 1.9 (2026-11-15).
- **For Erik, the zoom button** keeps the width it has at 100 % from the whole design to 999 %
  (a few points wider at 50 % than before, the number at its right), so that the bar never moves
  while zooming. Say if it should hug its number again; that costs a late frame now and then
  while zooming.
- **Left on a frame while zooming:** the rulers' numbers and the artboards' names (2 to 3 % of the
  main thread each, CoreText setting them), and tiles shrunk with the finest resampling on the
  queue the window's drawing waits for (tried the quicker way while moving: no difference
  measured, so not kept).
- **Where the design was looked at** is written after 30 s of rest; Bezzle closed by a crash meanwhile
  opens it where it was looked at before that.
- **Windows** was not looked at for the same causes (WinUI reading the view at every step, tiles
  in another format than the screen's, the zoom's number).

## Designs in synced folders

Made safe on 2026-11-15 against the duplicates ("Poster 2") iCloud Drive keeps when a design is
written on two Macs at once (`README.md` › The Mac app › Designs in synced folders). What is left:

- **Never seen with two real Macs:** two Macs in one process on a folder marked synced
  (`CloudFolderTests`, `GoogleDriveFolderTests`), and one copy editing a design in iCloud Drive on
  this Mac for four minutes and one in Google Drive for three, with no duplicate. Not tried: two
  Macs on one iCloud account, two computers on one Google Drive with the 2026-11-16 changes, Dropbox.
  What Google Drive kept twice was found in Erik's work drive, written by three Macs before them.
- **Google Drive, released in 1.9.3** (2026-11-16, Mac and Windows): pictures and versions from the relay wait beside
  the design, copies inside a design are taken back in, a link's design in the folder is opened
  rather than made again (`README.md` › Designs in synced folders). Not looked at: what Google Drive
  does when two computers change `document.json` at once (a Mac writes it whenever it changes the
  design); `Library.carry` moving a design into a folder holding the same one still names it
  "Poster 2" (taken in by `copiesFromTheService` once both are open there).
- **A Mac only looking on** still writes what it did with the relay's room (`cloud.json`, in its own
  folder, `CloudShare.keep`): harmless to Google Drive, but to iCloud Drive a write of the design.
- **Both Macs changing it at once** still makes the service keep two now and then; the copy is
  taken back in within 20 s while the design is open, or when the designs list is read. One the
  service made that holds nothing new (only a picture or the view) is left as it is.
- **Windows** has the same rules since 2026-11-15 (`Windows/README.md` › The app). Checked in the
  VM: a copy editing a design in a folder marked synced writes every edit (five of five) and its
  own parts. Not checked there: two copies on one design (the one looking on writing nothing), a
  copy the service made taken back in and sent to the Recycle Bin, a design away for a moment;
  nor with a real OneDrive, Google Drive or iCloud for Windows. The 2026-11-16 Google Drive rules
  (arrivals beside the design, copies inside taken back in, a link's design found) were checked
  there headless only (`bezzle-share … drive`), not with two computers.
- **A Mac only looking on** keeps where the design was looked at only until it is closed, and its
  Finder picture and versions are made by the Mac that changed it.

## Opening a design

The tab covered by the window's paper with Bezzle's mark pressed into it while the design opens
(2026-11-15, `README.md` › The Mac app › Opening a design). What that left:

- **Never seen by a person:** photographed held still at moments of the gesture and filmed at
  about ten frames a second in test copies in the background, light and dark, on this Mac's
  1728 × 997 window at 2×. Not seen at 75 Hz on Erik's 5120 × 1440 screen at 1×, nor with a design
  as heavy as Erik's largest designs (the largest tried: 4,860 layers and 60 photos).
- **Measured in Debug alone:** an optimized build makes the design sooner, so more designs opened
  in a second tab come through within the grace, without the mark.
- **A Photoshop document** keeps its own progress while it comes in (`BringingInView`), not the
  mark. Files from Adobe XD, Figma and Sketch are still brought in on the main thread, under the
  cover (the mark goes on meanwhile; the menus and the bar wait).
- **Windows** (`Windows/README.md` › The app): seen only in the VM, at one scale, with WARP for a
  graphics card. Unlike the Mac: the ink runs in behind a straight edge (a soft one needs the ink
  as a composition surface with a gradient mask: `CompositionVisualSurface` and
  `CompositionMaskBrush` are in the bindings, untried); the bar's controls show with the design's
  page a moment before the paper lifts; a file from another app is brought in without the cover,
  under its own "Bringing in" page, as before.

## Housekeeping

- **The Export sheet closes by itself** once every file is written, and stays only to say what
  could not be made (2026-11-16, both `ExportSheet.swift`). On the Mac built, not tried in a
  window (the folder panel wants a person). On Windows written while the VM was off: never built
  nor tried there.

- **The AI server, numbers past any size** (found 2026-11-15 in the audit after 1.8's crash; the
  whole-number reader and places among layers no longer break off): what reads a number its own
  way still turns one past any whole number into one and breaks off. `import_website` with a
  width of `1e30` or `"inf"` (`MCPTools.swift`, `Int(width.rounded())`), a carousel's slides of
  `1e20` and a font feature of `1e20` (`MCPLayers.swift`), a place `"fill -9223372036854775808"`
  in `MCPStyles.swift`. And the server's own reading of a request sent in chunks takes a negative
  chunk size, which any program on this Mac could send (`MCPServer.swift`, the chunked body).
  `steps` of `1e18` (`MCPTools.swift`) does not break off but runs for ever.

- **Windows' own panels** were not looked through for what broke 1.8 off on the Mac (a card or
  a drag asking for layers, rows or tabs that have gone since it was made, 2026-11-15). What they
  share with the Mac is safe there too: the layers list's drop (`LayerDrop`), a layer's place
  (`BezzleDocument.attach`, `insert`) and the versions ruler's string (`RulerMotion`).

- **The full test run in parallel** fails on a quiet Mac since 1.8 (found 2026-11-15, on 1.8.1's
  commit too): `FilmSharpTests.withTheViewCloseOnlyWhatIsInTheViewIsDrawnSharper` waits more than
  a minute for pictures from the film stage's one queue, which every test's stage shares. It no
  longer stops the run when it does (`#require`); one at a time it passes. To fix: a queue for
  each stage, or a longer wait in that test when others share the queue.

- **The VM's disk** has 42.8 GB free of 127 since 2026-11-14, when every finished agent's
  folder in `C:\src` was removed (`win-*`, `shader-check`). Left there beside `Bezzle` and
  `bezzle-release`: `curves`, `cutout-samples`, `import-samples`, a few build logs, and about 250
  old `C:\bezzle\BezzleDesktop-*.log` files.

- **1.9 and 1.9.1 as released, not watched** (2026-11-15; 1.9 for the Mac and Windows from a7a82af,
  1.9.1 the Mac's alone from e401c34, for designs in synced folders turning up twice, Windows staying
  at 1.9): an installed 1.8, 1.8.1 or 1.9 taking the update, on the Mac (Sparkle's window with the notes, a delta) or on Windows.
  The released Mac copy was not launched, since it shares Erik's container; 1.9 had the whole
  test suite one test at a time (2,228 tests), the Mac parity check (the canvas tools' log the
  same as before the six agents' work) and the speed measures in an optimized Debug build. The
  Windows installers were not run; the Arm64 release build they hold was launched once in the VM
  (its home window, responding). None of the agents' work was seen in a running window.

- **1.9.3 as released, not watched** (2026-11-16, the Mac and Windows from d70f4e1, for Google
  Drive keeping pictures once for every computer and a link's design twice): an installed 1.9.2
  taking the update was not seen on either. Before it: the whole Mac suite one test at a time
  (2,526 tests), Windows' share code checked headless in the VM (`bezzle-share … drive`), the Mac
  build against real Google Drive with planted copies. The Mac was notarized with the API key
  (`ASC_KEY_PATH`), as the keychain profile `harness-notary` was gone from this Mac that afternoon;
  the Windows installers are the dry run's, not run.

- **1.9.4 as released, not watched** (2026-11-20, the Mac and Windows from 6b820d5, for
  MarcDietschi's Windows speed-ups from his fork: the zoom refreshes only the canvas and its label,
  and the font scan reuses each file's first 4 KB). The tests were not run (Erik: "no tests"). The
  changes were built in the VM and tried in a Debug copy: zoom over the AI server and with
  Ctrl+wheel (label, rulers, selection and panels following, nothing moving at the 2% floor), and
  the old and new font readers over the VM's 143 font files gave the same 166 faces (30 to 21 ms).
  The Mac was notarized with the API key, `harness-notary` still missing; the Windows installers
  are the dry run's, not run, and no installed 1.9.3 was seen taking the update.
