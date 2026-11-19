#include "libraw/libraw.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#include <algorithm>
#include <cmath>

#ifdef __APPLE__
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#else
#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>
using Microsoft::WRL::ComPtr;
#endif

static void require_raw(int code) {
  if (code != LIBRAW_SUCCESS) throw std::runtime_error(libraw_strerror(code));
}

// Preview files have a bounded size and are separate from full-size exports.
static std::vector<unsigned char> preview_pixels(const libraw_processed_image_t& image,
                                                unsigned& width, unsigned& height) {
  const double scale = std::min(1.0, 2560.0 / std::max(image.width, image.height));
  width = std::max(1u, static_cast<unsigned>(std::lround(image.width * scale)));
  height = std::max(1u, static_cast<unsigned>(std::lround(image.height * scale)));
  std::vector<unsigned char> pixels(static_cast<size_t>(width) * height * 3);
  for (unsigned y = 0; y < height; ++y) {
    for (unsigned x = 0; x < width; ++x) {
      const double sx = (x + .5) * image.width / width - .5;
      const double sy = (y + .5) * image.height / height - .5;
      const unsigned x0 = static_cast<unsigned>(std::max(0.0, sx));
      const unsigned y0 = static_cast<unsigned>(std::max(0.0, sy));
      const unsigned x1 = std::min(x0 + 1, static_cast<unsigned>(image.width - 1));
      const unsigned y1 = std::min(y0 + 1, static_cast<unsigned>(image.height - 1));
      const double fx = std::max(0.0, sx - x0), fy = std::max(0.0, sy - y0);
      for (unsigned c = 0; c < 3; ++c) {
        const double top = image.data[(y0 * image.width + x0) * 3 + c] * (1-fx)
                         + image.data[(y0 * image.width + x1) * 3 + c] * fx;
        const double bottom = image.data[(y1 * image.width + x0) * 3 + c] * (1-fx)
                            + image.data[(y1 * image.width + x1) * 3 + c] * fx;
        pixels[(y * width + x) * 3 + c] = static_cast<unsigned char>(std::lround(top * (1-fy) + bottom * fy));
      }
    }
  }
  return pixels;
}

#ifdef __APPLE__
static void encode(const char* path, bool png, int quality,
                   const libraw_processed_image_t& image) {
  auto color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  auto provider = CGDataProviderCreateWithData(nullptr, image.data, image.data_size, nullptr);
  auto bitmap = CGImageCreate(image.width, image.height, 8, 24, image.width * 3,
      color, kCGImageAlphaNone, provider, nullptr, false, kCGRenderingIntentDefault);
  auto url = CFURLCreateFromFileSystemRepresentation(nullptr,
      reinterpret_cast<const UInt8*>(path), strlen(path), false);
  auto destination = url ? CGImageDestinationCreateWithURL(url,
      png ? CFSTR("public.png") : CFSTR("public.jpeg"), 1, nullptr) : nullptr;
  bool success = false;
  if (bitmap && destination) {
    double value = quality / 100.0;
    auto number = CFNumberCreate(nullptr, kCFNumberDoubleType, &value);
    const void* keys[] = {kCGImageDestinationLossyCompressionQuality};
    const void* values[] = {number};
    auto properties = CFDictionaryCreate(nullptr, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CGImageDestinationAddImage(destination, bitmap, properties);
    success = CGImageDestinationFinalize(destination);
    CFRelease(properties);
    CFRelease(number);
  }
  if (destination) CFRelease(destination);
  if (url) CFRelease(url);
  if (bitmap) CGImageRelease(bitmap);
  CGDataProviderRelease(provider);
  CGColorSpaceRelease(color);
  if (!success) throw std::runtime_error("Could not encode image; check available disk space and permissions.");
}
#else
static void hr(HRESULT result) {
  if (FAILED(result)) throw std::runtime_error("Windows image encoder failed (" + std::to_string(result) + ").");
}
static void encode(const wchar_t* path, bool png, int quality,
                   const libraw_processed_image_t& image) {
  hr(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
  ComPtr<IWICImagingFactory> factory;
  hr(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
      IID_PPV_ARGS(&factory)));
  ComPtr<IWICStream> stream;
  hr(factory->CreateStream(&stream));
  hr(stream->InitializeFromFilename(path, GENERIC_WRITE));
  ComPtr<IWICBitmapEncoder> encoder;
  hr(factory->CreateEncoder(png ? GUID_ContainerFormatPng : GUID_ContainerFormatJpeg,
      nullptr, &encoder));
  hr(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache));
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> properties;
  hr(encoder->CreateNewFrame(&frame, &properties));
  if (!png) {
    PROPBAG2 option = {};
    option.pstrName = const_cast<wchar_t*>(L"ImageQuality");
    VARIANT value; VariantInit(&value);
    value.vt = VT_R4; value.fltVal = quality / 100.0f;
    hr(properties->Write(1, &option, &value));
  }
  hr(frame->Initialize(properties.Get()));
  hr(frame->SetSize(image.width, image.height));
  WICPixelFormatGUID format = GUID_WICPixelFormat24bppRGB;
  hr(frame->SetPixelFormat(&format));
  // Some WIC encoders request BGR. Convert through WIC rather than assuming RGB.
  ComPtr<IWICBitmap> bitmap;
  hr(factory->CreateBitmapFromMemory(image.width, image.height,
      GUID_WICPixelFormat24bppRGB, image.width * 3, image.data_size,
      const_cast<BYTE*>(image.data), &bitmap));
  ComPtr<IWICFormatConverter> converter;
  hr(factory->CreateFormatConverter(&converter));
  hr(converter->Initialize(bitmap.Get(), format, WICBitmapDitherTypeNone,
      nullptr, 0, WICBitmapPaletteTypeCustom));
  hr(frame->WriteSource(converter.Get(), nullptr));
  hr(frame->Commit());
  hr(encoder->Commit());
}
#endif

// A separate process bounds decoder failures and permits immediate cancellation.
#ifdef __APPLE__
int main(int argc, char** argv) {
  const bool png = argc == 5 && strcmp(argv[3], "png") == 0;
  const bool preview = argc == 5 && strcmp(argv[3], "preview") == 0;
  const int quality = argc == 5 ? atoi(argv[4]) : 0;
  const bool valid_format = argc == 5 && (png || preview || strcmp(argv[3], "jpg") == 0);
#else
int wmain(int argc, wchar_t** argv) {
  const bool png = argc == 5 && wcscmp(argv[3], L"png") == 0;
  const bool preview = argc == 5 && wcscmp(argv[3], L"preview") == 0;
  const int quality = argc == 5 ? _wtoi(argv[4]) : 0;
  const bool valid_format = argc == 5 && (png || preview || wcscmp(argv[3], L"jpg") == 0);
#endif
  if (!valid_format || quality < 1 || quality > 100) {
    fputs("Usage: shipian_raw_converter input output jpg|png|preview quality\n", stderr);
    return 2;
  }
  try {
    LibRaw raw;
    raw.imgdata.rawparams.max_raw_memory_mb = 2048;
    raw.imgdata.params.use_camera_wb = 1;
    raw.imgdata.params.output_color = 1; // sRGB
    raw.imgdata.params.output_bps = 8;
    raw.imgdata.params.user_qual = 3; // full-resolution AHD; no embedded preview
    require_raw(raw.open_file(argv[1]));
    if (preview && std::max(raw.imgdata.sizes.width, raw.imgdata.sizes.height) > 3000) {
      raw.imgdata.params.half_size = 1;
    }
    require_raw(raw.unpack());
    require_raw(raw.dcraw_process());
    int error = 0;
    std::unique_ptr<libraw_processed_image_t, decltype(&LibRaw::dcraw_clear_mem)>
        image(raw.dcraw_make_mem_image(&error), &LibRaw::dcraw_clear_mem);
    require_raw(error);
    if (!image || image->type != LIBRAW_IMAGE_BITMAP || image->colors != 3 ||
        image->bits != 8 || image->width == 0 || image->height == 0 ||
        static_cast<size_t>(image->width) * image->height * 3 != image->data_size) {
      throw std::runtime_error("Unsupported RAW pixel layout.");
    }
    unsigned width = image->width, height = image->height;
    if (preview && std::max(width, height) > 2560) {
      auto pixels = preview_pixels(*image, width, height);
      // The processed bitmap header is variable-length; keep the owned LibRaw
      // image intact and build another bounded bitmap for the system encoder.
      const auto bytes = pixels.size();
      auto scaled = std::unique_ptr<libraw_processed_image_t, decltype(&std::free)>(
          static_cast<libraw_processed_image_t*>(std::malloc(sizeof(libraw_processed_image_t) + bytes)), &std::free);
      if (!scaled) throw std::bad_alloc();
      scaled->type = LIBRAW_IMAGE_BITMAP;
      scaled->width = width; scaled->height = height;
      scaled->colors = 3; scaled->bits = 8; scaled->data_size = static_cast<unsigned>(bytes);
      std::memcpy(scaled->data, pixels.data(), bytes);
      encode(argv[2], false, quality, *scaled);
    } else {
      encode(argv[2], png, quality, *image);
    }
    printf("{\"width\":%u,\"height\":%u,\"engine\":\"LibRaw %s\"}\n",
        width, height, LibRaw::version());
    return 0;
  } catch (const std::exception& error) {
    fprintf(stderr, "%s\n", error.what());
    return 1;
  } catch (...) {
    fputs("RAW decoding failed.\n", stderr);
    return 1;
  }
}
