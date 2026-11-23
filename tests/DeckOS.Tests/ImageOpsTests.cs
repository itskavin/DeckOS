using System;
using System.IO;
using DeckOS.Lib;
using Xunit;

namespace DeckOS.Tests
{
    /// <summary>
    /// As operacoes de imagem nos dois caminhos: o alvo do Windows testa o GDI+, o net8.0 o Skia
    /// (o mesmo do macOS/Linux).
    /// </summary>
    public class ImageOpsTests
    {
        private static (int W, int H) PngSize(byte[] png)
        {
            Assert.Equal(new byte[] { 0x89, 0x50, 0x4E, 0x47 }, png[..4]);
            int Be(int o) => (png[o] << 24) | (png[o + 1] << 16) | (png[o + 2] << 8) | png[o + 3];
            return (Be(16), Be(20));
        }

        private static byte[] Rgb(int side)
        {
            var rgb = new byte[side * side * 3];
            for (var i = 0; i < rgb.Length; i++) rgb[i] = (byte)(i * 7);
            return rgb;
        }

        [Fact]
        public void RgbParaPng_EReducao()
        {
            var png = ImageOps.RgbToPng(Rgb(300), 300);
            Assert.Equal((300, 300), PngSize(png));

            // PNG grande vira icone de 144; PNG que ja cabe vai como esta.
            Assert.Equal((144, 144), PngSize(ImageOps.IconPng(png, 144)));
            var small = ImageOps.RgbToPng(Rgb(72), 72);
            Assert.Same(small, ImageOps.IconPng(small, 144));
        }

        [Fact]
        public void Capa_ReduzEmJpeg_ESoQuandoPassa()
        {
            var big = ImageOps.RgbToPng(Rgb(400), 400);
            var jpeg = ImageOps.ShrinkToJpeg(big, 200)!;
            Assert.Equal(0xFF, jpeg[0]);
            Assert.Equal(0xD8, jpeg[1]);
            Assert.Null(ImageOps.ShrinkToJpeg(ImageOps.RgbToPng(Rgb(100), 100), 200));
        }

        [Fact]
        public void RecorteQuadrado()
        {
            var file = Path.Combine(Path.GetTempPath(), "deckos-crop-" + Guid.NewGuid().ToString("N") + ".png");
            File.WriteAllBytes(file, ImageOps.RgbToPng(Rgb(256), 256));
            try { Assert.Equal((96, 96), PngSize(ImageOps.SquareCropPng(file, 96))); }
            finally { File.Delete(file); }
        }
    }
}
