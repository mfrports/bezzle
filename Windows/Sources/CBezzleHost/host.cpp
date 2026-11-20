// Bezzle's core on Windows, the part Skia does: see BezzleHost.h. Each piece follows its
// counterpart in Web/site/bezzle.mjs, which does the same with CanvasKit (Skia in the browser), so
// a design draws and measures here as it does there, and there as on the Mac.

#include "BezzleHost.h"
#include "avif-files.h"
#include "hdr.h"
#include "picture-files.h"

#include "include/core/SkBitmap.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkData.h"
#include "include/core/SkFont.h"
#include "include/core/SkFontMetrics.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkMaskFilter.h"
#include "include/core/SkBlurTypes.h"
#include "include/core/SkImage.h"
#include "include/core/SkPaint.h"
#include "include/core/SkPath.h"
#include "include/core/SkRRect.h"
#include "include/core/SkPathBuilder.h"
#include "include/core/SkPathUtils.h"
#include "include/core/SkStream.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTypeface.h"
#include "include/codec/SkCodec.h"
#include "include/codec/SkEncodedImageFormat.h"
#include "include/codec/SkEncodedOrigin.h"
#include "include/codec/SkJpegDecoder.h"
#include "include/codec/SkPngDecoder.h"
#include "include/codec/SkWebpDecoder.h"
#include "include/effects/SkDashPathEffect.h"
#include "include/encode/SkICC.h"
#include "include/encode/SkPngEncoder.h"
#include "include/encode/SkWebpEncoder.h"
#include "include/docs/SkPDFDocument.h"
#include "include/docs/SkPDFJpegHelpers.h"
#include "include/effects/SkGradient.h"
#include "include/effects/SkImageFilters.h"
#include "include/pathops/SkPathOps.h"
#include "include/ports/SkFontMgr_empty.h"
#include "modules/skcms/skcms.h"
#include "modules/skparagraph/include/FontCollection.h"
#include "modules/skparagraph/include/Paragraph.h"
#include "modules/skparagraph/include/ParagraphBuilder.h"
#include "modules/skparagraph/include/ParagraphStyle.h"
#include "modules/skparagraph/include/TextStyle.h"
#include "modules/skparagraph/include/TypefaceFontProvider.h"
#include "modules/skunicode/include/SkUnicode_icu.h"

#include <algorithm>
#include <array>
#include <iterator>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

using namespace skia::textlayout;

namespace {

std::mutex lock;

/// With BEZZLE_HOST_TRACE set, what a drawing asks for and is not there goes to stderr.
bool tracing() {
    static const bool on = getenv("BEZZLE_HOST_TRACE") != nullptr;
    return on;
}

std::vector<uint8_t> answer;

void keep(const std::vector<double>& values) {
    answer.resize(values.size() * sizeof(double));
    if (!values.empty()) memcpy(answer.data(), values.data(), answer.size());
}

// MARK: Paths, as CanvasKit's commands: a verb, then its points.

enum Verb { kMove = 0, kLine = 1, kQuad = 2, kConic = 3, kCubic = 4, kClose = 5 };

SkPath readPath(const double* c, size_t n, SkPathFillType fill) {
    SkPathBuilder b(fill);
    size_t i = 0;
    auto f = [&](size_t k) { return static_cast<float>(c[i + k]); };
    while (i < n) {
        switch (static_cast<int>(c[i++])) {
            case kMove: if (i + 2 > n) return b.detach(); b.moveTo(f(0), f(1)); i += 2; break;
            case kLine: if (i + 2 > n) return b.detach(); b.lineTo(f(0), f(1)); i += 2; break;
            case kQuad: if (i + 4 > n) return b.detach(); b.quadTo(f(0), f(1), f(2), f(3)); i += 4; break;
            case kConic: if (i + 5 > n) return b.detach(); b.conicTo(f(0), f(1), f(2), f(3), f(4)); i += 5; break;
            case kCubic: if (i + 6 > n) return b.detach(); b.cubicTo(f(0), f(1), f(2), f(3), f(4), f(5)); i += 6; break;
            case kClose: b.close(); break;
            default: return b.detach();
        }
    }
    return b.detach();
}

void writePath(const SkPath& path, std::vector<double>& out) {
    SkPath::Iter it(path, false);
    while (auto r = it.next()) {
        const auto& p = r->fPoints;
        switch (r->fVerb) {
            case SkPathVerb::kMove: out.insert(out.end(), {double(kMove), p[0].fX, p[0].fY}); break;
            case SkPathVerb::kLine: out.insert(out.end(), {double(kLine), p[1].fX, p[1].fY}); break;
            case SkPathVerb::kQuad: out.insert(out.end(), {double(kQuad), p[1].fX, p[1].fY, p[2].fX, p[2].fY}); break;
            case SkPathVerb::kConic:
                out.insert(out.end(), {double(kConic), p[1].fX, p[1].fY, p[2].fX, p[2].fY, r->fConicWeight});
                break;
            case SkPathVerb::kCubic:
                out.insert(out.end(), {double(kCubic), p[1].fX, p[1].fY, p[2].fX, p[2].fY, p[3].fX, p[3].fY});
                break;
            case SkPathVerb::kClose: out.push_back(double(kClose)); break;
        }
    }
}

SkPathFillType fillOf(double rule) { return rule == 1 ? SkPathFillType::kEvenOdd : SkPathFillType::kWinding; }

/// op, rule, then path A, path B and parameters, each counted: as bezzle.mjs's pathOp.
std::vector<double> pathOp(const double* v, size_t n) {
    std::vector<double> out;
    if (n < 3) return out;
    size_t i = 0;
    const int op = int(v[i++]);
    const auto fill = fillOf(v[i++]);
    const size_t nA = size_t(v[i++]); if (i + nA > n) return out;
    const double* a = v + i; i += nA;
    const size_t nB = i < n ? size_t(v[i++]) : 0; if (i + nB > n) return out;
    const double* b = v + i; i += nB;
    const size_t nP = i < n ? size_t(v[i++]) : 0; if (i + nP > n) return out;
    const double* p = v + i;
    const SkPath A = readPath(a, nA, fill);
    std::optional<SkPath> R;
    if (op >= 1 && op <= 4) {
        const SkPathOp ops[] = {kUnion_SkPathOp, kIntersect_SkPathOp, kDifference_SkPathOp, kXOR_SkPathOp};
        R = Op(A, readPath(b, nB, fill), ops[op - 1]);
    } else if (op == 5) {
        R = Simplify(A);
    } else if (op == 6 && nP >= 4) {
        SkPaint paint;
        paint.setStyle(SkPaint::kStroke_Style);
        paint.setStrokeWidth(float(p[0]));
        const SkPaint::Cap caps[] = {SkPaint::kButt_Cap, SkPaint::kRound_Cap, SkPaint::kSquare_Cap};
        const SkPaint::Join joins[] = {SkPaint::kMiter_Join, SkPaint::kRound_Join, SkPaint::kBevel_Join};
        paint.setStrokeCap(caps[std::clamp(int(p[1]), 0, 2)]);
        paint.setStrokeJoin(joins[std::clamp(int(p[2]), 0, 2)]);
        paint.setStrokeMiter(float(p[3]));
        R = skpathutils::FillPathWithPaint(A, paint);
    } else if (op == 7) {
        // makeDashed(on, off, phase): the dashes as a hairline would draw them, not stroked.
        const float on = nP > 1 ? float(p[1]) : 1, off = nP > 2 ? float(p[2]) : on;
        const float intervals[] = {on, off};
        SkPaint paint;
        paint.setStyle(SkPaint::kStroke_Style);
        paint.setStrokeWidth(0);
        paint.setPathEffect(SkDashPathEffect::Make(intervals, nP > 0 ? float(p[0]) : 0));
        R = skpathutils::FillPathWithPaint(A, paint);
    }
    if (R) writePath(*R, out);
    return out;
}

// MARK: Pictures

struct Asset {
    sk_sp<SkImage> image;
    /// An AVIF file's bytes, kept for developing it: an HDR picture is developed from its light as
    /// Core Image takes it in (`developFrom`, made the first time), not from what is drawn of it.
    std::shared_ptr<std::vector<uint8_t>> avifFile;
    bool developLooked = false;
    sk_sp<SkImage> developFrom;
};
std::vector<Asset> assets;                      // by number - 1
std::map<std::string, int> assetsByName;
std::map<std::string, sk_sp<SkImage>> pendingJPEGs;
/// The pictures shown by a glimpse of them until they come (bz_asset_stand_in).
std::set<std::string> standIns;

int keepAsset(const std::string& name, Asset asset) {
    assets.push_back(std::move(asset));
    const int number = int(assets.size());
    assetsByName[name] = number;
    standIns.erase(name);
    return number;
}

/// What an AVIF file's colours mean, as the Mac's Image I/O reads them: by its ICC profile when it
/// has one, else by its numbers (ITU-T H.273). Unspecified reads as sRGB, and so does the video
/// transfer of BT.709 (1, 6, 14, 15) with sRGB's or Display P3's primaries, as Image I/O has it;
/// with other primaries Image I/O takes that transfer for a plain gamma of 1.961, QuickTime's
/// (measured on a BT.2020 picture: 47 dB from the Mac's reading, where BT.1886's 2.4 gave 24).
sk_sp<SkColorSpace> avifColors(const avif::Picture& p) {
    if (!p.icc.empty()) {
        skcms_ICCProfile profile;
        if (skcms_Parse(p.icc.data(), p.icc.size(), &profile)) {
            if (auto colors = SkColorSpace::Make(profile)) return colors;
        }
    }
    const int primaries = p.primaries == 0 || p.primaries == 2 ? 1 : p.primaries;
    int transfer = p.transfer;
    const bool video = transfer == 1 || transfer == 6 || transfer == 14 || transfer == 15;
    if (transfer == 0 || transfer == 2 || (video && (primaries == 1 || primaries == 12))) transfer = 13;
    if (primaries == 1 && transfer == 13) return SkColorSpace::MakeSRGB();
    if (transfer != 13 && video) {
        const float* c = p.chromaticities;
        const SkColorSpacePrimaries chroma = {c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]};
        skcms_Matrix3x3 gamut;
        if (chroma.toXYZD50(&gamut)) return SkColorSpace::MakeRGB({1.961f, 1, 0, 0, 0, 0, 0}, gamut);
    }
    auto colors = SkColorSpace::MakeCICP(SkNamedPrimaries::CicpId(primaries), SkNamedTransferFn::CicpId(transfer));
    return colors ? colors : SkColorSpace::MakeSRGB();
}

/// The colours a picture is worked on in where the Mac keeps its own (CutoutMaker: "its colour
/// space when that is RGB, sRGB otherwise"): `space`, null for sRGB, and the ICC profile that
/// says so, the file's own bytes where it has one, so a cutout carries the profile its photo did.
struct OwnColors {
    sk_sp<SkColorSpace> space;
    std::vector<uint8_t> icc;
};

/// A picture's own colours, from its colour space as read and the ICC profile it carries, if any:
/// none (sRGB) where it is sRGB already, where its profile is not RGB (grey, CMYK, which the Mac
/// works on in sRGB), or where its light goes past white (PQ, HLG), which drawing brings down
/// to what a screen shows first.
OwnColors ownColors(const SkColorSpace* space, const uint8_t* icc, size_t iccSize) {
    OwnColors own;
    if (!space || space->isSRGB()) return own;
    skcms_TransferFunction fn;
    if (!space->isNumericalTransferFn(&fn)) return own;
    if (icc && iccSize) {
        skcms_ICCProfile profile;
        if (!skcms_Parse(icc, iccSize, &profile) || profile.data_color_space != skcms_Signature_RGB) return own;
        own.icc.assign(icc, icc + iccSize);
    } else {
        skcms_ICCProfile profile;
        space->toProfile(&profile);
        auto written = SkWriteICCProfile(&profile, "");
        if (!written) return own;
        own.icc.assign(written->bytes(), written->bytes() + written->size());
    }
    own.space = sk_ref_sp(space);
    return own;
}

/// Whether an AVIF picture's light goes past white (PQ or HLG), by its numbers or by those its
/// profile carries: its transfer and primaries, or 0 and 0.
std::pair<int, int> hdrKind(const avif::Picture& p) {
    if (!p.icc.empty()) {
        skcms_ICCProfile profile;
        if (skcms_Parse(p.icc.data(), p.icc.size(), &profile) && profile.has_CICP && hdr::isHDR(profile.CICP.transfer_characteristics)) {
            return {profile.CICP.transfer_characteristics, profile.CICP.color_primaries};
        }
        return {0, 0};
    }
    return hdr::isHDR(p.transfer) ? std::pair<int, int>{p.transfer, p.primaries} : std::pair<int, int>{0, 0};
}

/// An HDR picture as the Mac draws it into Bezzle's 8-bit sRGB pictures (hdr.h): tone mapped
/// from its own headroom, as Core Graphics maps it.
sk_sp<SkImage> hdrPicture(const avif::Picture& p, std::pair<int, int> kind) {
    const double headroom = hdr::headroom(p.maxCLL, p.mastering);
    auto* pixels = new std::vector<uint8_t>(hdr::toSRGB(p.pixels.data(), p.sixteen, p.width, p.height, kind.first, kind.second, headroom));
    const SkImageInfo info = SkImageInfo::Make(p.width, p.height, kRGBA_8888_SkColorType, p.opaque ? kOpaque_SkAlphaType : kPremul_SkAlphaType,
                                               SkColorSpace::MakeSRGB());
    auto bytes = SkData::MakeWithProc(pixels->data(), pixels->size(), [](const void*, void* kept) { delete static_cast<std::vector<uint8_t>*>(kept); }, pixels);
    return SkImages::RasterFromData(info, std::move(bytes), size_t(p.width) * 4);
}

/// An HDR picture as the Mac's Core Image takes it in to develop it (hdr.h, the ITU method):
/// linear light, 1 for reference white, nothing held to 0…1, in BT.2020's primaries or Display
/// P3's; null for any other picture.
sk_sp<SkImage> hdrDevelopFrom(const void* data, size_t count) {
    avif::Picture p;
    if (!avif::sniff(data, count) || !avif::read(data, count, true, p)) return nullptr;
    const auto kind = hdrKind(p);
    if (!kind.first) return nullptr;
    auto* light = new std::vector<float>(hdr::toDevelop(p.pixels.data(), p.sixteen, p.width, p.height, kind.first, kind.second));
    const auto space = SkColorSpace::MakeRGB(SkNamedTransferFn::kLinear, kind.second == hdr::p3 ? SkNamedGamut::kDisplayP3 : SkNamedGamut::kRec2020);
    const SkImageInfo info = SkImageInfo::Make(p.width, p.height, kRGBA_F32_SkColorType, kPremul_SkAlphaType, space);
    auto bytes = SkData::MakeWithProc(light->data(), light->size() * sizeof(float), [](const void*, void* kept) { delete static_cast<std::vector<float>*>(kept); }, light);
    return SkImages::RasterFromData(info, std::move(bytes), size_t(p.width) * 16);
}

/// An AVIF file's picture (Skia's codecs read none here): upright as its rotation and mirror turn
/// it, or as kept; null if it is none. Its own colours go to `own`, when asked. An HDR picture
/// comes as Bezzle's drawing shows it, brought down into sRGB as the Mac brings it.
sk_sp<SkImage> avifPicture(const void* data, size_t count, bool upright, OwnColors* own = nullptr) {
    avif::Picture p;
    if (!avif::read(data, count, upright, p)) return nullptr;
    if (const auto kind = hdrKind(p); kind.first) return hdrPicture(p, kind);
    const auto colors = avifColors(p);
    if (own) *own = ownColors(colors.get(), p.icc.data(), p.icc.size());
    const SkImageInfo info = SkImageInfo::Make(p.width, p.height, p.sixteen ? kR16G16B16A16_unorm_SkColorType : kRGBA_8888_SkColorType,
                                               p.opaque ? kOpaque_SkAlphaType : kPremul_SkAlphaType, colors);
    const size_t row = size_t(p.width) * (p.sixteen ? 8 : 4);
    auto* pixels = new std::vector<uint8_t>(std::move(p.pixels));
    auto bytes = SkData::MakeWithProc(pixels->data(), pixels->size(), [](const void*, void* kept) { delete static_cast<std::vector<uint8_t>*>(kept); }, pixels);
    return SkImages::RasterFromData(info, std::move(bytes), row);
}

/// A picture turned and mirrored as an Exif orientation says, to stand upright.
sk_sp<SkImage> turned(const sk_sp<SkImage>& image, SkEncodedOrigin origin) {
    if (!image || origin == kTopLeft_SkEncodedOrigin) return image;
    const bool across = SkEncodedOriginSwapsWidthHeight(origin);
    const int w = across ? image->height() : image->width(), h = across ? image->width() : image->height();
    auto surface = SkSurfaces::Raster(image->imageInfo().makeWH(w, h));
    if (!surface) return nullptr;
    SkCanvas* canvas = surface->getCanvas();
    canvas->clear(SK_ColorTRANSPARENT);
    canvas->concat(SkEncodedOriginToMatrix(origin, image->width(), image->height()));
    SkPaint paint;
    paint.setBlendMode(SkBlendMode::kSrc);
    canvas->drawImage(image, 0, 0, SkSamplingOptions(), &paint);
    return surface->makeImageSnapshot();
}

/// An HEIF file's picture (HEIC), which Skia's codecs do not read, as Windows reads it where it
/// can (heif.cpp): upright as its rotation and mirror turn it, or as kept; in its own colours.
/// Null where Windows cannot read it, heif::lastProblem() saying why. Its own colours go to
/// `own`, when asked.
sk_sp<SkImage> heifPicture(const void* data, size_t count, bool upright, OwnColors* own = nullptr) {
    heif::Picture p;
    if (heif::read(data, count, p) != heif::none) return nullptr;
    sk_sp<SkColorSpace> colors = SkColorSpace::MakeSRGB();
    if (!p.icc.empty()) {
        skcms_ICCProfile profile;
        if (skcms_Parse(p.icc.data(), p.icc.size(), &profile)) {
            if (auto c = SkColorSpace::Make(profile)) colors = c;
        }
    }
    if (own) *own = ownColors(colors.get(), p.icc.data(), p.icc.size());
    const SkImageInfo info = SkImageInfo::Make(p.width, p.height, kRGBA_8888_SkColorType, kPremul_SkAlphaType, colors);
    auto* pixels = new std::vector<uint8_t>(std::move(p.pixels));
    auto bytes = SkData::MakeWithProc(pixels->data(), pixels->size(), [](const void*, void* kept) { delete static_cast<std::vector<uint8_t>*>(kept); }, pixels);
    auto image = SkImages::RasterFromData(info, std::move(bytes), size_t(p.width) * 4);
    return upright ? turned(image, SkEncodedOrigin(std::clamp(p.orientation, 1, 8))) : image;
}

void registerImageDecoders() {
    static std::once_flag registered;
    std::call_once(registered, [] {
        SkCodecs::Register(SkPngDecoder::Decoder());
        SkCodecs::Register(SkJpegDecoder::Decoder());
        SkCodecs::Register(SkWebpDecoder::Decoder());
    });
}

sk_sp<SkImage> rasterWithMipmaps(const sk_sp<SkImage>& image) {
    // With mipmaps, as the page makes them, for pictures drawn smaller.
    auto raster = image ? image->makeRasterImage(nullptr) : nullptr;
    return raster ? raster->withDefaultMipmaps() : nullptr;
}

sk_sp<SkImage> decode(const void* data, size_t count) {
    registerImageDecoders();
    if (!data || !count) return nullptr;
    // Upright, as the Mac reads a design's pictures (Canvas/Assets.swift, with the transform).
    if (avif::sniff(data, count)) {
        auto image = avifPicture(data, count, true);
        return image ? image->withDefaultMipmaps() : nullptr;
    }
    if (heif::sniff(data, count)) {
        auto image = heifPicture(data, count, true);
        return image ? image->withDefaultMipmaps() : nullptr;
    }
    return rasterWithMipmaps(SkImages::DeferredFromEncodedData(SkData::MakeWithCopy(data, count)));
}

extern "C" int32_t bz_image_size(const void* data, int32_t count, int32_t* width, int32_t* height) {
    if (avif::sniff(data, size_t(count))) {
        int w = 0, h = 0;
        if (!avif::size(data, size_t(count), true, &w, &h)) return 0;
        *width = w;
        *height = h;
        return 1;
    }
    if (heif::sniff(data, size_t(count))) {
        int w = 0, h = 0;
        if (heif::size(data, size_t(count), true, &w, &h) != heif::none) return 0;
        *width = w;
        *height = h;
        return 1;
    }
    registerImageDecoders();
    auto codec = SkCodec::MakeFromData(SkData::MakeWithoutCopy(data, size_t(count)));
    if (!codec) return 0;
    const auto d = codec->dimensions();
    // Turned on its side by its orientation, it is as wide as it is tall.
    const bool turned = SkEncodedOriginSwapsWidthHeight(codec->getOrigin());
    *width = turned ? d.height() : d.width();
    *height = turned ? d.width() : d.height();
    return d.width() > 0 && d.height() > 0 ? 1 : 0;
}

// Pictures in files being brought in from other apps (Import/, through the ImageIO stand-ins in
// Windows/Sources/BezzleCore/Import): read and written as Image I/O does, as the pixels are kept,
// not turned by their orientation. On any thread.

extern "C" int32_t bz_image_pixel_size(const void* data, int64_t count, int32_t* width, int32_t* height) {
    // Cropped to its clean aperture, as Image I/O counts it, but not turned.
    if (avif::sniff(data, size_t(count))) {
        int w = 0, h = 0;
        if (!avif::size(data, size_t(count), false, &w, &h)) return 0;
        *width = w;
        *height = h;
        return 1;
    }
    if (heif::sniff(data, size_t(count))) {
        int w = 0, h = 0;
        if (heif::size(data, size_t(count), false, &w, &h) != heif::none) return 0;
        *width = w;
        *height = h;
        return 1;
    }
    registerImageDecoders();
    auto codec = SkCodec::MakeFromData(SkData::MakeWithoutCopy(data, size_t(count)));
    if (!codec) return 0;
    const auto d = codec->dimensions();
    *width = d.width();
    *height = d.height();
    return d.width() > 0 && d.height() > 0 ? 1 : 0;
}

extern "C" int32_t bz_image_decode(const void* data, int64_t count, int32_t width, int32_t height, void* pixels) {
    if (avif::sniff(data, size_t(count))) {
        auto image = avifPicture(data, size_t(count), false);
        if (!image || image->width() != width || image->height() != height) return 1;
        // In sRGB, as Skia's codecs give the others.
        const SkImageInfo info = SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
        return image->readPixels(nullptr, info, pixels, size_t(width) * 4, 0, 0) ? 0 : 2;
    }
    if (heif::sniff(data, size_t(count))) {
        auto image = heifPicture(data, size_t(count), false);
        if (!image || image->width() != width || image->height() != height) return 1;
        const SkImageInfo info = SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
        return image->readPixels(nullptr, info, pixels, size_t(width) * 4, 0, 0) ? 0 : 2;
    }
    registerImageDecoders();
    auto codec = SkCodec::MakeFromData(SkData::MakeWithoutCopy(data, size_t(count)));
    if (!codec || codec->dimensions().width() != width || codec->dimensions().height() != height) return 1;
    const SkImageInfo info = SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    const auto result = codec->getPixels(info, pixels, size_t(width) * 4);
    return result == SkCodec::kSuccess || result == SkCodec::kIncompleteInput || result == SkCodec::kErrorInInput ? 0 : 2;
}

extern "C" int64_t bz_png_encode(int32_t width, int32_t height, const void* pixels, int32_t straight, void* out, int64_t capacity) {
    const SkImageInfo info = SkImageInfo::Make(std::max(1, width), std::max(1, height), kRGBA_8888_SkColorType,
                                               straight ? kUnpremul_SkAlphaType : kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    SkDynamicMemoryWStream stream;
    // Packed less tightly than Skia would (its 6), as the Mac's Image I/O packs them: a mockup's
    // full-size layers are written in about half the time, and still no larger than the Mac's.
    SkPngEncoder::Options options;
    options.fZLibLevel = 3;
    if (!SkPngEncoder::Encode(&stream, SkPixmap(info, pixels, size_t(width) * 4), options)) return -1;
    const int64_t size = int64_t(stream.bytesWritten());
    if (size > capacity) return -size;
    stream.copyTo(out);
    return size;
}

extern "C" int64_t bz_jpeg_encode(int32_t width, int32_t height, const void* pixels, double quality, void* out, int64_t capacity) {
    std::vector<uint8_t> bytes;
    if (!jpeg::write(width, height, static_cast<const uint8_t*>(pixels), quality, 0, bytes)) return -1;
    const int64_t size = int64_t(bytes.size());
    if (size > capacity) return -size;
    std::memcpy(out, bytes.data(), bytes.size());
    return size;
}

/// A picture file's picture small, as Image I/O makes a thumbnail with its transform (see
/// bz_image_thumbnail): in sRGB, or with `own`, in the picture's own colours, which go to `colors`.
int32_t thumbnail(const void* data, int64_t count, int32_t longest, int32_t* width, int32_t* height, void* pixels, OwnColors* colors) {
    if (!data || count <= 0 || longest <= 0) return 0;
    // The picture upright, as large as needed to come out sharp at its small size: a JPEG read
    // straight at a half, a quarter or an eighth, which is quick even for a large photo.
    sk_sp<SkImage> source;
    SkEncodedOrigin origin = kTopLeft_SkEncodedOrigin;
    // Its size as kept, whatever size it is read at; whether it is a JPEG.
    SkISize kept = {0, 0};
    bool jpeg = false;
    OwnColors own;
    if (avif::sniff(data, size_t(count))) {
        source = avifPicture(data, size_t(count), true, colors ? &own : nullptr);
        if (source) kept = source->dimensions();
    } else if (heif::sniff(data, size_t(count))) {
        source = heifPicture(data, size_t(count), true, colors ? &own : nullptr);
        if (source) kept = source->dimensions();
    } else {
        registerImageDecoders();
        auto codec = SkCodec::MakeFromData(SkData::MakeWithoutCopy(data, size_t(count)));
        if (!codec) return 0;
        origin = codec->getOrigin();
        jpeg = codec->getEncodedFormat() == SkEncodedImageFormat::kJPEG;
        if (colors) {
            const skcms_ICCProfile* profile = codec->getICCProfile();
            if (profile && profile->data_color_space != skcms_Signature_RGB) {
                // Grey or CMYK: sRGB, as the Mac works on it.
            } else {
                const bool kept = profile && profile->buffer && profile->size;
                own = ownColors(codec->getInfo().colorSpace(), kept ? profile->buffer : nullptr, kept ? profile->size : 0);
            }
        }
        const auto full = codec->dimensions();
        kept = full;
        const float want = std::min(1.0f, 2.0f * float(longest) / float(std::max(full.width(), full.height())));
        for (const SkISize size : {codec->getScaledDimensions(want), full}) {
            SkBitmap bitmap;
            if (!bitmap.tryAllocPixels(SkImageInfo::Make(size, kRGBA_8888_SkColorType, kPremul_SkAlphaType,
                                                         own.space ? own.space : SkColorSpace::MakeSRGB()))) return 0;
            const auto result = codec->getPixels(bitmap.pixmap());
            if (result == SkCodec::kSuccess || result == SkCodec::kIncompleteInput || result == SkCodec::kErrorInInput) {
                bitmap.setImmutable();
                source = bitmap.asImage();
                break;
            }
        }
    }
    if (!source) return 0;
    const bool across = SkEncodedOriginSwapsWidthHeight(origin);
    // Upright: as read, and as kept.
    const double uw = across ? source->height() : source->width(), uh = across ? source->width() : source->height();
    // As large as Image I/O makes a thumbnail, measured on macOS 27 for sixteen shapes: a JPEG
    // brought to `longest` along its longer side, rounding (1200 by 800 to 32 by 21); any other
    // halved first, rounding down, for as long as its longer side stays `longest` or more (a PNG
    // of 1200 by 800 to 32 by 22, 900 by 600 to 32 by 21). Never larger than it is. (HEIC comes
    // out a pixel apart at times: Image I/O makes it some other way, not matched here.)
    double fw = across ? kept.height() : kept.width(), fh = across ? kept.width() : kept.height();
    if (std::max(fw, fh) > longest) {
        while (!jpeg && std::floor(std::max(fw, fh) / 2) >= longest) {
            fw = std::floor(fw / 2);
            fh = std::floor(fh / 2);
        }
        const double k = double(longest) / std::max(fw, fh);
        fw *= k;
        fh *= k;
    }
    const int w = std::max(1, int(std::lround(fw))), h = std::max(1, int(std::lround(fh)));
    const SkImageInfo info = SkImageInfo::Make(w, h, kRGBA_8888_SkColorType, kPremul_SkAlphaType,
                                               own.space ? own.space : SkColorSpace::MakeSRGB());
    auto surface = SkSurfaces::Raster(info);
    if (!surface) return 0;
    SkCanvas* canvas = surface->getCanvas();
    canvas->clear(SK_ColorTRANSPARENT);
    canvas->scale(float(w / uw), float(h / uh));
    canvas->concat(SkEncodedOriginToMatrix(origin, source->width(), source->height()));
    SkPaint paint;
    paint.setBlendMode(SkBlendMode::kSrc);
    canvas->drawImage(source->withDefaultMipmaps(), 0, 0, SkSamplingOptions(SkFilterMode::kLinear, SkMipmapMode::kLinear), &paint);
    if (!surface->readPixels(info, pixels, size_t(w) * 4, 0, 0)) return 0;
    *width = w;
    *height = h;
    if (colors) *colors = std::move(own);
    return 1;
}

extern "C" int32_t bz_image_thumbnail(const void* data, int64_t count, int32_t longest, int32_t* width, int32_t* height, void* pixels) {
    return thumbnail(data, count, longest, width, height, pixels, nullptr);
}

extern "C" int32_t bz_image_thumbnail_own(const void* data, int64_t count, int32_t longest, int32_t* width, int32_t* height, void* pixels,
                                          void* icc, int32_t iccCapacity) {
    OwnColors own;
    if (!thumbnail(data, count, longest, width, height, pixels, &own)) return -1;
    if (!own.icc.empty() && int64_t(own.icc.size()) <= int64_t(iccCapacity)) std::memcpy(icc, own.icc.data(), own.icc.size());
    return int32_t(own.icc.size());
}

/// The colour space an ICC profile says, null for sRGB (none given) or a profile Skia cannot take.
sk_sp<SkColorSpace> profileColors(const void* icc, int32_t count) {
    if (!icc || count <= 0) return SkColorSpace::MakeSRGB();
    skcms_ICCProfile profile;
    if (!skcms_Parse(icc, size_t(count), &profile)) return nullptr;
    return SkColorSpace::Make(profile);
}

extern "C" int32_t bz_pixels_convert(const void* pixels, int32_t width, int32_t height, const void* fromICC, int32_t fromCount,
                                     const void* toICC, int32_t toCount, void* out) {
    const auto from = profileColors(fromICC, fromCount), to = profileColors(toICC, toCount);
    if (!from || !to || width <= 0 || height <= 0) return 1;
    const SkPixmap source(SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType, from), pixels, size_t(width) * 4);
    return source.readPixels(SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType, to), out, size_t(width) * 4) ? 0 : 2;
}

extern "C" int32_t bz_heif_sniff(const void* data, int64_t count) { return heif::sniff(data, size_t(count)) ? 1 : 0; }

extern "C" int32_t bz_heif_problem(void) { return int32_t(heif::lastProblem()); }

void loadPendingJPEG(const std::string& name) {
    if (auto pending = pendingJPEGs.find(name); pending != pendingJPEGs.end()) {
        auto image = rasterWithMipmaps(pending->second);
        pendingJPEGs.erase(pending);
        // If decoding fails, keep any image or glimpse already registered under this name.
        if (image) keepAsset(name, Asset{std::move(image)});
    }
}

/// A picture by name: its number, width and height, or 0 when there is none (bezzle.mjs's image).
std::vector<double> imageByName(const double* v, size_t n) {
    std::string name;
    for (size_t i = 0; i < n; i++) name.push_back(char(int(v[i])));
    loadPendingJPEG(name);
    auto it = assetsByName.find(name);
    if (it == assetsByName.end()) {
        if (tracing()) fprintf(stderr, "[host] no asset %s\n", name.c_str());
        return {0};
    }
    const auto& image = assets[it->second - 1].image;
    return {double(it->second), double(image->width()), double(image->height())};
}

struct Picture {
    enum Kind { kAsset, kRecording, kChanged, kPixels } kind = kAsset;
    int width = 0, height = 0;
    int asset = 0;
    std::vector<double> commands;
    int from = 0;
    double crop[4] = {0, 0, 0, 0};
    double blur = -1;
    bool clamp = false;
    bool hasPerspective = false;
    double perspective[9] = {};
    bool hasRamp = false;
    double ramp[4] = {};
    int bytesPerRow = 0;
    std::vector<uint8_t> pixels;
    /// A photo developed (bz_picture_develop): its colour cube, `cubeSize` a side, and the rest.
    bool develops = false;
    std::vector<float> cube;
    int cubeSize = 0;
    double dehaze = 0, clarity = 0, texture = 0, sharpness = 0;
};
std::map<int, Picture> pictures;
std::map<int, sk_sp<SkImage>> made;

sk_sp<SkImage> get(int id);
void play(SkCanvas* canvas, const double* c, size_t n);

SkImageInfo rgba(int w, int h) {
    return SkImageInfo::Make(std::max(1, w), std::max(1, h), kRGBA_8888_SkColorType, kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
}

template <typename Draw> sk_sp<SkImage> raster(int w, int h, Draw draw) {
    auto surface = SkSurfaces::Raster(rgba(w, h));
    if (!surface) return nullptr;
    SkCanvas* canvas = surface->getCanvas();
    canvas->clear(SK_ColorTRANSPARENT);
    draw(canvas);
    return surface->makeImageSnapshot();
}

// MARK: Developing photos, as the Mac's Developer does with Core Image

namespace develop {

inline float encode(float x) {
    const float a = std::fabs(x);
    const float v = a <= 0.0031308f ? a * 12.92f : 1.055f * std::pow(a, 1.0f / 2.4f) - 0.055f;
    return x < 0 ? -v : v;
}
inline float decode(float x) {
    const float a = std::fabs(x);
    const float v = a <= 0.04045f ? a / 12.92f : std::pow((a + 0.055f) / 1.055f, 2.4f);
    return x < 0 ? -v : v;
}
inline float luma(const float* c) { return 0.2126f * c[0] + 0.7152f * c[1] + 0.0722f * c[2]; }

SkImageInfo linear(int w, int h) {
    return SkImageInfo::Make(w, h, kRGBA_F32_SkColorType, kPremul_SkAlphaType, SkColorSpace::MakeSRGBLinear());
}

/// A picture as Core Image works on it: light itself, premultiplied, four floats a pixel.
std::vector<float> read(const sk_sp<SkImage>& image, int w, int h) {
    std::vector<float> px(size_t(w) * h * 4);
    auto surface = SkSurfaces::Raster(linear(w, h));
    if (!surface) return {};
    surface->getCanvas()->clear(SK_ColorTRANSPARENT);
    SkPaint paint;
    paint.setBlendMode(SkBlendMode::kSrc);
    surface->getCanvas()->drawImageRect(image, SkRect::MakeWH(float(w), float(h)), SkSamplingOptions(SkFilterMode::kLinear, SkMipmapMode::kLinear), &paint);
    surface->readPixels(linear(w, h), px.data(), size_t(w) * 16, 0, 0);
    return px;
}

/// The same pixels blurred by `sigma`, their edges carried on outward first, as Core Image's
/// clamped Gaussian blur is: in light, as Core Image blurs.
std::vector<float> blurred(const std::vector<float>& px, int w, int h, float sigma) {
    SkPixmap source(linear(w, h), px.data(), size_t(w) * 16);
    auto image = SkImages::RasterFromPixmapCopy(source);
    auto surface = SkSurfaces::Raster(linear(w, h));
    std::vector<float> out(px.size());
    if (!image || !surface) return px;
    SkPaint paint;
    paint.setBlendMode(SkBlendMode::kSrc);
    paint.setImageFilter(SkImageFilters::Blur(sigma, sigma, SkTileMode::kClamp, nullptr));
    surface->getCanvas()->drawImage(image, 0, 0, SkSamplingOptions(), &paint);
    surface->readPixels(linear(w, h), out.data(), size_t(w) * 16, 0, 0);
    return out;
}

/// A pixel as the Mac's kernels see it: unpremultiplied, through the sRGB curve.
inline void seen(const float* p, float* c) {
    const float a = p[3];
    for (int k = 0; k < 3; k++) c[k] = encode(a > 0.0001f ? p[k] / a : 0);
}

/// The colour of a picture's haze: that of its haziest part, where even its darkest colour is
/// lightest, as a sky usually is (the Mac's Developer.air), from the picture read small.
void air(const sk_sp<SkImage>& image, float out[3]) {
    out[0] = out[1] = out[2] = 0.9f;
    const int w0 = image->width(), h0 = image->height();
    const double s = std::min(1.0, 96.0 / std::max(w0, h0));
    const int w = std::max(1, int(std::lround(w0 * s))), h = std::max(1, int(std::lround(h0 * s)));
    const SkImageInfo info = SkImageInfo::Make(w, h, kRGBA_8888_SkColorType, kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    auto surface = SkSurfaces::Raster(info);
    if (!surface) return;
    surface->getCanvas()->clear(SK_ColorTRANSPARENT);
    surface->getCanvas()->drawImageRect(image, SkRect::MakeWH(float(w), float(h)), SkSamplingOptions(SkFilterMode::kLinear, SkMipmapMode::kLinear), nullptr);
    std::vector<uint8_t> px(size_t(w) * h * 4);
    surface->readPixels(info, px.data(), size_t(w) * 4, 0, 0);
    std::vector<std::pair<float, std::array<float, 3>>> darks;
    for (size_t i = 0; i < size_t(w) * h; i++) {
        const float a = px[i * 4 + 3] / 255.0f;
        if (a <= 0.5f) continue;
        const std::array<float, 3> c = {px[i * 4] / 255.0f / a, px[i * 4 + 1] / 255.0f / a, px[i * 4 + 2] / 255.0f / a};
        darks.push_back({std::min({c[0], c[1], c[2]}), c});
    }
    std::sort(darks.begin(), darks.end(), [](const auto& x, const auto& y) { return x.first > y.first; });
    const size_t top = std::max<size_t>(1, darks.size() / 100);
    if (darks.empty()) return;
    float sum[3] = {0, 0, 0};
    for (size_t i = 0; i < top && i < darks.size(); i++) for (int k = 0; k < 3; k++) sum[k] += darks[i].second[k];
    const size_t n = std::min(top, darks.size());
    for (int k = 0; k < 3; k++) out[k] = std::clamp(sum[k] / float(n), 0.45f, 1.0f);
}

/// The haze taken away, or more laid over, after the dark channel prior (the Mac's
/// Developer.dehazed and its bezzleDehaze kernel), worked out on a quarter of the picture.
void dehaze(std::vector<float>& px, int w, int h, double amount, const float air[3]) {
    const double longest = std::max(w, h);
    const int qw = std::max(1, int(std::lround(w * 0.25))), qh = std::max(1, int(std::lround(h * 0.25)));
    // A quarter of the picture, its darkest colour round about each pixel, softened.
    std::vector<float> small(size_t(qw) * qh * 4);
    for (int y = 0; y < qh; y++) {
        for (int x = 0; x < qw; x++) {
            // Box-sampled down, as a quarter scale averages what it covers.
            float sum[4] = {0, 0, 0, 0};
            int count = 0;
            for (int dy = 0; dy < 4; dy++) for (int dx = 0; dx < 4; dx++) {
                const int sx = std::min(w - 1, x * 4 + dx), sy = std::min(h - 1, y * 4 + dy);
                const float* p = &px[(size_t(sy) * w + sx) * 4];
                for (int k = 0; k < 4; k++) sum[k] += p[k];
                count++;
            }
            float* o = &small[(size_t(y) * qw + x) * 4];
            const float m = std::min({sum[0], sum[1], sum[2]}) / count;
            o[0] = o[1] = o[2] = m;
            o[3] = sum[3] / count;
        }
    }
    const int reach = std::max(1, int(std::lround(longest * 0.25 * 0.01)));
    // The darkest in a square `reach` each way: across, then down.
    std::vector<float> across(small.size());
    for (int y = 0; y < qh; y++) for (int x = 0; x < qw; x++) {
        float m[4] = {1e9f, 1e9f, 1e9f, 1e9f};
        for (int d = -reach; d <= reach; d++) {
            const int sx = std::clamp(x + d, 0, qw - 1);
            const float* p = &small[(size_t(y) * qw + sx) * 4];
            for (int k = 0; k < 4; k++) m[k] = std::min(m[k], p[k]);
        }
        std::copy(m, m + 4, &across[(size_t(y) * qw + x) * 4]);
    }
    for (int y = 0; y < qh; y++) for (int x = 0; x < qw; x++) {
        float m[4] = {1e9f, 1e9f, 1e9f, 1e9f};
        for (int d = -reach; d <= reach; d++) {
            const int sy = std::clamp(y + d, 0, qh - 1);
            const float* p = &across[(size_t(sy) * qw + x) * 4];
            for (int k = 0; k < 4; k++) m[k] = std::min(m[k], p[k]);
        }
        std::copy(m, m + 4, &small[(size_t(y) * qw + x) * 4]);
    }
    small = blurred(small, qw, qh, float(reach * 1.6));
    const float a = std::max((air[0] + air[1] + air[2]) / 3.0f, 0.2f);
    const float amt = float(amount);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            float* e = &px[(size_t(y) * w + x) * 4];
            if (e[3] <= 0.0001f) continue;
            // The dark round about, laid back over the whole picture, smoothly.
            const float fx = std::clamp((x + 0.5f) / 4 - 0.5f, 0.0f, float(qw - 1)), fy = std::clamp((y + 0.5f) / 4 - 0.5f, 0.0f, float(qh - 1));
            const int x0 = int(fx), y0 = int(fy), x1 = std::min(x0 + 1, qw - 1), y1 = std::min(y0 + 1, qh - 1);
            const float tx = fx - x0, ty = fy - y0;
            auto at = [&](int xx, int yy, int k) { return small[(size_t(yy) * qw + xx) * 4 + k]; };
            float dark[2];
            for (int k = 0; k < 2; k++) {
                const int ch = k == 0 ? 0 : 3;
                dark[k] = (at(x0, y0, ch) * (1 - tx) + at(x1, y0, ch) * tx) * (1 - ty) + (at(x0, y1, ch) * (1 - tx) + at(x1, y1, ch) * tx) * ty;
            }
            float c[3];
            seen(e, c);
            const float d = std::clamp(encode(dark[1] > 0.0001f ? dark[0] / dark[1] : 0) / a, 0.0f, 1.0f);
            if (amt > 0) {
                const float t = std::max(1 - amt * 0.92f * d, 0.22f);
                for (int k = 0; k < 3; k++) c[k] = (c[k] - air[k]) / t + air[k] + (1 - t) * 0.18f * amt;
            } else {
                const float m = -amt * 0.62f * (0.3f + 0.7f * d);
                for (int k = 0; k < 3; k++) c[k] = c[k] + (air[k] - c[k]) * m;
            }
            for (int k = 0; k < 3; k++) e[k] = decode(c[k]) * e[3];
        }
    }
}

/// Light from one gamut's primaries to another's (linear sRGB to linear Display P3 and back).
inline void mix(const skcms_Matrix3x3& m, const float* in, float* out) {
    for (int r = 0; r < 3; r++) out[r] = m.vals[r][0] * in[0] + m.vals[r][1] * in[1] + m.vals[r][2] * in[2];
}

/// Each colour, as it looks, through the cube, as Core Image's colour cube in sRGB takes it:
/// unpremultiplied, the nearest eight of its steps mixed. With `into` and `back`, in another
/// colour space with sRGB's curve, as the Mac takes a Display P3 photo's colours through it in
/// Display P3 (CIColorCubeWithColorSpace): its light into that space's primaries and back.
void cube(std::vector<float>& px, const std::vector<float>& lut, int n, const skcms_Matrix3x3* into = nullptr, const skcms_Matrix3x3* back = nullptr) {
    if (n < 2 || lut.size() < size_t(n) * n * n * 3) return;
    const float top = float(n - 1);
    for (size_t i = 0; i < px.size(); i += 4) {
        float* p = &px[i];
        const float a = p[3];
        if (a <= 0.0001f) continue;
        float c[3], light[3] = {p[0] / a, p[1] / a, p[2] / a};
        if (into) {
            float there[3];
            mix(*into, light, there);
            std::copy(there, there + 3, light);
        }
        for (int k = 0; k < 3; k++) c[k] = std::clamp(encode(light[k]), 0.0f, 1.0f) * top;
        const int r0 = std::min(int(c[0]), n - 2), g0 = std::min(int(c[1]), n - 2), b0 = std::min(int(c[2]), n - 2);
        const float tr = c[0] - r0, tg = c[1] - g0, tb = c[2] - b0;
        float out[3] = {0, 0, 0};
        for (int db = 0; db < 2; db++) for (int dg = 0; dg < 2; dg++) for (int dr = 0; dr < 2; dr++) {
            const float wgt = (dr ? tr : 1 - tr) * (dg ? tg : 1 - tg) * (db ? tb : 1 - tb);
            const float* e = &lut[((size_t(b0 + db) * n + (g0 + dg)) * n + (r0 + dr)) * 3];
            for (int k = 0; k < 3; k++) out[k] += e[k] * wgt;
        }
        for (int k = 0; k < 3; k++) light[k] = decode(out[k]);
        if (back) {
            float here[3];
            mix(*back, light, here);
            std::copy(here, here + 3, light);
        }
        for (int k = 0; k < 3; k++) p[k] = light[k] * a;
    }
}

/// Clarity, texture and sharpness, as the Mac's bezzleDetail kernel: the difference from a wide
/// blur in the middle tones, the band between a fine and a middling blur, and the difference
/// from the finest blur in lightness only. Each blur is taken in turn, to keep only two at once.
void detail(std::vector<float>& px, int w, int h, double clarity, double texture, double sharpness) {
    const double longest = std::max(w, h);
    const size_t count = size_t(w) * h;
    // What each pixel becomes as it looks, from how it looks to begin with.
    std::vector<float> o(count * 3), c(count * 3);
    for (size_t i = 0; i < count; i++) seen(&px[i * 4], &o[i * 3]);
    c = o;
    auto sigma = [&](double part, double least) { return float(std::max(longest * part, least)); };
    if (clarity != 0) {
        const auto wide = blurred(px, w, h, sigma(0.014, 2));
        for (size_t i = 0; i < count; i++) {
            if (px[i * 4 + 3] <= 0.0001f) continue;
            float s[3];
            seen(&wide[i * 4], s);
            const float l = std::clamp(luma(s), 0.0f, 1.0f);
            const float m = 1 - std::pow(std::fabs(2 * l - 1), 2.2f);
            for (int k = 0; k < 3; k++) c[i * 3 + k] += float(clarity) * m * (o[i * 3 + k] - s[k]);
        }
    }
    if (texture != 0) {
        const auto mid = blurred(px, w, h, sigma(0.0045, 1.5));
        const auto fine = blurred(px, w, h, sigma(0.0011, 0.6));
        for (size_t i = 0; i < count; i++) {
            if (px[i * 4 + 3] <= 0.0001f) continue;
            float f[3], md[3];
            seen(&fine[i * 4], f);
            seen(&mid[i * 4], md);
            // Not where it would push deep shadows to black or bright skies to white.
            const float m = 1 - std::pow(std::fabs(2 * std::clamp(luma(&o[i * 3]), 0.0f, 1.0f) - 1), 3.0f);
            for (int k = 0; k < 3; k++) c[i * 3 + k] += float(texture) * m * (f[k] - md[k]);
        }
    }
    if (sharpness != 0) {
        const auto tiny = blurred(px, w, h, sigma(0.00045, 0.7));
        for (size_t i = 0; i < count; i++) {
            if (px[i * 4 + 3] <= 0.0001f) continue;
            float t[3];
            seen(&tiny[i * 4], t);
            const float d = std::clamp(luma(&o[i * 3]) - luma(t), -0.25f, 0.25f);
            for (int k = 0; k < 3; k++) c[i * 3 + k] += float(sharpness) * d;
        }
    }
    for (size_t i = 0; i < count; i++) {
        float* p = &px[i * 4];
        if (p[3] <= 0.0001f) continue;
        for (int k = 0; k < 3; k++) p[k] = decode(c[i * 3 + k]) * p[3];
    }
}

}  // namespace develop

/// Whether a picture's colours are Display P3's, by its primaries and white, as the Mac's
/// Developer asks whether its colour space is a P3 one.
bool isP3(const SkColorSpace* space) {
    skcms_Matrix3x3 m;
    if (!space || !space->toXYZD50(&m)) return false;
    for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++) {
        if (std::fabs(m.vals[r][c] - SkNamedGamut::kDisplayP3.vals[r][c]) > 0.002f) return false;
    }
    return true;
}

/// A photo developed as the Mac's Developer develops it, from the picture as it is: in Display P3
/// when it is a Display P3 photo, so its brightest colours are kept, and sRGB otherwise.
sk_sp<SkImage> developed(const sk_sp<SkImage>& from, const Picture& d) {
    const int w = from->width(), h = from->height();
    auto px = develop::read(from, w, h);
    if (px.empty()) return from;
    const auto p3 = isP3(from->colorSpace()) ? SkColorSpace::MakeRGB(SkNamedTransferFn::kSRGB, SkNamedGamut::kDisplayP3) : nullptr;
    if (d.dehaze != 0) {
        float air[3];
        develop::air(from, air);
        develop::dehaze(px, w, h, d.dehaze, air);
    }
    if (!d.cube.empty()) {
        if (p3) {
            skcms_Matrix3x3 into, back;
            SkColorSpace::MakeSRGB()->gamutTransformTo(p3.get(), &into);
            p3->gamutTransformTo(SkColorSpace::MakeSRGB().get(), &back);
            develop::cube(px, d.cube, d.cubeSize, &into, &back);
        } else {
            develop::cube(px, d.cube, d.cubeSize);
        }
    }
    if (d.clarity != 0 || d.texture != 0 || d.sharpness != 0) develop::detail(px, w, h, d.clarity, d.texture, d.sharpness);
    // Back into sRGB (or Display P3), eight bits a channel, as the Mac's developed pictures are.
    SkPixmap done(develop::linear(w, h), px.data(), size_t(w) * 16);
    auto image = SkImages::RasterFromPixmapCopy(done);
    if (!image) return from;
    auto surface = SkSurfaces::Raster(SkImageInfo::Make(w, h, kRGBA_8888_SkColorType, kPremul_SkAlphaType, p3 ? p3 : SkColorSpace::MakeSRGB()));
    if (!surface) return from;
    surface->getCanvas()->clear(SK_ColorTRANSPARENT);
    SkPaint paint;
    paint.setBlendMode(SkBlendMode::kSrc);
    surface->getCanvas()->drawImage(image, 0, 0, SkSamplingOptions(), &paint);
    return surface->makeImageSnapshot();
}

sk_sp<SkImage> make(const Picture& d) {
    switch (d.kind) {
        case Picture::kAsset:
            return d.asset > 0 && size_t(d.asset) <= assets.size() ? assets[d.asset - 1].image : nullptr;
        case Picture::kRecording:
            return raster(d.width, d.height, [&](SkCanvas* canvas) {
                // Core Graphics' space: y up from the bottom left.
                canvas->concat(SkMatrix::MakeAll(1, 0, 0, 0, -1, float(d.height), 0, 0, 1));
                play(canvas, d.commands.data(), d.commands.size());
            });
        case Picture::kChanged: {
            auto from = get(d.from);
            if (!from) return nullptr;
            if (d.develops) {
                // An HDR picture from its light, as the Mac's Core Image takes it in.
                auto source = from;
                if (auto it = pictures.find(d.from); it != pictures.end() && it->second.kind == Picture::kAsset && it->second.asset > 0
                    && size_t(it->second.asset) <= assets.size()) {
                    Asset& asset = assets[size_t(it->second.asset) - 1];
                    if (!asset.developLooked && asset.avifFile) asset.developFrom = hdrDevelopFrom(asset.avifFile->data(), asset.avifFile->size());
                    asset.developLooked = true;
                    if (asset.developFrom) source = asset.developFrom;
                }
                return developed(source, d);
            }
            const double crop[4] = {d.crop[2] > 0 ? d.crop[0] : 0, d.crop[2] > 0 ? d.crop[1] : 0, 0, 0};
            return raster(d.width, d.height, [&](SkCanvas* canvas) {
                canvas->translate(float(-crop[0]), float(-crop[1]));
                if (d.hasPerspective) {
                    const double* m = d.perspective;
                    canvas->concat(SkMatrix::MakeAll(float(m[0]), float(m[1]), float(m[2]), float(m[3]), float(m[4]),
                                                     float(m[5]), float(m[6]), float(m[7]), float(m[8])));
                }
                const SkSamplingOptions sampling(SkFilterMode::kLinear, SkMipmapMode::kNone);
                const SkTileMode tiles = d.clamp ? SkTileMode::kClamp : SkTileMode::kDecal;
                if (d.hasRamp && d.blur > 0) {
                    // A blur growing along the ramp: the picture at a few strengths, from sharp to
                    // the whole blur, each weighed by how near the ramp is to it there, and added
                    // up. The weights always come to one, so it blends from one to the next.
                    const int levels = 5;
                    const SkPoint ends[2] = {{float(d.ramp[0]), float(d.ramp[1])}, {float(d.ramp[2]), float(d.ramp[3])}};
                    for (int k = 0; k < levels; k++) {
                        const float at = float(k) / float(levels - 1), step = 1.0f / float(levels - 1);
                        std::vector<SkColor4f> colors;
                        std::vector<float> positions;
                        if (k > 0) { positions.push_back(at - step); colors.push_back({0, 0, 0, 0}); }
                        positions.push_back(at);
                        colors.push_back({0, 0, 0, 1});
                        if (k < levels - 1) { positions.push_back(at + step); colors.push_back({0, 0, 0, 0}); }
                        if (positions.size() == 1) { positions.insert(positions.begin(), 0); colors.insert(colors.begin(), {0, 0, 0, 1}); }
                        SkPaint weigh;
                        weigh.setShader(SkShaders::LinearGradient(ends, SkGradient(SkGradient::Colors(colors, positions, SkTileMode::kClamp), {})));
                        weigh.setBlendMode(SkBlendMode::kDstIn);
                        SkPaint sum;
                        sum.setBlendMode(SkBlendMode::kPlus);
                        canvas->saveLayer(nullptr, &sum);
                        SkPaint level;
                        const float sigma = float(d.blur) * at;
                        if (sigma > 0.01f) level.setImageFilter(SkImageFilters::Blur(sigma, sigma, tiles, nullptr));
                        canvas->drawImage(from, 0, 0, sampling, &level);
                        canvas->drawPaint(weigh);
                        canvas->restore();
                    }
                } else {
                    SkPaint paint;
                    if (d.blur >= 0) paint.setImageFilter(SkImageFilters::Blur(float(d.blur), float(d.blur), tiles, nullptr));
                    canvas->drawImage(from, 0, 0, sampling, &paint);
                }
            });
        }
        case Picture::kPixels: {
            if (d.pixels.empty()) return nullptr;
            return SkImages::RasterFromData(rgba(d.width, d.height), SkData::MakeWithCopy(d.pixels.data(), d.pixels.size()), size_t(d.bytesPerRow));
        }
    }
    return nullptr;
}

sk_sp<SkImage> get(int id) {
    if (auto it = made.find(id); it != made.end()) return it->second;
    auto it = pictures.find(id);
    if (it == pictures.end()) {
        if (tracing()) fprintf(stderr, "[host] no picture %d\n", id);
        return nullptr;
    }
    auto image = make(it->second);
    made[id] = image;
    return image;
}

// MARK: Text, through Skia's paragraphs (bezzle.mjs's style, paragraph, slice and textCall)

sk_sp<SkFontMgr> fontManager() {
    static sk_sp<SkFontMgr> manager = SkFontMgr_New_Custom_Empty();
    return manager;
}
sk_sp<TypefaceFontProvider> provider = sk_make_sp<TypefaceFontProvider>();
sk_sp<FontCollection> collection;
sk_sp<SkUnicode> unicode;
std::map<std::string, sk_sp<SkTypeface>> faces;   // "family|face"
/// The faces Windows has of its own that an open font was given under the same name before, which
/// Skia knows by that name and "|own" (bz_font_add_at).
std::set<std::string> owned;
std::map<std::string, double> leadings;

}  // namespace

extern "C" int32_t bz_fallback_font(uint32_t character, int32_t emoji, int32_t weight, int32_t italic, int32_t stretch,
                                    wchar_t* path, int32_t capacity, int32_t* index);

namespace {

/// The font Windows falls back on for a letter (fallback.cpp asks DirectWrite which), read by
/// Skia: each file once, mapped rather than copied, and kept; nothing where there is none.
/// The families of the fonts fallen back on, for telling their letters from the text's own.
std::set<std::string> fallbackFamilies;

sk_sp<SkTypeface> fallenBackOn(SkUnichar character, bool emoji, const SkFontStyle& style) {
    static std::map<std::wstring, sk_sp<SkTypeface>> read;
    constexpr int32_t room = 1024;
    wchar_t path[room] = {0};
    int32_t index = 0;
    if (!bz_fallback_font(uint32_t(character), emoji, style.weight(), style.slant() != SkFontStyle::kUpright_Slant, style.width(),
                          path, room, &index)) {
        return nullptr;
    }
    const std::wstring key = std::wstring(path) + L"|" + std::to_wstring(index);
    if (auto it = read.find(key); it != read.end()) return it->second;
    sk_sp<SkTypeface> typeface;
    if (FILE* file = _wfopen(path, L"rb")) {
        if (auto data = SkData::MakeFromFILE(file)) typeface = fontManager()->makeFromData(std::move(data), index);
        fclose(file);
    }
    if (typeface) {
        SkString family;
        typeface->getFamilyName(&family);
        fallbackFamilies.insert(family.c_str());
    }
    read[key] = typeface;
    return typeface;
}

/// How far the fonts fallen back on reach above and below a line's baseline, and their leading
/// (the most of each), for a line as tall as Text Kit makes one whose letters some other font
/// has; nought where the line has none of theirs.
std::array<double, 3> fallbackRise(Paragraph* line) {
    std::array<double, 3> rise = {0, 0, 0};
    if (!line || fallbackFamilies.empty()) return rise;
    line->visit([&](int, const Paragraph::VisitorInfo* info) {
        if (!info || !info->font.getTypeface()) return;
        SkString family;
        info->font.getTypeface()->getFamilyName(&family);
        if (!fallbackFamilies.count(family.c_str())) return;
        SkFontMetrics m;
        info->font.getMetrics(&m);
        rise[0] = std::max(rise[0], double(-m.fAscent));
        rise[1] = std::max(rise[1], double(m.fDescent));
        rise[2] = std::max(rise[2], double(m.fLeading));
    });
    return rise;
}

/// Windows' own fonts for letters none of a text's fonts has, as Core Text falls back on the
/// Mac's: Skia asks only for those letters, after the run's own font and the system font's
/// stand-in, at the weight and slant of the run's face, and for an emoji without a family,
/// which then is to be in colour.
class SystemFallback final : public SkFontMgr {
protected:
    int onCountFamilies() const override { return 0; }
    void onGetFamilyName(int, SkString*) const override {}
    sk_sp<SkFontStyleSet> onCreateStyleSet(int) const override { return nullptr; }
    sk_sp<SkFontStyleSet> onMatchFamily(const char[]) const override { return nullptr; }
    sk_sp<SkTypeface> onMatchFamilyStyle(const char[], const SkFontStyle&) const override { return nullptr; }
    sk_sp<SkTypeface> onMatchFamilyStyleCharacter(const char family[], const SkFontStyle& style, const char*[], int,
                                                  SkUnichar character) const override {
        return fallenBackOn(character, family == nullptr, style);
    }
    sk_sp<SkTypeface> onMakeFromData(sk_sp<SkData>, int) const override { return nullptr; }
    sk_sp<SkTypeface> onMakeFromStreamIndex(std::unique_ptr<SkStreamAsset>, int) const override { return nullptr; }
    sk_sp<SkTypeface> onMakeFromStreamArgs(std::unique_ptr<SkStreamAsset>, const SkFontArguments&) const override { return nullptr; }
    sk_sp<SkTypeface> onMakeFromFile(const char[], int) const override { return nullptr; }
    sk_sp<SkTypeface> onLegacyMakeTypeface(const char[], SkFontStyle) const override { return nullptr; }
};

/// Whether letters asked to look like emoji (U+FE0F after them) are set in Windows' colour emoji
/// first, as Core Text sets them in Apple Color Emoji whatever font the text is in: the open
/// fonts have plain outlines of some (a heart, a sun) that the Mac's fonts do not. Registered
/// as the family "Emoji|" the first time it is needed.
bool colourEmoji() {
    static int state = 0;
    if (state == 0) {
        auto typeface = getenv("BEZZLE_NO_FALLBACK") ? nullptr : fallenBackOn(0x1F600, true, SkFontStyle());
        if (typeface) provider->registerTypeface(typeface, SkString("Emoji|"));
        state = typeface ? 1 : 2;
    }
    return state == 1;
}

/// Where letters asked to look like emoji begin and end in `text` (UTF-16): each one before a
/// U+FE0F, with the selector, a keycap, skin tones, tags and what a joiner joins to them.
std::vector<std::pair<size_t, size_t>> emojiAsked(const std::u16string& text) {
    std::vector<std::pair<size_t, size_t>> out;
    if (text.find(u'\uFE0F') == std::u16string::npos) return out;
    auto next = [&](size_t at) -> std::pair<uint32_t, size_t> {
        const char16_t c = text[at];
        if (c >= 0xD800 && c < 0xDC00 && at + 1 < text.size()) return {0x10000 + ((uint32_t(c) - 0xD800) << 10) + (uint32_t(text[at + 1]) - 0xDC00), 2};
        return {uint32_t(c), 1};
    };
    size_t at = 0;
    while (at < text.size()) {
        const auto [c, n] = next(at);
        if (at + n < text.size() && text[at + n] == 0xFE0F) {
            size_t end = at + n + 1;
            while (end < text.size()) {
                const auto [d, m] = next(end);
                const bool joins = d == 0x200D && end + m < text.size();
                if (d == 0xFE0F || d == 0x20E3 || (d >= 0x1F3FB && d <= 0x1F3FF) || (d >= 0xE0020 && d <= 0xE007F)) {
                    end += m;
                } else if (joins) {
                    end += m;
                    end += next(end).second;
                } else {
                    break;
                }
            }
            if (!out.empty() && out.back().second == at) out.back().second = end; else out.push_back({at, end});
            at = end;
        } else {
            at += n;
        }
    }
    return out;
}

sk_sp<FontCollection> fonts() {
    if (!collection) {
        collection = sk_make_sp<FontCollection>();
        collection->setDefaultFontManager(provider);
        // Asked for letters only when no font of the run has them: it knows no families.
        if (!getenv("BEZZLE_NO_FALLBACK")) collection->setDynamicFontManager(sk_make_sp<SystemFallback>());
        collection->enableFontFallback();
        unicode = SkUnicodes::ICU::Make();
    }
    return collection;
}

struct Run {
    std::u16string text;
    std::string family, face;
    double size, tracking, weight, opticalSize;
    bool underline, strike, hasColor;
    SkColor4f color;
    std::string features, axes;
    /// Skia's word spacing: what each gap between words takes more (justified lines of joining letters).
    double wordSpacing = 0;
};

/// "tag=value,tag=value" as pairs of four-letter tags and numbers.
std::vector<std::pair<std::string, double>> tagged(const std::string& list) {
    std::vector<std::pair<std::string, double>> out;
    size_t at = 0;
    while (at < list.size()) {
        size_t end = list.find(',', at);
        if (end == std::string::npos) end = list.size();
        std::string item = list.substr(at, end - at);
        size_t eq = item.find('=');
        if (eq == 4) out.push_back({item.substr(0, 4), std::atof(item.c_str() + 5)});
        at = end + 1;
    }
    return out;
}

SkFourByteTag fourBytes(const std::string& t) { return SkSetFourByteTag(t[0], t[1], t[2], t[3]); }

std::u16string utf16(const char* s) {
    std::u16string out;
    for (const unsigned char* p = reinterpret_cast<const unsigned char*>(s); *p;) {
        uint32_t c = *p++;
        int more = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : c >= 0xC0 ? 1 : 0;
        if (more) c &= (0x3F >> more);
        for (; more > 0 && (*p & 0xC0) == 0x80; more--) c = (c << 6) | (*p++ & 0x3F);
        if (c >= 0x10000) {
            c -= 0x10000;
            out.push_back(char16_t(0xD800 + (c >> 10)));
            out.push_back(char16_t(0xDC00 + (c & 0x3FF)));
        } else {
            out.push_back(char16_t(c));
        }
    }
    return out;
}

TextStyle style(const Run& run) {
    TextStyle s;
    s.setFontSize(float(run.size));
    s.setLetterSpacing(float(run.tracking));
    if (run.wordSpacing != 0) s.setWordSpacing(float(run.wordSpacing));
    s.setColor(run.hasColor ? run.color.toSkColor() : SK_ColorTRANSPARENT);
    // The font's OpenType features as the layer sets them, and its axes: the system font's weight
    // and optical size by its face and size, unless the layer sets them itself.
    const auto features = tagged(run.features);
    for (const auto& [tag, value] : features) s.addFontFeature(SkString(tag.c_str()), int(value));
    // The Mac always sets letters' spacing (Text Kit's kern), and set to nought, Core Text leaves
    // out the font's own kerning between pairs such as "Te"; set to anything else, it keeps it.
    const bool kernSet = std::any_of(features.begin(), features.end(), [](const auto& f) { return f.first == "kern"; });
    if (run.tracking == 0 && !kernSet) s.addFontFeature(SkString("kern"), 0);
    std::vector<SkFontArguments::VariationPosition::Coordinate> axes;
    const auto set = tagged(run.axes);
    auto has = [&](const char* tag) { for (const auto& a : set) if (a.first == tag) return true; return false; };
    if (run.family == "System") {
        s.setFontFamilies({SkString("System")});
        if (!has("wght")) axes.push_back({SkSetFourByteTag('w', 'g', 'h', 't'), float(run.weight > 0 ? run.weight : 400)});
        if (run.opticalSize > 0 && !has("opsz")) axes.push_back({SkSetFourByteTag('o', 'p', 's', 'z'), float(run.opticalSize)});
    } else {
        const std::string name = run.family + "|" + run.face;
        s.setFontFamilies({SkString((owned.count(name) ? name + "|own" : name).c_str()), SkString("System")});
    }
    for (const auto& [tag, value] : set) axes.push_back({fourBytes(tag), float(value)});
    if (!axes.empty()) {
        SkFontArguments arguments;
        arguments.setVariationDesignPosition({axes.data(), int(axes.size())});
        s.setFontArguments(arguments);
    }
    // How heavy and leaning the face is, which a font fallen back on for letters it lacks takes.
    const bool leans = run.face.find("Italic") != std::string::npos || run.face.find("Oblique") != std::string::npos;
    s.setFontStyle(SkFontStyle(int(run.weight > 0 ? run.weight : 400), SkFontStyle::kNormal_Width,
                               leans ? SkFontStyle::kItalic_Slant : SkFontStyle::kUpright_Slant));
    int decoration = TextDecoration::kNoDecoration;
    if (run.underline) decoration |= TextDecoration::kUnderline;
    if (run.strike) decoration |= TextDecoration::kLineThrough;
    if (decoration) {
        s.setDecoration(TextDecoration(decoration));
        s.setDecorationColor(s.getColor());
    }
    return s;
}

/// Runs set as one paragraph `width` wide, aligned 0 left, 1 center, 2 right, 3 justified, read from
/// right to left when `rtl` says so. A tab is set as a space, which its spacing widens to its stop.
std::unique_ptr<Paragraph> paragraph(const std::vector<Run>& runs, const Run& first, double width, int align, bool rtl = false) {
    ParagraphStyle ps;
    const TextAlign aligns[] = {TextAlign::kLeft, TextAlign::kCenter, TextAlign::kRight, TextAlign::kJustify};
    ps.setTextAlign(aligns[std::clamp(align, 0, 3)]);
    ps.setTextDirection(rtl ? TextDirection::kRtl : TextDirection::kLtr);
    ps.setReplaceTabCharacters(true);
    ps.setTextStyle(style(first));
    // Set at the width given, as Text Kit sets lines: Skia otherwise narrows it to whole points
    // and rounds lines' heights and widths, as Flutter wants.
    ps.setApplyRoundingHack(false);
    // Each face as it is: never made bolder or slanted where it is not, as the Mac does not.
    ps.setFakeMissingFontStyles(false);
    // fonts() first: it makes `unicode` too, and arguments are evaluated in no set order.
    auto collection = fonts();
    auto builder = ParagraphBuilder::make(ps, collection, unicode);
    for (const auto& r : runs) {
        const auto asked = emojiAsked(r.text);
        if (asked.empty() || !colourEmoji()) {
            builder->pushStyle(style(r));
            builder->addText(r.text);
            builder->pop();
            continue;
        }
        // Letters asked to look like emoji in Windows' colour emoji, the rest as they are.
        TextStyle plain = style(r), emoji = plain;
        emoji.setFontFamilies({SkString("Emoji|"), SkString("System")});
        size_t at = 0;
        for (const auto& [a, z] : asked) {
            if (a > at) { builder->pushStyle(plain); builder->addText(r.text.substr(at, a - at)); builder->pop(); }
            builder->pushStyle(emoji);
            builder->addText(r.text.substr(a, z - a));
            builder->pop();
            at = z;
        }
        if (at < r.text.size()) { builder->pushStyle(plain); builder->addText(r.text.substr(at)); builder->pop(); }
    }
    auto p = builder->Build();
    p->layout(float(width));
    return p;
}

/// The runs of [start, end) of the words, in UTF-16, as Skia and Text Kit both count.
std::vector<Run> slice(const std::vector<Run>& runs, size_t start, size_t end) {
    std::vector<Run> out;
    size_t at = 0;
    for (const auto& r : runs) {
        const size_t a = std::max(start, at), z = std::min(end, at + r.text.size());
        if (z > a) {
            Run part = r;
            part.text = r.text.substr(a - at, z - a);
            out.push_back(part);
        }
        at += r.text.size();
    }
    return out;
}

double leadingOf(const Run& run) {
    if (run.family == "System") return 0;
    const std::string key = run.family + "|" + run.face + "|" + std::to_string(run.size);
    if (auto it = leadings.find(key); it != leadings.end()) return it->second;
    double leading = 0;
    if (auto it = faces.find(run.family + "|" + run.face); it != faces.end()) {
        SkFont font(it->second, float(run.size));
        SkFontMetrics metrics;
        font.getMetrics(&metrics);
        leading = metrics.fLeading;
    }
    leadings[key] = leading;
    return leading;
}

struct Text {
    /// Each line on its own, where Skia puts its baseline, and how far to the left it is drawn:
    /// Skia puts half the letters' spacing before each, Core Text all of it after, which shows in
    /// lines set from the left (centred or set from the right, Skia's lines lie where the Mac's do).
    /// Its words too, from `start` on in the text's (UTF-16), for telling which a letter is of.
    /// Its runs too, for the lines under and through its letters when it is outlined.
    struct Line { std::unique_ptr<Paragraph> paragraph; double baseline; double back; size_t start = 0; std::u16string words; std::vector<Run> runs; };
    std::vector<Line> lines;
    std::vector<double> baselines;
};
std::map<int, Text> texts;
int nextText = 1;

/// A text set as one line for a curve, or a straight text's letters taken one by one: each letter
/// drawn on its own where the core places it, and where in the words (UTF-16) it is from.
struct Glyph { SkFont font; SkGlyphID id; int32_t at = 0; };
std::map<int, std::vector<Glyph>> glyphLines;

/// How many bytes UTF-8 takes for these letters, as Skia counts its clusters.
size_t utf8Length(const std::u16string& s) {
    size_t n = 0;
    for (size_t k = 0; k < s.size(); k++) {
        const char16_t c = s[k];
        if (c >= 0xD800 && c < 0xDC00 && k + 1 < s.size()) { n += 4; k++; }
        else n += c < 0x80 ? 1 : c < 0x800 ? 2 : 3;
    }
    return n;
}

/// Where in these letters (UTF-16) the one `utf8` bytes into them as UTF-8 is.
size_t utf16Index(const std::u16string& s, size_t utf8) {
    size_t n = 0;
    for (size_t k = 0; k < s.size(); k++) {
        if (n >= utf8) return k;
        const char16_t c = s[k];
        if (c >= 0xD800 && c < 0xDC00 && k + 1 < s.size()) { n += 4; k++; }
        else n += c < 0x80 ? 1 : c < 0x800 ? 2 : 3;
    }
    return s.size();
}

/// Whether a letter ends a line wherever it is: a paragraph's end or a line break.
bool breaksLine(char16_t u) { return u == 0x0A || u == 0x0D || u == 0x2028 || u == 0x2029 || u == 0x85; }

/// Whether a letter ends a paragraph, as the Unicode bidi algorithm counts them (a line break,
/// U+2028, does not).
bool endsParagraph(char16_t u) { return u == 0x0A || u == 0x0D || u == 0x2029 || u == 0x85 || (u >= 0x1C && u <= 0x1E); }

/// The spaces a justified line is spread at, as Text Kit counts them: a no-break space is a letter.
bool spreadsAt(char16_t u) {
    return u == 0x20 || u == 0x09 || (u >= 0x2000 && u <= 0x200A && u != 0x2007) || u == 0x205F || u == 0x3000 || u == 0x1680;
}

/// Whether a letter is of a script whose letters join (Arabic and its like), whose runs Skia
/// never spaces apart (Run::isCursiveScript).
bool joins(char16_t u) {
    return (u >= 0x0600 && u <= 0x08FF && !(u >= 0x0780 && u <= 0x07BF)) || (u >= 0x1800 && u <= 0x18AF) || (u >= 0xA840 && u <= 0xA87F)
        || (u >= 0xFB50 && u <= 0xFDFF) || (u >= 0xFE70 && u <= 0xFEFF);
}

/// Which way a letter reads, where it has a way of its own: 1 right to left (Hebrew, Arabic and
/// their like), -1 left to right (letters of other scripts), 0 none (spaces, digits, punctuation,
/// symbols). Close enough to Unicode's bidi classes for telling which way a paragraph runs.
int reads(const std::u16string& s, size_t k) {
    const char16_t u = s[k];
    if (u >= 0xD800 && u < 0xDC00 && k + 1 < s.size()) {
        const uint32_t c = 0x10000 + ((uint32_t(u) - 0xD800) << 10) + (uint32_t(s[k + 1]) - 0xDC00);
        if ((c >= 0x10800 && c <= 0x10FFF) || (c >= 0x1E800 && c <= 0x1EFFF)) return 1;
        if (c >= 0x1F000 && c <= 0x1FFFF) return 0;
        return -1;
    }
    if ((u >= 0x0590 && u <= 0x08FF) || (u >= 0xFB1D && u <= 0xFDFF) || (u >= 0xFE70 && u <= 0xFEFE)) return 1;
    if ((u >= 'A' && u <= 'Z') || (u >= 'a' && u <= 'z') || u == 0xAA || u == 0xB5 || u == 0xBA) return -1;
    if (u >= 0xC0 && u <= 0x24F) return u == 0xD7 || u == 0xF7 ? 0 : -1;
    if ((u >= 0x370 && u <= 0x58F) || (u >= 0x900 && u <= 0x1FFF) || (u >= 0x2C00 && u <= 0x2DFF) || (u >= 0x3040 && u <= 0xD7FF)
        || (u >= 0xF900 && u <= 0xFB1C)) return -1;
    return 0;
}

/// Whether the paragraph that `from` is in reads from right to left, as Text Kit takes it (its
/// paragraphs' writing direction is natural): by its first letter that reads one way or the other.
bool rightToLeft(const std::u16string& s, size_t from) {
    size_t start = from;
    while (start > 0 && !endsParagraph(s[start - 1])) start--;
    for (size_t k = start; k < s.size() && !endsParagraph(s[k]); k++) {
        if (const int way = reads(s, k)) return way > 0;
    }
    return false;
}

/// The faces Text Kit spreads as a justification table of their own says (Courier's 'just'
/// table): their spaces grow by up to their size on either side, their letters not at all.
bool ownJustification(const Run& r) { return r.family == "Courier"; }

/// A justified line's runs spread to `width`, as Text Kit spreads a line that is not its
/// paragraph's last (measured on the Mac, as bezzle.mjs's spreadOut). Each letter can grow on its
/// left and on its right, both by up to 0.1445 of its size, and each space by up to half its
/// size; between a letter and a space to its right neither grows (where both are of a face
/// without a table of its own). The spaces grow first, all by the same part of what they can;
/// then the letters; then the spaces again, without end, or, on a line without spaces, the
/// letters. Courier's spaces grow by up to their size on either side, and its letters not at
/// all, so that a line of Courier without spaces is not spread. Only what follows a line's last
/// tab is spread: what comes before stays where the tab stops put it. All of this as the letters
/// lie from left to right, which is how Text Kit grows them in words read from right to left too.
/// Each letter takes what it grows to its right as Skia's letter spacing, which Skia also puts
/// to a letter's right. Letters that join (Arabic) Text Kit lengthens with kashidas, which Skia
/// cannot set and whose runs it never spaces apart: there the spaces between words take it all,
/// evenly, as Skia's word spacing. Empty when it needs no spreading or cannot be spread.
std::vector<Run> spreadOut(const std::vector<Run>& runs, Paragraph* line, double width) {
    std::vector<LineMetrics> lm;
    line->getLineMetrics(lm);
    const double extra = width - (lm.empty() ? 0 : lm[0].fWidth);
    if (!(extra > 0.001)) return {};
    std::u16string words;
    std::vector<size_t> runAt;
    for (size_t r = 0; r < runs.size(); r++) {
        words += runs[r].text;
        runAt.insert(runAt.end(), runs[r].text.size(), r);
    }
    // Where each letter Skia sets lies, left to right, by where it begins in the words: one for each
    // letter, however many glyphs it is drawn with.
    struct Spot { size_t at; double x; };
    std::vector<Spot> spots;
    line->visit([&](int, const Paragraph::VisitorInfo* info) {
        if (!info) return;
        for (int k = 0; k < info->count; k++) spots.push_back({utf16Index(words, info->utf8Starts[k]), double(info->origin.fX + info->positions[k].fX)});
    });
    std::stable_sort(spots.begin(), spots.end(), [](const Spot& a, const Spot& b) { return a.x < b.x; });
    size_t lastTab = std::u16string::npos;
    for (size_t k = 0; k < words.size(); k++) if (words[k] == u'\t') lastTab = k;
    std::vector<Spot> letters;
    std::vector<bool> seen(words.size() + 1, false);
    for (const auto& s : spots) {
        if (s.at >= words.size() || seen[s.at] || (lastTab != std::u16string::npos && s.at <= lastTab)) continue;
        seen[s.at] = true;
        letters.push_back(s);
    }
    const size_t n = letters.size();
    if (n < 2) return {};
    std::vector<double> after(words.size(), 0);
    bool joined = false;
    for (const auto& s : letters) joined = joined || joins(words[s.at]);
    if (joined) {
        // The gaps between words, in the order they are read, each as wide again as the others.
        std::vector<size_t> order;
        for (const auto& s : letters) order.push_back(s.at);
        std::sort(order.begin(), order.end());
        int gaps = 0;
        for (size_t i = 1; i < order.size(); i++) if (spreadsAt(words[order[i - 1]]) && !spreadsAt(words[order[i]])) gaps++;
        if (gaps == 0) return {};
        std::vector<Run> out = runs;
        for (auto& r : out) r.wordSpacing = extra / gaps;
        return out;
    }
    std::vector<double> left(n), right(n);
    std::vector<bool> space(n), own(n);
    double spaces = 0, others = 0;
    for (size_t i = 0; i < n; i++) {
        const Run& run = runs[runAt[letters[i].at]];
        space[i] = spreadsAt(words[letters[i].at]);
        own[i] = ownJustification(run);
        left[i] = right[i] = (space[i] ? (own[i] ? 1.0 : 0.5) : (own[i] ? 0.0 : 0.14453125)) * run.size;
    }
    left[0] = 0;
    right[n - 1] = 0;
    for (size_t i = 0; i + 1 < n; i++) {
        if (!space[i] && !own[i] && space[i + 1] && !own[i + 1]) right[i] = left[i + 1] = 0;
    }
    for (size_t i = 0; i < n; i++) (space[i] ? spaces : others) += left[i] + right[i];
    if (spaces <= 0 && others <= 0) return {};
    // How much of what they can the spaces grow, and the letters: up to all of it, then the rest.
    double rest = extra, bySpaces = 0, byLetters = 0;
    if (spaces > 0) { bySpaces = std::min(1.0, rest / spaces); rest -= bySpaces * spaces; }
    if (rest > 1e-9 && others > 0) { byLetters = std::min(1.0, rest / others); rest -= byLetters * others; }
    if (rest > 1e-9) {
        if (spaces > 0) bySpaces += rest / spaces;
        else byLetters += rest / others;
    }
    for (size_t i = 0; i < n; i++) {
        const double by = space[i] ? bySpaces : byLetters;
        after[letters[i].at] += right[i] * by;
        if (i + 1 < n) after[letters[i].at] += left[i + 1] * (space[i + 1] ? bySpaces : byLetters);
    }
    std::vector<Run> out;
    size_t start = 0;
    for (const auto& r : runs) {
        size_t a = 0;
        while (a < r.text.size()) {
            size_t z = a + 1;
            while (z < r.text.size() && after[start + z] == after[start + a] && !spreadsAt(r.text[z])) z++;
            Run part = r;
            part.text = r.text.substr(a, z - a);
            part.tracking = r.tracking + after[start + a];
            out.push_back(std::move(part));
            a = z;
        }
        start += r.text.size();
    }
    return out;
}

/// Half the spacing of a line's first letter, which Skia puts before the whole line (TextLine's
/// shift), as Skia picks that letter: the first not of a script whose letters join, whose runs it
/// never spaces apart; none when every letter that reads one way or the other joins.
double halfFirstSpacing(const std::vector<Run>& piece) {
    bool joined = false;
    for (const auto& r : piece) for (const char16_t u : r.text) joined = joined || joins(u);
    if (!joined) return piece[0].tracking / 2;
    for (const auto& r : piece) {
        for (size_t k = 0; k < r.text.size(); k++) if (reads(r.text, k) != 0 && !joins(r.text[k])) return r.tracking / 2;
    }
    return 0;
}

/// The runs with each tab one of its own, so it can be spaced as wide as its stop needs.
std::vector<Run> tabsApart(std::vector<Run> runs) {
    std::vector<Run> out;
    for (auto& r : runs) {
        if (r.text.find(u'\t') == std::u16string::npos) { out.push_back(std::move(r)); continue; }
        size_t a = 0;
        while (a < r.text.size()) {
            size_t z = r.text[a] == u'\t' ? a + 1 : r.text.find(u'\t', a);
            if (z == std::u16string::npos) z = r.text.size();
            Run part = r;
            part.text = r.text.substr(a, z - a);
            out.push_back(std::move(part));
            a = z;
        }
    }
    return out;
}

/// The tabs of the words from `start` to `end` set at Text Kit's stops (NSParagraphStyle's
/// default, every 28 points from where a line begins): each as wide as it takes to reach the
/// first stop past where it begins. Skia has no stops and sets a tab as a space
/// (replaceTabCharacters); each tab's own spacing makes up the rest. Set again after each tab
/// that moves, as what follows it, and where lines break, moves with it. Past the twelfth stop
/// (336 points), where Text Kit takes a tab to the next line, a tab stays a space. Lines read from
/// right to left keep their tabs as spaces.
void stopTabs(std::vector<Run>& runs, size_t start, size_t end, double width, bool rtl) {
    std::u16string words;
    std::vector<size_t> runAt;
    for (size_t r = 0; r < runs.size(); r++) {
        words += runs[r].text;
        runAt.insert(runAt.end(), runs[r].text.size(), r);
    }
    std::vector<size_t> tabs;
    for (size_t k = start; k < end && k < words.size(); k++) if (words[k] == u'\t') tabs.push_back(k);
    if (tabs.empty() || rtl) return;
    for (size_t round = 0; round < 2 * tabs.size() + 2; round++) {
        const auto those = slice(runs, start, end);
        if (those.empty()) return;
        auto p = paragraph(those, those[0], width, 0);
        std::vector<LineMetrics> lines;
        p->getLineMetrics(lines);
        auto leftOf = [&](size_t k) -> double {
            auto rects = p->getRectsForRange(unsigned(k), unsigned(k + 1), RectHeightStyle::kTight, RectWidthStyle::kTight);
            return rects.empty() ? NAN : double(rects[0].rect.left());
        };
        bool moved = false;
        for (const size_t t : tabs) {
            const size_t k = t - start;
            const LineMetrics* line = nullptr;
            for (const auto& m : lines) if (m.fStartIndex <= k && k < m.fEndIncludingNewline) { line = &m; break; }
            if (!line) continue;
            // As wide as to the next letter, or, at the end of its line, as its own box.
            const bool last = k + 1 >= line->fEndIncludingNewline || breaksLine(words[t + 1]);
            const double first = leftOf(line->fStartIndex), at = leftOf(k), next = last ? NAN : leftOf(k + 1);
            if (std::isnan(first) || std::isnan(at)) continue;
            const double x = at - first, stop = 28 * (std::floor(x / 28 + 1e-9) + 1);
            if (stop > 336 + 1e-6) continue;
            double now = next - at;
            if (last) {
                auto rects = p->getRectsForRange(unsigned(k), unsigned(k + 1), RectHeightStyle::kTight, RectWidthStyle::kTight);
                if (rects.empty()) continue;
                now = rects[0].rect.width();
            }
            const double wanted = stop - x;
            if (std::abs(wanted - now) > 0.005) {
                runs[runAt[t]].tracking += wanted - now;
                moved = true;
                break;
            }
        }
        if (!moved) return;
    }
}

// MARK: Playing a recording (bezzle.mjs's look and play)

const SkBlendMode blends[] = {
    SkBlendMode::kSrcOver, SkBlendMode::kMultiply, SkBlendMode::kScreen, SkBlendMode::kOverlay, SkBlendMode::kDarken,
    SkBlendMode::kLighten, SkBlendMode::kColorDodge, SkBlendMode::kColorBurn, SkBlendMode::kSoftLight,
    SkBlendMode::kHardLight, SkBlendMode::kDifference, SkBlendMode::kExclusion, SkBlendMode::kHue,
    SkBlendMode::kSaturation, SkBlendMode::kColor, SkBlendMode::kLuminosity, SkBlendMode::kClear, SkBlendMode::kSrc,
    SkBlendMode::kSrcIn, SkBlendMode::kSrcOut, SkBlendMode::kSrcATop, SkBlendMode::kDstOver, SkBlendMode::kDstIn,
    SkBlendMode::kDstOut, SkBlendMode::kDstATop, SkBlendMode::kXor, SkBlendMode::kMultiply, SkBlendMode::kPlus,
};

struct Look { double alpha; int blend; bool shadowed; };

/// Alpha, blend mode and shadow, as each drawing carries them: 10 numbers.
Look look(const double* c, size_t& i, SkPaint& paint, SkCanvas* canvas) {
    const double alpha = c[i], blend = c[i + 1], shadowed = c[i + 2];
    const int b = int(blend);
    paint.setBlendMode(b >= 0 && b < int(std::size(blends)) ? blends[b] : SkBlendMode::kSrcOver);
    if (shadowed != 0) {
        // Given in device pixels, as Core Graphics measures shadows: back into the canvas's own space.
        const SkMatrix m = canvas->getTotalMatrix();
        const double a = m.getScaleX(), bb = m.getSkewY(), cc = m.getSkewX(), d = m.getScaleY();
        const double det = a * d - bb * cc;
        const double dx = c[i + 3], dy = c[i + 4];
        const double lx = det != 0 ? (d * dx - cc * dy) / det : dx, ly = det != 0 ? (-bb * dx + a * dy) / det : dy;
        const double scale = std::sqrt(std::abs(det)) != 0 ? std::sqrt(std::abs(det)) : 1;
        const float sigma = float(c[i + 5] / scale);
        const SkColor4f color = {float(c[i + 6]), float(c[i + 7]), float(c[i + 8]), float(c[i + 9])};
        paint.setImageFilter(SkImageFilters::DropShadow(float(lx), float(ly), sigma, sigma, color.toSkColor(), nullptr));
    }
    i += 10;
    return {alpha, b, shadowed != 0};
}

SkPath path(const double* c, size_t& i, size_t n, double rule) {
    const size_t count = size_t(c[i]);
    const size_t start = i + 1;
    i = std::min(n, start + count);
    return readPath(c + start, i - start, fillOf(rule));
}

SkColor4f color(const double* c, size_t& i, double alpha) {
    const SkColor4f out = {float(c[i]), float(c[i + 1]), float(c[i + 2]), float(c[i + 3] * alpha)};
    i += 4;
    return out;
}

/// Whether the recording being played goes into a PDF (bz_pdf_page).
bool playingPDF = false;

// Faded layers in a PDF. SkPDF draws a layer (saveLayer, which every faded layer and group becomes)
// into a device of its own, writes that as a transparency group Form XObject and places it with a
// `cm` inside the page's flip. A gradient in it becomes a shading Pattern whose /Matrix SkPDF gives
// in the form's own space (SkPDFDevice's populate_graphic_state_entry_from_paint concatenates the
// layer device's initial transform, which is the identity), as ISO 32000 8.7.2 has patterns in forms.
// Quartz (Preview, PDFKit, Quick Look, Safari) takes the matrix in the page's default space instead,
// ignoring where the form is put: the gradient lands as if the layer stood unflipped at the page's
// bottom left, shifted by the layer's place and, top to bottom, off its shape, so a faded rectangle's
// gradient moves and a faded ellipse's or letters' shows one flat end colour. pdfium (Chrome, Edge)
// follows the standard and draws them in place. The Mac's own PDFs keep their forms in the page's
// space and paint gradients with `sh`, so both draw them alike. Here a faded layer that holds a
// gradient is played without a layer of its own where that draws the same (`carryLayer`): its
// alpha carried into each drawing in it, which then lies in the page itself, where both readers
// agree. A gradient still inside a layer is drawn as pixels (`paintAsPixels`), which every reader
// places alike.

/// How much of the layers played without a layer of their own (`carryLayer`) shows: carried into
/// the alpha of each drawing in them.
double carried = 1;
/// How many layers of a PDF are open, and what was carried when each was opened.
std::vector<double> carriedBefore;

/// Where the drawing call after one begins, from just after its number.
size_t skipCall(int op, const double* c, size_t i, size_t n) {
    switch (op) {
        case 1: case 2: case 11: return i;
        case 3: return i + 6;
        case 4: return i + 1 < n && c[i + 1] == 0 ? i + 2 : i + 2 + size_t(i + 1 < n ? c[i + 1] : 0);
        case 5: { const size_t j = i + 15; return j < n ? j + 1 + size_t(c[j]) : n; }
        case 6: {
            if (i + 16 > n) return n;
            const size_t j = i + 16 + size_t(c[i + 15]) + 4;
            return j < n ? j + 1 + size_t(c[j]) : n;
        }
        case 7: case 8: { const size_t j = i + 10 + (op == 7 ? 4 : 6); return j + 2 < n ? j + 3 + 5 * size_t(c[j + 2]) : n; }
        case 9: return i + 16;
        case 10: return i + 15;
        case 12: return i + 18;
        case 13: return i + 16;
    }
    return n;
}

/// Letters painted with a gradient or a picture (WebText.swift's and WebCurvedText.swift's draw:
/// a layer of the letters, and in it a layer of the paint kept only where they are) as a PDF
/// keeps them, as the Mac's TextLayout.Manager does: the paint cut to the letters' outlines,
/// which keeps them sharp, the lines under and through them in their own colour. A PDF has no
/// layers that keep only what lies on what is there: Skia makes them groups masked by others,
/// in which the Mac's own PDF reader shows gradients moved off their letters. `i` is just after
/// the outer layer's number; false when what follows is not letters painted so, played as it is.
/// With no canvas, only whether it is so, and where it ends.
bool paintedLetters(SkCanvas* canvas, const double* c, size_t i, size_t n, size_t* next) {
    if (i + 15 > n || c[i] != 1 || c[i + 1] != 0 || c[i + 2] != 0) return false;
    size_t j = i + 15;
    // The letters, until the paint's layer: their outlines in the outer layer's space.
    SkPathBuilder outlines;
    struct Rule { SkRect rect; SkColor4f color; SkMatrix matrix; };
    std::vector<Rule> rules;
    std::vector<SkMatrix> saved;
    SkMatrix m;
    size_t paint = 0;
    while (j < n && !paint) {
        const int op = int(c[j++]);
        switch (op) {
            case 1: saved.push_back(m); break;
            case 2: if (saved.empty()) return false; m = saved.back(); saved.pop_back(); break;
            case 3: m.preConcat(SkMatrix::MakeAll(float(c[j]), float(c[j + 2]), float(c[j + 4]), float(c[j + 1]), float(c[j + 3]), float(c[j + 5]), 0, 0, 1)); break;
            case 5: {
                const double rule = c[j + 10];
                size_t k = j + 15;
                outlines.addPath(path(c, k, n, rule).makeTransform(m));
                break;
            }
            case 12: {
                const int id = int(c[j + 10]);
                const double x = c[j + 11], y = c[j + 12];
                auto it = texts.find(id);
                if (it == texts.end()) break;
                const auto& t = it->second;
                for (size_t k = 0; k < t.lines.size(); k++) {
                    const auto& line = t.lines[k];
                    if (!line.paragraph) continue;
                    const double baseline = k < t.baselines.size() ? t.baselines[k] : 0;
                    const double dx = x - line.back, dy = y + baseline - line.baseline;
                    line.paragraph->visit([&](int, const Paragraph::VisitorInfo* info) {
                        if (!info) return;
                        SkFontMetrics fm;
                        info->font.getMetrics(&fm);
                        std::map<size_t, std::pair<double, double>> spans;
                        for (int g = 0; g < info->count; g++) {
                            const size_t inLine = utf16Index(line.words, info->utf8Starts[g]);
                            size_t run = 0, from = 0;
                            while (run + 1 < line.runs.size() && inLine >= from + line.runs[run].text.size()) { from += line.runs[run].text.size(); run++; }
                            // Letters left unseen (those of a colour of their own) are not painted.
                            if (run >= line.runs.size() || !line.runs[run].hasColor || line.runs[run].color.fA <= 0) continue;
                            const double gx = dx + info->origin.fX + info->positions[g].fX, gy = dy + info->origin.fY + info->positions[g].fY;
                            if (auto glyph = info->font.getPath(info->glyphs[g])) outlines.addPath(glyph->makeTransform(SkMatrix::Translate(float(gx), float(gy)).postConcat(m)));
                            SkScalar w = 0;
                            info->font.getWidths({&info->glyphs[g], 1}, {&w, 1});
                            auto [at, made] = spans.try_emplace(run, gx, gx + double(w));
                            if (!made) { at->second.first = std::min(at->second.first, gx); at->second.second = std::max(at->second.second, gx + double(w)); }
                        }
                        const double ry = dy + info->origin.fY;
                        for (const auto& [run, span] : spans) {
                            const Run& r = line.runs[run];
                            SkScalar position = 0, thickness = 0;
                            if (r.underline) {
                                if (!fm.hasUnderlinePosition(&position)) position = -fm.fAscent * 0.1f;
                                if (!fm.hasUnderlineThickness(&thickness)) thickness = info->font.getSize() / 14;
                                rules.push_back({SkRect::MakeLTRB(float(span.first), float(ry + position), float(span.second), float(ry + position + thickness)), r.color, m});
                            }
                            if (r.strike) {
                                if (!fm.hasStrikeoutPosition(&position)) position = fm.fAscent * 0.3f;
                                if (!fm.hasStrikeoutThickness(&thickness)) thickness = info->font.getSize() / 14;
                                rules.push_back({SkRect::MakeLTRB(float(span.first), float(ry + position), float(span.second), float(ry + position + thickness)), r.color, m});
                            }
                        }
                    });
                }
                break;
            }
            case 13: {
                const int id = int(c[j + 10]), k = int(c[j + 11]);
                auto it = glyphLines.find(id);
                if (c[j + 15] > 0 && it != glyphLines.end() && k >= 0 && k < int(it->second.size())) {
                    const Glyph& g = it->second[size_t(k)];
                    if (auto glyph = g.font.getPath(g.id)) outlines.addPath(glyph->makeTransform(m));
                }
                break;
            }
            case 10:
                // The paint's layer, keeping only what lies on the letters.
                if (j + 15 > n || int(c[j + 1]) != 18) return false;
                paint = j + 15;
                break;
            default:
                return false;
        }
        if (!paint) j = skipCall(op, c, j, n);
    }
    if (!paint || !saved.empty()) return false;
    // Where the paint's layer ends, and the letters' after it.
    size_t k = paint;
    int depth = 1;
    size_t end = 0;
    while (k < n) {
        const int op = int(c[k]);
        if (op == 10) depth++;
        if (op == 11 && --depth == 0) { end = k; break; }
        k = skipCall(op, c, k + 1, n);
    }
    if (!end || end + 1 >= n || int(c[end + 1]) != 11) return false;
    // The lines under and through the letters in their own colour, then the paint cut to the letters.
    if (!canvas) {
        *next = end + 2;
        return true;
    }
    for (const auto& r : rules) {
        SkPaint p;
        p.setAntiAlias(true);
        p.setColor4f({r.color.fR, r.color.fG, r.color.fB, float(r.color.fA * carried)});
        canvas->save();
        canvas->concat(r.matrix);
        canvas->drawRect(r.rect, p);
        canvas->restore();
    }
    const SkPath shape = outlines.detach();
    if (!shape.isEmpty()) {
        canvas->save();
        canvas->clipPath(shape, SkClipOp::kIntersect, true);
        play(canvas, c + paint, end - paint);
        canvas->restore();
    }
    *next = end + 2;
    return true;
}

/// What a layer of a recording draws (from `i`, just after its number, look and bounds, on to the
/// end of the layer, `i` then just after it), with `m` and `clip` (in the page's own space) as
/// they are where it begins: the areas its drawings cover, whether a gradient is among them.
/// False when something in it needs the layer: a blend, a shadow, a layer of its own that does.
bool scanLayer(const double* c, size_t& i, size_t n, SkMatrix m, SkRect clip, std::vector<SkRect>& areas, bool& paints) {
    std::vector<std::pair<SkMatrix, SkRect>> saved;
    while (i < n) {
        const int op = int(c[i++]);
        switch (op) {
            case 1: saved.push_back({m, clip}); break;
            case 2:
                if (saved.empty()) return false;
                m = saved.back().first, clip = saved.back().second;
                saved.pop_back();
                break;
            case 3: m.preConcat(SkMatrix::MakeAll(float(c[i]), float(c[i + 2]), float(c[i + 4]), float(c[i + 1]), float(c[i + 3]), float(c[i + 5]), 0, 0, 1)); break;
            case 4: {
                if (i + 1 >= n || c[i + 1] == 0) {
                    clip.setEmpty();
                    break;
                }
                size_t k = i + 1;
                if (!clip.intersect(m.mapRect(path(c, k, n, c[i]).getBounds()))) clip.setEmpty();
                break;
            }
            case 5: case 6: case 7: case 8: case 9: case 12: case 13: {
                if (i + 10 > n || c[i + 1] != 0 || c[i + 2] != 0) return false;
                // What it may cover: its shape, or wherever the clip lets it (a paint, letters).
                SkRect area = clip;
                if (op == 5) {
                    size_t k = i + 15;
                    area = m.mapRect(path(c, k, n, c[i + 10]).getBounds());
                } else if (op == 6 && i + 16 <= n) {
                    size_t k = i + 16 + size_t(c[i + 15]) + 4;
                    const float reach = float(c[i + 10] * std::max(1.0, c[i + 13])) / 2 + 1;
                    area = m.mapRect(path(c, k, n, 0).getBounds().makeOutset(reach, reach));
                } else if (op == 9) {
                    area = m.mapRect(SkRect::MakeXYWH(float(c[i + 11]), float(c[i + 12]), float(c[i + 13]), float(c[i + 14])));
                }
                if (!area.intersect(clip)) area.setEmpty();
                if (!area.isEmpty()) areas.push_back(area);
                if (op == 7 || op == 8) paints = true;
                break;
            }
            case 10: {
                // Letters painted with a gradient or a picture: drawn as one, wherever they are.
                size_t after = 0;
                const bool has = i + 15 <= n && c[i + 10] != 0;
                SkRect inner = clip;
                if (has && !inner.intersect(m.mapRect(SkRect::MakeXYWH(float(c[i + 11]), float(c[i + 12]), float(c[i + 13]), float(c[i + 14])))))
                    inner.setEmpty();
                if (paintedLetters(nullptr, c, i, n, &after)) {
                    if (!inner.isEmpty()) areas.push_back(inner);
                    paints = true;
                    i = after;
                    continue;
                }
                if (i + 15 > n || c[i + 1] != 0 || c[i + 2] != 0) return false;
                size_t k = i + 15;
                if (!scanLayer(c, k, n, m, inner, areas, paints)) return false;
                i = k;
                continue;
            }
            case 11: return saved.empty();
            default: return false;
        }
        i = skipCall(op, c, i, n);
    }
    return false;
}

/// A layer of a recording played into a PDF without a layer of its own, its alpha carried into
/// each drawing in it (see `carried`), when that draws the same and it holds a gradient: when it
/// has no blend or shadow of its own, nor anything in it, and no two of its drawings overlap, so
/// that none shows through another. `i` is just after its number; false when it is played as a
/// layer.
bool carryLayer(SkCanvas* canvas, const double* c, size_t i, size_t n, size_t* next) {
    if (i + 15 > n || c[i + 1] != 0 || c[i + 2] != 0) return false;
    const bool has = c[i + 10] != 0;
    const SkRect bounds = SkRect::MakeXYWH(float(c[i + 11]), float(c[i + 12]), float(c[i + 13]), float(c[i + 14]));
    const SkMatrix m = canvas->getTotalMatrix();
    SkRect clip = SkRect::Make(canvas->getDeviceClipBounds());
    if (has && !clip.intersect(m.mapRect(bounds))) clip.setEmpty();
    std::vector<SkRect> areas;
    bool paints = false;
    size_t end = i + 15;
    if (!scanLayer(c, end, n, m, clip, areas, paints) || !paints || areas.size() > 64) return false;
    for (size_t a = 0; a < areas.size(); a++) {
        for (size_t b = a + 1; b < areas.size(); b++) {
            if (SkRect::Intersects(areas[a], areas[b])) return false;
        }
    }
    const double before = carried;
    carried *= c[i];
    canvas->save();
    if (has) canvas->clipRect(bounds, SkClipOp::kIntersect, true);
    play(canvas, c + i + 15, end - 1 - (i + 15));
    canvas->restore();
    carried = before;
    *next = end;
    return true;
}

/// A gradient inside a layer of a PDF (see `carried`) drawn as pixels where the clip lets it show,
/// two to a point as Bezzle's PDFs have their other pixels (fewer for one over 2048 points), placed
/// as a picture is, which every reader puts where it belongs.
void paintAsPixels(SkCanvas* canvas, const SkPaint& paint) {
    SkRect area = SkRect::Make(canvas->getDeviceClipBounds());
    if (!area.intersect(SkRect::Make(canvas->getBaseLayerSize()))) return;
    const float density = std::min(2.0f, 4096.0f / std::max(area.width(), area.height()));
    const int w = std::max(1, int(std::ceil(area.width() * density))), h = std::max(1, int(std::ceil(area.height() * density)));
    auto surface = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(w, h, SkColorSpace::MakeSRGB()));
    if (!surface) return;
    SkCanvas* pixels = surface->getCanvas();
    pixels->clear(SK_ColorTRANSPARENT);
    pixels->scale(float(w) / area.width(), float(h) / area.height());
    pixels->translate(-area.left(), -area.top());
    pixels->concat(canvas->getTotalMatrix());
    SkPaint whole = paint;
    whole.setAlphaf(1);
    whole.setBlendMode(SkBlendMode::kSrcOver);
    pixels->drawPaint(whole);
    SkPaint put;
    put.setAlphaf(paint.getAlphaf());
    put.setBlendMode(paint.asBlendMode().value_or(SkBlendMode::kSrcOver));
    canvas->save();
    canvas->resetMatrix();
    canvas->drawImageRect(surface->makeImageSnapshot(), area, SkSamplingOptions(SkFilterMode::kLinear), &put);
    canvas->restore();
}

void play(SkCanvas* canvas, const double* c, size_t n) {
    size_t i = 0;
    while (i < n) {
        const int op = int(c[i++]);
        switch (op) {
            case 1: canvas->save(); break;
            case 2: canvas->restore(); break;
            case 3:
                canvas->concat(SkMatrix::MakeAll(float(c[i]), float(c[i + 2]), float(c[i + 4]), float(c[i + 1]), float(c[i + 3]),
                                                 float(c[i + 5]), 0, 0, 1));
                i += 6;
                break;
            case 4: {
                const double rule = c[i++];
                if (c[i] == 0) { canvas->clipRect(SkRect::MakeEmpty(), SkClipOp::kIntersect, false); i += 1; break; }
                canvas->clipPath(path(c, i, n, rule), SkClipOp::kIntersect, true);
                break;
            }
            case 5: case 6: {
                SkPaint paint;
                paint.setAntiAlias(true);
                const Look l = look(c, i, paint, canvas);
                if (op == 5) {
                    const double rule = c[i++];
                    paint.setColor4f(color(c, i, l.alpha * carried));
                    canvas->drawPath(path(c, i, n, rule), paint);
                } else {
                    paint.setStyle(SkPaint::kStroke_Style);
                    paint.setStrokeWidth(float(c[i]));
                    const SkPaint::Cap caps[] = {SkPaint::kButt_Cap, SkPaint::kRound_Cap, SkPaint::kSquare_Cap};
                    const SkPaint::Join joins[] = {SkPaint::kMiter_Join, SkPaint::kRound_Join, SkPaint::kBevel_Join};
                    paint.setStrokeCap(caps[std::clamp(int(c[i + 1]), 0, 2)]);
                    paint.setStrokeJoin(joins[std::clamp(int(c[i + 2]), 0, 2)]);
                    paint.setStrokeMiter(float(c[i + 3]));
                    const double phase = c[i + 4];
                    const size_t nd = size_t(c[i + 5]);
                    i += 6;
                    if (nd > 0) {
                        std::vector<float> dashes;
                        for (size_t k = 0; k < nd; k++) dashes.push_back(float(c[i + k]));
                        if (nd % 2) for (size_t k = 0; k < nd; k++) dashes.push_back(float(c[i + k]));
                        paint.setPathEffect(SkDashPathEffect::Make(dashes, float(phase)));
                    }
                    i += nd;
                    paint.setColor4f(color(c, i, l.alpha * carried));
                    canvas->drawPath(path(c, i, n, 0), paint);
                }
                break;
            }
            case 7: case 8: {
                SkPaint paint;
                paint.setAntiAlias(true);
                const Look l = look(c, i, paint, canvas);
                const double* g = c + i;
                i += op == 7 ? 4 : 6;
                const bool before = c[i] != 0, after = c[i + 1] != 0;
                const size_t count = size_t(c[i + 2]);
                i += 3;
                std::vector<SkColor4f> colors;
                std::vector<float> positions;
                for (size_t k = 0; k < count; k++) {
                    positions.push_back(float(c[i]));
                    colors.push_back({float(c[i + 1]), float(c[i + 2]), float(c[i + 3]), float(c[i + 4])});
                    i += 5;
                }
                const SkTileMode mode = before || after ? SkTileMode::kClamp : SkTileMode::kDecal;
                const SkGradient gradient(SkGradient::Colors(colors, positions, mode), {});
                sk_sp<SkShader> shader;
                if (op == 7) {
                    const SkPoint points[2] = {{float(g[0]), float(g[1])}, {float(g[2]), float(g[3])}};
                    shader = SkShaders::LinearGradient(points, gradient);
                } else {
                    shader = SkShaders::TwoPointConicalGradient({float(g[0]), float(g[1])}, float(g[2]),
                                                                {float(g[3]), float(g[4])}, float(g[5]), gradient);
                }
                paint.setShader(shader);
                paint.setAlphaf(float(l.alpha * carried));
                if (playingPDF && !carriedBefore.empty()) {
                    paintAsPixels(canvas, paint);
                } else {
                    canvas->drawPaint(paint);
                }
                break;
            }
            case 9: {
                SkPaint paint;
                paint.setAntiAlias(true);
                const Look l = look(c, i, paint, canvas);
                const int id = int(c[i]);
                const float x = float(c[i + 1]), y = float(c[i + 2]), w = float(c[i + 3]), h = float(c[i + 4]);
                i += 6;
                if (auto image = get(id)) {
                    paint.setAlphaf(float(l.alpha * carried));
                    // Core Graphics draws a picture with its top row at the rectangle's top, which is up.
                    canvas->save();
                    canvas->concat(SkMatrix::MakeAll(1, 0, 0, 0, -1, 2 * y + h, 0, 0, 1));
                    canvas->drawImageRect(image, SkRect::MakeWH(float(image->width()), float(image->height())), SkRect::MakeXYWH(x, y, w, h),
                                          SkSamplingOptions(SkFilterMode::kLinear, SkMipmapMode::kLinear), &paint,
                                          SkCanvas::kFast_SrcRectConstraint);
                    canvas->restore();
                }
                break;
            }
            case 10: {
                size_t after = 0;
                if (playingPDF && paintedLetters(canvas, c, i, n, &after)) { i = after; break; }
                if (playingPDF && carryLayer(canvas, c, i, n, &after)) { i = after; break; }
                SkPaint paint;
                const Look l = look(c, i, paint, canvas);
                paint.setAlphaf(float(l.alpha * carried));
                const bool has = c[i] != 0;
                const SkRect bounds = SkRect::MakeXYWH(float(c[i + 1]), float(c[i + 2]), float(c[i + 3]), float(c[i + 4]));
                i += 5;
                canvas->saveLayer(has ? &bounds : nullptr, &paint);
                // What was carried goes into the layer's own alpha, not again into what is in it.
                if (playingPDF) {
                    carriedBefore.push_back(carried);
                    carried = 1;
                }
                break;
            }
            case 11:
                canvas->restore();
                if (playingPDF && !carriedBefore.empty()) {
                    carried = carriedBefore.back();
                    carriedBefore.pop_back();
                }
                break;
            case 13: {
                // One letter of a line set for a curve, its baseline's left end at the origin.
                SkPaint paint;
                paint.setAntiAlias(true);
                const Look l = look(c, i, paint, canvas);
                const int id = int(c[i]), k = int(c[i + 1]);
                i += 2;
                paint.setColor4f(color(c, i, l.alpha * carried));
                if (auto it = glyphLines.find(id); it != glyphLines.end() && k >= 0 && k < int(it->second.size())) {
                    const Glyph& g = it->second[size_t(k)];
                    const SkPoint origin = {0, 0};
                    canvas->drawGlyphs({&g.id, 1}, {&origin, 1}, {0, 0}, g.font, paint);
                }
                break;
            }
            case 12: {
                SkPaint paint;
                const Look l = look(c, i, paint, canvas);
                const int id = int(c[i]);
                const float x = float(c[i + 1]), y = float(c[i + 2]);
                i += 3 + 5;
                const bool layered = l.alpha * carried < 1 || l.shadowed || l.blend != 0;
                if (layered) { paint.setAlphaf(float(l.alpha * carried)); canvas->saveLayer(nullptr, &paint); }
                if (auto it = texts.find(id); it != texts.end()) {
                    auto& t = it->second;
                    for (size_t k = 0; k < t.lines.size(); k++) {
                        auto& line = t.lines[k];
                        if (!line.paragraph) continue;
                        const double baseline = k < t.baselines.size() ? t.baselines[k] : 0;
                        line.paragraph->paint(canvas, float(x - line.back), float(y + baseline - line.baseline));
                    }
                }
                if (layered) canvas->restore();
                break;
            }
            default:
                fprintf(stderr, "[host] unknown drawing call %d at %zu\n", op, i - 1);
                return;
        }
    }
}

}  // namespace

// MARK: The C interface

extern "C" int32_t bz_host_call(int32_t function, const void* bytes, int32_t count) {
    std::lock_guard<std::mutex> guard(lock);
    const auto* doubles = static_cast<const double*>(bytes);
    const size_t n = size_t(std::max(count, 0)) / sizeof(double);
    switch (function) {
        case 1: keep(pathOp(doubles, n)); break;
        case 2: keep(imageByName(doubles, n)); break;
        case 4:
            fprintf(stderr, "[core] %.*s\n", int(count), static_cast<const char*>(bytes));
            answer.clear();
            break;
        default: answer.clear();
    }
    return int32_t(answer.size());
}

extern "C" void bz_host_take(void* into) {
    std::lock_guard<std::mutex> guard(lock);
    if (into && !answer.empty()) memcpy(into, answer.data(), answer.size());
}

extern "C" int32_t bz_font_add(const char* family, const char* face, const void* data, int32_t count) {
    std::lock_guard<std::mutex> guard(lock);
    auto typeface = fontManager()->makeFromData(SkData::MakeWithCopy(data, size_t(count)));
    if (!typeface) return 0;
    const std::string name = std::string(family) == "System" ? "System" : std::string(family) + "|" + face;
    provider->registerTypeface(typeface, SkString(name.c_str()));
    faces[name] = typeface;
    leadings.clear();
    if (collection) collection->clearCaches();
    return 1;
}

extern "C" int32_t bz_font_add_at(const char* family, const char* face, const void* data, int32_t count, int32_t index) {
    std::lock_guard<std::mutex> guard(lock);
    auto typeface = fontManager()->makeFromData(SkData::MakeWithCopy(data, size_t(count)), index);
    if (!typeface) return 0;
    const std::string name = std::string(family) + "|" + face;
    // Windows' own face of a family an open font stood in for (Arial for Arimo) under a name of
    // its own, which letters then ask for: under the same name Skia would go on showing the
    // first it was given of a face.
    const bool before = faces.count(name) > 0;
    provider->registerTypeface(typeface, SkString((before ? name + "|own" : name).c_str()));
    if (before) owned.insert(name);
    faces[name] = typeface;
    leadings.clear();
    if (collection) collection->clearCaches();
    return 1;
}

namespace {
std::vector<Run> runsOf(const bz_text_run* given, int32_t count) {
    std::vector<Run> runs;
    for (int32_t k = 0; k < count; k++) {
        const auto& r = given[k];
        runs.push_back({utf16(r.text ? r.text : ""), r.family ? r.family : "System", r.face ? r.face : "", r.size, r.tracking,
                        r.weight, r.opticalSize, r.underline != 0, r.strike != 0, r.hasColor != 0,
                        {float(r.color[0]), float(r.color[1]), float(r.color[2]), float(r.color[3])},
                        r.features ? r.features : "", r.axes ? r.axes : ""});
    }
    if (runs.empty()) runs.push_back({u"", "System", "", 12, 0, 400, 0, false, false, false, {0, 0, 0, 1}, "", ""});
    return runs;
}
}  // namespace

extern "C" int32_t bz_text_lay(const bz_text_run* given, int32_t count, double width, int32_t align,
                               const double* indents, int32_t indentCount,
                               double* lines, int32_t capacity, int32_t* lineCount) {
    std::lock_guard<std::mutex> guard(lock);
    std::vector<Run> runs = tabsApart(runsOf(given, count));
    size_t total = 0;
    for (const auto& r : runs) total += r.text.size();
    // The words in parts set at widths of their own: paragraphs set further in (items of lists)
    // narrower, and drawn that much to the right; the rest as wide as asked. Without any, one part.
    struct Part { size_t start, end; double indent; bool rtl = false; };
    std::vector<Part> parts;
    size_t at = 0;
    for (int32_t k = 0; indents && k < indentCount; k++) {
        const size_t a = std::min(size_t(std::max(indents[k * 3], 0.0)), total), z = std::min(size_t(std::max(indents[k * 3 + 1], 0.0)), total);
        if (z <= a || a < at) continue;
        if (a > at) parts.push_back({at, a, 0});
        parts.push_back({a, z, std::max(indents[k * 3 + 2], 0.0)});
        at = z;
    }
    if (parts.empty() || at < total) parts.push_back({at, total, 0});
    std::u16string letters;
    for (const auto& r : runs) letters += r.text;
    // Paragraphs read from right to left in parts of their own, where the way they read changes,
    // as Text Kit takes each paragraph's way from its first letter that reads one way or the other.
    std::vector<Part> directed;
    for (const auto& part : parts) {
        size_t from = part.start;
        bool rtl = rightToLeft(letters, from);
        for (size_t k = part.start; k < part.end; k++) {
            if (!endsParagraph(letters[k]) || k + 1 >= part.end) continue;
            if (letters[k] == 0x0D && letters[k + 1] == 0x0A) continue;
            const bool next = rightToLeft(letters, k + 1);
            if (next == rtl) continue;
            directed.push_back({from, k + 1, part.indent, rtl});
            from = k + 1;
            rtl = next;
        }
        directed.push_back({from, part.end, part.indent, rtl});
    }
    parts = std::move(directed);
    // Each part's tabs at their stops, as wide as Text Kit sets them.
    for (const auto& part : parts) stopTabs(runs, part.start, part.end, part.indent > 0 ? std::max(width - part.indent, 1.0) : width, part.rtl);
    Text text;
    const double leading = leadingOf(runs[0]);
    const bool fromLeft = align == 0 || align == 3;
    int32_t written = 0, all = 0;
    double top = 0;
    for (size_t p = 0; p < parts.size(); p++) {
        const Part& part = parts[p];
        const double w = part.indent > 0 ? std::max(width - part.indent, 1.0) : width;
        // One part alone is the whole text, as it was always set.
        const std::vector<Run> those = parts.size() == 1 ? runs : slice(runs, part.start, part.end);
        // Justified lines are broken as lines set from the left are, and spread here, never by Skia.
        const int laid = align == 3 ? 0 : align;
        auto set = paragraph(those.empty() ? runs : those, those.empty() ? runs[0] : those[0], w, laid, part.rtl);
        std::vector<LineMetrics> metrics;
        set->getLineMetrics(metrics);
        for (size_t j = 0; j < metrics.size(); j++) {
            const auto& m = metrics[j];
            // A part ending in a paragraph's break has an empty line after it, set alone, which in
            // the whole text is the next part's first.
            if (p + 1 < parts.size() && j > 0 && j + 1 == metrics.size() && part.start + metrics[j - 1].fEndIncludingNewline >= part.end) continue;
            const size_t start = part.start + m.fStartIndex, end = part.start + m.fEndIncludingNewline;
            auto piece = slice(runs, start, part.start + m.fEndExcludingWhitespaces);
            // Each line drawn on its own, so it can sit where the core puts it.
            std::unique_ptr<Paragraph> line = piece.empty() ? nullptr : paragraph(piece, piece[0], w, laid, part.rtl);
            // Justified, every line but a paragraph's last is spread to the width, as Text Kit spreads it;
            // not one that ends with a tab, as nothing follows its last tab.
            bool spread = false;
            const bool tabbed = std::find(letters.begin() + part.start + m.fEndExcludingWhitespaces, letters.begin() + end, u'\t') != letters.begin() + end;
            if (line && align == 3 && end < letters.size() && end > 0 && !breaksLine(letters[end - 1]) && !tabbed) {
                auto spaced = spreadOut(piece, line.get(), w);
                if (!spaced.empty()) {
                    piece = std::move(spaced);
                    line = paragraph(piece, piece[0], 1e6, 0, part.rtl);
                    spread = true;
                }
            }
            double baseline = m.fBaseline, left = m.fLeft;
            if (line) {
                std::vector<LineMetrics> lm;
                line->getLineMetrics(lm);
                // Where Skia paints the line's letters: its ascent down, rounded to a whole point
                // (TextLine::paint), which is not where its line metrics put the baseline.
                if (!lm.empty()) { baseline = std::floor(lm[0].fAscent + 0.5); left = lm[0].fLeft; }
            }
            // Set from the left, its letters begin at its indent, as Text Kit's do; Skia's own
            // left there is off by half the spacing it puts before the first letter.
            if (fromLeft) left = 0;
            std::u16string words;
            for (const auto& r : piece) words += r.text;
            const double back = (piece.empty() || !fromLeft ? 0 : halfFirstSpacing(piece)) - part.indent;
            // A line with a tab measures as far as its last letter, with the spaces and tabs it
            // ends with, as Text Kit's used rect of such a line does (of no other).
            double measured = spread ? w : m.fWidth;
            size_t ends = end;
            while (ends > start && breaksLine(letters[ends - 1])) ends--;
            if (!spread && fromLeft && std::find(letters.begin() + start, letters.begin() + ends, u'\t') != letters.begin() + ends) {
                const auto rects = set->getRectsForRange(unsigned(start - part.start), unsigned(ends - part.start), RectHeightStyle::kTight, RectWidthStyle::kTight);
                if (!rects.empty()) {
                    double l = rects[0].rect.left(), r = rects[0].rect.right();
                    for (const auto& b : rects) { l = std::min(l, double(b.rect.left())); r = std::max(r, double(b.rect.right())); }
                    measured = r - l;
                }
            }
            text.lines.push_back({std::move(line), baseline, back, start, std::move(words), piece});
            text.baselines.push_back(top + m.fBaseline);
            if (written < capacity) {
                // Skia shares the leading out above and below the line; Text Kit keeps it apart.
                double* out = lines + written * 10;
                out[0] = double(start);
                out[1] = double(end);
                out[2] = measured;
                out[3] = m.fAscent - leading / 2;
                out[4] = m.fDescent - leading / 2;
                out[5] = leading;
                out[6] = part.indent + left;
                const auto rise = fallbackRise(text.lines.back().paragraph.get());
                out[7] = rise[0];
                out[8] = rise[1];
                out[9] = rise[2];
                written++;
            }
            all++;
        }
        top += set->getHeight();
    }
    if (lineCount) *lineCount = all;
    const int id = nextText++;
    texts[id] = std::move(text);
    return id;
}

extern "C" void bz_text_place(int32_t id, const double* baselines, int32_t count) {
    std::lock_guard<std::mutex> guard(lock);
    if (auto it = texts.find(id); it != texts.end()) it->second.baselines.assign(baselines, baselines + std::max(count, 0));
}

extern "C" int32_t bz_text_boxes(int32_t id, int32_t start, int32_t end, double* boxes, int32_t capacity) {
    std::lock_guard<std::mutex> guard(lock);
    auto it = texts.find(id);
    if (it == texts.end() || end <= start) return 0;
    int32_t written = 0;
    const auto& t = it->second;
    for (size_t k = 0; k < t.lines.size(); k++) {
        const auto& line = t.lines[k];
        if (!line.paragraph) continue;
        const size_t from = line.start;
        const size_t to = k + 1 < t.lines.size() ? t.lines[k + 1].start : SIZE_MAX;
        const size_t s = std::max(size_t(start), from), e = std::min(size_t(end), to);
        if (s >= e) continue;
        auto rects = line.paragraph->getRectsForRange(unsigned(s - from), unsigned(e - from),
                                                      RectHeightStyle::kTight, RectWidthStyle::kTight);
        if (rects.empty()) continue;
        // One box a line, as Text Kit's enclosing rects are.
        double left = rects[0].rect.left(), right = rects[0].rect.right();
        for (const auto& r : rects) { left = std::min(left, double(r.rect.left())); right = std::max(right, double(r.rect.right())); }
        if (written < capacity) {
            double* out = boxes + written * 3;
            out[0] = double(k);
            out[1] = left - line.back;
            out[2] = right - line.back;
        }
        written++;
    }
    return written;
}

extern "C" int32_t bz_text_glyphs(const bz_text_run* given, int32_t count, double* out, int32_t capacity,
                                  int32_t* glyphCount, double* line) {
    std::lock_guard<std::mutex> guard(lock);
    const std::vector<Run> runs = runsOf(given, count);
    auto p = paragraph(runs, runs[0], 1e7, 0);
    std::vector<LineMetrics> metrics;
    p->getLineMetrics(metrics);
    // Where each run begins in the words' UTF-8, which is how Skia tells where a letter is from.
    std::vector<size_t> starts;
    size_t at = 0;
    std::u16string words;
    for (const auto& r : runs) { starts.push_back(at); at += utf8Length(r.text); words += r.text; }
    struct Laid { SkFont font; SkGlyphID id; double x, y; size_t run; int32_t at; };
    std::vector<Laid> laid;
    p->visit([&](int lineNumber, const Paragraph::VisitorInfo* info) {
        if (!info || lineNumber != 0) return;
        for (int k = 0; k < info->count; k++) {
            const size_t u = info->utf8Starts[k];
            size_t run = size_t(std::upper_bound(starts.begin(), starts.end(), u) - starts.begin());
            run = run > 0 ? run - 1 : 0;
            // Along the line from its start; up or down from the baseline as the letter is set.
            // Skia puts half the letters' spacing before each, Core Text all of it after.
            const double spacing = run < runs.size() ? runs[run].tracking : 0;
            laid.push_back({info->font, info->glyphs[k], double(info->origin.fX + info->positions[k].fX) - spacing / 2,
                            double(info->positions[k].fY), run, int32_t(utf16Index(words, u))});
        }
    });
    std::vector<Glyph> kept;
    // As long as Skia sets the line, but for the half of the spacing it puts before the first letter.
    double width = p->getMaxIntrinsicWidth() - runs[0].tracking / 2, capHeight = -1;
    for (size_t k = 0; k < laid.size(); k++) {
        const Laid& g = laid[k];
        SkFontMetrics m;
        g.font.getMetrics(&m);
        // As far as the next letter, or for the last, its own width and the spacing after it.
        double advance;
        if (k + 1 < laid.size() && laid[k + 1].x >= g.x) {
            advance = laid[k + 1].x - g.x;
        } else {
            SkScalar w = 0;
            g.font.getWidths({&g.id, 1}, {&w, 1});
            advance = double(w) + (g.run < runs.size() ? runs[g.run].tracking : 0);
        }
        width = std::max(width, g.x + advance);
        if (capHeight < 0) capHeight = m.fCapHeight;
        kept.push_back({g.font, g.id, g.at});
        if (int32_t(k) < capacity) {
            double* o = out + k * 10;
            SkScalar underline = 0, thickness = 0;
            if (!m.hasUnderlinePosition(&underline)) underline = -m.fAscent * 0.1f;
            if (!m.hasUnderlineThickness(&thickness)) thickness = g.font.getSize() / 14;
            o[0] = double(g.run);
            o[1] = g.x;
            o[2] = g.y;
            o[3] = advance;
            o[4] = -m.fAscent;
            o[5] = m.fDescent;
            o[6] = underline;
            o[7] = thickness;
            o[8] = m.fXHeight;
            o[9] = m.fCapHeight;
        }
    }
    if (glyphCount) *glyphCount = int32_t(laid.size());
    const double ascent = metrics.empty() ? runs[0].size * 0.8 : metrics[0].fAscent;
    const double descent = metrics.empty() ? runs[0].size * 0.2 : metrics[0].fDescent;
    if (line) {
        line[0] = width;
        line[1] = ascent;
        line[2] = descent;
        line[3] = capHeight >= 0 ? capHeight : ascent * 0.7;
    }
    const int id = nextText++;
    glyphLines[id] = std::move(kept);
    return id;
}

extern "C" int32_t bz_glyph_starts(int32_t id, int32_t* out, int32_t capacity) {
    std::lock_guard<std::mutex> guard(lock);
    auto it = glyphLines.find(id);
    if (it == glyphLines.end()) return 0;
    const auto& line = it->second;
    for (size_t k = 0; k < line.size() && int32_t(k) < capacity; k++) out[k] = line[k].at;
    return int32_t(line.size());
}

extern "C" int32_t bz_text_letters(int32_t id, double* out, int32_t capacity, int32_t* letterCount) {
    std::lock_guard<std::mutex> guard(lock);
    if (letterCount) *letterCount = 0;
    auto it = texts.find(id);
    if (it == texts.end()) return 0;
    const auto& t = it->second;
    std::vector<Glyph> kept;
    int32_t n = 0;
    for (size_t k = 0; k < t.lines.size(); k++) {
        const auto& line = t.lines[k];
        if (!line.paragraph) continue;
        // Where drawing call 12 paints the line, from the text's top left: its baseline where
        // the core put it, and back by half the spacing for a line set from the left.
        const double baseline = k < t.baselines.size() ? t.baselines[k] : 0;
        const double dx = -line.back, dy = baseline - line.baseline;
        line.paragraph->visit([&](int, const Paragraph::VisitorInfo* info) {
            if (!info) return;
            SkFontMetrics m;
            info->font.getMetrics(&m);
            SkScalar underline = 0, thickness = 0;
            if (!m.hasUnderlinePosition(&underline)) underline = -m.fAscent * 0.1f;
            if (!m.hasUnderlineThickness(&thickness)) thickness = info->font.getSize() / 14;
            for (int g = 0; g < info->count; g++) {
                const int32_t at = int32_t(line.start + utf16Index(line.words, info->utf8Starts[g]));
                SkScalar w = 0;
                info->font.getWidths({&info->glyphs[g], 1}, {&w, 1});
                if (n < capacity) {
                    double* o = out + size_t(n) * 9;
                    o[0] = dx + info->origin.fX + info->positions[g].fX;
                    o[1] = dy + info->origin.fY + info->positions[g].fY;
                    o[2] = w;
                    o[3] = -m.fAscent;
                    o[4] = m.fDescent;
                    o[5] = underline;
                    o[6] = thickness;
                    o[7] = m.fXHeight;
                    o[8] = at;
                }
                kept.push_back({info->font, info->glyphs[g], at});
                n++;
            }
        });
    }
    if (letterCount) *letterCount = n;
    const int letters = nextText++;
    glyphLines[letters] = std::move(kept);
    return letters;
}

namespace {
/// Whether a font draws its letters as pictures (emoji in colour), which have no outlines to take.
bool drawsPictures(const SkFont& font) {
    const SkTypeface* t = font.getTypeface();
    if (!t) return false;
    for (const char* tag : {"COLR", "CBDT", "sbix", "SVG "}) {
        if (t->getTableSize(SkSetFourByteTag(tag[0], tag[1], tag[2], tag[3])) > 0) return true;
    }
    return false;
}
}  // namespace

extern "C" int32_t bz_text_outline(int32_t id, int32_t start, int32_t end) {
    std::lock_guard<std::mutex> guard(lock);
    answer.clear();
    auto it = texts.find(id);
    if (it == texts.end() || end <= start) return 0;
    const auto& t = it->second;
    SkPathBuilder letters;
    std::vector<SkRect> lineRects;
    bool pictures = false;
    for (size_t k = 0; k < t.lines.size(); k++) {
        const auto& line = t.lines[k];
        if (!line.paragraph) continue;
        // Where drawing call 12 paints the line, from the text's top left.
        const double baseline = k < t.baselines.size() ? t.baselines[k] : 0;
        const double dx = -line.back, dy = baseline - line.baseline;
        line.paragraph->visit([&](int, const Paragraph::VisitorInfo* info) {
            if (!info) return;
            SkFontMetrics m;
            info->font.getMetrics(&m);
            // Where the letters asked for begin and end in each of the line's runs, for the lines
            // under and through them: Skia shapes runs of one font together, whatever their styles.
            std::map<size_t, std::pair<double, double>> spans;
            for (int g = 0; g < info->count; g++) {
                const size_t inLine = utf16Index(line.words, info->utf8Starts[g]);
                const int32_t at = int32_t(line.start + inLine);
                if (at < start || at >= end) continue;
                if (drawsPictures(info->font)) { pictures = true; continue; }
                const double x = dx + info->origin.fX + info->positions[g].fX, y = dy + info->origin.fY + info->positions[g].fY;
                if (auto glyph = info->font.getPath(info->glyphs[g])) letters.addPath(*glyph, float(x), float(y));
                SkScalar w = 0;
                info->font.getWidths({&info->glyphs[g], 1}, {&w, 1});
                size_t run = 0, from = 0;
                while (run + 1 < line.runs.size() && inLine >= from + line.runs[run].text.size()) { from += line.runs[run].text.size(); run++; }
                auto [it, made] = spans.try_emplace(run, x, x + double(w));
                if (!made) { it->second.first = std::min(it->second.first, x); it->second.second = std::max(it->second.second, x + double(w)); }
            }
            // Each run's own lines under and through its letters, as Skia draws them.
            const double y = dy + info->origin.fY;
            for (const auto& [run, span] : spans) {
                if (run >= line.runs.size() || span.first >= span.second) continue;
                const Run& r = line.runs[run];
                if (r.underline) {
                    SkScalar position = 0, thickness = 0;
                    if (!m.hasUnderlinePosition(&position)) position = -m.fAscent * 0.1f;
                    if (!m.hasUnderlineThickness(&thickness)) thickness = info->font.getSize() / 14;
                    lineRects.push_back(SkRect::MakeLTRB(float(span.first), float(y + position), float(span.second), float(y + position + thickness)));
                }
                if (r.strike) {
                    SkScalar position = 0, thickness = 0;
                    if (!m.hasStrikeoutPosition(&position)) position = m.fAscent * 0.3f;
                    if (!m.hasStrikeoutThickness(&thickness)) thickness = info->font.getSize() / 14;
                    lineRects.push_back(SkRect::MakeLTRB(float(span.first), float(y + position), float(span.second), float(y + position + thickness)));
                }
            }
        });
    }
    if (pictures) return -1;
    SkPath shapes = letters.detach();
    // The lines made one with the letters they cross, as the Mac's TextOutlines does, so that
    // where they overlap is filled whichever way each winds: Skia's union, wound to fill by the
    // winding rule paths are filled with (its own may be even-odd). Where that cannot be wound,
    // the lines run the way the letters' outsides do, which fills the same.
    SkPath out = shapes;
    if (!lineRects.empty()) {
        SkPathBuilder joined(shapes);
        joined.setFillType(SkPathFillType::kWinding);
        // Which way the letters' outsides run: the larger areas, whose sign the sum takes.
        double area = 0;
        SkPath::Iter it(shapes, false);
        SkPoint first = {0, 0}, last = {0, 0};
        while (auto r = it.next()) {
            const auto& q = r->fPoints;
            auto edge = [&](SkPoint a, SkPoint b) { area += double(a.fX) * b.fY - double(b.fX) * a.fY; };
            switch (r->fVerb) {
                case SkPathVerb::kMove: first = last = q[0]; break;
                case SkPathVerb::kLine: edge(last, q[1]); last = q[1]; break;
                case SkPathVerb::kQuad: case SkPathVerb::kConic: edge(last, q[1]); edge(q[1], q[2]); last = q[2]; break;
                case SkPathVerb::kCubic: edge(last, q[1]); edge(q[1], q[2]); edge(q[2], q[3]); last = q[3]; break;
                case SkPathVerb::kClose: edge(last, first); last = first; break;
            }
        }
        const auto direction = area >= 0 ? SkPathDirection::kCW : SkPathDirection::kCCW;
        SkPathBuilder ruled;
        for (const auto& rect : lineRects) { ruled.addRect(rect, direction); joined.addRect(rect, direction); }
        auto united = Op(shapes, ruled.detach(), kUnion_SkPathOp);
        auto wound = united ? AsWinding(*united) : std::nullopt;
        out = wound ? *wound : joined.detach();
    }
    std::vector<double> numbers;
    writePath(out, numbers);
    keep(numbers);
    return int32_t(answer.size());
}

extern "C" int32_t bz_glyph_outline(int32_t line, int32_t index) {
    std::lock_guard<std::mutex> guard(lock);
    answer.clear();
    auto it = glyphLines.find(line);
    if (it == glyphLines.end() || index < 0 || index >= int32_t(it->second.size())) return 0;
    const Glyph& g = it->second[size_t(index)];
    if (drawsPictures(g.font)) return -1;
    std::vector<double> numbers;
    if (auto glyph = g.font.getPath(g.id)) writePath(*glyph, numbers);
    keep(numbers);
    return int32_t(answer.size());
}

extern "C" void bz_text_forget(void) {
    std::lock_guard<std::mutex> guard(lock);
    texts.clear();
    glyphLines.clear();
}

namespace {

int32_t addAsset(const char* name, const void* data, int32_t count) {
    auto image = decode(data, size_t(count));
    if (!image) return 0;
    Asset asset{image};
    if (avif::sniff(data, size_t(count))) {
        const auto* bytes = static_cast<const uint8_t*>(data);
        asset.avifFile = std::make_shared<std::vector<uint8_t>>(bytes, bytes + count);
    }
    pendingJPEGs.erase(name);
    return keepAsset(name, std::move(asset));
}

}

extern "C" int32_t bz_asset_add(const char* name, const void* data, int32_t count) {
    std::lock_guard<std::mutex> guard(lock);
    return addAsset(name, data, count);
}

extern "C" int32_t bz_asset_add_from_package(const char* name, const void* data, int32_t count) {
    if (!data || count <= 0) return 0;
    std::lock_guard<std::mutex> guard(lock);
    if (!SkJpegDecoder::IsJpeg(data, size_t(count))) return addAsset(name, data, count) != 0;
    if (auto pending = pendingJPEGs.find(name); pending != pendingJPEGs.end()) {
        auto bytes = pending->second->refEncodedData();
        if (bytes && bytes->size() == size_t(count) && std::memcmp(bytes->data(), data, size_t(count)) == 0) return 1;
        // Only replace an earlier pending JPEG if its replacement can be decoded.
        return addAsset(name, data, count) != 0;
    }
    registerImageDecoders();
    auto image = SkImages::DeferredFromEncodedData(SkData::MakeWithCopy(data, size_t(count)));
    if (!image) return 0;
    pendingJPEGs.emplace(name, std::move(image));
    return 1;
}

extern "C" int32_t bz_asset_stand_in(const char* name, const void* data, int32_t count, int32_t longest) {
    std::lock_guard<std::mutex> guard(lock);
    // The picture itself is here already.
    loadPendingJPEG(name);
    if (assetsByName.count(name) && !standIns.count(name)) return 0;
    auto small = decode(data, size_t(count));
    if (!small || longest <= 0) return 0;
    // As Core Image does it on the Mac (LiveGlimpse.standIn): in light, its edges carried on
    // outward, grown to `longest` across, blurred by 1.1 of its pixels as they are grown, and cut to
    // its grown size; back in sRGB.
    const double s = double(longest) / std::max(small->width(), small->height());
    const int w = std::max(1, int(std::ceil(small->width() * s - 1e-6))), h = std::max(1, int(std::ceil(small->height() * s - 1e-6)));
    const auto light = [](int w, int h) { return SkImageInfo::Make(w, h, kRGBA_F16_SkColorType, kPremul_SkAlphaType, SkColorSpace::MakeSRGBLinear()); };
    SkPaint copy;
    copy.setBlendMode(SkBlendMode::kSrc);
    auto inLight = SkSurfaces::Raster(light(small->width(), small->height()));
    auto grown = SkSurfaces::Raster(light(w, h));
    auto blurred = SkSurfaces::Raster(light(w, h));
    if (!inLight || !grown || !blurred) return 0;
    inLight->getCanvas()->drawImage(small, 0, 0, SkSamplingOptions(), &copy);
    SkPaint grow;
    grow.setBlendMode(SkBlendMode::kSrc);
    grow.setShader(inLight->makeImageSnapshot()->makeShader(SkTileMode::kClamp, SkTileMode::kClamp, SkSamplingOptions(SkFilterMode::kLinear),
                                                            SkMatrix::Scale(float(s), float(s))));
    grown->getCanvas()->drawPaint(grow);
    SkPaint blur;
    blur.setBlendMode(SkBlendMode::kSrc);
    const float sigma = float(s * 1.1);
    blur.setImageFilter(SkImageFilters::Blur(sigma, sigma, SkTileMode::kClamp, nullptr));
    blurred->getCanvas()->drawImage(grown->makeImageSnapshot(), 0, 0, SkSamplingOptions(), &blur);
    auto shown = raster(w, h, [&](SkCanvas* canvas) { canvas->drawImage(blurred->makeImageSnapshot(), 0, 0, SkSamplingOptions(), &copy); });
    if (!shown) return 0;
    assets.push_back({shown->withDefaultMipmaps()});
    const int number = int(assets.size());
    assetsByName[name] = number;
    standIns.insert(name);
    return number;
}

extern "C" void bz_picture_asset(int32_t id, int32_t asset) {
    std::lock_guard<std::mutex> guard(lock);
    Picture p;
    p.kind = Picture::kAsset;
    p.asset = asset;
    pictures[id] = std::move(p);
}

extern "C" void bz_picture_recording(int32_t id, int32_t width, int32_t height, const double* commands, int64_t count) {
    std::lock_guard<std::mutex> guard(lock);
    Picture p;
    p.kind = Picture::kRecording;
    p.width = width;
    p.height = height;
    p.commands.assign(commands, commands + std::max<int64_t>(count, 0));
    pictures[id] = std::move(p);
}

extern "C" void bz_picture_changed(int32_t id, int32_t width, int32_t height, int32_t from, const double* crop, double blur,
                                   int32_t clamp, const double* perspective) {
    std::lock_guard<std::mutex> guard(lock);
    Picture p;
    p.kind = Picture::kChanged;
    p.width = width;
    p.height = height;
    p.from = from;
    if (crop) std::copy(crop, crop + 4, p.crop);
    p.blur = blur;
    p.clamp = clamp != 0;
    if (perspective) { p.hasPerspective = true; std::copy(perspective, perspective + 9, p.perspective); }
    pictures[id] = std::move(p);
}

extern "C" void bz_picture_develop(int32_t id, const float* cube, int32_t size, const double* amounts) {
    std::lock_guard<std::mutex> guard(lock);
    auto it = pictures.find(id);
    if (it == pictures.end()) return;
    Picture& p = it->second;
    p.develops = true;
    p.cubeSize = std::max(size, 0);
    if (cube && size > 1) p.cube.assign(cube, cube + size_t(size) * size * size * 3);
    if (amounts) { p.dehaze = amounts[0]; p.clarity = amounts[1]; p.texture = amounts[2]; p.sharpness = amounts[3]; }
}

extern "C" void bz_picture_ramp(int32_t id, const double* ends) {
    std::lock_guard<std::mutex> guard(lock);
    auto it = pictures.find(id);
    if (it == pictures.end() || !ends) return;
    it->second.hasRamp = true;
    std::copy(ends, ends + 4, it->second.ramp);
}

extern "C" void bz_picture_pixels(int32_t id, int32_t width, int32_t height, int32_t bytesPerRow, const uint8_t* bytes) {
    std::lock_guard<std::mutex> guard(lock);
    Picture p;
    p.kind = Picture::kPixels;
    p.width = width;
    p.height = height;
    p.bytesPerRow = bytesPerRow;
    p.pixels.assign(bytes, bytes + size_t(bytesPerRow) * size_t(std::max(height, 0)));
    pictures[id] = std::move(p);
}

extern "C" int32_t bz_picture_read(int32_t id, int32_t width, int32_t height, int32_t bgra, void* pixels) {
    std::lock_guard<std::mutex> guard(lock);
    auto image = get(id);
    if (!image) return 1;
    const SkImageInfo info = SkImageInfo::Make(std::max(1, width), std::max(1, height), bgra ? kBGRA_8888_SkColorType : kRGBA_8888_SkColorType,
                                               kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    return image->readPixels(nullptr, SkPixmap(info, pixels, size_t(width) * 4), 0, 0) ? 0 : 2;
}

namespace {
/// The film's pictures with their mipmaps, made once each for being shown smaller than drawn.
std::map<int, sk_sp<SkImage>> mipped;
}

extern "C" void bz_picture_forget(int32_t id) {
    std::lock_guard<std::mutex> guard(lock);
    pictures.erase(id);
    made.erase(id);
    mipped.erase(id);
}

// MARK: A film's frame (Host/FilmStage.swift, FilmMovie.swift)

namespace {

/// A piece of a frame with its picture found: what `layFilm` draws.
struct FilmLaid {
    sk_sp<SkImage> image;
    const bz_film_piece* piece;
};

/// Lays the pieces into rows `top` to `bottom` of a frame, over the backdrop. The canvas is the
/// whole frame's, cut down to those rows, so a pixel comes out as it does with the frame laid out
/// in one go, blurs too. Measured on a film with a blur and a camera that tilts: the same to the
/// last bit seen straight on, and seen in perspective up to 170 pixels of a million one step of
/// 255 off, on edges Skia cuts to the rows it fills.
void layFilm(const SkImageInfo& info, void* pixels, int top, int bottom, const double* backdrop, const std::vector<FilmLaid>& laid) {
    auto surface = SkSurfaces::WrapPixels(info, pixels, size_t(info.width()) * 4);
    if (!surface) return;
    SkCanvas* canvas = surface->getCanvas();
    canvas->clipIRect(SkIRect::MakeLTRB(0, top, info.width(), bottom));
    canvas->clear(backdrop ? SkColor4f{float(backdrop[0]), float(backdrop[1]), float(backdrop[2]), float(backdrop[3])} : SkColors::kTransparent);
    for (const FilmLaid& l : laid) {
        const bz_film_piece& p = *l.piece;
        const sk_sp<SkImage>& image = l.image;
        const double* m = p.map;
        const SkMatrix map = SkMatrix::MakeAll(float(m[0]), float(m[1]), float(m[2]), float(m[3]), float(m[4]), float(m[5]),
                                               float(m[6]), float(m[7]), float(m[8]));
        // What of it shows: the outline given (what lies in front of the eye), else all of it. The
        // outline is filled with the picture, so nothing behind the eye is ever drawn.
        SkPathBuilder outline;
        if (p.count >= 3) {
            outline.moveTo(float(p.outline[0]), float(p.outline[1]));
            for (int i = 1; i < std::min(p.count, int32_t(9)); i++) outline.lineTo(float(p.outline[2 * i]), float(p.outline[2 * i + 1]));
            outline.close();
        } else {
            outline.addRect(SkRect::MakeIWH(image->width(), image->height()));
        }
        SkPaint paint;
        paint.setAntiAlias(true);
        paint.setShader(image->makeShader(SkTileMode::kDecal, SkTileMode::kDecal, SkSamplingOptions(SkFilterMode::kLinear, SkMipmapMode::kLinear)));
        if (p.blur > 0.05) {
            // Blurred as the frame shows it, spreading past its edges.
            SkPaint layer;
            layer.setAlphaf(float(std::min(p.opacity, 1.0)));
            layer.setImageFilter(SkImageFilters::Blur(float(p.blur), float(p.blur), SkTileMode::kDecal, nullptr));
            canvas->saveLayer(nullptr, &layer);
        } else {
            paint.setAlphaf(float(std::min(p.opacity, 1.0)));
            canvas->save();
        }
        canvas->concat(map);
        canvas->drawPath(outline.detach(), paint);
        canvas->restore();
    }
}

/// How many bands a frame is laid out in, a thread each: one for each processor but one, none
/// thinner than 48 rows, and a small frame in one, which is laid out sooner than threads are
/// begun. BEZZLE_FILM_BANDS says another number, for comparing.
int filmBands(int width, int height) {
    static const int asked = [] {
        const char* said = getenv("BEZZLE_FILM_BANDS");
        return said ? std::max(1, atoi(said)) : 0;
    }();
    if (asked > 0) return std::min(asked, std::max(1, height));
    if (int64_t(width) * height < 160000) return 1;
    const int processors = int(std::thread::hardware_concurrency());
    return std::max(1, std::min({processors - 1, 12, height / 48}));
}

}

extern "C" int32_t bz_film_frame(int32_t width, int32_t height, const double* backdrop, const bz_film_piece* pieces, int32_t count,
                                 int32_t bgra, void* pixels) {
    // Held until the frame is whole: the pictures are the core's, which forgets them under it.
    std::lock_guard<std::mutex> guard(lock);
    const int w = std::max(1, width), h = std::max(1, height);
    const SkImageInfo info = SkImageInfo::Make(w, h, bgra ? kBGRA_8888_SkColorType : kRGBA_8888_SkColorType, kPremul_SkAlphaType,
                                               SkColorSpace::MakeSRGB());
    if (!SkSurfaces::WrapPixels(info, pixels, size_t(w) * 4)) return 1;
    std::vector<FilmLaid> laid;
    laid.reserve(size_t(std::max(count, 0)));
    for (int k = 0; k < count; k++) {
        const bz_film_piece& p = pieces[k];
        if (p.opacity < 0.001) continue;
        sk_sp<SkImage> image;
        if (auto it = mipped.find(p.picture); it != mipped.end()) {
            image = it->second;
        } else if (auto drawn = get(p.picture)) {
            image = drawn->withDefaultMipmaps();
            if (!image) image = drawn;
            mipped[p.picture] = image;
        }
        if (image) laid.push_back({image, &p});
    }
    // In bands, a thread each: a frame's time is Skia filling it on the processor, and the bands
    // share nothing but the pictures, which are only read.
    const int bands = filmBands(w, h);
    if (bands <= 1) {
        layFilm(info, pixels, 0, h, backdrop, laid);
        return 0;
    }
    std::vector<std::thread> threads;
    threads.reserve(size_t(bands - 1));
    for (int b = 1; b < bands; b++) {
        const int top = int(int64_t(h) * b / bands), bottom = int(int64_t(h) * (b + 1) / bands);
        threads.emplace_back([&info, pixels, top, bottom, backdrop, &laid] { layFilm(info, pixels, top, bottom, backdrop, laid); });
    }
    layFilm(info, pixels, 0, int(int64_t(h) / bands), backdrop, laid);
    for (auto& t : threads) t.join();
    return 0;
}

// Skia's own zlib (Chromium's, its names mapped by chromeconf.h, as the library was built).
#include "third_party/externals/zlib/zlib.h"

extern "C" int32_t bz_inflate(const void* bytes, int32_t count) {
    answer.clear();
    z_stream z = {};
    if (inflateInit2(&z, -15) != Z_OK) return -1;
    z.next_in = (Bytef*)bytes;
    z.avail_in = uInt(count);
    std::vector<uint8_t> out(size_t(count) * 4 + 4096);
    int result = Z_OK;
    while (result == Z_OK) {
        if (z.total_out >= out.size()) out.resize(out.size() * 2);
        z.next_out = out.data() + z.total_out;
        z.avail_out = uInt(out.size() - z.total_out);
        result = inflate(&z, Z_NO_FLUSH);
        if (result == Z_BUF_ERROR && z.avail_in > 0) result = Z_OK;
    }
    size_t made = z.total_out;
    inflateEnd(&z);
    if (result != Z_STREAM_END) return -1;
    out.resize(made);
    answer = std::move(out);
    return int32_t(answer.size());
}

extern "C" int64_t bz_inflate_into(const void* bytes, int64_t count, void* out, int64_t capacity) {
    z_stream z = {};
    if (inflateInit2(&z, -15) != Z_OK) return -1;
    // zlib counts in 32 bits: what is larger goes through in pieces.
    const Bytef* in = (const Bytef*)bytes;
    Bytef* to = (Bytef*)out;
    int64_t inLeft = count, outLeft = capacity;
    int result = Z_OK;
    while (result == Z_OK && outLeft > 0) {
        if (z.avail_in == 0 && inLeft > 0) {
            uInt n = uInt(std::min<int64_t>(inLeft, int64_t(1) << 30));
            z.next_in = (Bytef*)in;
            z.avail_in = n;
            in += n;
            inLeft -= n;
        }
        uInt room = uInt(std::min<int64_t>(outLeft, int64_t(1) << 30));
        z.next_out = to;
        z.avail_out = room;
        result = inflate(&z, Z_NO_FLUSH);
        uInt made = room - z.avail_out;
        to += made;
        outLeft -= made;
        // Out of input before the end: what there was is all there is.
        if (result == Z_BUF_ERROR) break;
    }
    inflateEnd(&z);
    if (result != Z_OK && result != Z_STREAM_END && result != Z_BUF_ERROR) return -1;
    return capacity - outLeft;
}

/// A PNG file's bytes with its colour profile, the 'iCCP' chunk Skia wrote, made `icc` itself:
/// the profile the picture it was made from carried, byte for byte, as Image I/O writes it.
bool withProfile(std::vector<uint8_t>& png, const void* icc, size_t count) {
    static const char name[] = "ICC Profile";
    uLongf packed = compressBound(uLong(count));
    // Its name and the 0 ending it, then 0 for zlib, the one way a profile is packed.
    std::vector<uint8_t> body(sizeof(name) + 1 + packed);
    std::memcpy(body.data(), name, sizeof(name));
    body[sizeof(name)] = 0;
    if (compress2(body.data() + sizeof(name) + 1, &packed, static_cast<const Bytef*>(icc), uLong(count), 9) != Z_OK) return false;
    body.resize(sizeof(name) + 1 + packed);
    auto be = [](uint32_t v) { return std::array<uint8_t, 4>{uint8_t(v >> 24), uint8_t(v >> 16), uint8_t(v >> 8), uint8_t(v)}; };
    std::vector<uint8_t> chunk;
    const auto length = be(uint32_t(body.size()));
    chunk.insert(chunk.end(), length.begin(), length.end());
    const uint8_t type[4] = {'i', 'C', 'C', 'P'};
    chunk.insert(chunk.end(), type, type + 4);
    chunk.insert(chunk.end(), body.begin(), body.end());
    uLong crc = crc32(0, type, 4);
    crc = crc32(crc, body.data(), uInt(body.size()));
    const auto sum = be(uint32_t(crc));
    chunk.insert(chunk.end(), sum.begin(), sum.end());
    // In place of Skia's own, or after the header when there is none; what else says the colours goes.
    size_t at = 8, place = 0;
    while (at + 12 <= png.size()) {
        const uint32_t n = uint32_t(png[at]) << 24 | uint32_t(png[at + 1]) << 16 | uint32_t(png[at + 2]) << 8 | png[at + 3];
        const std::string kind(reinterpret_cast<const char*>(&png[at + 4]), 4);
        const size_t end = at + 12 + n;
        if (end > png.size()) return false;
        if (kind == "IHDR") place = end;
        if (kind == "iCCP" || kind == "sRGB" || kind == "gAMA" || kind == "cHRM") {
            png.erase(png.begin() + std::ptrdiff_t(at), png.begin() + std::ptrdiff_t(end));
            continue;
        }
        if (kind == "IDAT" || kind == "IEND") break;
        at = end;
    }
    if (!place) return false;
    png.insert(png.begin() + std::ptrdiff_t(place), chunk.begin(), chunk.end());
    return true;
}

extern "C" int64_t bz_png_encode_own(int32_t width, int32_t height, const void* pixels, int32_t straight, const void* icc, int32_t iccCount,
                                     void* out, int64_t capacity) {
    const auto colors = profileColors(icc, iccCount);
    if (!colors) return -1;
    const SkImageInfo info = SkImageInfo::Make(std::max(1, width), std::max(1, height), kRGBA_8888_SkColorType,
                                               straight ? kUnpremul_SkAlphaType : kPremul_SkAlphaType, colors);
    SkDynamicMemoryWStream stream;
    // Packed as bz_png_encode packs them.
    SkPngEncoder::Options options;
    options.fZLibLevel = 3;
    if (!SkPngEncoder::Encode(&stream, SkPixmap(info, pixels, size_t(width) * 4), options)) return -1;
    std::vector<uint8_t> png(stream.bytesWritten());
    stream.copyTo(png.data());
    if (icc && iccCount > 0 && !withProfile(png, icc, size_t(iccCount))) return -1;
    const int64_t size = int64_t(png.size());
    if (size > capacity) return -size;
    std::memcpy(out, png.data(), png.size());
    return size;
}

extern "C" int32_t bz_png_write(const char* path, int32_t width, int32_t height, const void* pixels) {
    SkFILEWStream file(path);
    if (!file.isValid()) return 1;
    const SkPixmap pixmap(rgba(width, height), pixels, size_t(width) * 4);
    return SkPngEncoder::Encode(&file, pixmap, {}) ? 0 : 2;
}

extern "C" int32_t bz_image_write(const char* path, int32_t width, int32_t height, const void* pixels, int32_t format, double quality,
                                  double dpi) {
    SkFILEWStream file(path);
    if (!file.isValid()) return 1;
    const SkPixmap pixmap(rgba(width, height), pixels, size_t(width) * 4);
    switch (format) {
        case 1: {
            // As the Mac's Image I/O writes JPEG (jpeg.cpp).
            std::vector<uint8_t> bytes;
            if (!jpeg::write(width, height, static_cast<const uint8_t*>(pixels), quality, dpi, bytes)) return 2;
            return file.write(bytes.data(), bytes.size()) ? 0 : 2;
        }
        case 2: {
            // At the very top, lossless, as the Mac's WebP writer makes it.
            SkWebpEncoder::Options options;
            options.fCompression = quality >= 1 ? SkWebpEncoder::Compression::kLossless : SkWebpEncoder::Compression::kLossy;
            options.fQuality = float(quality >= 1 ? 75 : std::clamp(quality * 100, 0.0, 100.0));
            return SkWebpEncoder::Encode(&file, pixmap, options) ? 0 : 2;
        }
        case 3: {
            // As the Mac's Image I/O writes AVIF (avif.cpp).
            std::vector<uint8_t> bytes;
            if (!avif::write(width, height, static_cast<const uint8_t*>(pixels), quality, bytes)) return 2;
            return file.write(bytes.data(), bytes.size()) ? 0 : 2;
        }
        default:
            return SkPngEncoder::Encode(&file, pixmap, {}) ? 0 : 2;
    }
}

extern "C" int32_t bz_avif_available(void) { return avif::available() ? 1 : 0; }

extern "C" int32_t bz_pixels_scale(const void* pixels, int32_t width, int32_t height, void* out, int32_t toWidth, int32_t toHeight) {
    if (!pixels || !out || width <= 0 || height <= 0 || toWidth <= 0 || toHeight <= 0) return 1;
    const SkImageInfo from = SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    const SkImageInfo to = SkImageInfo::Make(toWidth, toHeight, kRGBA_8888_SkColorType, kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    auto image = SkImages::RasterFromPixmap(SkPixmap(from, pixels, size_t(width) * 4), nullptr, nullptr);
    auto surface = SkSurfaces::Raster(to);
    if (!image || !surface) return 2;
    SkCanvas* canvas = surface->getCanvas();
    canvas->clear(SK_ColorTRANSPARENT);
    canvas->scale(float(toWidth) / float(width), float(toHeight) / float(height));
    SkPaint paint;
    paint.setBlendMode(SkBlendMode::kSrc);
    canvas->drawImage(image->withDefaultMipmaps(), 0, 0, SkSamplingOptions(SkFilterMode::kLinear, SkMipmapMode::kLinear), &paint);
    return surface->readPixels(to, out, size_t(toWidth) * 4, 0, 0) ? 0 : 3;
}

extern "C" int32_t bz_image_encode(int32_t width, int32_t height, const void* pixels, int32_t format, double quality) {
    std::lock_guard<std::mutex> guard(lock);
    SkDynamicMemoryWStream stream;
    const SkPixmap pixmap(rgba(width, height), pixels, size_t(width) * 4);
    bool done = false;
    if (format == 1) {
        // As the Mac's NSBitmapImageRep writes JPEG, which is Image I/O's with no DPI (jpeg.cpp).
        std::vector<uint8_t> bytes;
        done = jpeg::write(width, height, static_cast<const uint8_t*>(pixels), quality, 0, bytes) && stream.write(bytes.data(), bytes.size());
    } else {
        done = SkPngEncoder::Encode(&stream, pixmap, {});
    }
    answer.clear();
    if (!done) return 0;
    sk_sp<SkData> data = stream.detachAsData();
    const auto* bytes = static_cast<const uint8_t*>(data->data());
    answer.assign(bytes, bytes + data->size());
    return int32_t(answer.size());
}

/// A PDF being written: its file, and the document drawing into it.
struct PDF {
    std::unique_ptr<SkFILEWStream> file;
    sk_sp<SkDocument> document;
};
std::map<int, PDF> pdfs;
int nextPDF = 1;

extern "C" int32_t bz_pdf_begin(const char* path) {
    std::lock_guard<std::mutex> guard(lock);
    PDF pdf;
    pdf.file = std::make_unique<SkFILEWStream>(path);
    if (!pdf.file->isValid()) return 0;
    // Pictures in it kept as JPEG where they came as JPEG, as Skia asks a PDF to be given.
    SkPDF::Metadata metadata = SkPDF::JPEG::MetadataWithCallbacks();
    metadata.fCreator = "Bezzle";
    metadata.fProducer = "Bezzle";
    pdf.document = SkPDF::MakeDocument(pdf.file.get(), metadata);
    if (!pdf.document) return 0;
    const int id = nextPDF++;
    pdfs[id] = std::move(pdf);
    return id;
}

extern "C" int32_t bz_pdf_page(int32_t pdf, int32_t picture, double width, double height, double scale) {
    std::lock_guard<std::mutex> guard(lock);
    auto it = pdfs.find(pdf);
    auto p = pictures.find(picture);
    if (it == pdfs.end() || p == pictures.end() || p->second.kind != Picture::kRecording) return 1;
    SkCanvas* canvas = it->second.document->beginPage(float(width), float(height));
    if (!canvas) return 2;
    // The recording, at `scale` pixels a point, played as shapes and text rather than pixels.
    canvas->scale(float(1 / scale), float(1 / scale));
    canvas->concat(SkMatrix::MakeAll(1, 0, 0, 0, -1, float(p->second.height), 0, 0, 1));
    playingPDF = true;
    carried = 1;
    carriedBefore.clear();
    play(canvas, p->second.commands.data(), p->second.commands.size());
    playingPDF = false;
    carried = 1;
    carriedBefore.clear();
    it->second.document->endPage();
    return 0;
}

extern "C" int32_t bz_pdf_end(int32_t pdf) {
    std::lock_guard<std::mutex> guard(lock);
    auto it = pdfs.find(pdf);
    if (it == pdfs.end()) return 1;
    it->second.document->close();
    it->second.file->flush();
    pdfs.erase(it);
    return 0;
}

extern "C" int32_t bz_shadow(int32_t width, int32_t height, int32_t pad, double blur, double dy, uint32_t rgb, double alpha, void* pixels) {
    const int w = std::max(1, width + 2 * pad), h = std::max(1, height + 2 * pad);
    const SkImageInfo info = SkImageInfo::Make(w, h, kBGRA_8888_SkColorType, kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    auto surface = SkSurfaces::WrapPixels(info, pixels, size_t(w) * 4);
    if (!surface) return 1;
    SkCanvas* canvas = surface->getCanvas();
    canvas->clear(SK_ColorTRANSPARENT);
    SkPaint paint;
    paint.setAntiAlias(true);
    paint.setColor4f({float((rgb >> 16 & 0xFF) / 255.0), float((rgb >> 8 & 0xFF) / 255.0), float((rgb & 0xFF) / 255.0), float(alpha)});
    if (blur > 0) paint.setMaskFilter(SkMaskFilter::MakeBlur(kNormal_SkBlurStyle, float(blur / 2)));
    canvas->drawRect(SkRect::MakeXYWH(float(pad), float(pad + dy), float(width), float(height)), paint);
    return 0;
}

extern "C" int32_t bz_stage(int32_t width, int32_t height, double scale, uint32_t table, uint32_t light, double strength,
                            double x, double y, double reach, double shade, void* pixels) {
    const int w = std::max(1, width), h = std::max(1, height);
    const SkImageInfo info = SkImageInfo::Make(w, h, kBGRA_8888_SkColorType, kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    auto surface = SkSurfaces::WrapPixels(info, pixels, size_t(w) * 4);
    if (!surface) return 1;
    SkCanvas* canvas = surface->getCanvas();
    canvas->clear(SK_ColorTRANSPARENT);
    auto c = [](uint32_t rgb, double a) { return SkColor4f{float((rgb >> 16 & 0xFF) / 255.0), float((rgb >> 8 & 0xFF) / 255.0), float((rgb & 0xFF) / 255.0), float(a)}; };
    const SkRRect shape = SkRRect::MakeRectXY(SkRect::MakeWH(float(w), float(h)), float(20 * scale), float(20 * scale));
    canvas->clipRRect(shape, true);
    SkPaint paint;
    paint.setAntiAlias(true);
    paint.setColor4f(c(table, 1));
    canvas->drawPaint(paint);
    // The pool: an elliptical gradient, as SwiftUI's EllipticalGradient fills the table's frame.
    const SkColor4f pool[2] = {c(light, strength), c(light, 0)};
    const SkGradient lit(SkGradient::Colors(pool, SkTileMode::kClamp), {});
    SkMatrix stretch = SkMatrix::Scale(float(w * reach), float(h * reach));
    stretch.postTranslate(float(w * x), float(h * y));
    SkPaint glow;
    glow.setShader(SkShaders::RadialGradient({0, 0}, 1, lit, &stretch));
    canvas->drawPaint(glow);
    // The far edge falling into shade.
    const SkColor4f fall[2] = {c(0, 0), c(0, shade)};
    const SkPoint ends[2] = {{0, float(h / 2.0)}, {0, float(h)}};
    SkPaint dim;
    dim.setShader(SkShaders::LinearGradient(ends, SkGradient(SkGradient::Colors(fall, SkTileMode::kClamp), {})));
    canvas->drawPaint(dim);
    return 0;
}
