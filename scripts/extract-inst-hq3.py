import json
import logging
import sys
from pathlib import Path

from separation_model_files import cached_model_file
from separation_progress import ExtractionProgress


MODEL_URL = (
    "https://huggingface.co/ssmall256/mlx-audio-separator/resolve/"
    "f262b68663e2fc6a9d43bd78bd78ca65cd83cd48/models/uvr-mdx-net-inst-hq3/"
)
WEIGHTS_SHA256 = "72c307239fbc415c9f3c1ef83fee38d19ac98b4b893f1a5afc4345296f48eea8"
CONFIG_SHA256 = "d8df573c2b0248e3ce77eb8f0fc3c528c9db5368f38335e249e25e05e84415ba"


def download_model(directory):
    cached_model_file(directory, "config.json", MODEL_URL + "config.json", CONFIG_SHA256)
    cached_model_file(directory, "model.safetensors", MODEL_URL + "model.safetensors", WEIGHTS_SHA256)


def extract(source, destination, model_dir, progress_path=None):
    progress = ExtractionProgress(progress_path)
    progress.update("preparingModel")
    import numpy as np
    import soundfile as sf

    audio, rate = sf.read(source, dtype="float32", always_2d=True)
    if rate != 44100 or audio.shape[1] != 2 or len(audio) == 0:
        raise ValueError("Expected nonempty 44.1 kHz stereo audio")

    weights = model_dir / "model.safetensors"
    config = model_dir / "config.json"
    progress.update("loadingModel")
    from mlx_audio_separator.separator.architectures import mdx_separator

    separator = mdx_separator.MDXSeparator(
        common_config={
            "logger": logging.getLogger("KTake"),
            "log_level": logging.WARNING,
            "model_name": "Inst HQ 3",
            "model_path": str(weights),
            "model_data": json.loads(config.read_text(encoding="utf-8")),
            "sample_rate": rate,
        },
        arch_config={"segment_size": 256, "overlap": 0.25},
    )
    # This checkpoint predicts the instrumental stem directly.
    with progress.report_batches(mdx_separator, "tqdm"):
        accompaniment = separator.demix(audio.T).T
    peak = float(np.max(np.abs(accompaniment)))
    if accompaniment.shape != audio.shape or not np.isfinite(peak):
        raise ValueError("Inst HQ 3 produced invalid audio")
    if peak > 1:
        accompaniment /= peak
    sf.write(destination, accompaniment, rate, subtype="PCM_24")


if __name__ == "__main__":
    if sys.argv[1] == "--download":
        download_model(Path(sys.argv[2]))
    else:
        extract(*(Path(argument) for argument in sys.argv[1:]))
