using System;
using System.IO;
#if WINDOWS
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
#else
using System.Runtime.InteropServices;
using SkiaSharp;
#endif

namespace DeckOS.Lib
{
    /// <summary>
    /// As poucas operacoes de imagem do servidor (capa do "tocando agora", icone da Steam,
    /// import do Stream Deck, tecla do Companion). No Windows com o GDI+ (System.Drawing),
    /// como sempre foi; no macOS/Linux o System.Drawing nao existe e entra o Skia (SkiaSharp).
    /// </summary>
    public static class ImageOps
    {
        /// <summary>Reduz para caber em <paramref name="size"/> px, em JPEG. Null se ja cabe (use o original).</summary>
        public static byte[]? ShrinkToJpeg(byte[] input, int size)
        {
#if WINDOWS
            using var ms = new MemoryStream(input);
            using var src = System.Drawing.Image.FromStream(ms);
            if (src.Width <= size && src.Height <= size) return null;
            var scale = (double)size / Math.Max(src.Width, src.Height);
            using var dst = new Bitmap(Math.Max(1, (int)(src.Width * scale)), Math.Max(1, (int)(src.Height * scale)));
            using (var g = Graphics.FromImage(dst))
            {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.DrawImage(src, 0, 0, dst.Width, dst.Height);
            }
            using var output = new MemoryStream();
            dst.Save(output, ImageFormat.Jpeg);
            return output.ToArray();
#else
            using var src = Decode(input);
            if (src.Width <= size && src.Height <= size) return null;
            var scale = (double)size / Math.Max(src.Width, src.Height);
            using var dst = Draw(src, new SKRect(0, 0, src.Width, src.Height),
                Math.Max(1, (int)(src.Width * scale)), Math.Max(1, (int)(src.Height * scale)));
            return Encode(dst, SKEncodedImageFormat.Jpeg, 85);
#endif
        }

        /// <summary>
        /// Recorte quadrado no centro (numa imagem vertical, um pouco acima do meio, onde costuma
        /// ficar a arte principal), em <paramref name="size"/> px, PNG.
        /// </summary>
        public static byte[] SquareCropPng(string file, int size)
        {
#if WINDOWS
            using var source = System.Drawing.Image.FromFile(file);
            var (x, y, side) = CropBox(source.Width, source.Height);
            using var bmp = new Bitmap(size, size);
            using (var g = Graphics.FromImage(bmp))
            {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.SmoothingMode = SmoothingMode.HighQuality;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.DrawImage(source, new Rectangle(0, 0, size, size), new Rectangle(x, y, side, side), GraphicsUnit.Pixel);
            }
            using var ms = new MemoryStream();
            bmp.Save(ms, ImageFormat.Png);
            return ms.ToArray();
#else
            using var src = Decode(File.ReadAllBytes(file));
            var (x, y, side) = CropBox(src.Width, src.Height);
            using var dst = Draw(src, SKRect.Create(x, y, side, side), size, size);
            return Encode(dst, SKEncodedImageFormat.Png, 100);
#endif
        }

        private static (int X, int Y, int Side) CropBox(int width, int height)
        {
            var side = Math.Min(width, height);
            var x = (width - side) / 2;
            var y = height > width ? (height - side) / 3 : (height - side) / 2;
            return (x, y, side);
        }

        /// <summary>
        /// Icone quadrado de <paramref name="size"/> px em PNG. GIF ate 2 MB vai como esta (reduzir
        /// perderia a animacao), e PNG que ja cabe tambem.
        /// </summary>
        public static byte[] IconPng(byte[] bytes, int size)
        {
#if WINDOWS
            using var input = new MemoryStream(bytes);
            using var source = System.Drawing.Image.FromStream(input);
            if (source.RawFormat.Equals(ImageFormat.Gif) && bytes.Length <= 2 * 1024 * 1024)
                return bytes;
            if (source.Width <= size && source.Height <= size && source.RawFormat.Equals(ImageFormat.Png))
                return bytes;
            using var bitmap = new Bitmap(size, size);
            using (var g = Graphics.FromImage(bitmap))
            {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.DrawImage(source, 0, 0, size, size);
            }
            using var output = new MemoryStream();
            bitmap.Save(output, ImageFormat.Png);
            return output.ToArray();
#else
            SKEncodedImageFormat format;
            using (var codec = SKCodec.Create(new SKMemoryStream(bytes)) ?? throw new InvalidDataException("Imagem ilegível"))
                format = codec.EncodedFormat;
            if (format == SKEncodedImageFormat.Gif && bytes.Length <= 2 * 1024 * 1024) return bytes;
            using var src = Decode(bytes);
            if (src.Width <= size && src.Height <= size && format == SKEncodedImageFormat.Png) return bytes;
            using var dst = Draw(src, new SKRect(0, 0, src.Width, src.Height), size, size);
            return Encode(dst, SKEncodedImageFormat.Png, 100);
#endif
        }

        /// <summary>RGB cru (3 bytes por pixel, linha a linha) de um quadrado de <paramref name="side"/> px para PNG.</summary>
        public static byte[] RgbToPng(byte[] rgb, int side)
        {
#if WINDOWS
            using var image = new Bitmap(side, side, PixelFormat.Format24bppRgb);
            var data = image.LockBits(new Rectangle(0, 0, side, side), ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);
            try
            {
                var row = new byte[side * 3];
                for (var y = 0; y < side; y++)
                {
                    // O Bitmap guarda BGR.
                    for (var x = 0; x < side; x++)
                    {
                        var i = (y * side + x) * 3;
                        row[x * 3] = rgb[i + 2];
                        row[x * 3 + 1] = rgb[i + 1];
                        row[x * 3 + 2] = rgb[i];
                    }
                    Marshal.Copy(row, 0, data.Scan0 + y * data.Stride, row.Length);
                }
            }
            finally
            {
                image.UnlockBits(data);
            }
            using var output = new MemoryStream();
            image.Save(output, ImageFormat.Png);
            return output.ToArray();
#else
            // O Skia nao tem RGB de 24 bits: vai para RGBA opaco.
            var rgba = new byte[side * side * 4];
            for (int i = 0, j = 0; i < side * side * 3; i += 3, j += 4)
            {
                rgba[j] = rgb[i];
                rgba[j + 1] = rgb[i + 1];
                rgba[j + 2] = rgb[i + 2];
                rgba[j + 3] = 255;
            }
            using var bitmap = new SKBitmap(new SKImageInfo(side, side, SKColorType.Rgba8888, SKAlphaType.Opaque));
            Marshal.Copy(rgba, 0, bitmap.GetPixels(), rgba.Length);
            return Encode(bitmap, SKEncodedImageFormat.Png, 100);
#endif
        }

#if !WINDOWS
        private static SKBitmap Decode(byte[] bytes) =>
            SKBitmap.Decode(bytes) ?? throw new InvalidDataException("Imagem ilegível");

        /// <summary>O trecho <paramref name="source"/> de <paramref name="src"/> em width x height, com reamostragem cubica.</summary>
        private static SKBitmap Draw(SKBitmap src, SKRect source, int width, int height)
        {
            var dst = new SKBitmap(new SKImageInfo(width, height, SKColorType.Rgba8888, SKAlphaType.Premul));
            using var canvas = new SKCanvas(dst);
            canvas.Clear(SKColors.Transparent);
            using var image = SKImage.FromBitmap(src);
            canvas.DrawImage(image, source, new SKRect(0, 0, width, height), new SKSamplingOptions(SKCubicResampler.Mitchell));
            canvas.Flush();
            return dst;
        }

        private static byte[] Encode(SKBitmap bitmap, SKEncodedImageFormat format, int quality)
        {
            using var image = SKImage.FromBitmap(bitmap);
            using var data = image.Encode(format, quality);
            return data.ToArray();
        }
#endif
    }
}
