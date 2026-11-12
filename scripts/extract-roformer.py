import os
import sys
from pathlib import Path

from separation_model_files import cached_model_file
from separation_progress import ExtractionProgress


MODEL_URL = (
    "https://huggingface.co/mlx-community/mel-roformer-kim-vocal-2-mlx/resolve/"
    "64cbfcb004e39430e5f584552c05949440ec39ce/"
)


def download_model(directory):
    files = {
        "config.json": "3300eacac960ab46933ef6df6b838eb35de1f0321db9242c1b06e6d2a6a62b58",
        "LICENSE": "1aa245b55067df5c63c847894e7040f76fa79ddde83e9e5ed8a5c29ef1865c14",
        "model.safetensors": "312c38e5b698f8dfaa4d6064e8f79010744825828917871a9d22673a43eb7fe5",
    }
    for name, checksum in files.items():
        cached_model_file(directory, name, MODEL_URL + name, checksum)


def extract(source, destination, model_dir, progress_path=None):
    progress = ExtractionProgress(progress_path)
    os.environ["HF_HUB_OFFLINE"] = "1"
    progress.update("loadingModel")
    import mlx.core as mx
    import numpy as np
    import soundfile as sf
    from mlx_audio.sts.models.mel_roformer import MelRoFormer

    audio, rate = sf.read(source, dtype="float32", always_2d=True)
    if rate != 44100 or audio.shape[1] != 2 or len(audio) == 0:
        raise ValueError("Expected nonempty 44.1 kHz stereo audio")

    model = MelRoFormer.from_pretrained(model_dir).eval()
    chunk = 352800
    hop = chunk // 2
    ramp = np.linspace(0, 1, hop, dtype=np.float32)[:, None]
    accompaniment = np.zeros_like(audio)
    for start in progress.track(range(0, max(1, len(audio) - hop), hop)):
        segment = audio[start:start + chunk]
        block = np.zeros((2, chunk), dtype=np.float32)
        block[:, :len(segment)] = segment.T
        voice = np.asarray(model(mx.array(block[None]))[0], dtype=np.float32).T
        instrumental = segment - voice[:len(segment)]
        if start:
            instrumental[:hop] *= ramp
        if start + chunk < len(audio):
            instrumental[-hop:] *= 1 - ramp
        accompaniment[start:start + len(segment)] += instrumental

    peak = float(np.max(np.abs(accompaniment)))
    if not np.isfinite(peak):
        raise ValueError("Separation produced invalid audio samples")
    if peak > 1:
        accompaniment /= peak
    sf.write(destination, accompaniment, rate, subtype="PCM_24")


if __name__ == "__main__":
    if sys.argv[1] == "--download":
        download_model(Path(sys.argv[2]))
    else:
        extract(*(Path(argument) for argument in sys.argv[1:]))
