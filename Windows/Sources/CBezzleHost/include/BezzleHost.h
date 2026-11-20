// What Bezzle's core asks of Windows, done with Skia (host.cpp): what the browser's page does for
// the WebAssembly core (Web/site/bezzle.mjs), call for call, so designs draw and measure alike.
// Path operations and pictures by name go through bz_host_call as in the browser, with the same
// numbers and bytes; text and pictures, which the browser passes as JSON, are given here as
// structs by Swift (Host/WindowsHost.swift); drawings are the core's recorded commands
// (Web/Platform/CGContext.swift).
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Does `function` (1 path operation, 2 picture by name, 4 log) with `count` bytes; keeps the
/// answer and returns its length, for bz_host_take.
int32_t bz_host_call(int32_t function, const void *bytes, int32_t count);
/// Copies the last answer into `into`, which holds its length.
void bz_host_take(void *into);

// MARK: Fonts and text

/// Adds a font face, by family and face as the core names them ("System" for the system font,
/// with an empty face). Returns 0 if Skia cannot read it.
int32_t bz_font_add(const char *family, const char *face, const void *data, int32_t count);
/// The same for the `index`th font of a file that holds several (a .ttc collection; 0 for any other).
int32_t bz_font_add_at(const char *family, const char *face, const void *data, int32_t count, int32_t index);

typedef struct bz_text_run {
    const char *text;           // UTF-8
    const char *family;
    const char *face;
    double size;
    double tracking;            // letter spacing, in points
    double weight;              // CSS weight of the face (100 to 900); for "System" also its wght axis
    double opticalSize;         // for "System": its opsz axis, 0 for none
    int32_t underline;
    int32_t strike;
    int32_t hasColor;           // without a colour the letters are not painted (a fill paints them)
    double color[4];            // r, g, b, a
    const char *features;       // OpenType features as "liga=0,ss01=1", or null
    const char *axes;           // variable font axes as "wght=500,wdth=90", or null
} bz_text_run;

/// Sets `count` runs `width` wide, aligned 0 left, 1 center, 2 right, 3 justified. Returns the
/// text's id and writes, for up to `capacity` lines, ten numbers each to `lines`: its start and
/// end (UTF-16), width, ascent and descent (less half the leading, as Skia shares it out), the
/// font's leading, where its letters begin from the text's left (its indent and as far again as
/// its alignment moves it), and the ascent, descent and leading of the fonts fallen back on for
/// letters the text's fonts lack (the most of each; nought without); `*lineCount` is how many
/// lines there are. `indents` holds
/// `indentCount` paragraphs set further in, three numbers each: where they begin and end (UTF-16)
/// and how far in their lines begin (items of lists).
int32_t bz_text_lay(const bz_text_run *runs, int32_t count, double width, int32_t align,
                    const double *indents, int32_t indentCount,
                    double *lines, int32_t capacity, int32_t *lineCount);
/// Where the core puts each line's baseline, from the text's top.
void bz_text_place(int32_t id, const double *baselines, int32_t count);
/// Where some letters of a text set by `bz_text_lay` are (`start` to `end`, UTF-16): for each
/// line they are on, up to `capacity`, three numbers to `boxes`: the line's number and where
/// the letters begin and end along it. Returns how many lines they are on.
int32_t bz_text_boxes(int32_t id, int32_t start, int32_t end, double *boxes, int32_t capacity);
/// Sets `count` runs as one line, for a text laid along a curve, its letters drawn one by one
/// (drawing call 13, by the line's id and a letter's place in it). Returns the line's id and
/// writes, for up to `capacity` letters, ten numbers each to `glyphs`: the run it is of, where
/// it is along the line, where it is from the baseline (y down), its advance, its font's ascent
/// and descent, where its underline is (below the baseline) and how thick, and its font's x height
/// and cap height. `*glyphCount` is how many letters there are, and `line` gets four numbers:
/// the line's width, ascent and descent, and the first letter's cap height.
int32_t bz_text_glyphs(const bz_text_run *runs, int32_t count, double *glyphs, int32_t capacity,
                       int32_t *glyphCount, double *line);
/// Where in the words (UTF-16) each letter of a line set by `bz_text_glyphs` or `bz_text_letters`
/// is from, for up to `capacity` letters. Returns how many letters the line has.
int32_t bz_glyph_starts(int32_t line, int32_t *starts, int32_t capacity);
/// A text set by `bz_text_lay`, its letters taken one by one, for letters springing to new places
/// over the canvas: each as a letter of a line drawing call 13 draws, by the line's id this
/// returns and the letter's place in it. Writes, for up to `capacity` letters, nine numbers each
/// to `letters`: where its baseline begins, x and y from the text's top left as drawing call 12
/// draws it, its own width, ascent and descent, where its underline is and how thick, its font's
/// x height, and where in the words (UTF-16) it is from. `*letterCount` is how many there are.
int32_t bz_text_letters(int32_t text, double *letters, int32_t capacity, int32_t *letterCount);
/// The outlines of the letters of a text set by `bz_text_lay` whose words lie from `start` to
/// `end` (UTF-16), and of the lines under and through them, made one with them, where drawing
/// call 12 draws them from the text's top left: in the path numbers of `bz_host_call`'s path
/// operations, taken with `bz_host_take`. Returns how many bytes, or -1 when some of those letters
/// are pictures (emoji in colour), which have no outlines.
int32_t bz_text_outline(int32_t text, int32_t start, int32_t end);
/// The outline of letter `index` of a line set by `bz_text_glyphs`, its baseline's left end at
/// nought and y running down, as `bz_text_outline` gives it; -1 when it is a picture.
int32_t bz_glyph_outline(int32_t line, int32_t index);
/// Forgets every text set, as when fonts were added.
void bz_text_forget(void);

// MARK: Spelling (spelling.cpp)

/// The languages Windows checks spelling in, as tags separated by commas ("en-US,de-CH"), UTF-8
/// to `out`. Returns how many bytes the list takes.
int32_t bz_spell_languages(char *out, int32_t capacity);
/// The misspelt words of `count` UTF-16 units of `text`, checked in `language`: for up to
/// `capacity` words, where each begins and how long it is, to `ranges`. Returns how many there
/// are, or -1 when Windows cannot check that language.
int32_t bz_spell_check(const char *language, const uint16_t *text, int32_t count, int32_t *ranges, int32_t capacity);
/// How a word might be spelt, likeliest first, one a line, UTF-8 to `out`. Returns how many
/// bytes they take.
int32_t bz_spell_guesses(const char *language, const uint16_t *word, int32_t count, char *out, int32_t capacity);
/// Adds a word to the dictionary of the person signed in.
void bz_spell_learn(const char *language, const uint16_t *word, int32_t count);
/// The words of `count` UTF-16 units of `text` said twice in a row, as Windows' spell checker
/// for `language` finds them (the second of each): for up to `capacity`, where each begins and
/// how long it is, to `ranges`. Returns how many there are, or -1 for a language it cannot check.
int32_t bz_spell_repeats(const char *language, const uint16_t *text, int32_t count, int32_t *ranges, int32_t capacity);

// MARK: Pictures

/// How big a picture file's picture is, in pixels, upright as its orientation turns it; 0 if
/// Skia cannot read it.
int32_t bz_image_size(const void *data, int32_t count, int32_t *width, int32_t *height);
/// How many pixels a picture file keeps, as Image I/O counts them (not turned by its
/// orientation); 0 if Skia cannot read it. On any thread.
int32_t bz_image_pixel_size(const void *data, int64_t count, int32_t *width, int32_t *height);
/// Reads a picture file's pixels, `width` by `height` as bz_image_pixel_size says, into premultiplied
/// RGBA, rows top first. Returns 0 when done. On any thread.
int32_t bz_image_decode(const void *data, int64_t count, int32_t width, int32_t height, void *pixels);
/// RGBA pixels (premultiplied, or not with `straight`) as a PNG file's bytes into `out`, which
/// holds `capacity`: how many bytes, minus that when they did not fit, -1 if it could not be made.
/// On any thread.
int64_t bz_png_encode(int32_t width, int32_t height, const void *pixels, int32_t straight, void *out, int64_t capacity);
/// A picture as a JPEG file's bytes, as the Mac's Image I/O writes them at `quality` with no DPI
/// given (jpeg.cpp), from premultiplied RGBA pixels, into `out`, which holds `capacity`: how many
/// bytes, minus that when they did not fit, -1 if it could not be made. On any thread.
int64_t bz_jpeg_encode(int32_t width, int32_t height, const void *pixels, double quality, void *out, int64_t capacity);
/// A picture file's picture small, as Image I/O makes a thumbnail with its transform: upright,
/// its longer side `longest` pixels at most (never larger than it is), into premultiplied sRGB
/// RGBA in `pixels`, which holds `longest` × `longest` × 4 bytes; its size to `width` and `height`.
/// Returns 0 if it cannot be read. On any thread.
int32_t bz_image_thumbnail(const void *data, int64_t count, int32_t longest, int32_t *width, int32_t *height, void *pixels);
/// The same in the picture's own colours, as the Mac's CutoutMaker works on a picture: its colour
/// space when that is RGB (Display P3, Adobe RGB…), sRGB when it is sRGB, grey, CMYK or HDR.
/// Returns how many bytes the ICC profile of those colours has (the file's own, or one made from
/// its numbers), written to `icc` when they fit in `iccCapacity`; 0 for sRGB; -1 if the picture
/// cannot be read. On any thread.
int32_t bz_image_thumbnail_own(const void *data, int64_t count, int32_t longest, int32_t *width, int32_t *height, void *pixels,
                               void *icc, int32_t iccCapacity);
/// Premultiplied RGBA pixels from the colours one ICC profile says to another's (none: sRGB), into
/// `out`. Returns 0 when done. On any thread.
int32_t bz_pixels_convert(const void *pixels, int32_t width, int32_t height, const void *fromICC, int32_t fromCount,
                          const void *toICC, int32_t toCount, void *out);
/// bz_png_encode for pixels in the colours of the ICC profile `icc` (none: sRGB), which the file
/// carries byte for byte, as Image I/O writes a picture's profile. On any thread.
int64_t bz_png_encode_own(int32_t width, int32_t height, const void *pixels, int32_t straight, const void *icc, int32_t iccCount,
                          void *out, int64_t capacity);
/// 1 when the bytes are an HEIF file of an HEVC picture (HEIC), which Windows reads only with
/// Microsoft's HEIF and HEVC extensions (heif.cpp), else 0.
int32_t bz_heif_sniff(const void *data, int64_t count);
/// Why the last HEIF picture Windows could not read was not read: 0 every one was, 1 no HEIF
/// Image Extensions, 2 no HEVC Video Extensions, 3 damaged or another reason.
int32_t bz_heif_problem(void);
/// Adds one of a design's pictures by name, as its encoded bytes. Returns its asset number, 0
/// if Skia cannot read it.
int32_t bz_asset_add(const char *name, const void *data, int32_t count);
/// Registers a picture from a design package. JPEG pixels are decoded on the first lookup.
/// Returns 1 if registered, or 0 if the image could not be read.
int32_t bz_asset_add_from_package(const char *name, const void *data, int32_t count);
/// Shows a picture that is not here yet by its glimpse (a JPEG a few dozen pixels across, from
/// whoever placed it in a shared design), until bz_asset_add brings the picture itself: grown to
/// `longest` across and blurred, as the Mac's LiveGlimpse.standIn makes it. Returns its asset
/// number, 0 when the picture is here already or the glimpse cannot be read.
int32_t bz_asset_stand_in(const char *name, const void *data, int32_t count, int32_t longest);
/// The pictures a drawing made, by the core's numbers (CGImage.Source).
void bz_picture_asset(int32_t id, int32_t asset);
void bz_picture_recording(int32_t id, int32_t width, int32_t height, const double *commands, int64_t count);
/// `crop` is x, y, width, height (width 0 for none); `blur` below 0 for none; `perspective` a
/// 3×3 matrix row by row, or null.
void bz_picture_changed(int32_t id, int32_t width, int32_t height, int32_t from,
                        const double *crop, double blur, int32_t clamp, const double *perspective);
void bz_picture_pixels(int32_t id, int32_t width, int32_t height, int32_t bytesPerRow, const uint8_t *bytes);
/// The changed picture `id`'s blur grows along a ramp instead: none at `ends` 0, 1 growing to
/// the whole blur at `ends` 2, 3, in the source's pixels from its top left.
void bz_picture_ramp(int32_t id, const double *ends);
/// A picture made by bz_picture_changed is a photo developed as the Mac develops it: haze away
/// (above nought) or over, then each colour through `cube` (`size` steps a side, red fastest, three
/// floats each; none when null), then clarity, texture and sharpness. `amounts`: dehaze, clarity,
/// texture, sharpness, as the Mac's kernels take them.
void bz_picture_develop(int32_t id, const float *cube, int32_t size, const double *amounts);

/// Makes picture `id` and writes its premultiplied pixels, RGBA (or BGRA with `bgra`), rows top
/// first, to `pixels`, which holds `width` × `height` × 4 bytes. Returns 0 when done.
int32_t bz_picture_read(int32_t id, int32_t width, int32_t height, int32_t bgra, void *pixels);

/// One piece of a film's frame (Host/FilmStage.swift): a picture the core made, placed in the
/// frame through `map`, a 3×3 matrix row by row from the picture's pixels to the frame's.
typedef struct bz_film_piece {
    int32_t picture;
    double map[9];
    double opacity;
    /// Its blur as the frame shows it, the sigma in the frame's pixels; 0 for none.
    double blur;
    /// What of it shows, in the picture's pixels: `count` points (3 to 9) of `outline`, x then y;
    /// below 3, all of it.
    int32_t count;
    double outline[18];
} bz_film_piece;

/// A film's frame: `backdrop` (r, g, b, a, premultiplied; null for none) and over it `count`
/// pieces, the lowest first, into premultiplied pixels, RGBA (or BGRA with `bgra`), rows top
/// first, `width` × `height` × 4 bytes. Returns 0 when done. On any thread.
int32_t bz_film_frame(int32_t width, int32_t height, const double *backdrop, const bz_film_piece *pieces, int32_t count,
                      int32_t bgra, void *pixels);

// MARK: Movies (movie.cpp)

/// A movie being written: H.264 in an MPEG-4 file, through Media Foundation's sink writer.
typedef struct bz_movie bz_movie;
/// Begins a movie at `path` (UTF-8) of `width` × `height` pixels (even), `fps` frames a second, at
/// about `bitrate` bits a second, its colours said to be sRGB (BT.709 primaries and matrix).
/// Null when it cannot be begun, with why in `error` (an HRESULT).
bz_movie *bz_movie_open(const char *path, int32_t width, int32_t height, int32_t fps, int64_t bitrate, int32_t *error);
/// Adds frame `index`: premultiplied BGRA pixels, rows top first, solid. 0 when added, else an
/// HRESULT. On any thread, one at a time.
int32_t bz_movie_add(bz_movie *movie, const void *pixels, int64_t index);
/// Ends the movie after `frames` frames and lets it go: 0 when the file is whole, else an HRESULT.
int32_t bz_movie_finish(bz_movie *movie, int64_t frames);
/// Gives the movie up and lets it go; what was written of it is left for the caller to remove.
void bz_movie_cancel(bz_movie *movie);
/// How far the last movie's work came before Windows refused a step, for saying where.
int32_t bz_movie_failed_step(void);
/// Forgets picture `id` and what was made of it: the core holds it no more.
void bz_picture_forget(int32_t id);
/// The shadow an artboard casts on the canvas: a `width` by `height` rectangle `dy` down, blurred
/// by `blur` (Core Graphics' measure: twice the sigma), in `rgb` at `alpha`, drawn into premultiplied
/// BGRA pixels `pad` larger on every side. Returns 0 when done.
int32_t bz_shadow(int32_t width, int32_t height, int32_t pad, double blur, double dy, uint32_t rgb, double alpha, void *pixels);
/// Home's table: `table` in a rectangle of radius 20 (points, at `scale` pixels each), a pool of
/// `light` at `strength` round (`x`, `y`) (fractions of the width and height) out to `reach` of the
/// diagonal, and black at `shade` towards the bottom; into BGRA pixels. Returns 0 when done.
int32_t bz_stage(int32_t width, int32_t height, double scale, uint32_t table, uint32_t light, double strength,
                 double x, double y, double reach, double shade, void *pixels);
/// Unpacks raw DEFLATE (RFC 1951, as Apple's COMPRESSION_ZLIB writes it, the icon library's
/// packing): keeps the bytes and returns their length, for bz_host_take; -1 if they cannot be.
int32_t bz_inflate(const void *bytes, int32_t count);
/// The same, into `out`, which holds `capacity` bytes, on any thread: how many bytes it wrote
/// (`capacity` when there were more), -1 if they cannot be unpacked.
int64_t bz_inflate_into(const void *bytes, int64_t count, void *out, int64_t capacity);
/// Writes pixels as bz_picture_read makes them to a PNG file at `path` (UTF-8). Returns 0 when done.
int32_t bz_png_write(const char *path, int32_t width, int32_t height, const void *pixels);
/// Premultiplied RGBA pixels as a picture file's bytes, `format` 0 PNG, 1 JPEG (as the Mac's
/// NSBitmapImageRep writes it, jpeg.cpp), `quality` 0…1: how many bytes, which `bz_host_take`
/// hands over; 0 when it could not be made.
int32_t bz_image_encode(int32_t width, int32_t height, const void *pixels, int32_t format, double quality);
/// Writes premultiplied RGBA pixels as a picture file: `format` 0 PNG, 1 JPEG (as the Mac's Image
/// I/O writes it, jpeg.cpp, saying `dpi` when more than 0), 2 WebP (lossless at a quality of 1),
/// 3 AVIF (as the Mac's Image I/O writes it, avif.cpp), `quality` 0…1. Returns 0 when written.
int32_t bz_image_write(const char *path, int32_t width, int32_t height, const void *pixels, int32_t format, double quality, double dpi);
/// 1 when this build reads and writes AVIF (Windows/avif.ps1 made libavif and libaom for it), else 0.
int32_t bz_avif_available(void);
/// Premultiplied RGBA pixels `width` by `height` drawn again at `toWidth` by `toHeight`, smoothly
/// (mipmaps and straight lines between pixels, as a thumbnail is made), into `out`. Returns 0
/// when done. On any thread.
int32_t bz_pixels_scale(const void *pixels, int32_t width, int32_t height, void *out, int32_t toWidth, int32_t toHeight);

// MARK: The subject matte (matte.cpp)
//
// BiRefNet with ONNX Runtime, for Remove Background: on the graphics card through DirectML or on
// the processor, as it is opened. Error and device texts are UTF-8, into buffers of `capacity`.

/// 2 when ONNX Runtime with DirectML is beside Bezzle, 1 with ONNX Runtime alone, 0 without.
int32_t bz_matte_available(void);
/// What of this PC decides how it makes a matte: its memory in `bytes`, its processor's `cores`
/// but for the efficiency cores, and of the graphics adapter a matte would run on (the fastest
/// Direct3D 12 runs on) the memory it has of its own in `dedicated`, whether it is Windows' own
/// on the processor in `software`, and its name. Returns 1 with such an adapter, 0 without one
/// (`dedicated` is 0 then). Asks Direct3D, so not for the main thread.
int32_t bz_matte_machine(int64_t *bytes, int32_t *cores, int64_t *dedicated, int32_t *software, char *name, int32_t capacity);
/// How short memory is just now: the share of it in use, in percent, in `load`, and the bytes
/// Windows can still hand out in `available`. Returns 1 when Windows said, else 0. On any thread.
int32_t bz_matte_memory(int32_t *load, int64_t *available);
/// What Bezzle has held, for measuring a way: the most memory since it started in `peak` and the
/// most it had asked Windows for in `asked`, and what the graphics adapter a matte runs on holds
/// for it just now, of its own memory in `card` and of the PC's in `shared`; all in bytes.
/// Returns 1 when Windows said, else 0. Asks Direct3D, so not for the main thread.
int32_t bz_matte_held(int64_t *peak, int64_t *asked, int64_t *card, int64_t *shared);
/// Opens the model at `path`: `device` 1 on the processor; 4 on the processor the lean way, which
/// holds no more than the model has in use at once and takes several times as long, for the same
/// matte; 3 on the graphics card; 2 through
/// DirectML on any adapter, Windows' software one too (for trying it where there is no card).
/// With 2 and 3 a card that cannot is an error, here and in any run after. 0 is the graphics card
/// if it can be, else the processor, a card that gives up in a run followed by the processor.
/// Says where it runs in `device_out`. Returns a handle, or null and why in `error`.
void *bz_matte_open(const char *path, int32_t device, char *error, int32_t capacity, char *device_out, int32_t deviceCapacity);
/// The side of the square the opened model takes its picture at, as its graph says; 0 where it
/// takes any size.
int32_t bz_matte_side(void *matte);
/// Runs the model on `input`, red, green and blue planes of `side` × `side` floats 0…1, into
/// `output`, `side` × `side` floats 0…1. Returns 0 when done, else why in `error`. On any thread;
/// one at a time.
int32_t bz_matte_run(void *matte, const float *input, int32_t side, float *output, char *error, int32_t capacity);
/// Where the model runs now, in words, into `out`: 1 on the graphics card, 0 on the processor.
int32_t bz_matte_device(void *matte, char *out, int32_t capacity);
void bz_matte_close(void *matte);
/// A PDF: begun at a path (0 if it cannot be), given pages, each a recorded picture the core made
/// at `scale` pixels a point and `width` by `height` points, and ended, which writes it.
int32_t bz_pdf_begin(const char *path);
int32_t bz_pdf_page(int32_t pdf, int32_t picture, double width, double height, double scale);
int32_t bz_pdf_end(int32_t pdf);

/// AES-256-GCM with Windows' own cryptography (sealing.cpp): `seal` 1 seals `count` bytes of
/// `input` into `output` and writes the 16-byte `tag`; 0 opens them, checking `tag`. A 32-byte
/// key and a 12-byte nonce. Returns 0 when done, and when opening, only if nothing was changed.
int32_t bz_gcm(int32_t seal, const uint8_t *key, const uint8_t *nonce, const uint8_t *aad, int32_t aadCount,
               const uint8_t *input, int64_t count, uint8_t *output, uint8_t *tag);
/// HMAC-SHA256 of `data` with `key` into the 32 bytes at `out`. Returns 0 when done.
int32_t bz_hmac_sha256(const uint8_t *key, int32_t keyCount, const uint8_t *data, int64_t count, uint8_t *out);

// MARK: Web pages (webview.cpp)
//
// Each a WebView2 of its own, out of sight, on a thread of its own: every call waits there for
// WebView2, so none is made on a thread that must keep answering (the window's). Bezzle's browser,
// which a person sees and uses, lives on the app's own thread instead (bz_web_host_here), and is
// asked from others all the same. Every page keeps its cookies and storage in Bezzle's own
// profile, so a sign-in lasts from one page and one launch to the next. Text is UTF-8.

/// Opens a web view laid out `width` by `height` CSS pixels, at `scale` device pixels each (0 for
/// the screen's), telling pages it is `agent` (empty for WebView2's own), with `awake` run in
/// every page before its own scripts. Returns its number, 0 when it could not be (bz_web_error).
int32_t bz_web_open(int32_t width, int32_t height, double scale, const char *agent, const char *awake);
/// Makes the calling thread, whose message loop keeps running (the app's main thread), the one
/// the browser's web view lives on. 0 when it is.
int32_t bz_web_host_here(void);
/// Opens the browser's web view on that thread, from another: as bz_web_open's, out of sight
/// until placed, a page asking to open a window of its own opening in it, and what a page asks
/// of a person (alerts, questions) asked of them while it is in a window. 0 when it could not be.
int32_t bz_web_open_shown(int32_t width, int32_t height, double scale, const char *agent, const char *scripts);
/// Lays the browser's view over `window` (a window of the app's thread) at `x`, `y` in it, laid
/// out `width` by `height` CSS pixels, `scale` device pixels each, in a window of its own that
/// `window` owns; with no window, out of sight at that size, where a page is read. Asked again when
/// `window` moves. 0 when done.
int32_t bz_web_place(int32_t view, void *window, double x, double y, int32_t width, int32_t height, double scale);
/// Back (1), forward (2), again (3), stop (4), or the keyboard to the page (5). 0 when done.
int32_t bz_web_go(int32_t view, int32_t what);
/// The browser's page as it is now, as JSON: its url, title, whether it can go back and forward,
/// and whether it is loading. Let go with bz_web_free.
char *bz_web_page(int32_t view);
/// Is told, on the app's thread, each time what bz_web_page says may have changed.
typedef void (*bz_web_watcher)(int32_t view);
void bz_web_watch(int32_t view, bz_web_watcher watcher);
/// Lays it out at another size, telling pages it is `agent` from the next one loaded. 0 when done.
int32_t bz_web_resize(int32_t view, int32_t width, int32_t height, const char *agent);
/// Starts loading the page at the address `text`, or `text` itself as a page with `isHTML`. 0 when begun.
int32_t bz_web_load(int32_t view, const char *text, int32_t isHTML);
/// How loading goes: 0 loading, 1 loaded, 2 failed, 3 the page stopped working. Failed, `error`
/// says why: 1 the server's certificate, 2 the connection was lost, 3 offline, 4 the server not
/// reached, 5 no server of that name, 6 too many redirects, 7 a password asked for, 8 too slow, 0
/// anything else. `status` the page's HTTP status (0 unknown), `navigations` how many loads have
/// begun, redirects and the page's own included.
int32_t bz_web_state(int32_t view, int32_t *status, int32_t *error, int32_t *navigations);
/// Calls the DevTools protocol's `method` with `params` (JSON), waiting up to `timeout`
/// milliseconds: 0 answered, 1 refused, -1 not asked, -2 no answer in time. `answer` gets the
/// answer's JSON (or why not), to be let go with bz_web_free.
int32_t bz_web_call(int32_t view, const char *method, const char *params, int32_t timeout, char **answer);
/// Lets the view go, and its window.
void bz_web_close(int32_t view);
/// Why the last view could not be opened, to be let go with bz_web_free.
char *bz_web_error(void);
void bz_web_free(void *pointer);

// MARK: WebSockets

/// A WebSocket through WinHTTP (websocket.cpp), for the live room's connection to the relay: each
/// call blocks on the thread that makes it; one may receive while another sends.
typedef struct bz_ws bz_ws;
/// Opens `path` (with its query) on `host`:`port`, over TLS with `secure`, with `headers` added
/// ("Name: value\r\n…"), giving up on connecting or sending after `timeout` ms. Null when it
/// could not, with Windows' error in `error` (100000 + the HTTP status when the server refused).
bz_ws *bz_ws_open(const wchar_t *host, int32_t port, int32_t secure, const wchar_t *path, const wchar_t *headers,
                  int32_t timeout, uint32_t *error);
/// Waits for the next whole message, into `*buffer` (grown with realloc to `*capacity`; the caller
/// frees it): its length, with `kind` 0 for binary and 1 for text, or -1 once the socket closed,
/// failed or was aborted, or the message grew past `limit`.
int64_t bz_ws_receive(bz_ws *ws, uint8_t **buffer, uint64_t *capacity, int32_t *kind, int64_t limit);
/// Sends one whole message, binary or text: 0 when sent.
int32_t bz_ws_send(bz_ws *ws, const void *data, uint64_t length, int32_t text);
/// Closes the socket, ending a receive or send waiting on it.
void bz_ws_abort(bz_ws *ws);
/// Lets it go, once nothing uses it any more.
void bz_ws_free(bz_ws *ws);

#ifdef __cplusplus
}
#endif
