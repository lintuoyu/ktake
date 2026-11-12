import logging
import os
import sys
import tempfile
from pathlib import Path

from separation_model_files import cached_model_file
from separation_progress import ExtractionProgress


WEIGHTS_NAME = "small_karaoke_gaboxaufr.ckpt"
WEIGHTS_URL = (
    "https://huggingface.co/GaboxR67/MelBandRoformers/resolve/"
    "48bb486bc68985ec90eeca6be5eb9003304b6a49/melbandroformers/karaoke/" + WEIGHTS_NAME
)
WEIGHTS_SHA256 = "6182fc508c0791d5a2ee4121b51f5ae9115a1bdbd209a8688b0620f4fd17fdca"
SAMPLE_RATE = 44100
STFT_HOP = 441
SEGMENT_FRAMES = 1101


def model_config():
    # Gabox / Aufr33's single-head checkpoint estimates the lead vocal.
    return {
        "audio": {"sample_rate": SAMPLE_RATE, "hop_length": STFT_HOP},
        "model": {
            "dim": 384,
            "depth": 6,
            "stereo": True,
            "num_stems": 1,
            "time_transformer_depth": 1,
            "freq_transformer_depth": 1,
            "num_bands": 60,
            "dim_head": 64,
            "heads": 8,
            "stft_n_fft": 2048,
            "stft_hop_length": STFT_HOP,
            "stft_win_length": 2048,
            "mask_estimator_depth": 2,
            "mlp_expansion_factor": 1,
        },
        "training": {"instruments": ["Vocals", "Instrumental"], "target_instrument": "Vocals"},
        "inference": {"dim_t": SEGMENT_FRAMES, "num_overlap": 1},
    }


def convert_weights(checkpoint):
    from mlx_audio_separator.separator.models.roformer.loader import load_roformer_model

    os.environ["MLX_SAVE_SAFETENSORS"] = "1"
    load_roformer_model(str(checkpoint), model_config())
    converted = checkpoint.with_suffix(".safetensors")
    if not converted.is_file():
        raise ValueError("Small Karaoke model conversion failed")
    return converted


def download_model(directory):
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=directory) as temporary:
        checkpoint = cached_model_file(Path(temporary), WEIGHTS_NAME, WEIGHTS_URL, WEIGHTS_SHA256)
        convert_weights(checkpoint).replace(directory / "model.safetensors")


def extract(source, destination, model_dir, progress_path=None):
    progress = ExtractionProgress(progress_path)
    progress.update("preparingModel")

    import mlx.core as mx
    import mlx.nn as nn
    import numpy as np
    import soundfile as sf
    from mlx_audio_separator.separator.architectures import mdxc_separator

    audio, rate = sf.read(source, dtype="float32", always_2d=True)
    if rate != SAMPLE_RATE or audio.shape[1] != 2 or len(audio) == 0:
        raise ValueError("Expected nonempty 44.1 kHz stereo audio")

    weights = model_dir / "model.safetensors"
    progress.update("loadingModel")
    config = model_config()
    # The MLX separator takes the step between chunks in seconds.
    step = STFT_HOP * (SEGMENT_FRAMES - 1) / config["inference"]["num_overlap"]
    separator = mdxc_separator.MDXCSeparator(
        common_config={
            "logger": logging.getLogger("KTake"),
            "log_level": logging.WARNING,
            "model_name": "Small Karaoke",
            "model_path": str(weights),
            "model_data": config,
            "sample_rate": rate,
        },
        arch_config={
            "segment_size": SEGMENT_FRAMES,
            "batch_size": 1,
            "overlap": (step + 0.01) / rate,
        },
    )
    # The original checkpoint has no final normalization layer.
    if "final_norm.weight" not in mx.load(str(weights)):
        separator.model_run.final_norm = nn.Identity()

    progress.update("separating")
    with progress.report_batches(mdxc_separator, "tqdm"):
        accompaniment = separator._demix_mlx(audio.T)["Instrumental"].T
    if accompaniment.shape != audio.shape or not np.isfinite(accompaniment).all():
        raise ValueError("Small Karaoke produced invalid audio")
    peak = float(np.max(np.abs(accompaniment)))
    if peak > 1:
        accompaniment /= peak
    progress.update("saving")
    sf.write(destination, accompaniment, rate, subtype="PCM_24")


if __name__ == "__main__":
    if sys.argv[1] == "--download":
        download_model(Path(sys.argv[2]))
    else:
        extract(*(Path(argument) for argument in sys.argv[1:]))
