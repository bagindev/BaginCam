"""
convert_sr.py - Real-ESRGAN realesr-general-x4v3 (SRVGGNetCompact, BSD-3) -> Core ML.

Dijalankan di GitHub Actions macOS (workflow convert-sr-model.yml) karena coremltools +
coremlcompiler butuh macOS. Bisa juga dipakai lokal (Windows) hanya untuk cek arsitektur:
  python convert_sr.py --check realesr-general-x4v3.pth

Output: BaginCamSR_x4_256.mlpackage  (input "input" RGB 256x256, output "output" RGB 1024x1024)
"""
import argparse

import torch
import torch.nn as nn
import torch.nn.functional as F

TILE = 256
SCALE = 4


class SRVGGNetCompact(nn.Module):
    """arsitektur identik dengan basicsr/archs/srvgg_arch.py (Real-ESRGAN)"""

    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32, upscale=4):
        super().__init__()
        self.upscale = upscale
        self.body = nn.ModuleList()
        self.body.append(nn.Conv2d(num_in_ch, num_feat, 3, 1, 1))
        self.body.append(nn.PReLU(num_parameters=num_feat))
        for _ in range(num_conv):
            self.body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            self.body.append(nn.PReLU(num_parameters=num_feat))
        self.body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out)
        return out + F.interpolate(x, scale_factor=self.upscale, mode="nearest")


class Wrapper(nn.Module):
    """input 0..1 (ImageType scale 1/255) -> output 0..255 untuk ImageType keluaran"""

    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, x):
        return torch.clamp(self.net(x) * 255.0, 0.0, 255.0)


def load(path):
    sd = torch.load(path, map_location="cpu", weights_only=True)
    for key in ("params_ema", "params"):
        if isinstance(sd, dict) and key in sd:
            sd = sd[key]
            break
    net = SRVGGNetCompact()
    net.load_state_dict(sd, strict=True)
    return net.eval()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("weights")
    ap.add_argument("--check", action="store_true", help="hanya cek load + forward (tanpa coremltools)")
    ap.add_argument("--out", default="BaginCamSR_x4_256.mlpackage")
    args = ap.parse_args()

    net = load(args.weights)
    n_params = sum(p.numel() for p in net.parameters())
    x = torch.rand(1, 3, 64, 64)
    with torch.no_grad():
        y = net(x)
    print(f"OK: {n_params/1e6:.2f} M parameter, forward {list(x.shape)} -> {list(y.shape)}")
    if args.check:
        return

    import coremltools as ct
    model = Wrapper(net).eval()
    example = torch.rand(1, 3, TILE, TILE)
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="input", shape=example.shape, scale=1 / 255.0,
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )
    mlmodel.short_description = "BaginCam AI Zoom: Real-ESRGAN realesr-general-x4v3 (BSD-3-Clause), tile 256 -> 1024"
    mlmodel.author = "Real-ESRGAN (Xintao Wang et al.), converted for BaginCam"
    mlmodel.license = "BSD-3-Clause"
    mlmodel.save(args.out)
    print("tersimpan:", args.out)

    # verifikasi: Core ML (fp16) vs PyTorch pada gambar uji bertekstur
    import numpy as np
    from PIL import Image
    yy, xx = np.mgrid[0:TILE, 0:TILE]
    img = np.stack([128 + 100 * np.sin(xx / 5.0), 128 + 100 * np.cos(yy / 7.0),
                    128 + 100 * np.sin((xx + yy) / 3.0)], -1).clip(0, 255).astype(np.uint8)
    pred = mlmodel.predict({"input": Image.fromarray(img)})["output"]
    got = np.asarray(pred.convert("RGB"), dtype=np.float32)
    with torch.no_grad():
        ref = model(torch.from_numpy(img).permute(2, 0, 1)[None].float() / 255.0)[0].permute(1, 2, 0).numpy()
    mse = float(np.mean((got - ref) ** 2))
    psnr = 10 * np.log10(255.0 ** 2 / max(mse, 1e-9))
    print(f"verifikasi Core ML vs PyTorch: PSNR {psnr:.1f} dB (harus > 35)")
    if psnr < 35:
        raise SystemExit("hasil Core ML berbeda jauh dari PyTorch")


if __name__ == "__main__":
    main()
